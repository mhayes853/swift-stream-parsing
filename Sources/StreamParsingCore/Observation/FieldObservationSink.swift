// The machinery behind field observation: the depth bookkeeping that tells a watched field's value
// is complete, the sink that feeds it while forwarding every event to `PartialSink`, and the
// `PartialsStream` drivers the sync and async iterators share.

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
