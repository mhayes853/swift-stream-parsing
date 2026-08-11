// Routes parse events into a value described by a StreamSchema.
//
// Frames point into the value being built. Only the innermost open container is ever mutated,
// so an element pointer stays valid for that element's lifetime: appending to an outer array
// cannot happen while an inner one is open.
public struct PartialSink<Root: StreamParseableObject>: StreamParseSink {
  public private(set) var streamFailure: StreamSinkFailure?

  @usableFromInline var root: UnsafeMutableRawPointer
  @usableFromInline var frames: [StreamFrame] = []
  @usableFromInline var started = false
  @usableFromInline var pendingDictionaryFrame: StreamFrame?

  public init(root: UnsafeMutablePointer<Root>) {
    self.root = UnsafeMutableRawPointer(root)
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
      self.frames.append(StreamFrame(storage: self.root, schema: Root.streamSchema))
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
    self.scalarTarget = self.resolveScalarTarget()
  }

  public mutating func stringChunk(_ bytes: Span<UInt8>) {
    guard let target = self.scalarTarget else { return }
    target.schema.applyString(target.storage, target.field, bytes)
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
    guard let top = self.frames.last else { return nil }
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

  private mutating func withScalarTarget(
    _ body: (UnsafeMutableRawPointer, Int32, StreamSchema) -> Void
  ) {
    guard let target = self.resolveScalarTarget() else { return }
    body(target.storage, target.field, target.schema)
  }

  // A schema that accepts and discards everything, used for subtrees the destination has no
  // field for. Without it an unknown key's nested object would be routed to the parent.
  @usableFromInline
  static var ignoredSchema: StreamSchema {
    StreamSchema(shape: .object)
  }
}
