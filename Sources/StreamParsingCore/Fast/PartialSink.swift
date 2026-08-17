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
  @usableFromInline var pendingDictionaryFrame: StreamFrame?

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
  @usableFromInline let frames: UnsafeMutablePointer<StreamFrame>
  @usableFromInline var frameCount = 0

  // Frames there was no room for. A container that could not be pushed must not pop one that
  // could, and a caller that catches the depth error and keeps feeding gets more `beginObject`
  // calls after it, so overflow has to stay balanced rather than merely not crash once.
  @usableFromInline var droppedFrameCount = 0

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
  var topFrame: UnsafeMutablePointer<StreamFrame>? {
    self.frameCount > 0 ? self.frames + (self.frameCount &- 1) : nil
  }

  @usableFromInline
  mutating func pushFrame(_ frame: StreamFrame) {
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
      let schema = canHoldContainer ? self.rootSchema : Self.ignoredSchema
      self.pushFrame(StreamFrame(storage: self.root, schema: schema))
      return
    }

    let hasKnownDestination = self.hasKnownValueDestination
    guard let target = self.valueTarget() else {
      // A container under an unknown object key is ignored. Every other missing target describes
      // a known destination whose schema cannot accept a container.
      if hasKnownDestination { self.recordFailure(.typeMismatch) }
      self.pushFrame(StreamFrame(storage: self.root, schema: Self.ignoredSchema))
      return
    }
    guard target.schema.shape.canHold(container: shape) else {
      self.recordFailure(.typeMismatch)
      self.pushFrame(StreamFrame(storage: self.root, schema: Self.ignoredSchema))
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
  private mutating func valueTarget() -> StreamFrame? {
    guard let top = self.topFrame else { return nil }
    switch top.pointee.schema.shape {
    case .array:
      return top.pointee.schema.appendElement(top.pointee.storage)
    case .object:
      guard top.pointee.pendingField >= 0 else { return nil }
      return top.pointee.schema.enterField(top.pointee.storage, top.pointee.pendingField)
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
    case .ignore:
      top.pointee.pendingField = -1
    }
  }

  public mutating func keyBegin() {}
  public mutating func keyChunk(_ bytes: Span<UInt8>) { self.key(bytes) }
  public mutating func keyEnd() {}

  // MARK: Scalars

  public mutating func string(_ bytes: Span<UInt8>) {
    self.withScalarTarget { storage, field, schema in
      schema.applyString(storage, field, bytes)
    }
  }

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

  public mutating func boolean(_ value: Bool) {
    self.withScalarTarget { storage, field, schema in
      schema.applyBoolean(storage, field, value)
    }
  }

  public mutating func null() {
    self.withScalarTarget { storage, field, schema in
      schema.applyNull(storage, field)
    }
  }

  // MARK: Scalar routing

  @usableFromInline
  struct ScalarTarget {
    var storage: UnsafeMutableRawPointer
    var schema: StreamSchema
    var field: Int32
  }

  @usableFromInline var scalarTarget: ScalarTarget?

  private mutating func resolveScalarTarget() -> ScalarTarget? {
    guard let top = self.topFrame else {
      // A bare scalar document never opens a container, so no frame was ever pushed and the
      // root is the destination.
      guard !self.started else { return nil }
      guard self.rootSchema.shape == .scalar else {
        self.recordFailure(.typeMismatch)
        return nil
      }
      return ScalarTarget(storage: self.root, schema: self.rootSchema, field: 0)
    }
    switch top.pointee.schema.shape {
    case .array:
      guard let element = top.pointee.schema.appendElement(top.pointee.storage) else { return nil }
      return ScalarTarget(storage: element.storage, schema: element.schema, field: 0)
    case .object:
      guard top.pointee.pendingField >= 0 else { return nil }
      return ScalarTarget(
        storage: top.pointee.storage, schema: top.pointee.schema, field: top.pointee.pendingField
      )
    case .dictionary:
      guard let frame = self.pendingDictionaryFrame else { return nil }
      return ScalarTarget(storage: frame.storage, schema: frame.schema, field: 0)
    case .scalar:
      return ScalarTarget(storage: top.pointee.storage, schema: top.pointee.schema, field: 0)
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
