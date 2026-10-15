import CustomDump
import StreamParsing
import Testing

@testable import StreamParsingCore

// `StringInfo`'s contract, on every route a string takes to a `StreamStringConvertible` that is not
// `StreamString`: each string brings exactly one call carrying `.begin` and one carrying `.end`,
// in that order, whether the parser holds it whole or delivers it in chunks.

// MARK: - Declarations

// Folds its calls into the strings they spell, and counts any call the contract does not allow.
private struct Recorded: StreamStringConvertible, StreamParseable, StreamPartial, Equatable {
  typealias Partial = Self
  var strings = [String]()
  var violations = 0
  var isOpen = false

  static func streamInitialValue() -> Self { Self() }

  mutating func streamAppend(utf8 bytes: Span<UInt8>, info: StringInfo) -> StreamApplyResult {
    if info.flags.contains(.begin) {
      if self.isOpen { self.violations += 1 }
      self.isOpen = true
      self.strings.append("")
    } else if !self.isOpen {
      self.violations += 1
      return .applied
    }
    bytes.withUnsafeBufferPointer { self.strings[self.strings.count - 1] += String(decoding: $0, as: UTF8.self) }
    if info.flags.contains(.end) { self.isOpen = false }
    return .applied
  }
}

@StreamParseable
private struct Holder: Equatable {
  var recorded: Recorded
  var maybe: Recorded?
}

@StreamParseable
private struct GenericHolder<Value: StreamParseable & Equatable>: Equatable {
  var value: Value
}

// A matcher and no table: the sink's `.match` route.
private struct MatchedHolder: StreamPartial, StreamParseable {
  var recorded = Recorded()
  static func streamInitialValue() -> Self { Self() }
  static let streamSchema = StreamSchema(
    shape: .object,
    matchField: { key in key.count == 8 ? 0 : -1 },
    applyString: { storage, field, bytes, info in
      guard field == 0 else { return .unsupported }
      return storage.assumingMemoryBound(to: Self.self).pointee.recorded
        .streamAppend(utf8: bytes, info: info)
    }
  )
}

// Whole, escaped (chunked even in one buffer), empty, and long enough to cross a chunk.
private let strings = ["abc", #"a\nb\"c"#, "", "é€😀 and some more text past seven bytes"]
private let decoded = ["abc", "a\nb\"c", "", "é€😀 and some more text past seven bytes"]

// MARK: - Tests

@Suite
struct `StringInfo tests` {
  @Test(arguments: [Int.max, 7, 1])
  func `A root string opens and closes once`(chunk: Int) throws {
    for (string, expected) in zip(strings, decoded) {
      var value = Recorded()
      try parsePartial(#""\#(string)""#, into: &value, chunk: chunk)
      expectNoDifference(value, Recorded(strings: [expected]), string)
    }
  }

  @Test(arguments: [Int.max, 7, 1])
  func `A member opens and closes once, table, matched and delegated`(chunk: Int) throws {
    for (string, expected) in zip(strings, decoded) {
      var holder = Holder.Partial()
      try parsePartial(
        #"{"recorded":"\#(string)","maybe":"\#(string)"}"#, into: &holder, chunk: chunk
      )
      expectNoDifference(holder.recorded, Recorded(strings: [expected]), "table \(string)")
      expectNoDifference(holder.maybe, Recorded(strings: [expected]), "optional \(string)")

      var matched = MatchedHolder()
      try parsePartial(#"{"recorded":"\#(string)"}"#, into: &matched, chunk: chunk)
      expectNoDifference(matched.recorded, Recorded(strings: [expected]), "matched \(string)")

      var generic = GenericHolder<Recorded>.Partial()
      try parsePartial(#"{"value":"\#(string)"}"#, into: &generic, chunk: chunk)
      expectNoDifference(generic.value, Recorded(strings: [expected]), "delegated \(string)")
    }
  }

  @Test(arguments: [Int.max, 7, 1])
  func `Elements and dictionary values open and close once each`(chunk: Int) throws {
    var array = StreamArray<Recorded>()
    try parsePartial(#"["abc","a\nb",""]"#, into: &array, chunk: chunk)
    expectNoDifference(
      Array(array),
      [Recorded(strings: ["abc"]), Recorded(strings: ["a\nb"]), Recorded(strings: [""])]
    )

    var dictionary = StreamDictionary<Recorded>()
    try parsePartial(#"{"a":"x\ty","b":"z"}"#, into: &dictionary, chunk: chunk)
    expectNoDifference(dictionary["a"], Recorded(strings: ["x\ty"]))
    expectNoDifference(dictionary["b"], Recorded(strings: ["z"]))
  }

  // A repeated key writes a second string into the same value: a second `.begin` after `.end`.
  @Test(arguments: [Int.max, 7, 1])
  func `A repeated key opens the value again`(chunk: Int) throws {
    var holder = Holder.Partial()
    try parsePartial(#"{"recorded":"ab","recorded":"c\nd"}"#, into: &holder, chunk: chunk)
    expectNoDifference(holder.recorded, Recorded(strings: ["ab", "c\nd"]))
  }
}
