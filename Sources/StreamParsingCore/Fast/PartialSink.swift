// Routes parse events into a value described by a StreamSchema.
//
// Frames point into the value being built. Only the innermost open container is ever mutated,
// so an element pointer stays valid for that element's lifetime: appending to an outer array
// cannot happen while an inner one is open.
public struct PartialSink<Root>: StreamParseSink {
  public private(set) var streamFailure: StreamSinkFailure?

  @usableFromInline var root: UnsafeMutableRawPointer
  @usableFromInline var rootSchema: StreamSchema
  @usableFromInline var frames: [StreamFrame] = []
  @usableFromInline var started = false
  @usableFromInline var pendingDictionaryFrame: StreamFrame?

  // A document whose root is an array, a dictionary or a bare scalar is as valid as one rooted
  // in an object, so the root's shape comes from its schema rather than from a constraint.
  public init(root: UnsafeMutablePointer<Root>, schema: StreamSchema) {
    self.root = UnsafeMutableRawPointer(root)
    self.rootSchema = schema
  }

  // MARK: Containers

  public mutating func beginObject() {
    self.enterContainer(shape: .object)
  }

  public mutating func beginArray() {
    self.enterContainer(shape: .array)
  }

  public mutating func endObject() {
    _ = self.frames.popLast()
  }

  public mutating func endArray() {
    _ = self.frames.popLast()
  }

  private mutating func enterContainer(shape: StreamSchema.Shape) {
    guard self.started else {
      self.started = true
      // A scalar destination has nothing to route a container's contents into, so the subtree is
      // discarded rather than written through the root.
      let schema = self.rootSchema.shape == .scalar ? Self.ignoredSchema : self.rootSchema
      self.frames.append(StreamFrame(storage: self.root, schema: schema))
      return
    }
    guard let target = self.valueTarget() else {
      // No destination for this container, so its contents are skipped rather than misrouted.
      self.frames.append(StreamFrame(storage: self.root, schema: Self.ignoredSchema))
      return
    }
    self.frames.append(target)
  }

  // Produces the frame a value should be written through, appending an array element first when
  // the enclosing container is an array.
  private mutating func valueTarget() -> StreamFrame? {
    guard let top = self.frames.last else { return nil }
    switch top.schema.shape {
    case .array:
      return top.schema.appendElement(top.storage)
    case .object:
      guard top.pendingField >= 0 else { return nil }
      return top.schema.enterField(top.storage, top.pendingField)
    case .dictionary:
      defer { self.pendingDictionaryFrame = nil }
      return self.pendingDictionaryFrame
    case .scalar:
      return nil
    }
  }

  // MARK: Keys

  public mutating func key(_ bytes: Span<UInt8>) {
    guard var top = self.frames.last else { return }
    if top.schema.shape == .dictionary {
      // The key span does not outlive this call, so the value's frame is resolved now rather
      // than remembered and resolved when the value arrives.
      self.pendingDictionaryFrame = top.schema.enterKey(top.storage, bytes)
      return
    }
    top.pendingField = top.schema.matchField(bytes)
    self.frames[self.frames.count - 1] = top
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

  // A number arrives as a run of values, one per digit, so its destination is resolved once and
  // updated after that. Resolving per event would append a fresh array element per digit, which
  // turned `[1,2` into `[1, 1, 2]`. Strings have always worked this way; numbers do now too.
  public mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) {
    if !self.inNumber {
      self.numberTarget = self.resolveScalarTarget()
      self.inNumber = true
    }
    let target = self.numberTarget
    if !info.flags.contains(.incomplete) {
      self.inNumber = false
      self.numberTarget = nil
    }
    guard let target else { return }
    if !target.schema.applyNumber(target.storage, target.field, bytes, info) {
      self.recordFailure(.typeMismatch)
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

  // Tracked separately from the target itself, because a number under a key the destination does
  // not have resolves to no target at all, and that still has to count as being mid-number.
  @usableFromInline var numberTarget: ScalarTarget?
  @usableFromInline var inNumber = false

  private mutating func resolveScalarTarget() -> ScalarTarget? {
    guard let top = self.frames.last else {
      // A bare scalar document never opens a container, so no frame was ever pushed and the
      // root is the destination.
      guard !self.started, self.rootSchema.shape == .scalar else { return nil }
      return ScalarTarget(storage: self.root, schema: self.rootSchema, field: 0)
    }
    switch top.schema.shape {
    case .array:
      guard let element = top.schema.appendElement(top.storage) else { return nil }
      return ScalarTarget(storage: element.storage, schema: element.schema, field: 0)
    case .object:
      guard top.pendingField >= 0 else { return nil }
      return ScalarTarget(storage: top.storage, schema: top.schema, field: top.pendingField)
    case .dictionary:
      guard let frame = self.pendingDictionaryFrame else { return nil }
      return ScalarTarget(storage: frame.storage, schema: frame.schema, field: 0)
    case .scalar:
      return ScalarTarget(storage: top.storage, schema: top.schema, field: 0)
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
