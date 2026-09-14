import Testing

import StreamParsingCore

// `StreamParseSink._streamCoalescesStringChunks` is advisory about *boundaries only*: a sink that
// answers `true` gets the same events in the same order carrying the same bytes, with the string
// content of a value regrouped into fewer chunks. Nothing else about a parse may move — not the
// key/number/structure stream, not the errors, not where a rejection surfaces, and not where a
// chunk boundary cuts a value.
//
// The oracle is the same document parsed with the same chunking through a sink that answers
// `false`, with adjacent `stringChunk`s of each value folded together on both sides.
@Suite
struct `Coalesced string chunk tests` {
  enum Event: Equatable {
    case beginObject, endObject, beginArray, endArray
    case key([UInt8])
    case stringBegin, stringChunk([UInt8]), stringEnd
    case number([UInt8], NumberInfo)
    case boolean(Bool), null
  }

  // Two conformances that differ in exactly one static answer. Spelled as a generic over a
  // `Policy` witness so the bodies cannot drift apart.
  protocol CoalescePolicy {
    static var coalesces: Bool { get }
  }
  enum Coalescing: CoalescePolicy { static var coalesces: Bool { true } }
  enum Fragmenting: CoalescePolicy { static var coalesces: Bool { false } }

  struct RecordingSink<Policy: CoalescePolicy>: StreamParseSink {
    var events: [Event] = []
    var streamFailure: StreamSinkFailure?
    var rejectAtString: Int? = nil
    var stringsSeen = 0

    static var _streamCoalescesStringChunks: Bool { Policy.coalesces }

    mutating func beginObject() -> StreamContainerDisposition {
      self.events.append(.beginObject)
      return .stream
    }
    mutating func endObject() { self.events.append(.endObject) }
    mutating func beginArray() -> StreamContainerDisposition {
      self.events.append(.beginArray)
      return .stream
    }
    mutating func endArray() { self.events.append(.endArray) }
    mutating func key(_ bytes: Span<UInt8>) { self.events.append(.key(streamCopy(bytes))) }
    mutating func stringBegin() {
      self.events.append(.stringBegin)
      self.stringsSeen += 1
      if self.stringsSeen == self.rejectAtString, self.streamFailure == nil {
        self.streamFailure = StreamSinkFailure(reason: .typeMismatch)
      }
    }
    mutating func stringChunk(_ bytes: Span<UInt8>) {
      self.events.append(.stringChunk(streamCopy(bytes)))
    }
    mutating func stringEnd() { self.events.append(.stringEnd) }
    mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) {
      self.events.append(.number(streamCopy(bytes), info))
    }
    mutating func boolean(_ value: Bool) { self.events.append(.boolean(value)) }
    mutating func null() { self.events.append(.null) }
  }

  struct Outcome: Equatable {
    var events: [Event]
    var error: JSONParsingError?
  }

  // Adjacent chunks folded: the one difference the property is allowed to make.
  //
  // The run is accumulated in a local rather than rewritten into `out`: rebuilding the element as
  // `.stringChunk(previous + bytes)` allocated and copied the whole value so far on every chunk,
  // which is quadratic in the number of chunks -- and the chunk-of-one ladder makes that the
  // number of *bytes*. Appending in place into an accumulator nothing else references is
  // amortised linear.
  static func folding(_ events: [Event]) -> [Event] {
    var out = [Event]()
    out.reserveCapacity(events.count)
    var run: [UInt8]?
    for event in events {
      if case .stringChunk(let bytes) = event {
        if run == nil { run = bytes } else { run!.append(contentsOf: bytes) }
        continue
      }
      if let run { out.append(.stringChunk(run)) }
      run = nil
      out.append(event)
    }
    if let run { out.append(.stringChunk(run)) }
    return out
  }

  // How many strings the document actually reaches before it ends or fails, which is what bounds
  // the rejection points worth trying: a single string document has no second string to reject at,
  // so a second pass over it would re-run the first one's parse for nothing.
  static func stringCount(_ bytes: [UInt8]) -> Int {
    Self.run(bytes, chunk: .max, policy: Fragmenting.self)
      .events
      .reduce(into: 0) { count, event in if case .stringBegin = event { count += 1 } }
  }

  static func run<Policy: CoalescePolicy>(
    _ bytes: [UInt8], chunk: Int, policy: Policy.Type, rejectAtString: Int? = nil
  ) -> Outcome {
    var sink = RecordingSink<Policy>()
    sink.rejectAtString = rejectAtString
    var error: JSONParsingError?
    do {
      try feed(bytes, chunk: chunk, into: &sink)
    } catch let caught {
      error = caught
    }
    return Outcome(events: Self.folding(sink.events), error: error)
  }

  // `Int.max` and any size at or past the document is the same single call parse, and every
  // document here is under 11 KB, so the ladder is deduped against the document's own length
  // rather than run twice.
  static func expectEquivalent(
    _ bytes: [UInt8], _ label: String, rejectAtString: Int? = nil,
    chunks: [Int] = [Int.max, 1, 7, 64, 1000]
  ) {
    for chunk in Set(chunks.map { min($0, bytes.count) }).sorted() {
      let fragmented = Self.run(
        bytes, chunk: chunk, policy: Fragmenting.self, rejectAtString: rejectAtString
      )
      let coalesced = Self.run(
        bytes, chunk: chunk, policy: Coalescing.self, rejectAtString: rejectAtString
      )
      guard coalesced != fragmented else { continue }
      let at =
        zip(coalesced.events, fragmented.events).enumerated().first { $1.0 != $1.1 }?.offset
        ?? min(coalesced.events.count, fragmented.events.count)
      let lo = max(0, at - 3)
      Issue.record(
        """
        \(label): chunk \(chunk) diverges at event \(at) \
        (\(coalesced.events.count) vs \(fragmented.events.count) events; \
        errors \(String(describing: coalesced.error)) vs \(String(describing: fragmented.error)))
          coalesced:  \(coalesced.events[lo..<min(coalesced.events.count, at + 2)])
          fragmented: \(fragmented.events[lo..<min(fragmented.events.count, at + 2)])
        """
      )
      return
    }
  }

  static let documents: [(String, String)] = [
    ("simple escapes", #"["a\nb\tc", "\"quoted\"", "back\\slash"]"#),
    ("escape at start", #"["\nabc", "Abc"]"#),
    ("escape at end", #"["abc\n", "abcA"]"#),
    ("only escapes", #"["\n\t\r\b\f\/\\\""]"#),
    ("unicode escapes", #"["\u0041\u00e9\u20ac\ud83d\ude00", "\u0000"]"#),
    ("lone high surrogate", #"["\ud83d"]"#),
    ("bad escape", #"["\q"]"#),
    ("bad hex", #"["\u00zz"]"#),
    ("truncated escape", #"["abc\"#),
    ("non-ascii around escapes", #"["h\u00e9llo\nw\u00f6rld\t\u65e5\u672c\u8a9e and héllo"]"#),
    ("escaped key", #"{"a\nb": "c\nd", "plain": "value"}"#),
    (
      "long escaped value",
      "[\"" + String(repeating: "0123456789abcdef\\n", count: 600) + "\"]"
    ),
    (
      "escape spanning the buffer",
      "[\"" + String(repeating: "x", count: 5000) + "\\n"
        + String(repeating: "y", count: 5000) + "\"]"
    ),
    ("mixed values", #"{"a": [1, 2.5, true, null, "x\ny"], "b": "no escapes here"}"#)
  ]

  @Test(arguments: documents)
  func `Coalescing only regroups string chunks`(label: String, json: String) {
    Self.expectEquivalent(Array(json.utf8), label)
  }

  @Test(arguments: documents)
  func `A rejection surfaces in the same place`(label: String, json: String) {
    let bytes = Array(json.utf8)
    let strings = Self.stringCount(bytes)
    guard strings > 0 else { return }
    for reject in 1...min(strings, 2) {
      Self.expectEquivalent(bytes, "\(label) reject \(reject)", rejectAtString: reject)
    }
  }

  // Two chunkings per corpus: whole, and one small enough to cut values apart. A third size only
  // repeated the property these two already cover, at megabytes of recorded events apiece.
  @Test(arguments: ["citm_catalog", "gsoc-2018", "llm_message", "twitter", "twitterescaped"])
  func `Benchmark corpora coalesce to the same bytes`(name: String) throws {
    let document = try #require(streamBenchmarkCorpus(name))
    Self.expectEquivalent(document, name, chunks: [Int.max, 4096])
  }
}
