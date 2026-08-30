// A `StreamFrame` whose schema is borrowed rather than owned.
//
// The sink lowers to this the moment it receives a frame and never stores a `StreamFrame`, so the
// frame stack, the pending dictionary frame and the scalar target stop retaining. `StreamFrame`
// itself is unchanged: a schema handed across the public API is an ordinary strong reference, and
// only the sink's internal copies borrow.
//
// This is trivial, so pushing and popping a frame is a store and a decrement rather than an ARC
// pair, and `deinitialize` on the stack is a no-op.
//
// Sound only while every schema a frame can carry outlives the parse. That already holds: an
// object or container field's schema is the `private static let` its parent hoists, an element or
// value schema is captured by the container schema that produced it, the root's is
// `rootSchema`, and an ignored subtree's is `ignoredStreamSchema`. `StreamSchemaBorrowAudit`
// checks it in debug builds rather than trusting it.
@usableFromInline
struct BorrowedFrame {
  @usableFromInline var storage: UnsafeMutableRawPointer
  @usableFromInline unowned(unsafe) var schema: StreamSchema
  @usableFromInline var pendingField: Int32
  // Occupies padding the 24-byte frame already had. Copying the schema's precomputed byte when a
  // container opens keeps ordinary object scalars from chasing cold leaf metadata merely to
  // reject a fast route.
  @usableFromInline var leafRoute: _StreamLeafRoute

  @usableFromInline
  init(storage: UnsafeMutableRawPointer, schema: StreamSchema, pendingField: Int32 = -1) {
    self.storage = storage
    self.schema = schema
    self.pendingField = pendingField
    self.leafRoute = .generic
  }

  @usableFromInline
  init(borrowing frame: StreamFrame) {
    self.storage = frame.storage
    self.schema = frame.schema
    self.pendingField = frame.pendingField
    self.leafRoute = .generic
  }
}

// Embedded Swift has no `weak`, so the audit compiles out there along with the calls to it. That
// is not a gap worth closing: a schema without a durable owner is a mistake a conformance makes,
// and it is caught by any non-Embedded debug build of the same conformance.
#if DEBUG && !hasFeature(Embedded)
  // Whether the schemas the sink borrowed outlived the frames that borrowed them.
  //
  // A schema whose only owner is the frame it arrived in is deallocated the instant that frame is
  // lowered, and every later use of it is a use after free — the failure this design trades safety
  // for, and one that otherwise surfaces as a crash somewhere with nothing pointing back at the
  // cause. A hand written `enterField` that builds its schema on the spot is how it happens.
  //
  // A weak reference is the test rather than a refcount. `isKnownUniquelyReferenced` at the borrow
  // depends on whether the caller's temporary is still alive, which differs between -Onone and -O,
  // so it both false-positives and false-negatives. Deallocation is the thing that actually
  // matters, and a weak reference reports exactly that.
  //
  // Per sink rather than global, so there is no shared mutable state to race on and the identity
  // of a schema that died is still in hand when the report is made.
  @usableFromInline
  struct StreamSchemaBorrowAudit {
    @usableFromInline
    struct Borrow {
      @usableFromInline weak var schema: StreamSchema?
      @usableFromInline let identity: ObjectIdentifier

      @usableFromInline
      init(_ schema: StreamSchema) {
        self.schema = schema
        self.identity = ObjectIdentifier(schema)
      }
    }

    @usableFromInline var borrows: [Borrow] = []

    @usableFromInline
    init() {}

    // One entry per distinct schema, not per frame: a document enters the same schema once per
    // occurrence and there are only ever a handful of them.
    @usableFromInline
    mutating func record(_ schema: StreamSchema) {
      let identity = ObjectIdentifier(schema)
      guard !self.borrows.contains(where: { $0.identity == identity }) else { return }
      self.borrows.append(Borrow(schema))
    }

    @usableFromInline
    func verify() {
      for borrow in self.borrows where borrow.schema == nil {
        preconditionFailure(
          """
          A StreamFrame's schema was deallocated while the sink still borrowed it, which means the \
          frame was its only owner. Schema \(borrow.identity) has to be stored somewhere that \
          outlives the parse — the `private static let` the macro hoists onto the enclosing \
          Partial, or a stored `let` next to the conformance that builds it.
          """
        )
      }
    }
  }
#endif

// Routes parse events into a value described by a StreamSchema.
//
// Frames point into the value being built. Only the innermost open container is ever mutated,
// so an element pointer stays valid for that element's lifetime: appending to an outer array
// cannot happen while an inner one is open.
public struct PartialSink<Root>: ~Copyable, StreamParseSink {
  public private(set) var streamFailure: StreamSinkFailure?

  @usableFromInline var root: UnsafeMutableRawPointer
  @usableFromInline var rootSchema: StreamSchema
  @usableFromInline var started = false
  // Cached from the top frame in padding next to `started`, so the common scalar route tests a
  // fixed byte rather than calling out to rediscover the top frame and its schema.
  @usableFromInline var activeLeafRoute: _StreamLeafRoute = .generic
  @usableFromInline var pendingDictionaryFrame: BorrowedFrame?
  @usableFromInline var pendingDictionaryStorage: UnsafeMutableRawPointer?

  // The frame stack, one fixed allocation rather than an `Array`.
  //
  // The parser caps depth at `JSONParser.maximumDepth` and rejects anything past it, so the stack
  // has a known bound and never grows. What that buys is not the allocation — there was one either
  // way — but the bookkeeping `Array` charges to be resizable: a uniqueness check on every
  // mutation and a bounds check on every read, both of which `key(_:)` used to pay per key, since
  // it read the top frame out, edited it and wrote it back. A key now edits the top frame where it
  // sits.
  //
  // Capacity is the cap plus one because the cap is checked *after* the sink is told the container
  // opened: `consumeStructural` calls `beginObject` and then `push`, so the frame for the rejected
  // depth arrives before the parse throws.
  @usableFromInline let frames: UnsafeMutablePointer<BorrowedFrame>
  @usableFromInline var frameCount = 0

  // Frames there was no room for. A container that could not be pushed must not pop one that
  // could, and a caller that catches the depth error and keeps feeding gets more `beginObject`
  // calls after it, so overflow has to stay balanced rather than merely not crash once.
  @usableFromInline var droppedFrameCount = 0

  #if DEBUG && !hasFeature(Embedded)
    @usableFromInline var audit = StreamSchemaBorrowAudit()
  #endif

  // Lowers a frame the schema handed back, recording the borrow so a debug build can tell whether
  // the schema outlives it.
  @usableFromInline
  mutating func borrow(_ frame: StreamFrame) -> BorrowedFrame {
    #if DEBUG && !hasFeature(Embedded)
      self.audit.record(frame.schema)
    #endif
    return BorrowedFrame(borrowing: frame)
  }

  @usableFromInline
  static var frameCapacity: Int { JSONParser.maximumDepth + 1 }

  // A document whose root is an array, a dictionary or a bare scalar is as valid as one rooted
  // in an object, so the root's shape comes from its schema rather than from a constraint.
  public init(root: UnsafeMutablePointer<Root>, schema: StreamSchema) {
    self.root = UnsafeMutableRawPointer(root)
    self.rootSchema = schema
    self.frames = .allocate(capacity: Self.frameCapacity)
  }

  deinit {
    self.frames.deinitialize(count: self.frameCount)
    self.frames.deallocate()
  }

  // MARK: Frame stack

  @usableFromInline
  var topFrame: UnsafeMutablePointer<BorrowedFrame>? {
    self.frameCount > 0 ? self.frames + (self.frameCount &- 1) : nil
  }

  @usableFromInline
  mutating func pushFrame(_ initialFrame: BorrowedFrame) {
    #if DEBUG && !hasFeature(Embedded)
      self.audit.verify()
    #endif
    guard self.frameCount < Self.frameCapacity else {
      self.droppedFrameCount &+= 1
      self.recordFailure(.depthExceeded)
      return
    }
    var frame = initialFrame
    frame.leafRoute = frame.schema.leafRoute
    if frame.leafRoute.usesFrameElementIndex {
      // Objects use this field for a matched member. A fixed-width array has no keys, so the same
      // four bytes are its element cursor without increasing the 24-byte frame.
      frame.pendingField = 0
    }
    (self.frames + self.frameCount).initialize(to: frame)
    self.frameCount &+= 1
    self.activeLeafRoute = frame.leafRoute
  }

  @usableFromInline
  mutating func popFrame() {
    guard self.droppedFrameCount == 0 else {
      self.droppedFrameCount &-= 1
      return
    }
    guard self.frameCount > 0 else { return }
    self.frameCount &-= 1
    (self.frames + self.frameCount).deinitialize(count: 1)
    self.activeLeafRoute = self.frameCount == 0
      ? .generic
      : (self.frames + (self.frameCount &- 1)).pointee.leafRoute
  }

  // MARK: Containers

  mutating func beginObject() {
    self.enterContainer(shape: .object)
  }

  mutating func beginArray() {
    switch self.activeLeafRoute {
    case .arraySIMD2Double, .arraySIMD3Double, .arraySIMD4Double,
      .arrayOptionalSIMD2Double, .arrayOptionalSIMD3Double, .arrayOptionalSIMD4Double:
      self.openKnownSIMDDoubleElement(self.activeLeafRoute)
      return
    default:
      break
    }
    self.enterContainer(shape: .array)
  }

  mutating func endObject() {
    self.popFrame()
  }

  mutating func endArray() {
    if self.droppedFrameCount == 0 {
      let expected: Int32
      if self.activeLeafRoute == .inlineArray {
        expected = self.topFrame?.pointee.schema.fixedElementCount ?? -1
      } else {
        let lanes = self.activeLeafRoute.fixedSIMDLaneCount
        expected = lanes == 0 ? -1 : lanes
      }
      if expected >= 0, self.topFrame?.pointee.pendingField != expected {
        self.recordFailure(.typeMismatch)
      }
    }
    self.popFrame()
  }

  private mutating func enterContainer(shape: StreamSchema.Shape) {
    guard self.started else {
      self.started = true
      let canHoldContainer = self.rootSchema.shape.canHold(container: shape)
      if !canHoldContainer { self.recordFailure(.typeMismatch) }
      if canHoldContainer { self.rootSchema.prepareRoot(self.root) }
      let schema = canHoldContainer ? self.rootSchema : Self.ignoredSchema
      self.pushFrame(BorrowedFrame(storage: self.root, schema: schema))
      return
    }

    let hasKnownDestination = self.hasKnownValueDestination
    guard let target = self.valueTarget() else {
      // A container under an unknown object key is ignored. Every other missing target describes
      // a known destination whose schema cannot accept a container.
      if hasKnownDestination { self.recordFailure(.typeMismatch) }
      self.pushFrame(BorrowedFrame(storage: self.root, schema: Self.ignoredSchema))
      return
    }
    guard target.schema.shape.canHold(container: shape) else {
      self.recordFailure(.typeMismatch)
      self.pushFrame(BorrowedFrame(storage: self.root, schema: Self.ignoredSchema))
      return
    }
    self.pushFrame(target)
  }

  private var hasKnownValueDestination: Bool {
    guard let top = self.topFrame else { return false }
    switch top.pointee.schema.shape {
    case .array: return true
    case .object: return top.pointee.pendingField >= 0
    case .dictionary:
      return self.pendingDictionaryStorage != nil || self.pendingDictionaryFrame != nil
    case .scalar: return true
    }
  }

  // Produces the frame a value should be written through, appending an array element first when
  // the enclosing container is an array. Whether the frame can hold the value that arrives is the
  // caller's question, not this one's: a scalar frame is the right answer for a scalar and the
  // wrong one for a container.
  private mutating func valueTarget() -> BorrowedFrame? {
    guard let top = self.topFrame else { return nil }
    switch top.pointee.schema.shape {
    case .array:
      let indexed = top.pointee.leafRoute == .inlineArray
      let index = indexed ? top.pointee.pendingField : -1
      if indexed, index >= top.pointee.schema.fixedElementCount {
        // More elements than the fixed array declares: bounded storage overflowing, the same
        // failure an inline string reports when a value outruns its capacity. An array that
        // closes *short* of its arity is still a mismatch, checked in `endArray`.
        self.recordFailure(.capacityExceeded)
        return nil
      }
      guard let frame = top.pointee.schema.appendElement(top.pointee.storage, index) else {
        if indexed { self.recordFailure(.capacityExceeded) }
        return nil
      }
      if indexed { top.pointee.pendingField = index &+ 1 }
      return self.borrow(frame)
    case .object:
      guard top.pointee.pendingField >= 0 else { return nil }
      var field = top.pointee.pendingField
      if top.pointee.schema.keyRouting == .table {
        let entry = top.pointee.schema.fieldEntries.unsafelyUnwrapped + Int(field)
        // A scalar member cannot hold a container; the caller reads nil against a known
        // destination as the mismatch it is.
        guard entry.pointee.kind == .container else { return nil }
        field = entry.pointee.index
      }
      guard let frame = top.pointee.schema.enterField(top.pointee.storage, field) else {
        return nil
      }
      return self.borrow(frame)
    case .dictionary:
      defer { self.pendingDictionaryFrame = nil }
      return self.pendingDictionaryFrame
    case .scalar:
      return nil
    }
  }

  // MARK: Keys

  // One load and one switch over the routing the schema precomputed. The `ignore` case is the one
  // worth having: a schema with no matcher answers -1 to every key, and reaching that answer
  // through the closure costs the load, the retain, the indirect call and the release that any
  // other schema call costs. The frames standing over subtrees the destination has no field for
  // are exactly those schemas, and they see most of the keys in a document a model only partly
  // declares — 52% of `twitter.json`'s.
  mutating func key(_ bytes: Span<UInt8>) {
    guard let top = self.topFrame else { return }
    // Read through the frame each time rather than bound to a local. A local outlives the call it
    // is passed to, and `enterKey` takes the frame's own storage, so the optimizer has to keep the
    // schema alive across it — which is a retain, and cost one per entry on the dictionary path.
    // Read in place it is a borrow, and the loads fold.
    switch top.pointee.schema.keyRouting {
    case .table:
      top.pointee.pendingField = Self.matchTable(top, bytes)
    case .match:
      top.pointee.pendingField = top.pointee.schema.matchField(bytes)
    case .dictionary:
      switch self.activeLeafRoute {
      case .dictionaryStreamString, .dictionaryOptionalStreamString,
        .dictionaryBool, .dictionaryOptionalBool:
        self.pendingDictionaryStorage = self.openKnownDictionaryValue(
          top.pointee.storage, route: self.activeLeafRoute, forKey: bytes
        )
        self.pendingDictionaryFrame = nil
        return
      default:
        break
      }
      // The key span does not outlive this call, so the value's frame is resolved now rather
      // than remembered and resolved when the value arrives.
      self.pendingDictionaryFrame = top.pointee.schema.enterKey(top.pointee.storage, bytes)
        .map { self.borrow($0) }
    case .ignore:
      top.pointee.pendingField = -1
    }
  }

  // MARK: Scalars

  mutating func stringBegin() {
    switch self.activeLeafRoute {
    case .arrayStreamString, .arrayOptionalStreamString,
      .dictionaryStreamString, .dictionaryOptionalStreamString:
      self.homogeneousStringStorage = self.openKnownStreamStringTarget(self.activeLeafRoute)
      self.scalarTarget = nil
      return
    case .simd2Number, .simd3Number, .simd4Number,
      .simd2Double, .simd3Double, .simd4Double,
      .optionalSIMD2Double, .optionalSIMD3Double, .optionalSIMD4Double:
      self.scalarTarget = nil
      self.recordFailure(.typeMismatch)
      return
    default:
      break
    }
    let target = self.resolveScalarTarget()
    self.scalarTarget = target
    guard let target else { return }
    if let entry = target.entry {
      // A table member: materialised and reserved here, appended to in place by the chunks.
      let result = self.openTableString(entry, target.storage)
      if result != .applied {
        self.scalarTarget = nil
        self.recordFailure(Self.failureReason(for: result))
      }
      return
    }
    // The empty span both materializes the destination and settles whether it accepts strings at
    // all, so a mismatch is reported at the opening quote rather than at the first chunk.
    let result = withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 1) { buffer in
      let empty = UnsafeBufferPointer(start: buffer.baseAddress, count: 0)
      return target.schema.applyString(target.storage, target.field, Span(_unsafeElements: empty))
    }
    if result != .applied {
      self.scalarTarget = nil
      self.recordFailure(Self.failureReason(for: result))
      return
    }
    // Bounded inline storage is recognized here rather than through a container route, because
    // the resolved target is the same shape whether the destination is a scalar field, an array
    // element or a dictionary value -- one route covers all three, and none of them requires the
    // sink to know which `StreamInlineString` capacity it is writing into.
    self.inlineStringCapacity = target.schema.leafRoute == .valueInlineString
      ? target.schema.inlineCapacity
      : 0
  }

  mutating func stringChunk(_ bytes: Span<UInt8>) {
    if let storage = self.homogeneousStringStorage {
      storage.assumingMemoryBound(to: StreamString.self).pointee.streamAppend(utf8: bytes)
      return
    }
    guard let target = self.scalarTarget else { return }
    if self.inlineStringCapacity != 0 {
      let result = _streamInlineStringAppend(
        target.storage, capacity: self.inlineStringCapacity, bytes
      )
      self.stringResultRaw = max(self.stringResultRaw, result.rawValue)
      return
    }
    // The one added check on the string hot path. A destination that reached `stringBegin` has
    // already proved it accepts strings, so this branch is never taken except by bounded storage
    // that has filled up -- predicted not-taken, and it is what turns an overflow into a reported
    // failure rather than silently dropped bytes.
    // The one addition to the string hot path, and deliberately not a branch.
    //
    // Checking the result here and reporting immediately cost 8.7% of `Real Twitter - bulk
    // discarding` (2268 -> 2465 us): the compare after the call keeps the target's schema
    // reference live across it and breaks the tail call the discarded-result version got. Folding
    // with `max` instead is a load, a compare-and-select and a store, and measured back at parity
    // (2255-2269 us). `applied` is zero and the failures are greater, so the fold is sticky: a
    // later chunk that happens to fit cannot erase an earlier chunk's refusal. Folding with `|=`
    // over disjoint bits was measured too and is the same speed, so `max` is kept: it leaves the
    // raw values free to be ordinary integers.
    //
    // The cost is where the failure surfaces: at the closing quote rather than at the chunk that
    // overflowed. Same token, so the reported offset is the end of the string value instead of
    // its middle -- which is what `stringEnd` reads it for.
    let result = target.schema.applyString(target.storage, target.field, bytes)
    self.stringResultRaw = max(self.stringResultRaw, result.rawValue)
  }

  mutating func stringEnd() {
    self.homogeneousStringStorage = nil
    self.scalarTarget = nil
    self.inlineStringCapacity = 0
    // Once per string value rather than once per chunk, which is what makes the fold above worth
    // it: a document of short strings pays this at every closing quote, and a document of long
    // ones pays it far less often than it feeds chunks.
    if self.stringResultRaw != 0 {
      self.recordFailure(
        self.stringResultRaw == StreamApplyResult.capacityExceeded.rawValue
          ? .capacityExceeded
          : .typeMismatch
      )
      self.stringResultRaw = 0
    }
  }

  mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) {
    switch self.activeLeafRoute {
    case .arrayDouble:
      self.appendHomogeneousDouble(bytes, info: info)
      return
    case .arrayInt:
      self.appendHomogeneousInt(bytes, info: info)
      return
    case .simd2Double, .simd3Double, .simd4Double,
      .optionalSIMD2Double, .optionalSIMD3Double, .optionalSIMD4Double:
      self.applyKnownSIMDDouble(bytes, info: info, route: self.activeLeafRoute)
      return
    case .simd2Number, .simd3Number, .simd4Number:
      self.applySIMDNumberNormally(bytes, info: info, route: self.activeLeafRoute)
      return
    default:
      self.applyNumberNormally(bytes, info: info)
      return
    }
  }

  mutating func boolean(_ value: Bool) {
    switch self.activeLeafRoute {
    case .arrayBool, .arrayOptionalBool, .dictionaryBool, .dictionaryOptionalBool:
      self.applyKnownBoolean(value, route: self.activeLeafRoute)
      return
    case .simd2Number, .simd3Number, .simd4Number,
      .simd2Double, .simd3Double, .simd4Double,
      .optionalSIMD2Double, .optionalSIMD3Double, .optionalSIMD4Double:
      self.recordFailure(.typeMismatch)
      return
    default:
      self.applyBooleanNormally(value)
      return
    }
  }

  mutating func null() {
    if self.topFrame == nil, !self.started {
      let result = self.rootSchema.applyNull(self.root, StreamSchema.wholeValueField)
      if result != .applied {
        self.recordFailure(Self.failureReason(for: result))
      }
      return
    }
    switch self.activeLeafRoute {
    case .arrayOptionalStreamString, .arrayOptionalBool,
      .arrayOptionalDouble, .arrayOptionalInt,
      .dictionaryOptionalStreamString, .dictionaryOptionalBool:
      self.applyKnownNull(self.activeLeafRoute)
      return
    case .simd2Number, .simd3Number, .simd4Number,
      .simd2Double, .simd3Double, .simd4Double,
      .optionalSIMD2Double, .optionalSIMD3Double, .optionalSIMD4Double:
      self.recordFailure(.typeMismatch)
      return
    default:
      self.applyNullNormally()
      return
    }
  }

  // MARK: Events

  // A batch of events. Under an object frame that matches keys, each `key` followed by a scalar
  // is routed in place: one `matchField`, one apply, nothing else — no frame resolution, no
  // `ScalarTarget` copy of the schema (a retain and a release per value), no closure per string
  // piece. The failure points are the single path's: a string is accepted at its `stringBegin`
  // (the empty span materialises the destination), a number or literal at itself. Everything
  // else — a container after a key, a dictionary frame, an array frame, a frame that ignores
  // keys — unrolls into the single events below, exactly as the one-at-a-time path did.
  public mutating func events(_ batch: borrowing StreamEventBatch) -> Int {
    let records = batch.records
    let count = batch.count
    var index = 0
    while index < count {
      let record = records[index]
      // A run of numbers into an array of numbers takes the schema's bulk appender: no frame per
      // element, no schema borrow per value. Its rejection is the element it refused. Only
      // `_streamArraySchema` carries one, so a fixed array or an array of SIMD vectors — whose
      // leaf routes need the frame's element cursor — never reaches this and falls through to
      // `number` below.
      if record.kind == .number, let top = self.topFrame, top.pointee.schema.shape == .array,
        let append = top.pointee.schema.appendNumbers
      {
        var runEnd = index &+ 1
        while runEnd < count && records[runEnd].kind == .number { runEnd &+= 1 }
        let taken = append(top.pointee.storage, batch, index, runEnd)
        if taken < runEnd &- index {
          self.recordFailure(.typeMismatch)
          return index &+ taken
        }
        index = runEnd
        continue
      }
      // The table form of the same fast path: the key resolves to an entry, and the scalar after
      // it is written by the entry's kind -- a typed store at the member's offset, no closure.
      if record.kind == .key, index &+ 1 < count, let top = self.topFrame,
        top.pointee.schema.keyRouting == .table
      {
        let field = Self.matchTable(top, batch.bytes(of: index))
        top.pointee.pendingField = field
        let next = records[index &+ 1]
        let entry = field >= 0 ? top.pointee.schema.fieldEntries.unsafelyUnwrapped + Int(field) : nil
        switch next.kind {
        case .string:
          if let entry {
            let result = self.writeTableString(entry, frame: top, batch.bytes(of: index &+ 1))
            if result != .applied {
              self.recordFailure(Self.failureReason(for: result))
              return index &+ 1
            }
          }
          index &+= 2
          continue
        case .number:
          if let entry {
            let bytes = batch.bytes(of: index &+ 1)
            let info = batch.info(of: index &+ 1)
            let result =
              entry.pointee.kind == .custom
              ? top.pointee.schema.applyNumber(top.pointee.storage, entry.pointee.index, bytes, info)
              : Self.writeTableNumber(
                entry, member: top.pointee.storage + Int(entry.pointee.offset), bytes, info
              )
            if result != .applied {
              self.recordFailure(Self.failureReason(for: result))
              return index &+ 1
            }
          }
          index &+= 2
          continue
        case .boolean:
          if let entry {
            let result =
              entry.pointee.kind == .custom
              ? top.pointee.schema.applyBoolean(
                top.pointee.storage, entry.pointee.index, next.booleanValue
              )
              : Self.writeTableBoolean(
                entry, member: top.pointee.storage + Int(entry.pointee.offset), next.booleanValue
              )
            if result != .applied {
              self.recordFailure(Self.failureReason(for: result))
              return index &+ 1
            }
          }
          index &+= 2
          continue
        case .null:
          if let entry {
            let kind = entry.pointee.kind
            let result =
              kind == .custom || kind == .container
              ? top.pointee.schema.applyNull(top.pointee.storage, entry.pointee.index)
              : Self.writeTableNull(entry, member: top.pointee.storage + Int(entry.pointee.offset))
            if result != .applied {
              self.recordFailure(Self.failureReason(for: result))
              return index &+ 1
            }
          }
          index &+= 2
          continue
        default:
          index &+= 1
          continue
        }
      }
      if record.kind == .key, index &+ 1 < count, let top = self.topFrame,
        top.pointee.schema.shape == .object, top.pointee.schema.keyRouting == .match
      {
        let next = records[index &+ 1]
        let field = top.pointee.schema.matchField(batch.bytes(of: index))
        top.pointee.pendingField = field
        switch next.kind {
        case .string:
          if field >= 0 {
            // An object field resolves to the frame's own schema and `wholeValueField` is never
            // in play, so this is exactly what `resolveScalarTarget` would have handed back —
            // including for bounded inline storage, whose capacity route keys off a *scalar*
            // schema's leaf route and is therefore not reachable from an object field either way.
            let opened = top.pointee.schema.applyString(top.pointee.storage, field, Span())
            if opened != .applied {
              self.recordFailure(Self.failureReason(for: opened))
              return index &+ 1
            }
            if next.length > 0 {
              let result = top.pointee.schema.applyString(
                top.pointee.storage, field, batch.bytes(of: index &+ 1)
              )
              if result != .applied {
                self.recordFailure(Self.failureReason(for: result))
                return index &+ 1
              }
            }
          }
          index &+= 2
          continue
        case .number:
          if field >= 0 {
            let result = top.pointee.schema.applyNumber(
              top.pointee.storage, field, batch.bytes(of: index &+ 1), batch.info(of: index &+ 1)
            )
            if result != .applied {
              self.recordFailure(Self.failureReason(for: result))
              return index &+ 1
            }
          }
          index &+= 2
          continue
        case .boolean:
          if field >= 0 {
            let result = top.pointee.schema.applyBoolean(
              top.pointee.storage, field, next.booleanValue
            )
            if result != .applied {
              self.recordFailure(Self.failureReason(for: result))
              return index &+ 1
            }
          }
          index &+= 2
          continue
        case .null:
          if field >= 0 {
            let result = top.pointee.schema.applyNull(top.pointee.storage, field)
            if result != .applied {
              self.recordFailure(Self.failureReason(for: result))
              return index &+ 1
            }
          }
          index &+= 2
          continue
        default:
          // A container follows: the key is already routed; the container takes the single path.
          index &+= 1
          continue
        }
      }
      switch record.kind {
      case .beginObject: self.beginObject()
      case .endObject: self.endObject()
      case .beginArray: self.beginArray()
      case .endArray: self.endArray()
      case .key: self.key(batch.bytes(of: index))
      case .stringBegin: self.stringBegin()
      case .stringChunk: self.stringChunk(batch.bytes(of: index))
      case .stringEnd: self.stringEnd()
      case .number: self.number(batch.bytes(of: index), info: batch.info(of: index))
      case .boolean: self.boolean(record.booleanValue)
      case .null: self.null()
      case .string:
        self.stringBegin()
        if self.streamFailure != nil { return index }
        if record.length > 0 { self.stringChunk(batch.bytes(of: index)) }
        self.stringEnd()
      }
      if self.streamFailure != nil { return index }
      index &+= 1
    }
    return index
  }

  // MARK: Scalar routing

  @usableFromInline
  struct ScalarTarget {
    var storage: UnsafeMutableRawPointer
    // Strong, unlike `BorrowedFrame`, and measured rather than assumed. Borrowing here made things
    // worse: a stored closure loaded off an `unowned(unsafe)` reference has to be converted to a
    // strong one first, where the same load off a strong stored property is a borrow the optimizer
    // gets for free. `Layer LLM message bulk - partial sink` went 604 -> 485 MB/s with retains
    // rising 12,000 -> 37,000, because this target is re-read once per `stringChunk` and that
    // document is the one made of long strings. Twitter, which routes many short scalars and few
    // chunks, preferred the borrow by 11% — the string path is the larger of the two.
    var schema: StreamSchema
    var field: Int32
    // The table entry the target came from, or nil for a target the closures apply: an array
    // element, a dictionary value, a scalar root, or a `custom`/`container` field. For a table
    // target `storage` is already the member's address.
    var entry: UnsafePointer<StreamField>?
  }

  @usableFromInline var scalarTarget: ScalarTarget?

  @usableFromInline var homogeneousStringStorage: UnsafeMutableRawPointer?

  // Non-zero while the open string value writes into bounded inline storage, in which case it is
  // that storage's capacity. One store per string value at `stringBegin`, which is what buys the
  // chunk path a capacity in a register instead of a load off the schema.
  @usableFromInline var inlineStringCapacity: Int32 = 0

  // The open string value's worst result so far, as a raw value so chunks can fold into it
  // without branching. Read and reset once per value in `stringEnd`.
  @usableFromInline var stringResultRaw: UInt8 = 0

  @inline(never)
  private mutating func openKnownStreamStringTarget(
    _ route: _StreamLeafRoute
  ) -> UnsafeMutableRawPointer? {
    guard let top = self.topFrame else { return nil }
    switch route {
    case .arrayStreamString:
      return top.pointee.storage.assumingMemoryBound(to: StreamArray<StreamString>.self)
        .pointee._openElement(StreamString())
    case .arrayOptionalStreamString:
      return top.pointee.storage.assumingMemoryBound(to: StreamArray<StreamString?>.self)
        .pointee._openElement(.some(StreamString()))
    case .dictionaryStreamString:
      guard let pending = self.pendingDictionaryStorage else { return nil }
      self.pendingDictionaryStorage = nil
      return pending
    case .dictionaryOptionalStreamString:
      guard let pending = self.pendingDictionaryStorage else { return nil }
      self.pendingDictionaryStorage = nil
      _streamMaterializeOptional(pending, as: StreamString.self)
      return pending
    default:
      return nil
    }
  }

  @inline(never)
  private mutating func applyKnownBoolean(_ value: Bool, route: _StreamLeafRoute) {
    switch route {
    case .arrayBool:
      guard let top = self.topFrame else { return }
      _ = top.pointee.storage.assumingMemoryBound(to: StreamArray<Bool>.self).pointee
        ._openElement(value)
    case .arrayOptionalBool:
      guard let top = self.topFrame else { return }
      _ = top.pointee.storage.assumingMemoryBound(to: StreamArray<Bool?>.self).pointee
        ._openElement(.some(value))
    case .dictionaryBool:
      guard let storage = self.pendingDictionaryStorage else { return }
      self.pendingDictionaryStorage = nil
      storage.assumingMemoryBound(to: Bool.self).pointee = value
    case .dictionaryOptionalBool:
      guard let storage = self.pendingDictionaryStorage else { return }
      self.pendingDictionaryStorage = nil
      storage.assumingMemoryBound(to: Bool?.self).pointee = .some(value)
    default:
      return
    }
  }

  @inline(never)
  private mutating func applyKnownNull(_ route: _StreamLeafRoute) {
    switch route {
    case .arrayOptionalStreamString:
      guard let top = self.topFrame else { return }
      _ = top.pointee.storage.assumingMemoryBound(to: StreamArray<StreamString?>.self)
        .pointee._openElement(nil)
    case .arrayOptionalBool:
      guard let top = self.topFrame else { return }
      _ = top.pointee.storage.assumingMemoryBound(to: StreamArray<Bool?>.self)
        .pointee._openElement(nil)
    case .arrayOptionalDouble:
      guard let top = self.topFrame else { return }
      _ = top.pointee.storage.assumingMemoryBound(to: StreamArray<Double?>.self)
        .pointee._openElement(nil)
    case .arrayOptionalInt:
      guard let top = self.topFrame else { return }
      _ = top.pointee.storage.assumingMemoryBound(to: StreamArray<Int?>.self)
        .pointee._openElement(nil)
    case .dictionaryOptionalStreamString:
      guard let storage = self.pendingDictionaryStorage else { return }
      self.pendingDictionaryStorage = nil
      storage.assumingMemoryBound(to: StreamString?.self).pointee = nil
    case .dictionaryOptionalBool:
      guard let storage = self.pendingDictionaryStorage else { return }
      self.pendingDictionaryStorage = nil
      storage.assumingMemoryBound(to: Bool?.self).pointee = nil
    default:
      return
    }
  }

  @inline(never)
  private mutating func openKnownDictionaryValue(
    _ storage: UnsafeMutableRawPointer,
    route: _StreamLeafRoute,
    forKey key: Span<UInt8>
  ) -> UnsafeMutableRawPointer {
    switch route {
    case .dictionaryStreamString:
      return storage.assumingMemoryBound(to: StreamDictionary<StreamString>.self).pointee
        ._openValue(forKey: key, initial: StreamString())
    case .dictionaryOptionalStreamString:
      return storage.assumingMemoryBound(to: StreamDictionary<StreamString?>.self).pointee
        ._openValue(forKey: key, initial: .some(StreamString()))
    case .dictionaryBool:
      return storage.assumingMemoryBound(to: StreamDictionary<Bool>.self).pointee
        ._openValue(forKey: key, initial: false)
    case .dictionaryOptionalBool:
      return storage.assumingMemoryBound(to: StreamDictionary<Bool?>.self).pointee
        ._openValue(forKey: key, initial: .some(false))
    default:
      preconditionFailure("A generic dictionary route reached the closed leaf opener")
    }
  }

  @inline(never)
  private mutating func openKnownSIMDDoubleElement(_ route: _StreamLeafRoute) {
    guard let top = self.topFrame else { return }
    switch route {
    case .arraySIMD2Double:
      let storage = top.pointee.storage.assumingMemoryBound(
        to: StreamArray<SIMD2<Double>>.self
      ).pointee._openElement(.zero)
      self.pushFrame(BorrowedFrame(storage: storage, schema: _streamSIMD2DoubleSchema))
    case .arraySIMD3Double:
      let storage = top.pointee.storage.assumingMemoryBound(
        to: StreamArray<SIMD3<Double>>.self
      ).pointee._openElement(.zero)
      self.pushFrame(BorrowedFrame(storage: storage, schema: _streamSIMD3DoubleSchema))
    case .arraySIMD4Double:
      let storage = top.pointee.storage.assumingMemoryBound(
        to: StreamArray<SIMD4<Double>>.self
      ).pointee._openElement(.zero)
      self.pushFrame(BorrowedFrame(storage: storage, schema: _streamSIMD4DoubleSchema))
    case .arrayOptionalSIMD2Double:
      let storage = top.pointee.storage.assumingMemoryBound(
        to: StreamArray<SIMD2<Double>?>.self
      ).pointee._openElement(.some(.zero))
      self.pushFrame(BorrowedFrame(storage: storage, schema: _streamSIMD2DoubleSchema))
    case .arrayOptionalSIMD3Double:
      let storage = top.pointee.storage.assumingMemoryBound(
        to: StreamArray<SIMD3<Double>?>.self
      ).pointee._openElement(.some(.zero))
      self.pushFrame(BorrowedFrame(storage: storage, schema: _streamSIMD3DoubleSchema))
    case .arrayOptionalSIMD4Double:
      let storage = top.pointee.storage.assumingMemoryBound(
        to: StreamArray<SIMD4<Double>?>.self
      ).pointee._openElement(.some(.zero))
      self.pushFrame(BorrowedFrame(storage: storage, schema: _streamSIMD4DoubleSchema))
    default:
      preconditionFailure("A non-SIMD-array route reached the closed SIMD element opener")
    }
  }

  @inline(never)
  private mutating func appendHomogeneousDouble(_ bytes: Span<UInt8>, info: NumberInfo) {
    guard let value = Double(streamParsing: bytes, info: info) else {
      self.recordFailure(.typeMismatch)
      return
    }
    guard let top = self.topFrame else { return }
    _ = top.pointee.storage.assumingMemoryBound(to: StreamArray<Double>.self).pointee
      ._openElement(value)
  }

  @inline(never)
  private mutating func appendHomogeneousInt(_ bytes: Span<UInt8>, info: NumberInfo) {
    guard let value = Int(streamParsing: bytes, info: info) else {
      self.recordFailure(.typeMismatch)
      return
    }
    guard let top = self.topFrame else { return }
    _ = top.pointee.storage.assumingMemoryBound(to: StreamArray<Int>.self).pointee
      ._openElement(value)
  }

  @inline(never)
  private mutating func applyKnownSIMDDouble(
    _ bytes: Span<UInt8>,
    info: NumberInfo,
    route: _StreamLeafRoute
  ) {
    guard let top = self.topFrame else { return }
    let lane = top.pointee.pendingField
    guard lane >= 0, lane < route.fixedSIMDLaneCount else {
      self.recordFailure(.typeMismatch)
      return
    }
    guard let value = Double(streamParsing: bytes, info: info) else {
      self.recordFailure(.typeMismatch)
      return
    }
    switch route {
    case .simd2Double, .optionalSIMD2Double:
      top.pointee.storage.assumingMemoryBound(to: SIMD2<Double>.self).pointee[Int(lane)] = value
    case .simd3Double, .optionalSIMD3Double:
      top.pointee.storage.assumingMemoryBound(to: SIMD3<Double>.self).pointee[Int(lane)] = value
    case .simd4Double, .optionalSIMD4Double:
      top.pointee.storage.assumingMemoryBound(to: SIMD4<Double>.self).pointee[Int(lane)] = value
    default:
      preconditionFailure("A non-Double SIMD route reached the closed Double writer")
    }
    top.pointee.pendingField = lane &+ 1
  }

  @inline(never)
  private mutating func applySIMDNumberNormally(
    _ bytes: Span<UInt8>,
    info: NumberInfo,
    route: _StreamLeafRoute
  ) {
    guard let top = self.topFrame else { return }
    let lane = top.pointee.pendingField
    guard lane >= 0, lane < route.fixedSIMDLaneCount else {
      self.recordFailure(.typeMismatch)
      return
    }
    let result = top.pointee.schema.applyNumber(top.pointee.storage, lane, bytes, info)
    guard result == .applied else {
      self.recordFailure(Self.failureReason(for: result))
      return
    }
    top.pointee.pendingField = lane &+ 1
  }

  // Outlining the closure route keeps its register pressure out of `number`. The public entry
  // point can then tail-call one of three routes after testing the cached byte instead of saving
  // every register needed only by the generic schema branch before it knows which route applies.
  @inline(never)
  private mutating func applyNumberNormally(_ bytes: Span<UInt8>, info: NumberInfo) {
    self.withScalarTarget(
      table: { entry, storage, schema in
        entry.pointee.kind == .custom
          ? schema.applyNumber(storage, entry.pointee.index, bytes, info)
          : Self.writeTableNumber(entry, member: storage, bytes, info)
      }
    ) { storage, field, schema in
      schema.applyNumber(storage, field, bytes, info)
    }
  }

  @inline(never)
  private mutating func applyBooleanNormally(_ value: Bool) {
    self.withScalarTarget(
      table: { entry, storage, schema in
        entry.pointee.kind == .custom
          ? schema.applyBoolean(storage, entry.pointee.index, value)
          : Self.writeTableBoolean(entry, member: storage, value)
      }
    ) { storage, field, schema in
      schema.applyBoolean(storage, field, value)
    }
  }

  @inline(never)
  private mutating func applyNullNormally() {
    self.withScalarTarget(
      table: { entry, storage, schema in
        entry.pointee.kind == .custom || entry.pointee.kind == .container
          ? schema.applyNull(storage, entry.pointee.index)
          : Self.writeTableNull(entry, member: storage)
      }
    ) { storage, field, schema in
      schema.applyNull(storage, field)
    }
  }

  // MARK: Table writes

  // The key match against the top frame's table, through the schema's raw views: nothing here
  // loads a reference, so nothing is retained per key.
  @inline(__always)
  private static func matchTable(
    _ frame: UnsafeMutablePointer<BorrowedFrame>, _ key: Span<UInt8>
  ) -> Int32 {
    streamMatchField(
      frame.pointee.schema.fieldEntries.unsafelyUnwrapped,
      count: frame.pointee.schema.fieldCount,
      keyBytes: frame.pointee.schema.fieldKeyBytes.unsafelyUnwrapped,
      key
    )
  }

  // A table entry's target. For a kind the table writes, `storage` is the member's own address;
  // a `custom` or `container` entry keeps the object's storage, which is what its closures take.
  @inline(__always)
  private static func tableTarget(
    _ entry: UnsafePointer<StreamField>,
    _ storage: UnsafeMutableRawPointer,
    _ schema: StreamSchema
  ) -> ScalarTarget {
    let kind = entry.pointee.kind
    let direct = kind != .custom && kind != .container
    return ScalarTarget(
      storage: direct ? storage + Int(entry.pointee.offset) : storage,
      schema: schema,
      field: entry.pointee.index,
      entry: entry
    )
  }

  // The typed store behind every number kind: convert, then write the value or its `.some`. The
  // optional store is a typed assignment rather than a raw write because `Optional`'s tag is
  // laid out per payload type, and the compiler knows where.
  @inline(__always)
  private static func storeNumber<T: StreamNumberConvertible>(
    _ type: T.Type,
    at storage: UnsafeMutableRawPointer,
    optional: Bool,
    _ bytes: Span<UInt8>,
    _ info: NumberInfo
  ) -> StreamApplyResult {
    guard let value = T(streamParsing: bytes, info: info) else { return .unsupported }
    if optional {
      storage.assumingMemoryBound(to: T?.self).pointee = value
    } else {
      storage.assumingMemoryBound(to: T.self).pointee = value
    }
    return .applied
  }

  @inline(__always)
  private static func storeNil<T>(
    _ type: T.Type, at storage: UnsafeMutableRawPointer
  ) -> StreamApplyResult {
    storage.assumingMemoryBound(to: T?.self).pointee = nil
    return .applied
  }

  // The kinds the table writes, at the member's own address. `custom` is the caller's to route to
  // the closure, so the schema never comes through here.
  @inline(never)
  private static func writeTableNumber(
    _ entry: UnsafePointer<StreamField>,
    member: UnsafeMutableRawPointer,
    _ bytes: Span<UInt8>,
    _ info: NumberInfo
  ) -> StreamApplyResult {
    let kind = entry.pointee.kind
    let optional = entry.pointee.isOptional
    switch kind {
    case .int: return Self.storeNumber(Int.self, at: member, optional: optional, bytes, info)
    case .double: return Self.storeNumber(Double.self, at: member, optional: optional, bytes, info)
    case .int64: return Self.storeNumber(Int64.self, at: member, optional: optional, bytes, info)
    case .uint64: return Self.storeNumber(UInt64.self, at: member, optional: optional, bytes, info)
    case .uint: return Self.storeNumber(UInt.self, at: member, optional: optional, bytes, info)
    case .int32: return Self.storeNumber(Int32.self, at: member, optional: optional, bytes, info)
    case .uint32: return Self.storeNumber(UInt32.self, at: member, optional: optional, bytes, info)
    case .int16: return Self.storeNumber(Int16.self, at: member, optional: optional, bytes, info)
    case .uint16: return Self.storeNumber(UInt16.self, at: member, optional: optional, bytes, info)
    case .int8: return Self.storeNumber(Int8.self, at: member, optional: optional, bytes, info)
    case .uint8: return Self.storeNumber(UInt8.self, at: member, optional: optional, bytes, info)
    case .float: return Self.storeNumber(Float.self, at: member, optional: optional, bytes, info)
    case .custom, .bool, .streamString, .inlineString, .container:
      return .unsupported
    }
  }

  @inline(never)
  private static func writeTableBoolean(
    _ entry: UnsafePointer<StreamField>,
    member: UnsafeMutableRawPointer,
    _ value: Bool
  ) -> StreamApplyResult {
    guard entry.pointee.kind == .bool else { return .unsupported }
    if entry.pointee.isOptional {
      member.assumingMemoryBound(to: Bool?.self).pointee = value
    } else {
      member.assumingMemoryBound(to: Bool.self).pointee = value
    }
    return .applied
  }

  // A null clears an optional member of any kind the table writes. A container member is nulled
  // through the closure, which knows the container's type; a non-optional member is a mismatch,
  // as `streamApplyNull`'s disfavoured overload always reported it.
  @inline(never)
  private static func writeTableNull(
    _ entry: UnsafePointer<StreamField>,
    member: UnsafeMutableRawPointer
  ) -> StreamApplyResult {
    let kind = entry.pointee.kind
    guard entry.pointee.isOptional else { return .unsupported }
    switch kind {
    case .int: return Self.storeNil(Int.self, at: member)
    case .double: return Self.storeNil(Double.self, at: member)
    case .int64: return Self.storeNil(Int64.self, at: member)
    case .uint64: return Self.storeNil(UInt64.self, at: member)
    case .uint: return Self.storeNil(UInt.self, at: member)
    case .int32: return Self.storeNil(Int32.self, at: member)
    case .uint32: return Self.storeNil(UInt32.self, at: member)
    case .int16: return Self.storeNil(Int16.self, at: member)
    case .uint16: return Self.storeNil(UInt16.self, at: member)
    case .int8: return Self.storeNil(Int8.self, at: member)
    case .uint8: return Self.storeNil(UInt8.self, at: member)
    case .float: return Self.storeNil(Float.self, at: member)
    case .bool: return Self.storeNil(Bool.self, at: member)
    case .streamString: return Self.storeNil(StreamString.self, at: member)
    case .inlineString:
      // `StreamInlineString<N>?`: the payload has no spare bits (an `Int32` count and raw bytes),
      // so the optional's tag is the byte after the payload, and nil is a one there.
      member.storeBytes(
        of: 1, toByteOffset: _streamInlineStringByteOffset + Int(entry.pointee.capacity),
        as: UInt8.self
      )
      return .applied
    case .custom, .container:
      return .unsupported
    }
  }

  // Materialises an optional inline string by hand: a zero count and a zero tag after the payload.
  @inline(__always)
  private static func materializeInlineString(
    _ member: UnsafeMutableRawPointer, capacity: Int32
  ) {
    let tagOffset = _streamInlineStringByteOffset + Int(capacity)
    if member.load(fromByteOffset: tagOffset, as: UInt8.self) != 0 {
      member.storeBytes(of: 0, as: Int32.self)
      member.storeBytes(of: 0, toByteOffset: tagOffset, as: UInt8.self)
    }
  }

  // Opens a string member for in-place appends: materialises an optional, reserves the hinted
  // capacity, and points the chunk path at the storage. `storage` is the member's own address
  // for a kind the table writes and the object's for `custom`.
  @inline(never)
  private mutating func openTableString(
    _ entry: UnsafePointer<StreamField>,
    _ storage: UnsafeMutableRawPointer
  ) -> StreamApplyResult {
    switch entry.pointee.kind {
    case .streamString:
      if entry.pointee.isOptional {
        _streamMaterializeOptional(storage, as: StreamString.self)
      }
      if entry.pointee.capacity > 0 {
        storage.assumingMemoryBound(to: StreamString.self).pointee
          .streamReserve(utf8ByteCount: Int(entry.pointee.capacity))
      }
      self.homogeneousStringStorage = storage
      return .applied
    case .inlineString:
      if entry.pointee.isOptional {
        Self.materializeInlineString(storage, capacity: entry.pointee.capacity)
      }
      self.inlineStringCapacity = entry.pointee.capacity
      return .applied
    case .custom:
      // The closure route, exactly as before the table: the empty span materialises and settles.
      let schema = self.scalarTarget.unsafelyUnwrapped.schema
      let field = entry.pointee.index
      return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 1) { buffer in
        let empty = UnsafeBufferPointer(start: buffer.baseAddress, count: 0)
        return schema.applyString(storage, field, Span(_unsafeElements: empty))
      }
    default:
      return .unsupported
    }
  }

  // The batched form: a whole string value in one record, written from the frame.
  @inline(never)
  private mutating func writeTableString(
    _ entry: UnsafePointer<StreamField>,
    frame: UnsafeMutablePointer<BorrowedFrame>,
    _ bytes: Span<UInt8>
  ) -> StreamApplyResult {
    let storage = frame.pointee.storage
    let member = storage + Int(entry.pointee.offset)
    switch entry.pointee.kind {
    case .streamString:
      if entry.pointee.isOptional {
        _streamMaterializeOptional(member, as: StreamString.self)
      }
      let string = member.assumingMemoryBound(to: StreamString.self)
      if entry.pointee.capacity > 0 {
        string.pointee.streamReserve(utf8ByteCount: Int(entry.pointee.capacity))
      }
      if bytes.count > 0 { string.pointee.streamAppend(utf8: bytes) }
      return .applied
    case .inlineString:
      if entry.pointee.isOptional {
        Self.materializeInlineString(member, capacity: entry.pointee.capacity)
      }
      return _streamInlineStringAppend(member, capacity: entry.pointee.capacity, bytes)
    case .custom:
      let opened = withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 1) { buffer in
        let empty = UnsafeBufferPointer(start: buffer.baseAddress, count: 0)
        return frame.pointee.schema.applyString(
          storage, entry.pointee.index, Span(_unsafeElements: empty)
        )
      }
      if opened != .applied { return opened }
      if bytes.count > 0 {
        return frame.pointee.schema.applyString(storage, entry.pointee.index, bytes)
      }
      return .applied
    default:
      return .unsupported
    }
  }


  private mutating func resolveScalarTarget() -> ScalarTarget? {
    #if DEBUG && !hasFeature(Embedded)
      self.audit.verify()
    #endif
    guard let top = self.topFrame else {
      // A bare scalar document never opens a container, so no frame was ever pushed and the
      // root is the destination.
      guard !self.started else { return nil }
      guard self.rootSchema.shape == .scalar else {
        self.recordFailure(.typeMismatch)
        return nil
      }
      return ScalarTarget(
        storage: self.root, schema: self.rootSchema, field: StreamSchema.wholeValueField,
        entry: nil
      )
    }
    switch top.pointee.schema.shape {
    case .array:
      let indexed = top.pointee.leafRoute == .inlineArray
      let index = indexed ? top.pointee.pendingField : -1
      if indexed, index >= top.pointee.schema.fixedElementCount {
        // The scalar-element twin of the same check in `valueTarget`, and the same failure: a
        // fixed array handed more elements than it declares is bounded storage overflowing.
        self.recordFailure(.capacityExceeded)
        return nil
      }
      guard let element = top.pointee.schema.appendElement(top.pointee.storage, index) else {
        if indexed { self.recordFailure(.capacityExceeded) }
        return nil
      }
      if indexed { top.pointee.pendingField = index &+ 1 }
      let borrowed = self.borrow(element)
      return ScalarTarget(
        storage: borrowed.storage, schema: borrowed.schema, field: StreamSchema.wholeValueField,
        entry: nil
      )
    case .object:
      guard top.pointee.pendingField >= 0 else { return nil }
      if top.pointee.schema.keyRouting == .table {
        let entry = top.pointee.schema.fieldEntries.unsafelyUnwrapped + Int(top.pointee.pendingField)
        return Self.tableTarget(entry, top.pointee.storage, top.pointee.schema)
      }
      return ScalarTarget(
        storage: top.pointee.storage, schema: top.pointee.schema, field: top.pointee.pendingField,
        entry: nil
      )
    case .dictionary:
      if let storage = self.pendingDictionaryStorage {
        self.pendingDictionaryStorage = nil
        return ScalarTarget(
          storage: storage,
          schema: top.pointee.schema,
          field: StreamSchema.wholeValueField,
          entry: nil
        )
      }
      guard let frame = self.pendingDictionaryFrame else { return nil }
      return ScalarTarget(
        storage: frame.storage, schema: frame.schema, field: StreamSchema.wholeValueField,
        entry: nil
      )
    case .scalar:
      return ScalarTarget(
        storage: top.pointee.storage, schema: top.pointee.schema, field: StreamSchema.wholeValueField,
        entry: nil
      )
    }
  }

  // A nil target means the destination has no such field, which is not an error: unknown keys
  // have always been ignored. A target that refuses the token is a type mismatch, because the
  // key matched something that cannot hold this kind of value.
  private mutating func withScalarTarget(
    _ body: (UnsafeMutableRawPointer, Int32, StreamSchema) -> StreamApplyResult
  ) {
    guard let target = self.resolveScalarTarget() else { return }
    let result = body(target.storage, target.field, target.schema)
    if result != .applied {
      self.recordFailure(Self.failureReason(for: result))
    }
  }

  // The same, when the target may be a table entry: `table` writes it, `body` is the closure
  // route for everything else.
  private mutating func withScalarTarget(
    table: (UnsafePointer<StreamField>, UnsafeMutableRawPointer, StreamSchema) -> StreamApplyResult,
    _ body: (UnsafeMutableRawPointer, Int32, StreamSchema) -> StreamApplyResult
  ) {
    guard let target = self.resolveScalarTarget() else { return }
    let result =
      if let entry = target.entry {
        table(entry, target.storage, target.schema)
      } else {
        body(target.storage, target.field, target.schema)
      }
    if result != .applied {
      self.recordFailure(Self.failureReason(for: result))
    }
  }

  // The sink reports one reason per failed apply. `unsupported` and anything a later version of
  // the enum adds read as a mismatch, which is what this sink could always say about a token a
  // destination refused; only capacity has a distinct answer.
  @usableFromInline
  static func failureReason(for result: StreamApplyResult) -> StreamSinkFailure.Reason {
    switch result {
    case .capacityExceeded: .capacityExceeded
    default: .typeMismatch
    }
  }

  @usableFromInline
  mutating func recordFailure(_ reason: StreamSinkFailure.Reason) {
    guard self.streamFailure == nil else { return }
    self.streamFailure = StreamSinkFailure(reason: reason)
  }

  // A schema that accepts and discards everything, used for subtrees the destination has no
  // field for. Without it an unknown key's nested object would be routed to the parent.
  @usableFromInline
  static var ignoredSchema: StreamSchema {
    ignoredStreamSchema
  }
}

@usableFromInline let ignoredStreamSchema = StreamSchema(shape: .object)

extension PartialSink where Root: StreamParseableRoot {
  public init(root: UnsafeMutablePointer<Root>) {
    self.init(root: root, schema: Root.streamSchema)
  }
}
