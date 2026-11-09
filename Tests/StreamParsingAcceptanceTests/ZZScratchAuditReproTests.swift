import Foundation
import StreamParsing
import StreamParsingCore
import Testing

// Minimal reproducers for the typed-layer audit. Every test asserts JSONDecoder's answer for the
// same Codable declaration, so each FAILS on 16530695.

@StreamParseable
enum ReproColor: String, Equatable, Codable {
  @StreamParseableDefault
  case red
  case green
}

@StreamParseable
struct ReproHolder: Equatable, Codable {
  var color: ReproColor
}

@StreamParseable
struct ReproDup: Equatable, Codable {
  var name: String
  var tags: [Int]
}

@StreamParseable
struct ReproInt: Equatable, Codable {
  var count: Int
}

@StreamParseable
struct ReproDouble: Equatable, Codable {
  var d: Double
}

@StreamParseable
struct ReproData: Equatable, Codable {
  var raw: Data
}

private func reproStream<M: StreamParseable>(_ json: String, as: M.Type, chunk: Int = .max) throws -> M {
  var stream = PartialsStream<M>(from: .json())
  let bytes = Array(json.utf8)
  var i = 0
  while i < bytes.count {
    try stream.next(bytes[i..<min(i + chunk, bytes.count)])
    i += chunk
  }
  return try stream.finish()
}

private func reproFoundation<M: Decodable>(_ json: String, as: M.Type) throws -> M {
  try JSONDecoder().decode(M.self, from: Data(json.utf8))
}

@Suite
struct ScratchAuditRepro {
  // 1. A complete string that is only a prefix of a raw value finishes as that case.
  @Test(arguments: [Int.max, 1])
  func stringEnumPrefixIsNotAValue(chunk: Int) {
    let json = #"{"color":"gre"}"#
    #expect(throws: (any Error).self) { try reproFoundation(json, as: ReproHolder.self) }
    // Observed: returns ReproHolder(color: .green).
    #expect(throws: (any Error).self) { try reproStream(json, as: ReproHolder.self, chunk: chunk) }
  }

  // 2. A repeated key concatenates strings and appends arrays.
  @Test(arguments: [Int.max, 1])
  func duplicateKeys(chunk: Int) throws {
    let json = #"{"name":"x","tags":[1],"name":"y","tags":[2]}"#
    let expected = try reproFoundation(json, as: ReproDup.self)  // name "x", tags [1] (first wins)
    let actual = try reproStream(json, as: ReproDup.self, chunk: chunk)  // name "xy", tags [1, 2]
    #expect(actual == expected)
    #expect(actual.name == "x" || actual.name == "y")
  }

  // 3. An integral number written with a fraction or exponent is rejected.
  @Test(arguments: ["1.0", "1e3", "-0.0", "1E0", "2.50e1"])
  func integralNumberWithFractionOrExponent(literal: String) throws {
    let json = #"{"count":\#(literal)}"#
    let expected = try reproFoundation(json, as: ReproInt.self)  // 1, 1000, 0, 1, 25
    // Observed: JSONParsingError(.sinkRejectedToken(.typeMismatch)).
    #expect(try reproStream(json, as: ReproInt.self) == expected)
  }

  // 4. A double that underflows is accepted as zero; JSONDecoder rejects it.
  @Test func doubleUnderflow() {
    let json = #"{"d":1e-400}"#
    #expect(throws: (any Error).self) { try reproFoundation(json, as: ReproDouble.self) }
    #expect(throws: (any Error).self) { try reproStream(json, as: ReproDouble.self) }  // d == 0.0
  }

  // 5. `Data` reads the string's UTF-8, not the base64 Codable writes.
  @Test func dataIsNotBase64Decoded() throws {
    let json = #"{"raw":"aGVsbG8="}"#
    let expected = try reproFoundation(json, as: ReproData.self)  // "hello", 5 bytes
    #expect(try reproStream(json, as: ReproData.self) == expected)  // 8 bytes "aGVsbG8="
  }
}

private struct CompletionRejectingSink: StreamParseSink {
  var failure: StreamSinkFailure? = nil
  var pending = [UInt8]()
  mutating func beginObject() -> StreamContainerDisposition { .stream }
  mutating func endObject() {}
  mutating func beginArray() -> StreamContainerDisposition { .stream }
  mutating func endArray() {}
  mutating func key(_ bytes: Span<UInt8>) {}
  mutating func stringBegin() { pending = [] }
  mutating func stringChunk(_ bytes: Span<UInt8>) { bytes.withUnsafeBufferPointer { pending += $0 } }
  mutating func stringEnd() { judge(pending) }
  mutating func string(_ bytes: Span<UInt8>) { judge(bytes.withUnsafeBufferPointer { Array($0) }) }
  mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) {}
  mutating func boolean(_ value: Bool) {}
  mutating func null() {}
  var streamFailure: StreamSinkFailure? { failure }
  mutating func judge(_ s: [UInt8]) {
    if s == Array("bad".utf8), failure == nil { failure = StreamSinkFailure(reason: .conversionFailed) }
  }
}

@Suite struct ZZScratchOffsetRepro {
  @Test func completionRejectionOffset() {
    let bytes = Array(#"["ok","bad",1]"#.utf8)
    var seen: [String: [Int]] = [:]
    for chunk in [1, 2, 5, 6, 11, Int.max] {
      var parser = JSONParser(); var sink = CompletionRejectingSink()
      var r = "accepted"
      do {
        try bytes.withUnsafeBufferPointer { b in
          var i = 0
          while i < b.count { let c = min(chunk, b.count - i); try parser.parse(UnsafeBufferPointer(rebasing: b[i..<(i + c)]), into: &sink); i += c }
        }
        try parser.finish(into: &sink)
      } catch let e as JSONParsingError { r = "\(e.reason)@\(e.byteOffset)" } catch {}
      seen[r, default: []].append(chunk)
    }
    print("OFFSETS \(seen)")
    #expect(seen.count == 1)
  }
}
