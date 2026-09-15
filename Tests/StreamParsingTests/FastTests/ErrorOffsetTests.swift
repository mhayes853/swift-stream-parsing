import CustomDump
import Testing

import StreamParsing
import StreamParsingCore

// Every error names the absolute offset of the byte it was detected at, and that offset must
// not depend on how the input was chunked. Before this suite, `error()` reported the offset of
// the chunk an error was thrown in — byte 0 for every bulk parse — and `finish` double-counted
// sink failures.
@Suite
struct `Error offset tests` {
  private static func parse(_ bytes: [UInt8], splitAt: Int) throws {
    var sink = CountingConformanceSink()
    try feed(bytes, splitAt: splitAt, into: &sink)
  }

  private static func failure(_ bytes: [UInt8], splitAt: Int) -> JSONParsingError? {
    do {
      try Self.parse(bytes, splitAt: splitAt)
      return nil
    } catch let error as JSONParsingError {
      return error
    } catch {
      return nil
    }
  }

  private static func bytewiseFailure(_ bytes: [UInt8]) -> JSONParsingError? {
    var sink = CountingConformanceSink()
    do {
      try feedByByte(bytes, into: &sink)
      return nil
    } catch {
      return error
    }
  }

  // MARK: - The offset does not depend on feed granularity

  // Sink-rejection offsets are exempt by design: a sink records its failure and the parser reads
  // it once per state machine step, so where it surfaces tracks the step, not the token.
  @Test(arguments: [
    "[1, x]",
    #"{"a":}"#,
    // Every position of every literal, because a literal is the one token whose comparison a
    // whole-token fast path would change: it is a fixed word, and the offset a mismatch reports
    // has to keep naming the byte that differs rather than the token's start.
    "[txue]",
    "[trxe]",
    "[trux]",
    "[fxlse]",
    "[faxse]",
    "[falxe]",
    "[falsx]",
    "[nxll]",
    "[nuxl]",
    "[nulx]",
    "[--1]",
    "[1e--2]",
    "[1.2.3]",
    "[01]",
    #"{"a" 1}"#,
    // The colon is peeked for directly after a key's closing quote, so a non-colon byte there
    // must report identically whether it is adjacent or behind whitespace, and whether or not the
    // chunk happens to end between the two.
    #"{"a"1}"#,
    #""ab\q""#,
    "\"a\u{5C}uD800\u{5C}uD801\"",
    "[1,]",
    "[1]]",
  ])
  func `Reports the same offset at every split`(json: String) {
    let bytes = Array(json.utf8)
    guard let expected = Self.failure(bytes, splitAt: bytes.count) else {
      Issue.record("Expected the bulk parse of \(json) to fail.")
      return
    }
    for split in 0...bytes.count {
      let actual = Self.failure(bytes, splitAt: split)
      expectNoDifference(actual, expected, "\(json) split at \(split)")
    }
    expectNoDifference(Self.bytewiseFailure(bytes), expected, "\(json) byte by byte")
  }

  // Invalid UTF-8 reports the sequence's lead byte, whether the sequence was validated in place
  // or reassembled across a boundary.
  @Test
  func `Reports invalid UTF-8 at the sequence lead at every split`() {
    let bytes: [UInt8] = Array(#"["ab"#.utf8) + [0xE0, 0x80, 0x80] + Array(#""]"#.utf8)
    guard let expected = Self.failure(bytes, splitAt: bytes.count) else {
      Issue.record("Expected the overlong sequence to be rejected.")
      return
    }
    expectNoDifference(expected.byteOffset, 4)
    for split in 0...bytes.count {
      expectNoDifference(Self.failure(bytes, splitAt: split), expected, "split at \(split)")
    }
    expectNoDifference(Self.bytewiseFailure(bytes), expected, "byte by byte")
  }

  // MARK: - The offset names the right byte

  @Test(arguments: [
    ("[1, x]", JSONParsingError.Reason.unexpectedToken, 4),  // the x
    (#"{"a" 1}"#, .unexpectedToken, 5),  // the 1 where a colon belongs
    ("[trux]", .invalidLiteral, 4),  // the x inside the literal
    ("[--1]", .invalidNumber, 4),  // detected at the token's final delimiter
    ("[1e--2]", .invalidNumber, 6),
    ("[01]", .invalidNumber, 3),
    (#""ab\q""#, .invalidEscape, 4),  // the q
    (#"{"a":1}}"#, .trailingContent, 7),  // the second brace
    ("[1,]", .unexpectedToken, 3),
  ])
  func `Reports the detection byte in a bulk parse`(
    json: String, reason: JSONParsingError.Reason, offset: Int
  ) {
    let bytes = Array(json.utf8)
    let error = Self.failure(bytes, splitAt: bytes.count)
    expectNoDifference(error, JSONParsingError(reason: reason, byteOffset: offset), "\(json)")
  }

  @Test
  func `Reports end of input for errors finish detects`() {
    let bytes = Array(#"{"a":1"#.utf8)
    let error = Self.failure(bytes, splitAt: bytes.count)
    expectNoDifference(error, JSONParsingError(reason: .unterminatedContainer, byteOffset: 6))
  }

  @Test
  func `Reports depth exceeded at the bracket that crossed the limit`() {
    let bytes = [UInt8](repeating: UInt8(ascii: "["), count: 70)
    let error = Self.failure(bytes, splitAt: bytes.count)
    expectNoDifference(error, JSONParsingError(reason: .depthExceeded, byteOffset: 64))
  }

  // MARK: - Sink rejections

  // A sink rejection is the one error the parser does not detect itself, so its offset comes
  // entirely from where the cursor happens to be when `checkEmission` reads the failure. That
  // made it the one error `fuseAfterValue` could move: fusing consumed the comma and the next
  // token's first byte before the check ran, so a rejected `1` in `[1,2]` reported byte 3.
  //
  // Both rows below are values whose successor is fusable — a comma then a value — which is the
  // only shape where the two paths could ever have disagreed.
  private static func sinkFailure<S: StreamParseSink>(
    _ json: String, sink: consuming S, splitAt: Int
  ) -> JSONParsingError? {
    var parser = JSONParser()
    var sink = sink
    let bytes = Array(json.utf8)
    do {
      try bytes.withUnsafeBufferPointer { buffer in
        let first = UnsafeBufferPointer(start: buffer.baseAddress, count: splitAt)
        let second = UnsafeBufferPointer(
          start: buffer.baseAddress! + splitAt, count: buffer.count - splitAt
        )
        if !first.isEmpty { try parser.parse(first, into: &sink) }
        if !second.isEmpty { try parser.parse(second, into: &sink) }
      }
      try parser.finish(into: &sink)
      return nil
    } catch let error as JSONParsingError {
      return error
    } catch {
      return nil
    }
  }

  // The same feed, one byte at a time through the dispatcher's per byte states.
  private static func bytewiseSinkFailure<S: StreamParseSink>(
    _ json: String, sink: consuming S
  ) -> JSONParsingError? {
    var parser = JSONParser()
    var sink = sink
    do {
      for byte in Array(json.utf8) { try parser.parse(byte: byte, into: &sink) }
      try parser.finish(into: &sink)
      return nil
    } catch let error as JSONParsingError {
      return error
    } catch {
      return nil
    }
  }

  // The same feed through the windowed walk: a one byte `windowThreshold` sends every chunk to
  // `parseWindowed`, which is the only production caller of the `coalescing: false` escape
  // decoder for a string *value* (`JSONParserWindow.scanStringValue`). It is driven the way
  // `WindowedParserTests` drives it rather than with a 32 KB chunk, so the offsets under test are
  // the document's own and do not have to be read through a pad.
  private static func windowedSinkFailure<S: StreamParseSink>(
    _ json: String, sink: consuming S
  ) -> JSONParsingError? {
    var parser = JSONParser(windowThreshold: 1)
    var sink = sink
    let bytes = Array(json.utf8)
    do {
      try bytes.withUnsafeBufferPointer { try parser.parse($0, into: &sink) }
      try parser.finish(into: &sink)
      return nil
    } catch let error as JSONParsingError {
      return error
    } catch {
      return nil
    }
  }

  @Test(arguments: 0...5)
  func `Reports a rejected number at its own token, not the next`(splitAt: Int) {
    let error = Self.sinkFailure("[1,2]", sink: RejectingSink(rejecting: .number), splitAt: splitAt)
    expectNoDifference(error?.reason, .sinkRejectedToken(StreamSinkFailure(reason: .typeMismatch)))
    expectNoDifference(error?.byteOffset, 2, "split at \(splitAt)")
  }

  // A string is refused at its `stringBegin` — that is where a typed destination learns it
  // will not take a string — and a whole `string` record is refused at the same point, so the
  // offset is the byte after the opening quote whether the chunking made it one record or
  // three (see `StreamEventRecord.Kind.string`).
  @Test(arguments: 0...9)
  func `Reports a rejected string at its own token, not the next`(splitAt: Int) {
    let error = Self.sinkFailure(
      #"["a","b"]"#, sink: RejectingSink(rejecting: .string), splitAt: splitAt
    )
    expectNoDifference(error?.reason, .sinkRejectedToken(StreamSinkFailure(reason: .typeMismatch)))
    expectNoDifference(error?.byteOffset, 2, "split at \(splitAt)")
  }

  // A key is read in place by the structural run, which then wants to carry on through the colon
  // and into the value. Any such fusion has to stop at a sink that already failed, or the
  // rejection surfaces with the cursor parked past bytes the unfused path had not consumed yet.
  @Test(arguments: 0...9)
  func `Reports a rejected key at its own token, not past the colon`(splitAt: Int) {
    let error = Self.sinkFailure(
      #"{"a":"b"}"#, sink: RejectingSink(rejecting: .key), splitAt: splitAt
    )
    expectNoDifference(error?.reason, .sinkRejectedToken(StreamSinkFailure(reason: .typeMismatch)))
    expectNoDifference(error?.byteOffset, 4, "split at \(splitAt)")
  }

  // The same, with the whitespace a fusion would also swallow, so a guard that only covers the
  // colon still shows up here.
  @Test(arguments: 0...12)
  func `Reports a rejected key before the whitespace around its colon`(splitAt: Int) {
    let error = Self.sinkFailure(
      #"{"a"  :  "b"}"#, sink: RejectingSink(rejecting: .key), splitAt: splitAt
    )
    expectNoDifference(error?.reason, .sinkRejectedToken(StreamSinkFailure(reason: .typeMismatch)))
    expectNoDifference(error?.byteOffset, 4, "split at \(splitAt)")
  }

  // A rejected key must not deliver the value's `stringBegin` either.
  @Test
  func `Stops before the value when the key is rejected`() {
    var parser = JSONParser()
    var sink = RejectingSink(rejecting: .key)
    let bytes = Array(#"{"a":"b"}"#.utf8)
    _ = try? bytes.withUnsafeBufferPointer { try parser.parse($0, into: &sink) }
    expectNoDifference(sink.startedStrings, 0)
  }

  // MARK: - Fused `\u` escapes

  // A `\uXXXX` is six bytes and a surrogate pair twelve, and every path that decodes one whole
  // hands the sink the decoded scalar as one string chunk. That chunk is the escape, so its
  // rejection reports the byte *after* the escape — the offset the per byte escape states report
  // from `consumeEscape`, and the offset a plain string chunk reports from its own last byte.
  //
  // `fusedUnicodeEscapeEnd` used to report at the escape's *selector* instead, which is the first
  // hex digit once `emitScratch` adds one: four bytes early for `\u0041`, ten for a pair. Only
  // the windowed walk reaches that entry for a string value, and no row here had a `\u` in it,
  // which is why it survived.
  @Test(arguments: [
    (Self.simpleEscape, 8),  // `["\u0041x"]`: the escape ends at byte 7
    (Self.pairEscape, 14),  // `["\uD83D\uDE00x"]`: the pair ends at byte 13
  ])
  func `Reports a rejected unicode escape after the escape, not at its first hex digit`(
    json: String, offset: Int
  ) {
    let rejection = StreamSinkFailure(reason: .typeMismatch)

    let bytewise = Self.bytewiseSinkFailure(json, sink: RejectingSink(rejecting: .stringChunk))
    expectNoDifference(bytewise?.reason, .sinkRejectedToken(rejection))
    expectNoDifference(bytewise?.byteOffset, offset, "byte by byte")

    let windowed = Self.windowedSinkFailure(json, sink: RejectingSink(rejecting: .stringChunk))
    expectNoDifference(windowed, bytewise, "windowed")

    // Feeding the escape across a chunk boundary puts it back on the per byte states inside a
    // bulk parse, so the bulk dispatcher reports the same offset there too.
    for split in 3...7 {
      let cut = Self.sinkFailure(json, sink: RejectingSink(rejecting: .stringChunk), splitAt: split)
      expectNoDifference(cut, bytewise, "bulk split at \(split)")
    }
  }

  // The bulk dispatcher is the one path that does *not* deliver the escape on its own: from the
  // first escape on it coalesces the whole value into its buffer and flushes one chunk at the
  // closing quote (`coalescedEscapedStringTail`). Chunk boundaries carry no meaning, so this is
  // not a disagreement about where an error is — every path reports one past the last input byte
  // of the chunk it actually rejected, which is the closing quote here. Pinned so a change that
  // moves the coalesced flush's offset has to come through this test.
  @Test(arguments: [
    (Self.simpleEscape, 9),  // the whole value `Ax`, flushed at the closing quote
    (Self.pairEscape, 15),
  ])
  func `Reports a rejected coalesced escape chunk at the value's end`(json: String, offset: Int) {
    let error = Self.sinkFailure(
      json, sink: RejectingSink(rejecting: .stringChunk), splitAt: Array(json.utf8).count
    )
    expectNoDifference(error?.reason, .sinkRejectedToken(StreamSinkFailure(reason: .typeMismatch)))
    expectNoDifference(error?.byteOffset, offset)
  }

  // A coalescing flush forced by an escape delivers the bytes buffered *before* it, so a rejection
  // reports one past that chunk's last content byte: the escape's backslash (71 here), not its
  // selector. Both the simple-escape and the `\u` arms flush through the same path.
  @Test(arguments: ["\u{5C}n", "\u{5C}u0042"])
  func `Reports a rejected coalescing flush at the escape's backslash`(escape: String) {
    let json = "[\"\u{5C}u0041" + String(repeating: "b", count: 63) + escape + "x\"]"
    var parser = JSONParser(bufferCapacity: 64)
    var sink = RejectingSink(rejecting: .stringChunk)
    let bytes = Array(json.utf8)
    var error: JSONParsingError?
    do {
      try bytes.withUnsafeBufferPointer { try parser.parse($0, into: &sink) }
    } catch let caught as JSONParsingError {
      error = caught
    } catch {}
    expectNoDifference(error?.reason, .sinkRejectedToken(StreamSinkFailure(reason: .typeMismatch)))
    expectNoDifference(error?.byteOffset, 71)
  }

  // Spelled with `\u{5C}` so the backslash is unambiguous next to the `u` the parser reads.
  private static let simpleEscape = "[\"\u{5C}u0041x\"]"
  private static let pairEscape = "[\"\u{5C}uD83D\u{5C}uDE00x\"]"

  // The parse has to stop at the rejection, not carry on into the next token's events.
  @Test
  func `Delivers no further tokens after a rejection`() {
    var parser = JSONParser()
    var sink = RejectingSink(rejecting: .string)
    let bytes = Array(#"["a","b"]"#.utf8)
    _ = try? bytes.withUnsafeBufferPointer { try parser.parse($0, into: &sink) }
    expectNoDifference(sink.startedStrings, 1)
  }
}

// Fails on the first token of one kind, and records how many string tokens it was told about, so
// a fusion that ran past a rejection shows up as an event count as well as an offset.
private struct RejectingSink: StreamParseSink {
  enum Kind { case number, string, key, stringChunk }

  let rejecting: Kind
  var streamFailure: StreamSinkFailure?
  var startedStrings = 0

  init(rejecting: Kind) {
    self.rejecting = rejecting
  }

  private mutating func fail() {
    if self.streamFailure == nil {
      self.streamFailure = StreamSinkFailure(reason: .typeMismatch)
    }
  }

  mutating func beginObject() -> StreamContainerDisposition { .stream }
  mutating func endObject() {}
  mutating func beginArray() -> StreamContainerDisposition { .stream }
  mutating func endArray() {}
  mutating func key(_ bytes: Span<UInt8>) { if self.rejecting == .key { self.fail() } }
  mutating func stringBegin() {
    self.startedStrings &+= 1
    if self.rejecting == .string { self.fail() }
  }
  mutating func stringChunk(_ bytes: Span<UInt8>) {
    if self.rejecting == .stringChunk { self.fail() }
  }
  mutating func stringEnd() {}
  mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) {
    if self.rejecting == .number { self.fail() }
  }
  mutating func boolean(_ value: Bool) {}
  mutating func null() {}
}
