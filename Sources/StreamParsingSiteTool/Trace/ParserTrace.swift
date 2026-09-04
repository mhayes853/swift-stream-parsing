import Foundation
import StreamParsingCore

/// A sink that keeps the token stream. Nothing here is a reimplementation: these are the calls the
/// parser makes, in the order it makes them.
struct RecordingSink: StreamParseSink {
  struct Event {
    var kind: String
    var text: String?
    /// Where the span the parser passed sits in the buffer that was parsed, when it passed one.
    /// This is the parser's own answer to "which bytes is this token", not a rescan of the input.
    var spanOffset: Int?
    var spanLength: Int?
  }

  var events: [Event] = []
  var streamFailure: StreamSinkFailure?
  /// The buffer handed to `parse`, so a span can be resolved back to an offset in it.
  var base: UnsafeRawPointer?
  var count: Int = 0

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
    self.append("key", bytes)
  }
  // Overridden rather than left to the default decomposition, so the trace shows which form the
  // parser actually chose: a whole `string` on the common path, the chunked triple otherwise.
  mutating func string(_ bytes: Span<UInt8>) {
    self.append("string", bytes)
  }
  mutating func stringBegin() { self.events.append(Event(kind: "stringBegin", text: nil)) }
  mutating func stringChunk(_ bytes: Span<UInt8>) {
    self.append("stringChunk", bytes)
  }
  mutating func stringEnd() { self.events.append(Event(kind: "stringEnd", text: nil)) }
  mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) {
    self.append("number", bytes)
  }
  mutating func boolean(_ value: Bool) {
    self.events.append(Event(kind: "boolean", text: value ? "true" : "false"))
  }
  mutating func null() { self.events.append(Event(kind: "null", text: "null")) }

  /// Records a span-carrying event with the span's position in the parsed buffer.
  ///
  /// A span that does not point into that buffer -- which is what a string the parser had to
  /// unescape into scratch storage looks like -- resolves to `nil` rather than to a wrong offset,
  /// and the caller downgrades its verification instead of guessing.
  private mutating func append(_ kind: String, _ bytes: Span<UInt8>) {
    var offset: Int?
    if let base = self.base {
      bytes.withUnsafeBufferPointer { buffer in
        guard let start = buffer.baseAddress else { return }
        let delta = UnsafeRawPointer(start) - base
        if delta >= 0 && delta + buffer.count <= self.count { offset = delta }
      }
    }
    self.events.append(
      Event(kind: kind, text: Self.text(bytes), spanOffset: offset, spanLength: bytes.count)
    )
  }

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
    try bytes.withUnsafeBufferPointer { buffer in
      sink.base = UnsafeRawPointer(buffer.baseAddress!)
      sink.count = buffer.count
      try parser.parse(buffer, into: &sink)
    }
    try parser.finish(into: &sink)

    let ranges = self.tokenRanges(bytes: bytes, events: sink.events)

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
          offset: ranges.spans[index].lowerBound,
          length: ranges.spans[index].count,
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

    return ContainerTrace(
      sample: sample,
      steps: steps,
      maximumDepth: try self.measuredMaximumDepth(),
      offsetsVerified: ranges.verified
    )
  }

  /// Where each token the parser reported sits in the bytes it was given.
  ///
  /// The animation needs to point at the input while it steps, and the offset it points at has to
  /// be the parser's, not a rescan's. Two independent derivations run here and are required to
  /// agree:
  ///
  /// - Every token that arrives with a `Span` already carries its position: the span points into
  ///   the very buffer that was handed to `parse`, so subtracting the base *is* the offset. That
  ///   covers keys, strings and numbers.
  /// - Structural tokens and literals arrive with no span at all -- `beginObject()` takes no
  ///   argument -- so a cursor walks forward from the end of the previous token, skipping
  ///   whitespace with the shipped `streamWhitespaceEnd` and stepping over one `,` or `:`. That is
  ///   the parser's own separator grammar and its own whitespace scanner, not a second scan of the
  ///   document.
  ///
  /// The walk also runs across the span-carrying tokens, and `verified` is false unless it landed
  /// on exactly the offset the span reported for every one of them. A chunked string -- where the
  /// bytes are unescaped into scratch storage and the span no longer points into the input --
  /// resolves to no offset and fails that check rather than being papered over.
  static func tokenRanges(
    bytes: [UInt8],
    events: [RecordingSink.Event]
  ) -> (spans: [Range<Int>], verified: Bool) {
    var spans: [Range<Int>] = []
    var verified = true
    var cursor = 0

    bytes.withUnsafeBytes { raw in
      let base = raw.baseAddress!
      for event in events {
        // Skip to the next token the way the parser does: whitespace, then at most one separator,
        // then whitespace again.
        cursor = streamWhitespaceEnd(base: base, from: cursor, to: bytes.count)
        if cursor < bytes.count, bytes[cursor] == 0x2C || bytes[cursor] == 0x3A {
          cursor = streamWhitespaceEnd(base: base, from: cursor + 1, to: bytes.count)
        }

        let start = cursor
        var length: Int
        switch event.kind {
        case "beginObject", "beginArray", "endObject", "endArray":
          length = 1
        case "key", "string":
          // The span is the content between the quotes, so the token is two bytes wider.
          length = (event.spanLength ?? 0) + 2
        case "number":
          length = streamNumberRunEnd(base: base, from: start, to: bytes.count) - start
        case "boolean", "null":
          length = event.text?.utf8.count ?? 0
        default:
          // A chunked string has no single token range here; say so rather than invent one.
          length = 0
          verified = false
        }
        if length <= 0 || start + length > bytes.count {
          length = min(1, bytes.count - start)
          verified = false
        }

        // Cross-check: where the parser handed over a span, the walk has to have landed on it.
        if let spanOffset = event.spanOffset {
          let expected = event.kind == "key" || event.kind == "string" ? start + 1 : start
          if spanOffset != expected { verified = false }
        } else if event.kind == "key" || event.kind == "string" || event.kind == "number" {
          verified = false
        }

        spans.append(start..<(start + length))
        cursor = start + length
      }
    }
    return (spans, verified)
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
