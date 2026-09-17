import Testing

import StreamParsingCore

// Every sink gets a string value's content coalesced from its first escape on: the decoded
// escapes and the literal runs between them are copied into the parser's buffer and delivered one
// chunk per buffer-full (see `JSONParser.coalescedEscapedStringTail`). That is allowed to change
// *boundaries only*: the same events in the same order carrying the same bytes, with the string
// content of a value regrouped into fewer chunks. Nothing else about a parse may move -- not the
// key/number/structure stream, not the errors, not where a `stringBegin` rejection surfaces, and
// not which parse call delivers which content: whatever was coalesced is flushed before a parse
// call returns.
//
// The oracle is the same document fed one byte per call. Byte fed input never enters the
// coalescing tail -- every backslash is the chunk's last byte, so each escape goes through the
// per-byte states and arrives as its own chunk -- which makes it an independent, fragment by
// fragment delivery of the same content. Each event is tagged with the parse call that delivered
// it; the byte fed tag (a byte offset) is mapped onto the chunked run's call index, and adjacent
// `stringChunk`s are folded only within one call on both sides.
@Suite
struct `Coalesced string chunk tests` {
  enum Event: Equatable {
    case beginObject, endObject, beginArray, endArray
    case key([UInt8])
    case stringBegin, stringChunk([UInt8]), stringEnd
    case number([UInt8], NumberInfo)
    case boolean(Bool), null
  }

  // `call` is the index of the parse call that delivered the event; `finish` is `Int.max`.
  struct Tagged: Equatable {
    var call: Int
    var event: Event
  }

  struct RecordingSink: StreamParseSink {
    var events: [Tagged] = []
    var call = 0
    var streamFailure: StreamSinkFailure?
    var rejectAtString: Int? = nil
    var rejectAtChunk: Int? = nil
    var stringsSeen = 0
    var chunksSeen = 0

    mutating func append(_ event: Event) { self.events.append(Tagged(call: self.call, event: event)) }

    mutating func beginObject() -> StreamContainerDisposition {
      self.append(.beginObject)
      return .stream
    }
    mutating func endObject() { self.append(.endObject) }
    mutating func beginArray() -> StreamContainerDisposition {
      self.append(.beginArray)
      return .stream
    }
    mutating func endArray() { self.append(.endArray) }
    mutating func key(_ bytes: Span<UInt8>) { self.append(.key(streamCopy(bytes))) }
    mutating func stringBegin() {
      self.append(.stringBegin)
      self.stringsSeen += 1
      if self.stringsSeen == self.rejectAtString, self.streamFailure == nil {
        self.streamFailure = StreamSinkFailure(reason: .typeMismatch)
      }
    }
    mutating func stringChunk(_ bytes: Span<UInt8>) {
      self.append(.stringChunk(streamCopy(bytes)))
      self.chunksSeen += 1
      if self.chunksSeen == self.rejectAtChunk, self.streamFailure == nil {
        self.streamFailure = StreamSinkFailure(reason: .typeMismatch)
      }
    }
    mutating func stringEnd() { self.append(.stringEnd) }
    mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) {
      self.append(.number(streamCopy(bytes), info))
    }
    mutating func boolean(_ value: Bool) { self.append(.boolean(value)) }
    mutating func null() { self.append(.null) }
  }

  struct Outcome: Equatable {
    var events: [Tagged]
    var error: JSONParsingError?
  }

  // The shared `feed` helper, with the sink told which call it is in.
  static func record(
    _ bytes: [UInt8], chunk: Int, rejectAtString: Int? = nil, rejectAtChunk: Int? = nil
  ) -> (events: [Tagged], error: JSONParsingError?) {
    var sink = RecordingSink()
    sink.rejectAtString = rejectAtString
    sink.rejectAtChunk = rejectAtChunk
    var parser = JSONParser()
    var error: JSONParsingError?
    do {
      try bytes.withUnsafeBufferPointer { input throws(JSONParsingError) in
        var i = 0
        while i < input.count {
          let count = min(chunk, input.count - i)
          try parser.parse(
            UnsafeBufferPointer(start: input.baseAddress! + i, count: count), into: &sink
          )
          i += count
          sink.call += 1
        }
      }
      sink.call = .max
      try parser.finish(into: &sink)
    } catch let caught {
      error = caught
    }
    return (sink.events, error)
  }

  // Adjacent chunks of one call folded: the one difference coalescing is allowed to make.
  //
  // The run is accumulated in a local rather than rewritten into `out`: rebuilding the element as
  // `.stringChunk(previous + bytes)` allocated and copied the whole value so far on every chunk,
  // which is quadratic in the number of chunks -- and the byte fed oracle makes that the number of
  // *bytes*. Appending in place into an accumulator nothing else references is amortised linear.
  static func folding(_ events: [Tagged], callOf: (Int) -> Int = { $0 }) -> [Tagged] {
    var out = [Tagged]()
    out.reserveCapacity(events.count)
    var run: (call: Int, bytes: [UInt8])?
    for tagged in events {
      let call = tagged.call == .max ? .max : callOf(tagged.call)
      if case .stringChunk(let bytes) = tagged.event {
        if run != nil, run!.call == call {
          run!.bytes.append(contentsOf: bytes)
        } else {
          if let run { out.append(Tagged(call: run.call, event: .stringChunk(run.bytes))) }
          run = (call, bytes)
        }
        continue
      }
      if let run { out.append(Tagged(call: run.call, event: .stringChunk(run.bytes))) }
      run = nil
      out.append(Tagged(call: call, event: tagged.event))
    }
    if let run { out.append(Tagged(call: run.call, event: .stringChunk(run.bytes))) }
    return out
  }

  // How many strings the document actually reaches before it ends or fails, which is what bounds
  // the rejection points worth trying: a single string document has no second string to reject at.
  static func stringCount(_ bytes: [UInt8]) -> Int {
    Self.record(bytes, chunk: .max).events
      .reduce(into: 0) { count, tagged in if case .stringBegin = tagged.event { count += 1 } }
  }

  // `Int.max` and any size at or past the document is the same single call parse, so the ladder is
  // deduped against the document's own length rather than run twice.
  static func expectEquivalent(
    _ bytes: [UInt8], _ label: String, rejectAtString: Int? = nil,
    chunks: [Int] = [Int.max, 2, 7, 64, 1000],
    byteFed oracle: (events: [Tagged], error: JSONParsingError?)? = nil
  ) {
    let byteFed = oracle ?? Self.record(bytes, chunk: 1, rejectAtString: rejectAtString)
    for chunk in Set(chunks.map { min($0, bytes.count) }).sorted() {
      let chunked = Self.record(bytes, chunk: chunk, rejectAtString: rejectAtString)
      let coalesced = Outcome(events: Self.folding(chunked.events), error: chunked.error)
      let fragmented = Outcome(
        events: Self.folding(byteFed.events) { $0 / chunk }, error: byteFed.error
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
          chunked:  \(coalesced.events[lo..<min(coalesced.events.count, at + 2)])
          byte fed: \(fragmented.events[lo..<min(fragmented.events.count, at + 2)])
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
  //
  // `twitter` and `twitterescaped` at 4 KB are the corpora that found the stale container stack
  // (see `ChunkedContainerStateTests`): the chunked parse *failed* where the byte fed one
  // succeeds. The oracle this file used before -- the same chunking through a
  // fragment-by-fragment sink -- failed identically on both sides and so never saw it.
  @Test(arguments: ["citm_catalog", "gsoc-2018", "llm_message", "twitter", "twitterescaped"])
  func `Benchmark corpora coalesce to the same bytes`(name: String) throws {
    let document = try #require(streamBenchmarkCorpus(name))
    Self.expectEquivalent(
      document, name, chunks: [Int.max, 4096], byteFed: Self.record(document, chunk: 1)
    )
  }

  // The stale container stack's reported case through this file's oracle: the first call ends
  // inside `[true,"b"`, the second closes the array and meets `"x\ny"`, and the escaped value must
  // not take the `,"t"` after it for an array comma (which rejected the colon at offset 30).
  @Test
  func `An escaped value after a cut container coalesces like the byte fed parse`() {
    let json = Array(#"{"a":[true,"b"],"s":"x\ny","t":1}"#.utf8)
    #expect(Self.record(json, chunk: 14).error == nil)
    Self.expectEquivalent(json, "cut container", chunks: [14])
  }

  // The equivalence above would pass for a parser that never coalesced; these pin that it does,
  // and exactly where the chunks fall.
  static func chunks(_ json: String, chunk: Int = .max) -> [Tagged] {
    Self.record(Array(json.utf8), chunk: chunk).events.filter {
      if case .stringChunk = $0.event { return true } else { return false }
    }
  }

  static func chunk(_ call: Int, _ text: String) -> Tagged {
    Tagged(call: call, event: .stringChunk(Array(text.utf8)))
  }

  @Test
  func `Content from the first escape on is one chunk`() {
    // The prefix is a zero-copy borrow; everything from the backslash to the quote is one flush.
    #expect(Self.chunks(#"["a\nb\tc"]"#) == [Self.chunk(0, "a"), Self.chunk(0, "\nb\tc")])
    #expect(Self.chunks(#"["\nabc"]"#) == [Self.chunk(0, "\nabc")])
    #expect(
      Self.chunks(#"["\u0041\u00e9\u20ac\ud83d\ude00"]"#) == [Self.chunk(0, "Aé€😀")]
    )
  }

  @Test
  func `A parse call flushes what it coalesced`() {
    // Cut after the `c`: the first call flushes `\nc` before returning, the second starts a new
    // zero-copy prefix at `d` and coalesces again from its own first escape.
    #expect(
      Self.chunks(#"["ab\ncd\tef"]"#, chunk: 7)
        == [Self.chunk(0, "ab"), Self.chunk(0, "\nc"), Self.chunk(1, "d"), Self.chunk(1, "\tef")]
    )
  }

  @Test
  func `A long escaped value is delivered per buffer-full`() {
    let json = "[\"" + String(repeating: "0123456789abcdef\\n", count: 600) + "\"]"
    let chunks = Self.chunks(json)
    let sizes = chunks.map { tagged -> Int in
      guard case .stringChunk(let bytes) = tagged.event else { return 0 }
      return bytes.count
    }
    // 16 bytes ahead of the first escape, then everything after it coalesced through the buffer.
    // The buffer's size is a tuning choice, so what is pinned is the invariant rather than the
    // exact cadence: a handful of flushes, none larger than the buffer, where fragment by
    // fragment delivery was 1,200 chunks.
    #expect(sizes.first == 16)
    #expect(sizes.reduce(0, +) == 600 * 17)
    #expect(sizes.count < 10)
    #expect(sizes.dropFirst().allSatisfy { $0 <= 4096 })
  }

  @Test
  func `A run as long as the buffer is handed over in place`() {
    // The 5,000 `y`s would not fit behind the decoded `\n`, and a run at least as long as the
    // whole buffer is its own chunk: the `\n` flushes alone and the run is not copied.
    let json =
      "[\"" + String(repeating: "x", count: 5000) + "\\n" + String(repeating: "y", count: 5000)
      + "\"]"
    #expect(
      Self.chunks(json) == [
        Self.chunk(0, String(repeating: "x", count: 5000)), Self.chunk(0, "\n"),
        Self.chunk(0, String(repeating: "y", count: 5000))
      ]
    )
  }

  @Test
  func `A chunk rejection reports at the flush`() {
    // `["ab\ncd"]`: the coalesced chunk `\ncd` is flushed at the closing quote (offset 8), so a
    // sink refusing it is reported there -- the offset flushing was reached at, not the `\n`'s.
    let outcome = Self.record(Array(#"["ab\ncd"]"#.utf8), chunk: .max, rejectAtChunk: 2)
    #expect(outcome.error?.byteOffset == 8)
    #expect(outcome.error?.reason == .sinkRejectedToken(StreamSinkFailure(reason: .typeMismatch)))
    #expect(
      outcome.events.map(\.event).suffix(2) == [.stringChunk(Array("ab".utf8)), .stringChunk(Array("\ncd".utf8))]
    )
  }
}
