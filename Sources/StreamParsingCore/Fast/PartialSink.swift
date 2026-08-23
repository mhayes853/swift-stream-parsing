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

  public mutating func beginObject() {
    self.enterContainer(shape: .object)
  }

  public mutating func beginArray() {
    self.enterContainer(shape: .array)
  }

  public mutating func endObject() {
    self.popFrame()
  }

  public mutating func endArray() {
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
      guard let frame = top.pointee.schema.appendElement(top.pointee.storage) else { return nil }
      return self.borrow(frame)
    case .object:
      guard top.pointee.pendingField >= 0 else { return nil }
      guard
        let frame = top.pointee.schema.enterField(top.pointee.storage, top.pointee.pendingField)
      else { return nil }
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
  public mutating func key(_ bytes: Span<UInt8>) {
    guard let top = self.topFrame else { return }
    // Read through the frame each time rather than bound to a local. A local outlives the call it
    // is passed to, and `enterKey` takes the frame's own storage, so the optimizer has to keep the
    // schema alive across it — which is a retain, and cost one per entry on the dictionary path.
    // Read in place it is a borrow, and the loads fold.
    switch top.pointee.schema.keyRouting {
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

  public mutating func stringBegin() {
    switch self.activeLeafRoute {
    case .arrayStreamString, .arrayOptionalStreamString,
      .dictionaryStreamString, .dictionaryOptionalStreamString:
      self.homogeneousStringStorage = self.openKnownStreamStringTarget(self.activeLeafRoute)
      self.scalarTarget = nil
      return
    default:
      break
    }
    let target = self.resolveScalarTarget()
    self.scalarTarget = target
    guard let target else { return }
    // The empty span both materializes the destination and settles whether it accepts strings at
    // all, so a mismatch is reported at the opening quote rather than at the first chunk.
    let applied = withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 1) { buffer in
      let empty = UnsafeBufferPointer(start: buffer.baseAddress, count: 0)
      return target.schema.applyString(target.storage, target.field, Span(_unsafeElements: empty))
    }
    if !applied {
      self.scalarTarget = nil
      self.recordFailure(.typeMismatch)
    }
  }

  public mutating func stringChunk(_ bytes: Span<UInt8>) {
    if let storage = self.homogeneousStringStorage {
      storage.assumingMemoryBound(to: StreamString.self).pointee.streamAppend(utf8: bytes)
      return
    }
    guard let target = self.scalarTarget else { return }
    _ = target.schema.applyString(target.storage, target.field, bytes)
  }

  public mutating func stringEnd() {
    self.homogeneousStringStorage = nil
    self.scalarTarget = nil
  }

  public mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) {
    switch self.activeLeafRoute {
    case .arrayDouble:
      self.appendHomogeneousDouble(bytes, info: info)
      return
    case .arrayInt:
      self.appendHomogeneousInt(bytes, info: info)
      return
    default:
      self.applyNumberNormally(bytes, info: info)
      return
    }
  }

  public mutating func boolean(_ value: Bool) {
    switch self.activeLeafRoute {
    case .arrayBool, .arrayOptionalBool, .dictionaryBool, .dictionaryOptionalBool:
      self.applyKnownBoolean(value, route: self.activeLeafRoute)
      return
    default:
      self.applyBooleanNormally(value)
      return
    }
  }

  public mutating func null() {
    if self.topFrame == nil, !self.started {
      if !self.rootSchema.applyNull(self.root, StreamSchema.wholeValueField) {
        self.recordFailure(.typeMismatch)
      }
      return
    }
    switch self.activeLeafRoute {
    case .arrayOptionalStreamString, .arrayOptionalBool,
      .arrayOptionalDouble, .arrayOptionalInt,
      .dictionaryOptionalStreamString, .dictionaryOptionalBool:
      self.applyKnownNull(self.activeLeafRoute)
      return
    default:
      self.applyNullNormally()
      return
    }
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
  }

  @usableFromInline var scalarTarget: ScalarTarget?

  @usableFromInline var homogeneousStringStorage: UnsafeMutableRawPointer?

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

  // Outlining the closure route keeps its register pressure out of `number`. The public entry
  // point can then tail-call one of three routes after testing the cached byte instead of saving
  // every register needed only by the generic schema branch before it knows which route applies.
  @inline(never)
  private mutating func applyNumberNormally(_ bytes: Span<UInt8>, info: NumberInfo) {
    self.withScalarTarget { storage, field, schema in
      schema.applyNumber(storage, field, bytes, info)
    }
  }

  @inline(never)
  private mutating func applyBooleanNormally(_ value: Bool) {
    self.withScalarTarget { storage, field, schema in
      schema.applyBoolean(storage, field, value)
    }
  }

  @inline(never)
  private mutating func applyNullNormally() {
    self.withScalarTarget { storage, field, schema in
      schema.applyNull(storage, field)
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
        storage: self.root, schema: self.rootSchema, field: StreamSchema.wholeValueField
      )
    }
    switch top.pointee.schema.shape {
    case .array:
      guard let element = top.pointee.schema.appendElement(top.pointee.storage) else { return nil }
      let borrowed = self.borrow(element)
      return ScalarTarget(
        storage: borrowed.storage, schema: borrowed.schema, field: StreamSchema.wholeValueField
      )
    case .object:
      guard top.pointee.pendingField >= 0 else { return nil }
      return ScalarTarget(
        storage: top.pointee.storage, schema: top.pointee.schema, field: top.pointee.pendingField
      )
    case .dictionary:
      if let storage = self.pendingDictionaryStorage {
        self.pendingDictionaryStorage = nil
        return ScalarTarget(
          storage: storage,
          schema: top.pointee.schema,
          field: StreamSchema.wholeValueField
        )
      }
      guard let frame = self.pendingDictionaryFrame else { return nil }
      return ScalarTarget(
        storage: frame.storage, schema: frame.schema, field: StreamSchema.wholeValueField
      )
    case .scalar:
      return ScalarTarget(
        storage: top.pointee.storage, schema: top.pointee.schema, field: StreamSchema.wholeValueField
      )
    }
  }

  // A nil target means the destination has no such field, which is not an error: unknown keys
  // have always been ignored. A target that refuses the token is a type mismatch, because the
  // key matched something that cannot hold this kind of value.
  private mutating func withScalarTarget(
    _ body: (UnsafeMutableRawPointer, Int32, StreamSchema) -> Bool
  ) {
    guard let target = self.resolveScalarTarget() else { return }
    if !body(target.storage, target.field, target.schema) {
      self.recordFailure(.typeMismatch)
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
