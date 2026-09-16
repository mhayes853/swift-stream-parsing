/// A selected field's state in the input document, independently of document completion.
/// `incomplete(nil)` means a token has started without a representable partial value yet.
/// Container completion means the closing delimiter arrived, not that every model member exists.
public enum ObservedField<Value> {
  case missing
  case null
  case incomplete(Value?)
  case complete(Value)
}

extension ObservedField: Equatable where Value: Equatable {}
extension ObservedField: Sendable where Value: Sendable {}

/// Failures configuring or reading a field observation.
public enum FieldObservationError: Error, Equatable, Sendable {
  /// Select a direct stored member registered in an object root's field table.
  case unsupportedField
  /// The runtime does not provide key-path reflection.
  case reflectionUnavailable
  /// Observation must be installed before any input has been parsed.
  case alreadyStarted
  /// A custom schema accepted a non-null token but did not populate the selected member.
  case unavailableValue
}

// Key paths and reflection are not supported by Embedded Swift. The event tracker below has
// no such dependency; only the typed selection and its public drivers need this gate.
#if !hasFeature(Embedded)
  @_spi(Reflection) import Swift

  /// A validated, reusable selection of one direct stored object field.
  /// Key aliases are resolved by the schema, not the Swift property name. Computed/nested paths,
  /// ignored members, and roots without a field table throw `unsupportedField`.
  /// Validation uses reflection once; reuse a path when parsing many documents of the same type.
  public struct ObservedFieldPath<Root: StreamParseableRoot, Value: StreamParseableRoot>: Sendable {
    let offset: Int
    let optional: Bool

    public init(_ path: KeyPath<Root, Value?>) throws {
      self.offset = try Self.validate(path, optional: true)
      self.optional = true
    }

    @_disfavoredOverload
    public init(_ path: KeyPath<Root, Value>) throws {
      self.offset = try Self.validate(path, optional: false)
      self.optional = false
    }

    private static func validate(_ path: PartialKeyPath<Root>, optional: Bool) throws -> Int {
      // An offset alone is insufficient: a nested stored key path can have the same offset as
      // its containing field. Check identity against the root's direct stored paths first.
      guard #available(macOS 11.3, iOS 14.5, tvOS 14.5, watchOS 7.4, *) else {
        throw FieldObservationError.reflectionUnavailable
      }
      let schema = Root.streamSchema
      guard let offset = MemoryLayout<Root>.offset(of: path),
        schema.shape == .object, let entries = schema.fieldEntries
      else {
        throw FieldObservationError.unsupportedField
      }
      var direct = false
      var matchingOffsets = 0
      let fullyReflected = _forEachFieldWithKeyPath(of: Root.self) { _, candidate in
        if candidate == path {
          direct = true
        }
        if MemoryLayout<Root>.offset(of: candidate) == offset {
          // Zero-sized members can even have equal key paths. Count all fields at this offset,
          // not just unequal paths: the schema table cannot distinguish overlapping members.
          matchingOffsets += 1
        }
        return true
      }
      guard fullyReflected, direct, matchingOffsets == 1 else { throw FieldObservationError.unsupportedField }
      for index in 0..<schema.fieldCount {
        if Int(entries[index].offset) == offset, entries[index].isOptional == optional {
          return offset
        }
      }
      throw FieldObservationError.unsupportedField
    }

    func snapshot(from root: UnsafeMutablePointer<Root>, phase: FieldObservationState.Phase)
      throws -> ObservedField<Value>
    {
      switch phase {
      case .missing: return .missing
      case .null: return .null
      case .incompleteScalar: return .incomplete(nil)
      case .incompleteValue, .complete:
        // The key path validated this exact stored type/offset. Reading only its slot avoids
        // copying the root and preserves nested Optional payloads rather than flattening them.
        let address = UnsafeRawPointer(root).advanced(by: self.offset)
        let value: Value? =
          self.optional
          ? address.assumingMemoryBound(to: Value?.self).pointee
          : .some(address.assumingMemoryBound(to: Value.self).pointee)
        if phase == .incompleteValue { return .incomplete(value) }
        guard let value else { throw FieldObservationError.unavailableValue }
        return .complete(value)
      }
    }
  }
#endif

// Constant-size state for one root member. Ordinary partials/sinks carry none of this state.
struct FieldObservationState {
  enum Phase { case missing, null, incompleteScalar, incompleteValue, complete }
  let offset: Int
  var phase = Phase.missing
  var depth = 0
  var pending = false
  var stringActive = false
  var containerDepth = 0

  mutating func beginContainer() {
    if self.depth == 1, self.pending {
      self.pending = false
      self.phase = .incompleteValue
      self.containerDepth = self.depth + 1
    }
    self.depth += 1
  }

  mutating func endContainer() {
    if self.depth == self.containerDepth {
      self.phase = .complete
      self.containerDepth = 0
    }
    self.depth -= 1
  }

  mutating func finishScalar(null: Bool = false) {
    if self.depth == 1, self.pending {
      self.phase = null ? .null : .complete
      self.pending = false
    }
  }

  mutating func settle(parserState: JSONParser.State) {
    // Number/literal starts have no sink event. At a successful chunk boundary the parser's
    // actual lexical state distinguishes a token in progress from a key awaiting ':'/a value.
    if self.depth == 1, self.pending, parserState == .number || parserState == .literal {
      self.phase = .incompleteScalar
    }
  }
}

// The base pointer is borrowed only for one parse/finish call. Never retained by the driver.
// Forward skip dispositions and failure polling exactly as PartialSink does; skipped subtrees
// still deliver their closing event, so depth remains balanced without observing their interior.
struct FieldObservationSink: ~Copyable, StreamParseSink {
  let base: UnsafeMutablePointer<PartialSink>
  var observation: FieldObservationState

  var streamFailure: StreamSinkFailure? { self.base.pointee.streamFailure }

  mutating func beginObject() -> StreamContainerDisposition {
    self.observation.beginContainer()
    return self.base.pointee.beginObject()
  }
  mutating func beginArray() -> StreamContainerDisposition {
    self.observation.beginContainer()
    return self.base.pointee.beginArray()
  }
  mutating func endObject() {
    self.base.pointee.endObject()
    self.observation.endContainer()
  }
  mutating func endArray() {
    self.base.pointee.endArray()
    self.observation.endContainer()
  }
  mutating func key(_ bytes: Span<UInt8>) {
    self.base.pointee.key(bytes)
    guard self.observation.depth == 1 else { return }
    self.observation.pending = false
    guard let top = self.base.pointee.topFrame,
      top.pointee.pendingField >= 0,
      let entries = self.base.pointee.rootSchema.fieldEntries
    else { return }
    self.observation.pending =
      Int(entries[Int(top.pointee.pendingField)].offset) == self.observation.offset
  }
  mutating func stringBegin() {
    if self.observation.depth == 1, self.observation.pending {
      self.observation.pending = false
      self.observation.stringActive = true
      self.observation.phase = .incompleteValue
    }
    self.base.pointee.stringBegin()
  }
  mutating func stringChunk(_ bytes: Span<UInt8>) { self.base.pointee.stringChunk(bytes) }
  mutating func stringEnd() {
    self.base.pointee.stringEnd()
    if self.observation.stringActive {
      self.observation.stringActive = false
      self.observation.phase = .complete
    }
  }
  mutating func string(_ bytes: Span<UInt8>) {
    self.base.pointee.string(bytes)
    self.observation.finishScalar()
  }
  mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) {
    self.base.pointee.number(bytes, info: info)
    self.observation.finishScalar()
  }
  mutating func boolean(_ value: Bool) {
    self.base.pointee.boolean(value)
    self.observation.finishScalar()
  }
  mutating func null() {
    self.base.pointee.null()
    self.observation.finishScalar(null: true)
  }
  mutating func commit() { self.base.pointee.commit() }
}

extension PartialsStream {
  mutating func nextObserving(_ bytes: some Sequence<UInt8>, state: inout FieldObservationState)
    throws
  {
    guard !self.hasParserThrown else { throw StreamParsingError.parserThrows }
    guard !self.hasFinished else { throw StreamParsingError.parserFinished }
    do {
      try withUnsafeMutablePointer(to: &self.sink) { base in
        var sink = FieldObservationSink(base: base, observation: state)
        defer { state = sink.observation }
        let parsed: Void? = try bytes.withContiguousStorageIfAvailable { buffer in
          try self.parser.parse(buffer, into: &sink)
        }
        if parsed == nil {
          for byte in bytes { try self.parser.parse(byte: byte, into: &sink) }
        }
        sink.observation.settle(parserState: self.parser.state)
      }
    } catch {
      self.hasParserThrown = true
      throw error
    }
  }

  mutating func finishObserving(state: inout FieldObservationState) throws {
    guard !self.hasParserThrown else { throw StreamParsingError.parserThrows }
    guard !self.hasFinished else { throw StreamParsingError.parserFinished }
    self.hasFinished = true
    do {
      try withUnsafeMutablePointer(to: &self.sink) { base in
        var sink = FieldObservationSink(base: base, observation: state)
        defer { state = sink.observation }
        try self.parser.finish(into: &sink)
      }
    } catch {
      self.hasParserThrown = true
      throw error
    }
  }
}
