import CustomDump
import Foundation
import Testing

import StreamParsing
import StreamParsingCore

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
@StreamParseable
private struct InlineFieldModel: Equatable {
  var title: StreamInlineString<16> = StreamInlineString<16>()
  var body: StreamInlineString<64> = StreamInlineString<64>()
}

// The fixed-capacity sibling of `StreamString`. What is pinned here that the dynamic type does
// not have to answer: overflow is a reported parse failure rather than growth, capacity is not
// part of the value's identity, and the layout the sink appends through is a promise.
// The suite type itself cannot carry the availability annotation -- swift-testing rejects
// `@Suite` on an annotated type -- so each member carries it instead. On Linux, where value
// generics need no runtime support, these annotations are inert.
@Suite
struct `Stream inline string tests` {
  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  private func accumulated<let capacity: Int>(
    _ content: [UInt8], chunk: Int, capacity: StreamInlineString<capacity>.Type
  ) -> (value: StreamInlineString<capacity>, result: StreamApplyResult) {
    var value = StreamInlineString<capacity>()
    var result = StreamApplyResult.applied
    content.withUnsafeBufferPointer { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = min(chunk, buffer.count - offset)
        let slice = UnsafeBufferPointer(start: buffer.baseAddress! + offset, count: count)
        let step = value.streamAppend(utf8: Span(_unsafeElements: slice))
        if step != .applied { result = step }
        offset += count
      }
    }
    return (value, result)
  }

  // MARK: - Accumulation

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test(arguments: [1, 3, 8, 64, Int.max])
  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  func `Chunking does not change the accumulated string`(chunk: Int) {
    let content = "inline content that fits"
    let (value, result) = self.accumulated(
      Array(content.utf8), chunk: chunk, capacity: StreamInlineString<64>.self
    )
    expectNoDifference(result, .applied)
    expectNoDifference(value.utf8Count, content.utf8.count)
    expectNoDifference(String(value), content)
  }

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test
  func `An empty value reads as empty`() {
    let value = StreamInlineString<16>()
    expectNoDifference(value.isEmpty, true)
    expectNoDifference(value.utf8Count, 0)
    expectNoDifference(String(value), "")
    expectNoDifference(value.availableCapacity, 16)
    expectNoDifference(StreamInlineString<16>.utf8Capacity, 16)
  }

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test
  func `Content filling the capacity exactly is accepted`() {
    let content = String(repeating: "a", count: 16)
    let (value, result) = self.accumulated(
      Array(content.utf8), chunk: .max, capacity: StreamInlineString<16>.self
    )
    expectNoDifference(result, .applied)
    expectNoDifference(String(value), content)
    expectNoDifference(value.availableCapacity, 0)
  }

  // MARK: - Overflow

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test
  func `Content past the capacity is refused`() {
    let content = String(repeating: "a", count: 17)
    let (value, result) = self.accumulated(
      Array(content.utf8), chunk: .max, capacity: StreamInlineString<16>.self
    )
    expectNoDifference(result, .capacityExceeded)
    // Refused entire: nothing of the overflowing chunk was taken.
    expectNoDifference(value.isEmpty, true)
  }

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test
  func `A refused chunk leaves everything accepted before it`() {
    var value = StreamInlineString<8>()
    expectNoDifference(value.append("12345"), .applied)
    expectNoDifference(value.append("6789"), .capacityExceeded)
    expectNoDifference(String(value), "12345")
    expectNoDifference(value.append("678"), .applied)
    expectNoDifference(String(value), "12345678")
  }

  // A chunk whose last scalar would straddle the capacity is refused whole, so a value never
  // holds a torn UTF-8 sequence -- the property that lets every read be a repairing decode of
  // bytes the parser actually validated.
  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test
  func `A multi-byte scalar is never torn by the capacity`() {
    var value = StreamInlineString<8>()
    expectNoDifference(value.append("123456"), .applied)
    expectNoDifference(value.append("é"), .applied)
    expectNoDifference(value.utf8Count, 8)
    var tight = StreamInlineString<8>()
    expectNoDifference(tight.append("1234567"), .applied)
    expectNoDifference(tight.append("é"), .capacityExceeded)
    expectNoDifference(String(tight), "1234567")
  }

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test
  func `Removing all content keeps the capacity`() {
    var value = StreamInlineString<16>()
    value.append("filled")
    value.removeAll()
    expectNoDifference(value.isEmpty, true)
    expectNoDifference(value.availableCapacity, 16)
    expectNoDifference(value.append("again"), .applied)
    expectNoDifference(String(value), "again")
  }

  // MARK: - Layout

  // The contract `_streamStringSchema` asserts and `PartialSink` appends through. A change to the
  // stored properties that moved either number would silently corrupt every parsed inline string,
  // so it is pinned here as well as checked when a schema is built.
  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test
  func `Layout is a header followed by exactly the capacity`() {
    expectNoDifference(MemoryLayout<StreamInlineString<1>>.size, 5)
    expectNoDifference(MemoryLayout<StreamInlineString<16>>.size, 20)
    expectNoDifference(MemoryLayout<StreamInlineString<64>>.size, 68)
    expectNoDifference(MemoryLayout<StreamInlineString<255>>.size, 259)
    expectNoDifference(StreamInlineString<16>._streamInlineByteOffset, 4)
    expectNoDifference(StreamInlineString<16>._streamInlineCapacity, 16)
    // Nothing refcounted, which is what makes a partial tree of these a memcpy.
    expectNoDifference(_isPOD(StreamInlineString<64>.self), true)
  }

  // MARK: - Views

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test
  func `The UTF-8 view exposes byte offsets`() {
    let value: StreamInlineString<32> = "héllo"
    expectNoDifference(Array(value.utf8), Array("héllo".utf8))
    expectNoDifference(String(value.utf8[1..<3]), "é")
    expectNoDifference(value.utf8.count, 6)
  }

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test
  func `The scalar view walks forward and backward over the same positions`() {
    let value: StreamInlineString<32> = "aé漢🙂"
    let scalars = Array(value.unicodeScalars)
    expectNoDifference(scalars, Array("aé漢🙂".unicodeScalars))
    var positions: [Int] = []
    var index = value.unicodeScalars.endIndex
    while index > value.unicodeScalars.startIndex {
      index = value.unicodeScalars.index(before: index)
      positions.append(index)
    }
    expectNoDifference(positions.reversed().map { $0 }, [0, 1, 3, 6])
  }

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test
  func `Characters agree with String iteration`() {
    let text = "a\u{0301}b🙂é"
    var value = StreamInlineString<32>()
    value.append(text)
    expectNoDifference(Array(value.characters), Array(text))
  }

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test
  func `Ill-formed bytes decode as replacement characters`() {
    var value = StreamInlineString<8>()
    let invalid: [UInt8] = [0x61, 0xFF, 0x62]
    invalid.withUnsafeBufferPointer {
      value.streamAppend(utf8: Span(_unsafeElements: $0))
    }
    expectNoDifference(String(value), "a\u{FFFD}b")
    expectNoDifference(Array(value.unicodeScalars), ["a", "\u{FFFD}", "b"])
  }

  // MARK: - Bridging and literals

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test
  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  // Runtime text goes through the failable initializer. A *literal* argument does not reach it --
  // the literal path wins overload resolution and traps instead -- which is the intended split:
  // a literal too long for its capacity is a programmer error, a document is not.
  func `Text that fits initializes, and text that does not returns nil`() {
    let short = String(repeating: "a", count: 8)
    let long = String(repeating: "a", count: 9)
    let fits = StreamInlineString<8>(short)
    let overflows = StreamInlineString<8>(long)
    expectNoDifference(fits.map(String.init), short)
    expectNoDifference(overflows == nil, true)
  }

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test
  func `Literals and interpolation build values`() {
    let literal: StreamInlineString<32> = "literal"
    expectNoDifference(String(literal), "literal")
    let count = 7
    let interpolated: StreamInlineString<32> = "count \(count) and \(literal)"
    expectNoDifference(String(interpolated), "count 7 and literal")
  }

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test
  func `Substring bridging matches the String decode`() {
    let value: StreamInlineString<32> = "bridged"
    expectNoDifference(Substring(value), "bridged")
    expectNoDifference(String(value.utf8[0..<3]), "bri")
  }

  // MARK: - Equality, ordering, hashing

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test
  func `Equality is byte-wise and ignores capacity`() {
    let small: StreamInlineString<16> = "same"
    let large: StreamInlineString<64> = "same"
    expectNoDifference(small == large, true)
    expectNoDifference(small != large, false)
    expectNoDifference(small == "same", true)
    expectNoDifference("same" == small, true)
    let other: StreamInlineString<16> = "different"
    expectNoDifference(small == other, false)
  }

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test
  func `Values equal across capacities hash equally`() {
    let small: StreamInlineString<16> = "same"
    let large: StreamInlineString<64> = "same"
    var left = Hasher()
    var right = Hasher()
    small.hash(into: &left)
    large.hash(into: &right)
    expectNoDifference(left.finalize(), right.finalize())
  }

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test
  func `Ordering is byte-wise lexicographic`() {
    let a: StreamInlineString<16> = "apple"
    let b: StreamInlineString<16> = "banana"
    let prefix: StreamInlineString<16> = "app"
    expectNoDifference(a < b, true)
    expectNoDifference(b < a, false)
    expectNoDifference(prefix < a, true)
    let wide: StreamInlineString<64> = "banana"
    expectNoDifference(a < wide, true)
  }

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test
  func `Optional comparison against String lifts`() {
    let value: StreamInlineString<16>? = "present"
    let missing: StreamInlineString<16>? = nil
    expectNoDifference(value == "present", true)
    expectNoDifference(missing == "present", false)
    expectNoDifference(missing != "present", true)
  }

  // MARK: - Searching

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test
  func `Searching is byte-wise`() {
    let value: StreamInlineString<32> = "streaming parser"
    expectNoDifference(value.hasPrefix("stream"), true)
    expectNoDifference(value.hasSuffix("parser"), true)
    expectNoDifference(value.hasPrefix("parser"), false)
    expectNoDifference(value.contains("ing p"), true)
    expectNoDifference(value.range(of: "parser"), 10..<16)
    expectNoDifference(value.range(of: "absent"), nil)
    expectNoDifference(value.range(of: ""), 0..<0)
  }

  // MARK: - Codable

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test
  func `Encoding and decoding round-trips through a single value`() throws {
    let value: StreamInlineString<32> = "codable"
    let data = try JSONEncoder().encode(value)
    expectNoDifference(String(decoding: data, as: UTF8.self), "\"codable\"")
    let decoded = try JSONDecoder().decode(StreamInlineString<32>.self, from: data)
    expectNoDifference(decoded, value)
  }

  // Decoding is the one direction where overflow has an error to report rather than a trap: the
  // bytes come from a document, exactly like the parser's.
  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test
  func `Decoding text past the capacity throws`() throws {
    let data = Data("\"far too long for eight\"".utf8)
    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(StreamInlineString<8>.self, from: data)
    }
  }

  // MARK: - Parsing

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  private func failure(_ json: String, chunk: Int = .max) -> StreamSinkFailure.Reason? {
    var value = InlineFieldModel.Partial()
    do {
      try parsePartial(json, into: &value, chunk: chunk)
      return nil
    } catch let error as JSONParsingError {
      guard case .sinkRejectedToken(let failure) = error.reason else { return nil }
      return failure.reason
    } catch {
      return nil
    }
  }

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test(arguments: [1, 4, Int.max])
  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  func `A parsed field accumulates through the schema`(chunk: Int) throws {
    var value = InlineFieldModel.Partial()
    try parsePartial(#"{"title":"hello","body":"world"}"#, into: &value, chunk: chunk)
    expectNoDifference(value.title == "hello", true)
    expectNoDifference(value.body == "world", true)
  }

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test(arguments: [1, 4, Int.max])
  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  func `A field overflowing its capacity fails the parse`(chunk: Int) {
    expectNoDifference(
      self.failure(#"{"title":"far more than sixteen bytes of title"}"#, chunk: chunk),
      .capacityExceeded
    )
  }

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test
  func `An escape decoded past the capacity fails the parse`() {
    expectNoDifference(self.failure(#"{"title":"aaaaaaaaaaaaaaaé"}"#), .capacityExceeded)
  }

  // The layout-erased route: the destination *is* the value, so the sink appends through the raw
  // pointer and the capacity carried on the schema rather than a closure. Every position that
  // takes that route is exercised here.
  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test(arguments: [1, 4, Int.max])
  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  func `A bare root takes the erased route`(chunk: Int) throws {
    var value = StreamInlineString<32>()
    try parsePartial(#""root string""#, into: &value, chunk: chunk)
    expectNoDifference(String(value), "root string")
  }

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test(arguments: [1, 4, Int.max])
  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  func `Array elements take the erased route`(chunk: Int) throws {
    var value = StreamArray<StreamInlineString<16>>()
    try parsePartial(#"["one","two","three"]"#, into: &value, chunk: chunk)
    expectNoDifference(value.count, 3)
    expectNoDifference(String(value[0]), "one")
    expectNoDifference(String(value[2]), "three")
  }

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test(arguments: [1, 4, Int.max])
  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  func `Dictionary values take the erased route`(chunk: Int) throws {
    var value = StreamDictionary<StreamInlineString<16>>()
    try parsePartial(#"{"a":"first","b":"second"}"#, into: &value, chunk: chunk)
    expectNoDifference(value.count, 2)
    expectNoDifference(String(value["a"]!), "first")
    expectNoDifference(String(value["b"]!), "second")
  }

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test
  func `An element overflowing its capacity fails the parse`() {
    var value = StreamArray<StreamInlineString<4>>()
    var reason: StreamSinkFailure.Reason?
    do {
      try parsePartial(#"["ok","far too long"]"#, into: &value)
    } catch let error as JSONParsingError {
      if case .sinkRejectedToken(let failure) = error.reason { reason = failure.reason }
    } catch {}
    expectNoDifference(reason, .capacityExceeded)
  }

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test
  func `A later chunk that fits cannot mask an earlier refusal`() {
    let long = String(repeating: "a", count: 40)
    expectNoDifference(self.failure("{\"title\":\"\(long)\\tb\"}"), .capacityExceeded)
  }

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  // The dictionary route opens its value through `enterKey` and picks the pointer up at
  // `stringBegin` without the empty-span probe, so the failures that probe used to report have to
  // still arrive by other means.
  @Test
  func `A dictionary value overflowing its capacity fails the parse`() {
    var value = StreamDictionary<StreamInlineString<4>>()
    var reason: StreamSinkFailure.Reason?
    do {
      try parsePartial(#"{"a":"ok","b":"far too long"}"#, into: &value)
    } catch let error as JSONParsingError {
      if case .sinkRejectedToken(let failure) = error.reason { reason = failure.reason }
    } catch {}
    expectNoDifference(reason, .capacityExceeded)
  }

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test(arguments: [#"{"a":42}"#, #"{"a":true}"#, #"{"a":null}"#, #"{"a":[]}"#])
  func `A non-string token in an inline string dictionary is a mismatch`(json: String) {
    var value = StreamDictionary<StreamInlineString<16>>()
    var reason: StreamSinkFailure.Reason?
    do {
      try parsePartial(json, into: &value)
    } catch let error as JSONParsingError {
      if case .sinkRejectedToken(let failure) = error.reason { reason = failure.reason }
    } catch {}
    expectNoDifference(reason, .typeMismatch)
  }

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test
  func `A type mismatch is still a mismatch, not a capacity failure`() {
    expectNoDifference(self.failure(#"{"title":42}"#), .typeMismatch)
  }
}
