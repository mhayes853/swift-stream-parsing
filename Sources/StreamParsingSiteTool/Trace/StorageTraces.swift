import Foundation

@testable import StreamParsingCore

// Recorders for storage: what a `StreamString`, a `StreamArray` and a `StreamDictionary` actually
// look like while they fill.
//
// These read the values' own stored properties after every append, so the block capacities the
// animation draws are the capacities the type chose, and the schedule constants come off the type
// rather than out of this file.

enum StorageTraces {
  private static func hex(_ value: UInt64) -> String {
    "0x" + String(value, radix: 16, uppercase: true)
  }

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
        utf8Count: value.utf8Count, event: "inline"
      )
    )

    for chunk in chunks {
      let bytes = Array(chunk.utf8)
      let blocksBefore = value.blocks.count
      let inlineBefore = value.usesInlineStorage
      bytes.withUnsafeBufferPointer { buffer in
        _ = value.streamAppend(utf8: buffer.span)
      }
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
          chunk: chunk,
          chunkBytes: bytes.count,
          inlineCount: value.usesInlineStorage ? value.inlineCount : 0,
          blocks: value.blocks.map(\.count),
          tailCount: value.tail.count,
          tailCapacity: value.tailBlockCapacity,
          utf8Count: value.utf8Count,
          event: event
        )
      )
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
            byte: value.utf8[position], region: "tail"
          )
        )
      } else {
        let found = value.sealedPosition(of: position)
        locate.append(
          StreamStringTrace.Locate(
            position: position, block: found.block, offset: found.offset,
            byte: value.utf8[position], region: "sealed"
          )
        )
      }
    }

    // The reader has to hand back what went in, and every locate has to name a byte that agrees
    // with the block it points into.
    var verified = value.utf8Count == written.count
    if verified {
      for index in 0..<written.count where value.utf8[index] != written[index] { verified = false }
    }
    for entry in locate where entry.region == "sealed" {
      if value.blocks[entry.block][entry.offset] != entry.byte { verified = false }
    }

    return StreamStringTrace(
      inlineCapacity: StreamString.inlineCapacity,
      firstBlockCapacity: StreamString.blockCapacity,
      maximumBlockCapacity: 1 << StreamString.maximumBlockShift,
      steps: steps,
      locate: locate,
      verified: verified
    )
  }

  // MARK: - StreamArray and StreamDictionary

  static func collections(elements: Int, keys: [String]) -> CollectionTrace {
    var verified = true

    // The array, filled through `_openElement`: the parser's own entry point, which is what puts
    // the element being parsed outside the blocked storage until it commits.
    var array = StreamArray<Int>()
    var arraySteps: [CollectionTrace.ArrayStep] = []
    for index in 0..<elements {
      // Opening an element is what commits the previous one, and a commit that fills the tail is
      // what seals a block -- so the event is decided by what the open did, not by counting.
      let sealedBefore = array.blocks.count
      _ = array._openElement(index)
      arraySteps.append(
        CollectionTrace.ArrayStep(
          index: index, value: index, blocks: array.blocks.map(\.count),
          tailCount: array.tail.count, tailCapacity: array.tail.capacity,
          pending: array.pending, count: array.count,
          event: array.blocks.count > sealedBefore ? "seal" : "open"
        )
      )
    }
    // Nothing follows the last element, so its commit is the drain the parser does at the close.
    array.drainPending()
    arraySteps.append(
      CollectionTrace.ArrayStep(
        index: elements - 1, value: elements - 1, blocks: array.blocks.map(\.count),
        tailCount: array.tail.count, tailCapacity: array.tail.capacity,
        pending: array.pending, count: array.count, event: "commit"
      )
    )
    if array.count != elements { verified = false }
    for index in 0..<elements where array[index] != index { verified = false }

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
          key: key, hash: Self.hex(hash), entryCount: dictionary.entries.count,
          storedValueCount: dictionary.storedValues.count,
          tableCount: dictionary.table?.count ?? 0, pendingSlot: dictionary.pendingSlot,
          event: dictionary.table != nil && dictSteps.last?.tableCount == 0 ? "index" : "open"
        )
      )
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
          key: key, hash: Self.hex(hash), buckets: buckets, slot: slot ?? -1, found: slot != nil
        )
      )
      // The recorded chain has to end where the shipped lookup ended.
      if let slot, dictionary.table != nil, buckets.last != nil,
        dictionary.table![buckets.last!] != slot
      {
        verified = false
      }
      if (slot != nil) != keys.contains(key) { verified = false }
    }
    if dictionary.count != keys.count { verified = false }
    for (index, key) in keys.enumerated() where dictionary[key] != index { verified = false }

    return CollectionTrace(
      array: CollectionTrace.ArrayTrace(
        blockCapacity: StreamArray<Int>.blockCapacity,
        initialTailCapacity: StreamArray<Int>.initialTailCapacity,
        steps: arraySteps
      ),
      dictionary: CollectionTrace.DictionaryTrace(
        indexThreshold: StreamDictionary<Int>.indexThreshold,
        steps: dictSteps,
        slots: slots,
        lookups: lookups
      ),
      verified: verified
    )
  }
}
