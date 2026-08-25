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

  @usableFromInline
  init(storage: UnsafeMutableRawPointer, schema: StreamSchema, pendingField: Int32 = -1) {
    self.storage = storage
    self.schema = schema
    self.pendingField = pendingField
  }

  @usableFromInline
  init(borrowing frame: StreamFrame) {
    self.storage = frame.storage
    self.schema = frame.schema
    self.pendingField = frame.pendingField
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
  @usableFromInline var pendingDictionaryFrame: BorrowedFrame?

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
  mutating func pushFrame(_ frame: BorrowedFrame) {
    #if DEBUG && !hasFeature(Embedded)
      self.audit.verify()
    #endif
    guard self.frameCount < Self.frameCapacity else {
      self.droppedFrameCount &+= 1
      self.recordFailure(.depthExceeded)
      return
    }
    (self.frames + self.frameCount).initialize(to: frame)
    self.frameCount &+= 1
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
    case .dictionary: return self.pendingDictionaryFrame != nil
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
    guard let target = self.scalarTarget else { return }
    _ = target.schema.applyString(target.storage, target.field, bytes)
  }

  public mutating func stringEnd() {
    self.scalarTarget = nil
  }

  public mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) {
    self.withScalarTarget { storage, field, schema in
      schema.applyNumber(storage, field, bytes, info)
    }
  }

  // A run of numbers into an array of numbers takes the schema's bulk appender: one frame
  // resolution per batch instead of one per number, and none of the per-element routing that
  // the profile counted as five retains and six releases per number. Any other destination
  // unrolls the batch through `number`, exactly as the protocol's default would.
  public mutating func numbers(_ batch: borrowing StreamNumberBatch) -> Int {
    if let top = self.topFrame, top.pointee.schema.shape == .array,
      let append = top.pointee.schema.appendNumbers
    {
      let taken = append(top.pointee.storage, batch)
      if taken < batch.count { self.recordFailure(.typeMismatch) }
      return taken
    }
    let infos = batch.infos
    var index = 0
    while index < batch.count {
      self.number(batch.token(at: index), info: infos[index])
      if self.streamFailure != nil { return index }
      index &+= 1
    }
    return index
  }

  public mutating func boolean(_ value: Bool) {
    self.withScalarTarget { storage, field, schema in
      schema.applyBoolean(storage, field, value)
    }
  }

  public mutating func null() {
    if self.topFrame == nil, !self.started {
      if !self.rootSchema.applyNull(self.root, StreamSchema.wholeValueField) {
        self.recordFailure(.typeMismatch)
      }
      return
    }
    self.withScalarTarget { storage, field, schema in
      schema.applyNull(storage, field)
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
