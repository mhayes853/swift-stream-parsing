import Foundation

@testable import StreamParsingCore

// Recorders for the sink boundary: the call log, the two dispositions, and the skip scanner's
// walk. Every one of these runs the shipped parser against a real sink; nothing is simulated.

// MARK: - A sink that answers `.skip` at one key

/// Records the parser's calls the way ``RecordingSink`` does, but refuses the interior of the
/// container that follows a chosen key.
///
/// This is the disposition contract exercised rather than described: the sink answers `.skip`,
/// the parser scans the subtree at structural speed, and the matching close still arrives.
struct SkippingSink: StreamParseSink {
  var events: [RecordingSink.Event] = []
  var streamFailure: StreamSinkFailure?
  var base: UnsafeRawPointer?
  var count: Int = 0

  /// The key whose container is refused.
  var skipKey: [UInt8] = []
  /// Set by `key(_:)` when the key matched; consumed by the container open that follows.
  private var armed = false

  mutating func beginObject() -> StreamContainerDisposition {
    self.events.append(RecordingSink.Event(kind: "beginObject", text: nil))
    return self.take()
  }
  mutating func endObject() {
    self.events.append(RecordingSink.Event(kind: "endObject", text: nil))
  }
  mutating func beginArray() -> StreamContainerDisposition {
    self.events.append(RecordingSink.Event(kind: "beginArray", text: nil))
    return self.take()
  }
  mutating func endArray() {
    self.events.append(RecordingSink.Event(kind: "endArray", text: nil))
  }

  mutating func key(_ bytes: Span<UInt8>) {
    var matches = self.skipKey.count == bytes.count
    if matches {
      // Written out rather than closed over: `Span` is `~Escapable`, so it cannot be captured.
      var i = 0
      while i < bytes.count {
        if bytes[i] != self.skipKey[i] {
          matches = false
          break
        }
        i += 1
      }
    }
    self.armed = matches
    self.append("key", bytes)
  }
  mutating func string(_ bytes: Span<UInt8>) { self.append("string", bytes) }
  mutating func stringBegin() {
    self.events.append(RecordingSink.Event(kind: "stringBegin", text: nil))
  }
  mutating func stringChunk(_ bytes: Span<UInt8>) { self.append("stringChunk", bytes) }
  mutating func stringEnd() { self.events.append(RecordingSink.Event(kind: "stringEnd", text: nil)) }
  mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) { self.append("number", bytes) }
  mutating func boolean(_ value: Bool) {
    self.events.append(RecordingSink.Event(kind: "boolean", text: value ? "true" : "false"))
  }
  mutating func null() { self.events.append(RecordingSink.Event(kind: "null", text: "null")) }

  private mutating func take() -> StreamContainerDisposition {
    defer { self.armed = false }
    return self.armed ? .skip : .stream
  }

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
      RecordingSink.Event(
        kind: kind,
        text: RecordingSink.text(bytes),
        spanOffset: offset,
        spanLength: bytes.count
      )
    )
  }
}

// MARK: - The recorders

enum SinkTraces {
  /// How the protocol spells each call, and which of the four groups it belongs to. The signature
  /// is the declaration's, so a renamed parameter shows up here.
  private static let shape: [String: (signature: String, group: String)] = [
    "beginObject": ("beginObject() -> StreamContainerDisposition", "structure"),
    "endObject": ("endObject()", "structure"),
    "beginArray": ("beginArray() -> StreamContainerDisposition", "structure"),
    "endArray": ("endArray()", "structure"),
    "key": ("key(_ bytes: Span<UInt8>)", "key"),
    "string": ("string(_ bytes: Span<UInt8>)", "whole"),
    "number": ("number(_ bytes: Span<UInt8>, info: NumberInfo)", "whole"),
    "boolean": ("boolean(_ value: Bool)", "whole"),
    "null": ("null()", "whole"),
    "stringBegin": ("stringBegin()", "chunked"),
    "stringChunk": ("stringChunk(_ bytes: Span<UInt8>)", "chunked"),
    "stringEnd": ("stringEnd()", "chunked")
  ]

  /// Turns a recorded event stream into the call log the animation steps through, and checks each
  /// span against the bytes it claims to cover.
  private static func calls(
    _ events: [RecordingSink.Event], bytes: [UInt8]
  ) -> (calls: [SinkCallTrace.Call], verified: Bool) {
    var out: [SinkCallTrace.Call] = []
    var depth = 0
    var verified = true
    for (index, event) in events.enumerated() {
      switch event.kind {
      case "beginObject", "beginArray": depth += 1
      case "endObject", "endArray": depth -= 1
      default: break
      }
      // A span the parser handed over has to cover exactly the bytes the call's text reports.
      // This is the whole zero-copy claim, checked rather than asserted.
      if let offset = event.spanOffset, let length = event.spanLength, let text = event.text {
        let covered = offset >= 0 && offset + length <= bytes.count
        if !covered || String(decoding: bytes[offset..<(offset + length)], as: UTF8.self) != text {
          verified = false
        }
      }
      let shape = Self.shape[event.kind] ?? (signature: event.kind, group: "structure")
      out.append(
        SinkCallTrace.Call(
          index: index,
          method: event.kind,
          signature: shape.signature,
          text: event.text,
          offset: event.spanOffset,
          length: event.spanLength,
          takesSpan: event.spanLength != nil,
          depthAfter: depth,
          group: shape.group
        )
      )
    }
    return (out, verified)
  }

  // MARK: The call log

  static func sinkCalls(sample: String) throws -> SinkCallTrace {
    let bytes = Array(sample.utf8)
    var sink = RecordingSink()
    var parser = JSONParser()
    try bytes.withUnsafeBufferPointer { buffer in
      sink.base = UnsafeRawPointer(buffer.baseAddress!)
      sink.count = buffer.count
      try parser.parse(buffer, into: &sink)
    }
    try parser.finish(into: &sink)
    let (calls, verified) = Self.calls(sink.events, bytes: bytes)
    return SinkCallTrace(sample: sample, bytes: bytes, calls: calls, verified: verified)
  }

  // MARK: Dispositions

  static func dispositions(sample: String, skipping key: String) throws -> DispositionTrace {
    let bytes = Array(sample.utf8)

    var streaming = RecordingSink()
    var streamingParser = JSONParser()
    try bytes.withUnsafeBufferPointer { buffer in
      streaming.base = UnsafeRawPointer(buffer.baseAddress!)
      streaming.count = buffer.count
      try streamingParser.parse(buffer, into: &streaming)
    }
    try streamingParser.finish(into: &streaming)

    var skipping = SkippingSink()
    skipping.skipKey = Array(key.utf8)
    var skippingParser = JSONParser()
    try bytes.withUnsafeBufferPointer { buffer in
      skipping.base = UnsafeRawPointer(buffer.baseAddress!)
      skipping.count = buffer.count
      try skippingParser.parse(buffer, into: &skipping)
    }
    try skippingParser.finish(into: &skipping)

    let (streamed, streamedOK) = Self.calls(streaming.events, bytes: bytes)
    let (skipped, skippedOK) = Self.calls(skipping.events, bytes: bytes)

    // Which of the streaming run's calls the skipping run also received. The skipping run is a
    // subsequence of the streaming one -- the parser cannot invent a call by skipping -- so one
    // walk over both settles it, and a mismatch means it is not a subsequence, which is a failure.
    var delivered = [Bool](repeating: false, count: streamed.count)
    var cursor = 0
    var subsequence = true
    for (index, call) in streamed.enumerated() {
      guard cursor < skipped.count else { break }
      if skipped[cursor].method == call.method && skipped[cursor].text == call.text {
        delivered[index] = true
        cursor += 1
      }
    }
    if cursor != skipped.count { subsequence = false }

    // The subtree's byte range: from the open bracket the sink refused to the close it still got.
    let ranges = ParserTraces.tokenRanges(bytes: bytes, events: streaming.events)
    var from = 0
    var to = bytes.count
    if let firstElided = delivered.firstIndex(of: false) {
      // The refused open is the call immediately before the first one that stopped arriving, and
      // its matching close is the next call that arrives again.
      from = ranges.spans[max(firstElided - 1, 0)].lowerBound
      var closeIndex = firstElided
      while closeIndex < delivered.count && !delivered[closeIndex] { closeIndex += 1 }
      if closeIndex < delivered.count { to = ranges.spans[closeIndex].upperBound }
    }

    // The close always arrives: that is the advisory contract's other half, and it is what lets a
    // `PartialSink` pop the ignored frame it pushed at the open.
    let closes = skipped.filter { $0.method == "endObject" || $0.method == "endArray" }.count
    let opens = skipped.filter { $0.method == "beginObject" || $0.method == "beginArray" }.count

    return DispositionTrace(
      sample: sample,
      bytes: bytes,
      skippedKey: key,
      streamed: streamed,
      skipped: skipped,
      delivered: delivered,
      skipFrom: from,
      skipTo: to,
      verified: streamedOK && skippedOK && subsequence && opens == closes
        && skipped.count < streamed.count
    )
  }

  // MARK: The skip scanner

  /// Walks a skipped subtree the way `consumeSkipRun` does, then runs `consumeSkipRun` over the
  /// same bytes from the same state and requires the two to land on the same cursor.
  ///
  /// The walk below calls the same `package` scanners the shipped loop calls, in the same order,
  /// which is what makes it a mirror rather than a second implementation of the grammar.
  static func skipRun(sample: String, from: Int, startDepth: Int, containers seed: UInt64) throws
    -> SkipRunTrace
  {
    let bytes = Array(sample.utf8)
    var steps: [SkipRunTrace.Step] = []
    var end = from

    bytes.withUnsafeBytes { raw in
      let base = raw.baseAddress!
      let to = bytes.count
      var i = from
      var depth = startDepth
      var containers = seed
      let endDepth = startDepth - 1

      func containerString(_ depth: Int, _ containers: UInt64) -> String {
        (0..<depth).map { containers & (1 << UInt64($0)) != 0 ? "1" : "0" }.joined()
      }

      while i < to {
        let scanned = streamWhitespaceEndByte(base: base, from: i, to: to)
        i = scanned.end
        if i == to { break }
        let byte = scanned.byte
        let at = i
        let before = depth
        i &+= 1
        var action = "literal"
        var scanner: String?
        var emits = false

        switch byte {
        case UInt8(ascii: "{"):
          containers |= 1 << UInt64(depth)
          depth &+= 1
          action = "open"
        case UInt8(ascii: "["):
          containers &= ~(1 << UInt64(depth))
          depth &+= 1
          action = "open"
        case UInt8(ascii: "}"), UInt8(ascii: "]"):
          action = "close"
          if depth &- 1 == endDepth {
            // The event precedes the depth update, exactly as the shipped run orders them.
            emits = true
            depth &-= 1
            steps.append(
              SkipRunTrace.Step(
                offset: at, byte: byte, action: "done", scanner: nil, next: i,
                depthBefore: before, depthAfter: depth,
                containers: containerString(depth, containers), emits: emits
              )
            )
            end = i
            return
          }
          depth &-= 1
        case UInt8(ascii: "\""):
          action = "string"
          scanner = "streamStringRun"
          // The string body, scanned by the same kernel the streaming path uses; an escape is
          // consumed blind, which is the one place the skip differs from a delivered string.
          var j = i
          while j < to {
            let run = streamStringRun(base: base, from: j, to: to)
            j = run.end
            guard j < to else { break }
            let terminator = base.load(fromByteOffset: j, as: UInt8.self)
            j &+= 1
            if terminator == UInt8(ascii: "\"") { break }
            if terminator == UInt8(ascii: "\\") { j &+= 1 }
          }
          i = j
        case UInt8(ascii: ","), UInt8(ascii: ":"):
          action = "separator"
        case UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "+"), UInt8(ascii: "E"),
          UInt8(ascii: "0")...UInt8(ascii: "9"):
          action = "number"
          scanner = "streamNumberRunEnd"
          // The whole byte class in one scan; the grammar walk over it is what the skip omits.
          i = streamNumberRunEnd(base: base, from: at, to: to)
        default:
          action = "literal"
        }

        steps.append(
          SkipRunTrace.Step(
            offset: at, byte: byte, action: action, scanner: scanner, next: i,
            depthBefore: before, depthAfter: depth,
            containers: containerString(depth, containers), emits: emits
          )
        )
      }
      end = i
    }

    // Now the shipped function, from the same state over the same bytes.
    var parser = JSONParser()
    parser.state = .skipping
    parser.depth = startDepth
    parser.containers = seed
    parser.skipEndDepth = startDepth - 1
    var sink = RecordingSink()
    let shippedEnd = try bytes.withUnsafeBytes { raw -> Int in
      try parser.consumeSkipRun(
        base: raw.baseAddress!, from: from, to: bytes.count, into: &sink
      )
    }

    return SkipRunTrace(
      sample: sample,
      bytes: bytes,
      from: from,
      startDepth: startDepth,
      steps: steps,
      end: end,
      shippedEnd: shippedEnd,
      // The mirror has to agree with the shipped scanner on the cursor, and the shipped scanner
      // has to have delivered exactly the one close the contract promises.
      verified: end == shippedEnd && sink.events.count == 1
        && (sink.events[0].kind == "endObject" || sink.events[0].kind == "endArray")
    )
  }
}

extension SinkTraces {
  /// The skip walk for whatever subtree a disposition trace refused, so the two animations point
  /// at the same bytes of the same document without either one being told where they are.
  static func skipRun(for disposition: DispositionTrace) throws -> SkipRunTrace {
    let openIndex = max((disposition.delivered.firstIndex(of: false) ?? 1) - 1, 0)
    let open = disposition.streamed[openIndex]
    // The container register the parser is holding when the skip begins, rebuilt from the calls
    // that got it there by the rule the parser documents: `{` shifts a 1 in at `depth`, `[` a 0.
    var containers: UInt64 = 0
    var depth = 0
    for call in disposition.streamed[...openIndex] {
      switch call.method {
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
    }
    return try Self.skipRun(
      sample: disposition.sample,
      from: disposition.skipFrom + 1,
      startDepth: open.depthAfter,
      containers: containers
    )
  }
}
