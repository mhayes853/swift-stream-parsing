import Foundation

@testable import StreamParsingCore

// Recorders for storage: what a `StreamString`, a `StreamArray` and a `StreamDictionary` actually
// look like while they fill.
//
// These read the values' own stored properties after every append, so the block capacities the
// animation draws are the capacities the type chose, and the schedule constants come off the type
// rather than out of this file.

enum StorageTraces {
  // MARK: - StreamString

  /// A real `StreamString` fed chunks the size the parser feeds them, read back after each one.
  ///
  /// `streamAppend(utf8:)` is the same entry point `PartialSink` uses for a `.streamString`
  /// member, so the ramp recorded here is the ramp a parse produces.
  static func streamString(chunks: [String]) -> StreamStringTrace {
    var value = StreamString()
    var steps: [StreamStringTrace.Step] = []
    var written: [UInt8] = []

    // The empty value as it starts, read off it rather than written down: the tail's capacity here
    // is the first block the schedule will ask for.
    steps.append(
      StreamStringTrace.Step(
        chunk: "", chunkBytes: 0, inlineCount: value.inlineCount, blocks: [],
        tailCount: value.tail.count, tailCapacity: value.tailBlockCapacity,
        utf8Count: value.utf8Count, event: "inline"))

    for chunk in chunks {
      let bytes = Array(chunk.utf8)
      let blocksBefore = value.blocks.count
      let inlineBefore = value.usesInlineStorage
      bytes.withUnsafeBufferPointer { buffer in _ = value.streamAppend(utf8: buffer.span) }
      written.append(contentsOf: bytes)

      // Which of the four things this append did, decided by what changed rather than by the size
      // of the chunk: the inline buffer overflowed, a block sealed, or neither.
      let event: String
      if inlineBefore && !value.usesInlineStorage {
        event = "promote"
      } else if value.blocks.count > blocksBefore {
        event = "seal"
      } else if value.usesInlineStorage {
        event = "inline"
      } else {
        event = "append"
      }

      steps.append(
        StreamStringTrace.Step(
          chunk: chunk, chunkBytes: bytes.count,
          inlineCount: value.usesInlineStorage ? value.inlineCount : 0,
          blocks: value.blocks.map(\.count), tailCount: value.tail.count,
          tailCapacity: value.tailBlockCapacity, utf8Count: value.utf8Count, event: event))
    }

    // The closed-form locate, called on the shipped value: one `clz` inside the doubling ramp and
    // a shift past it, rather than a search over prefix sums.
    let sealed = value.sealedCount
    var locate: [StreamStringTrace.Locate] = []
    let probes = [0, 1, sealed / 4, sealed - 1, sealed, value.utf8Count - 1]
    for position in Set(probes).sorted() where position >= 0 && position < value.utf8Count {
      if position >= sealed {
        locate.append(
          StreamStringTrace.Locate(
            position: position, block: value.blocks.count, offset: position - sealed,
            byte: value.utf8[position], region: "tail"))
      } else {
        let found = value.sealedPosition(of: position)
        locate.append(
          StreamStringTrace.Locate(
            position: position, block: found.block, offset: found.offset,
            byte: value.utf8[position], region: "sealed"))
      }
    }

    // The reader has to hand back what went in, and every locate has to name a byte that agrees
    // with the block it points into.
    let verified =
      value.utf8Count == written.count
      && written.indices.allSatisfy { value.utf8[$0] == written[$0] }
      && locate.filter { $0.region == "sealed" }.allSatisfy {
        value.blocks[$0.block][$0.offset] == $0.byte
      }

    return StreamStringTrace(
      inlineCapacity: StreamString.inlineCapacity, firstBlockCapacity: StreamString.blockCapacity,
      maximumBlockCapacity: 1 << StreamString.maximumBlockShift, steps: steps, locate: locate,
      verified: verified)
  }

  // MARK: - StreamArray and StreamDictionary

  static func collections(elements: Int, keys: [String]) -> CollectionTrace {
    var verified = true

    // The array, filled through `_openElement`: the parser's own entry point, which is what puts
    // the element being parsed outside the blocked storage until it commits.
    //
    // A snapshot -- a plain value copy -- is taken partway through and held for the rest of the
    // fill, because the thing worth showing about the blocks is what does *not* happen: the
    // filling block is written past rather than diverged from, so its object identity survives
    // every append made while the copy is alive. `sharedTail` is that identity compared against
    // the snapshot's, read off the shipped values rather than asserted here.
    var array = StreamArray<Int>()
    var arraySteps: [CollectionTrace.ArrayStep] = []
    let snapshotAt = elements / 2
    var snapshot: StreamArray<Int>?
    var snapshotBlock: ObjectIdentifier?
    var blockCopiedWhileShared = false

    func tailIdentity(_ value: StreamArray<Int>) -> ObjectIdentifier? {
      value.tail.map(ObjectIdentifier.init)
    }

    for index in 0..<elements {
      // Opening an element is what commits the previous one; a commit that fills the tail seals a
      // block, and one that fills the small first tail promotes it to a full-sized one. The event
      // is decided by what the open did to the storage, not by counting.
      let sealedBefore = array.blocks.count
      let capacityBefore = array.tail?.slotCapacity ?? 0
      _ = array._openElement(index)
      let capacity = array.tail?.slotCapacity ?? 0
      let event: String
      if array.blocks.count > sealedBefore {
        event = "seal"
      } else if capacityBefore != 0 && capacity != capacityBefore {
        event = "grow"
      } else {
        event = "open"
      }
      let shared = snapshotBlock != nil && tailIdentity(array) == snapshotBlock
      // A block copy while the snapshot holds it would show up here as the identity changing under
      // a plain append. A seal or a promotion changes it too, and legitimately -- the filling block
      // has moved on and the snapshot's is behind it -- so those stop the check rather than fail it.
      if snapshotBlock != nil, event == "open", !shared { blockCopiedWhileShared = true }
      if event != "open" { snapshotBlock = nil }
      arraySteps.append(
        CollectionTrace.ArrayStep(
          index: index, value: index, blocks: array.blocks.map(\.count), tailCount: array.tailCount,
          tailCapacity: capacity, pending: array.pending, count: array.count, sharedTail: shared,
          event: event))
      if index == snapshotAt {
        snapshot = array
        snapshotBlock = tailIdentity(array)
      }
    }
    // Nothing follows the last element, so its commit is the drain the parser does at the close.
    array.drainPending()
    arraySteps.append(
      CollectionTrace.ArrayStep(
        index: elements - 1, value: elements - 1, blocks: array.blocks.map(\.count),
        tailCount: array.tailCount, tailCapacity: array.tail?.slotCapacity ?? 0,
        pending: array.pending, count: array.count,
        sharedTail: snapshotBlock != nil && tailIdentity(array) == snapshotBlock, event: "commit"))
    verified = verified && array.count == elements && (0..<elements).allSatisfy { array[$0] == $0 }

    // The snapshot has to have stayed exactly what it was when it was taken -- the open element
    // it captured included -- while every append above went into the block it shares.
    let held = snapshot ?? StreamArray<Int>()
    verified =
      verified && held.count == snapshotAt + 1 && (0..<held.count).allSatisfy { held[$0] == $0 }
      && !blockCopiedWhileShared

    // The dictionary, filled through `_openValue`: the same call the sink makes for a dynamic key.
    var dictionary = StreamDictionary<Int>()
    var dictSteps: [CollectionTrace.DictStep] = []
    for (index, key) in keys.enumerated() {
      let keyBytes = Array(key.utf8)
      let hash = keyBytes.withUnsafeBufferPointer { StreamDictionary<Int>.hash($0) }
      keyBytes.withUnsafeBufferPointer { buffer in
        _ = dictionary._openValue(forKey: buffer.span, initial: index)
      }
      dictSteps.append(
        CollectionTrace.DictStep(
          key: key, hash: traceHex(hash), entryCount: dictionary.entries.count,
          storedValueCount: dictionary.storedValues.count, tableCount: dictionary.table?.count ?? 0,
          pendingSlot: dictionary.pendingSlot,
          event: dictionary.table != nil && dictSteps.last?.tableCount == 0 ? "index" : "open"))
    }
    dictionary.drainPending()
    let slots = dictionary.table.map { Array($0) } ?? []

    // Probes through the shipped lookup, with the probe chain recorded alongside it. A miss walks
    // to the first empty bucket, which is what bounds the chain.
    var lookups: [CollectionTrace.Lookup] = []
    for key in keys.prefix(2) + ["absent"] {
      let keyBytes = Array(key.utf8)
      var buckets: [Int] = []
      var slot: Int32?
      var hash: UInt64 = 0
      keyBytes.withUnsafeBufferPointer { buffer in
        hash = StreamDictionary<Int>.hash(buffer)
        if let table = dictionary.table {
          let mask = table.count - 1
          var probe = Int(hash & UInt64(mask))
          while buckets.count <= table.count {
            buckets.append(probe)
            let candidate = table[probe]
            if candidate < 0 { break }
            if dictionary.entries[Int(candidate)].hash == hash { break }
            probe = (probe &+ 1) & mask
          }
        } else {
          buckets = Array(0..<dictionary.entries.count)
        }
        slot = dictionary.slot(forKey: buffer, hash: hash)
      }
      lookups.append(
        CollectionTrace.Lookup(
          key: key, hash: traceHex(hash), buckets: buckets, slot: slot ?? -1, found: slot != nil))
      // The recorded chain has to end where the shipped lookup ended.
      if let slot, let table = dictionary.table, let bucket = buckets.last, table[bucket] != slot {
        verified = false
      }
      if (slot != nil) != keys.contains(key) { verified = false }
    }
    verified =
      verified && dictionary.count == keys.count
      && keys.enumerated().allSatisfy { dictionary[$0.element] == $0.offset }

    return CollectionTrace(
      array: CollectionTrace.ArrayTrace(
        blockCapacity: StreamArray<Int>.blockCapacity,
        initialTailCapacity: StreamArray<Int>.initialTailCapacity, snapshotAfter: snapshotAt,
        steps: arraySteps),
      dictionary: CollectionTrace.DictionaryTrace(
        indexThreshold: StreamDictionary<Int>.indexThreshold, steps: dictSteps, slots: slots,
        lookups: lookups), verified: verified)
  }
}
