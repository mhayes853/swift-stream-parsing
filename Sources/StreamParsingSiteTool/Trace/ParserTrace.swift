import Foundation
import StreamParsingCore

/// A sink that keeps the token stream. Nothing here is a reimplementation: these are the calls the
/// parser makes, in the order it makes them.
struct RecordingSink: StreamParseSink {
  struct Event {
    var kind: String
    var text: String?
  }

  var events: [Event] = []
  var streamFailure: StreamSinkFailure?

  mutating func beginObject() -> StreamContainerDisposition {
    self.events.append(Event(kind: "beginObject", text: nil))
    return .stream
  }
  mutating func endObject() { self.events.append(Event(kind: "endObject", text: nil)) }
  mutating func beginArray() -> StreamContainerDisposition {
    self.events.append(Event(kind: "beginArray", text: nil))
    return .stream
  }
  mutating func endArray() { self.events.append(Event(kind: "endArray", text: nil)) }

  mutating func key(_ bytes: Span<UInt8>) {
    self.events.append(Event(kind: "key", text: Self.text(bytes)))
  }
  // Overridden rather than left to the default decomposition, so the trace shows which form the
  // parser actually chose: a whole `string` on the common path, the chunked triple otherwise.
  mutating func string(_ bytes: Span<UInt8>) {
    self.events.append(Event(kind: "string", text: Self.text(bytes)))
  }
  mutating func stringBegin() { self.events.append(Event(kind: "stringBegin", text: nil)) }
  mutating func stringChunk(_ bytes: Span<UInt8>) {
    self.events.append(Event(kind: "stringChunk", text: Self.text(bytes)))
  }
  mutating func stringEnd() { self.events.append(Event(kind: "stringEnd", text: nil)) }
  mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) {
    self.events.append(Event(kind: "number", text: Self.text(bytes)))
  }
  mutating func boolean(_ value: Bool) {
    self.events.append(Event(kind: "boolean", text: value ? "true" : "false"))
  }
  mutating func null() { self.events.append(Event(kind: "null", text: "null")) }

  static func text(_ bytes: Span<UInt8>) -> String {
    var out: [UInt8] = []
    out.reserveCapacity(bytes.count)
    for i in 0..<bytes.count { out.append(bytes[i]) }
    return String(decoding: out, as: UTF8.self)
  }
}

enum ParserTraces {
  /// Runs a real parse and turns its container events into the register the parser keeps them in.
  ///
  /// `depth` and `containers` are `@usableFromInline`, so they are internal to `StreamParsingCore`
  /// and cannot be read from here. They do not need to be: the parser's rule is that a `{` shifts
  /// a 1 in at `depth` and a `[` shifts a 0, and the event stream driving that is the parser's own
  /// output.
  static func containers(sample: String) throws -> ContainerTrace {
    var sink = RecordingSink()
    var parser = JSONParser()
    let bytes = Array(sample.utf8)
    try bytes.withUnsafeBufferPointer { try parser.parse($0, into: &sink) }
    try parser.finish(into: &sink)

    var steps: [ContainerTrace.Step] = []
    var depth = 0
    var containers: UInt64 = 0

    for (index, event) in sink.events.enumerated() {
      let before = depth
      switch event.kind {
      case "beginObject":
        containers |= 1 << UInt64(depth)
        depth += 1
      case "beginArray":
        containers &= ~(1 << UInt64(depth))
        depth += 1
      case "endObject", "endArray":
        depth -= 1
      default:
        break
      }
      steps.append(
        ContainerTrace.Step(
          index: index,
          event: event.kind,
          text: event.text,
          depthBefore: before,
          depthAfter: depth,
          containersAfter: (0..<64).map { bit -> String in
            guard bit < depth else { return "." }
            return containers & (1 << UInt64(bit)) != 0 ? "1" : "0"
          }.joined(),
          containersBits: (0..<depth).map { Int((containers >> UInt64($0)) & 1) }
        )
      )
    }

    return ContainerTrace(sample: sample, steps: steps, maximumDepth: try self.measuredMaximumDepth())
  }

  /// The depth ceiling, measured rather than copied.
  ///
  /// `JSONParser.maximumDepth` is internal, and hard-coding 64 here would be a second place to
  /// keep it. Nesting arrays until the parser refuses asks the shipped parser what its own limit
  /// is, so the number in the explorer cannot disagree with the number in the code.
  static func measuredMaximumDepth() throws -> Int {
    var deepest = 0
    for depth in 1...96 {
      let json = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
      var sink = RecordingSink()
      var parser = JSONParser()
      let bytes = Array(json.utf8)
      do {
        try bytes.withUnsafeBufferPointer { try parser.parse($0, into: &sink) }
        try parser.finish(into: &sink)
        deepest = depth
      } catch {
        break
      }
    }
    return deepest
  }
}
