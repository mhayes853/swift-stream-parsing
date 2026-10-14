import CustomDump
import StreamParsing
import StreamParsingCore
import Testing

#if Foundation && canImport(Foundation)
  import Foundation
#endif

@StreamParseable
private struct Attachment: Equatable {
  var name: String
  var contents: StreamBase64Data
  var thumbnail: StreamBase64Data?
}

@Suite
struct `StreamBase64Data tests` {
  // RFC 4648, section 10: every padding case, and a string split at each byte in turn.
  private static let vectors: [(text: String, decoded: String)] = [
    ("", ""), ("Zg==", "f"), ("Zm8=", "fo"), ("Zm9v", "foo"),
    ("Zm9vYg==", "foob"), ("Zm9vYmE=", "fooba"), ("Zm9vYmFy", "foobar"),
  ]

  @Test(arguments: 1...9)
  func `The RFC 4648 vectors decode in chunks of every size`(chunk: Int) throws {
    for vector in Self.vectors {
      var value = StreamBase64Data()
      try parsePartial(#""\#(vector.text)""#, into: &value, chunk: chunk)
      expectNoDifference(value.bytes, Array(vector.decoded.utf8), "\(vector.text)")
      expectNoDifference(StreamBase64Data(streamPartial: value), StreamBase64Data(vector.decoded.utf8))
    }
  }

  // Each group of four characters shows up decoded as soon as its last character arrives, and not
  // before: the bytes of an unfinished group are not guessed at.
  @Test
  func `A partial holds each finished group`() throws {
    var stream = PartialsStream<StreamBase64Data>(from: .json())
    try stream.next(UInt8(ascii: "\""))
    var seen = [String]()
    for character in "Zm9vYmE=".utf8 {
      try stream.next(character)
      seen.append(String(decoding: stream.current.bytes, as: UTF8.self))
    }
    expectNoDifference(seen, ["", "", "", "foo", "foo", "foo", "foo", "fooba"])
  }

  @Test(
    arguments: [
      #""Zm9v Zm9v""#, #""Zm9v\nZm9v""#, #""Zm9vé""#, #""Zm9v-_""#,
      #""Zg==Zg==""#, #""Zg==Z""#, #""Zg=a""#, #""Z===""#, #""====""#, #""=""#,
    ]
  )
  func `Anything outside padded standard base64 fails the parse`(json: String) {
    for chunk in [Int.max, 1] {
      expectNoDifference(
        streamFailureReason(json, as: StreamBase64Data.self, chunk: chunk),
        .conversionFailed,
        "chunk \(chunk)"
      )
    }
  }

  // Lengths through several vector blocks (eight groups on x86_64, sixteen on arm64) and every
  // count of groups left over, with each padding; whole, and split mid-block.
  @Test(arguments: [Int.max, 33, 5])
  func `Every length decodes, across vector blocks and the groups after them`(chunk: Int) throws {
    let bytes = (0..<400).map { UInt8(truncatingIfNeeded: $0 &* 167 &+ 13) }
    for count in 0...bytes.count {
      let expected = Array(bytes.prefix(count))
      var value = StreamBase64Data()
      try parsePartial(#""\#(base64(expected))""#, into: &value, chunk: chunk)
      expectNoDifference(value.bytes, expected, "\(count) bytes")
    }
  }

  // Inside a vector block, in the groups after the last one, and in a block a chunk boundary cuts:
  // the vector tier hands the block back and the scalar loop finds the character. `\n` is the JSON
  // escape, which reaches the decoder as a line feed. `*`, `.`, `:`, `[`, `` ` `` and `{` each share
  // a four-byte bucket of arm64's lookup with characters of the alphabet.
  @Test(arguments: ["=", "-", " ", "@", "\u{7F}", "é", #"\n"#, "*", ".", ":", "[", "`", "{"])
  func `A character outside the alphabet is rejected wherever it falls`(bad: String) {
    let text = Array(base64((0..<255).map { UInt8($0) }).utf8)
    // `=` in the last place is the padding of a three-character group.
    for position in 0..<(bad == "=" ? text.count - 1 : text.count) {
      var characters = text
      characters.replaceSubrange(position...position, with: Array(bad.utf8))
      let document = #""\#(String(decoding: characters, as: UTF8.self))""#
      for chunk in [Int.max, 64] {
        expectNoDifference(
          streamFailureReason(document, as: StreamBase64Data.self, chunk: chunk),
          .conversionFailed,
          "\(bad.debugDescription) at \(position), chunk \(chunk)"
        )
      }
    }
  }

  @Test
  func `Bits the padding leaves over are dropped, as Foundation drops them`() throws {
    var value = StreamBase64Data()
    try parsePartial(#""Zh==""#, into: &value)
    expectNoDifference(value.bytes, Array("f".utf8))
  }

  // Without its padding a string ends inside a group, which only the lenient conversion accepts.
  @Test
  func `An unpadded string does not finish into a value`() throws {
    var stream = PartialsStream<StreamBase64Data>(from: .json())
    try stream.next(Array(#""Zm9vYg""#.utf8))
    let partial = try stream.finishPartial()

    expectNoDifference(StreamBase64Data(streamPartial: partial), nil)
    expectNoDifference(StreamBase64Data(orInitial: partial).bytes, Array("foo".utf8))

    var model = PartialsStream<StreamBase64Data>(from: .json())
    try model.next(Array(#""Zm9vYg""#.utf8))
    do {
      _ = try model.finish()
      Issue.record("finish() converted a string that ended inside a group")
    } catch let error as StreamParsingError {
      expectNoDifference(error, .incompleteValue)
    }
  }

  @Test
  func `Equality compares the bytes, not how far the decoder got`() throws {
    var value = StreamBase64Data()
    try parsePartial(#""Zm9vYg""#, into: &value)
    expectNoDifference(value, StreamBase64Data("foo".utf8))
    expectNoDifference(value.hashValue, StreamBase64Data("foo".utf8).hashValue)
  }

  @Test
  func `A model member decodes and finishes`() throws {
    var stream = PartialsStream<Attachment>(from: .json())
    try stream.next(Array(#"{"name":"a.txt","contents":"aGVsbG8=","thumbnail":null}"#.utf8))
    let attachment = try stream.finish()
    expectNoDifference(
      attachment,
      Attachment(name: "a.txt", contents: StreamBase64Data("hello".utf8), thumbnail: nil)
    )
  }

  @Test
  func `A model member that is rejected fails the parse`() {
    expectNoDifference(
      streamFailureReason(#"{"name":"a","contents":"aGVs bG8="}"#, as: Attachment.Partial.self),
      .conversionFailed
    )
  }

  @Test(arguments: [Int.max, 5, 1])
  func `An array holds one value per string`(chunk: Int) throws {
    var value = StreamArray<StreamBase64Data>()
    try parsePartial(#"["Zg==","Zm9vYmFy",""]"#, into: &value, chunk: chunk)
    expectNoDifference(
      Array(value),
      [StreamBase64Data("f".utf8), StreamBase64Data("foobar".utf8), StreamBase64Data()]
    )
  }

  // Standard, padded: what the decoder accepts. Independent of Foundation, so these tests run
  // without the trait.
  private func base64(_ bytes: [UInt8]) -> String {
    let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
    var text = [UInt8]()
    for start in stride(from: 0, to: bytes.count, by: 3) {
      let group = bytes[start..<min(start + 3, bytes.count)]
      let word = group.enumerated().reduce(UInt32(0)) {
        $0 | UInt32($1.element) << (16 - 8 * $1.offset)
      }
      for index in 0..<4 {
        let sextet = Int(word >> (18 - 6 * index) & 63)
        text.append(index <= group.count ? alphabet[sextet] : UInt8(ascii: "="))
      }
    }
    return String(decoding: text, as: UTF8.self)
  }

  #if Foundation && canImport(Foundation)
    // Thousands of groups, with every byte value, against Foundation's encoder.
    @Test(arguments: [Int.max, 4_099, 1_000, 7, 1])
    func `A long payload decodes as Foundation encodes it`(chunk: Int) throws {
      let bytes = (0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) }
      var value = StreamBase64Data()
      try parsePartial(#""\#(Data(bytes).base64EncodedString())""#, into: &value, chunk: chunk)
      expectNoDifference(value.bytes, bytes)
      expectNoDifference(value.data, Data(bytes))
    }

    @Test
    func `Codable writes and reads the string Data writes`() throws {
      let bytes: [UInt8] = [0, 1, 2, 250, 251, 252, 253]
      let encoded = try JSONEncoder().encode(StreamBase64Data(bytes))
      expectNoDifference(
        String(decoding: encoded, as: UTF8.self),
        String(decoding: try JSONEncoder().encode(Data(bytes)), as: UTF8.self)
      )
      expectNoDifference(
        try JSONDecoder().decode(StreamBase64Data.self, from: encoded), StreamBase64Data(bytes)
      )
      #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(StreamBase64Data.self, from: Data(#""Zm9vYg""#.utf8))
      }
    }
  #endif
}
