import Foundation

// MARK: - Payloads

enum Payloads {
  static let flat = Array(
    """
    {"id":4,"name":"Blob Johnson","email":"blob@example.com","age":42,\
    "score":98.25,"isActive":true}
    """.utf8
  )

  static let nested = Array(
    """
    {"id":7,"name":"Blob Jr","company":{"name":"Point-Free",\
    "address":{"street":"123 Functional Way","city":"Brooklyn","postalCode":"11201"}}}
    """.utf8
  )

  static let userList = Array(Self.makeUserList(count: 100).utf8)
  static let userList10 = Array(Self.makeUserList(count: 10).utf8)
  static let userList400 = Array(Self.makeUserList(count: 400).utf8)

  static let matrix = Array(Self.makeMatrix(rows: 40, columns: 25).utf8)

  static let counts = Array(Self.makeCounts(count: 100).utf8)

  static let countsByKeyCount = Dictionary(
    uniqueKeysWithValues: Self.keyCounts.map { ($0, Array(Self.makeCounts(count: $0).utf8)) }
  )

  // Keys past fifteen bytes are heap allocated rather than inline, which is what decides whether
  // materialising one on every entry costs a malloc.
  static let countsLongKeys = Array(Self.makeCounts(count: 128, keyPrefix: Self.longKeyPrefix).utf8)

  // One long key repeated many times isolates the allocation avoided when a resumed dictionary
  // value is opened from its borrowed span rather than from a newly materialised String.
  static let repeatedLongKeyDocument = Array(Self.makeRepeatedLongKeyDocument(count: 256).utf8)

  static let repeatedLongKey = "repeated_dictionary_key_with_a_much_longer_name_"

  static let keyCounts = [8, 32, 128, 512]

  static let shortKeyPrefix = "key_number_"
  static let longKeyPrefix = "key_number_with_a_much_longer_name_"

  static func countKeys(_ count: Int, prefix: String, from start: Int = 0) -> [[UInt8]] {
    (start..<(start + count)).map { Array("\(prefix)\($0)".utf8) }
  }

  // Field names that differ from the first byte, which is what an object's keys look like and
  // what a leading word prefilter is actually good at.
  static func diverseKeys(_ count: Int, from start: Int) -> [[UInt8]] {
    (start..<(start + count)).map { index in
      let stem = Self.keyStems[index % Self.keyStems.count]
      return Array("\(stem)_\(index)".utf8)
    }
  }

  private static let keyStems = [
    "id", "name", "email", "created", "updated", "status", "count", "total", "user", "items",
    "price", "quantity", "label", "kind", "source", "target", "score", "rank", "tags", "owner",
    "body", "title", "url", "parent", "child", "depth"
  ]

  static let document = Array(Self.makeDocument(bodyLength: 8_000).utf8)

  // The long string benchmark is a memcpy by comparison: one SIMD run the length of the body.
  // These three are the string shapes that defeat the run scanner, sized to the same ~8 KB.

  // Every third byte is an escape, so no run exceeds two bytes and the parse is dominated by the
  // per escape state machine and scratch emission.
  static let escapedString = Array(Self.makeEscapedDocument(repetitions: 1_300).utf8)

  // Six or twelve input bytes per character, all through the unicode escape path, half of the
  // characters surrogate pairs.
  static let unicodeEscapedString = Array(Self.makeUnicodeEscapedDocument(repetitions: 333).utf8)

  // Mixed two, three and four byte sequences, so the full UTF-8 validator runs on every chunk in
  // bulk and every character crosses the pending sequence path byte by byte.
  static let nonASCIIString = Array(Self.makeNonASCIIDocument(repetitions: 727).utf8)

  // The same content as `userList`, pretty printed, so roughly a third of the payload is the
  // indentation the scalar whitespace scanner walks.
  static let prettyUserList = Array(Self.makePrettyUserList(count: 100).utf8)

  static let twitter: [UInt8] = {
    guard let url = Bundle.module.url(
      forResource: "twitter",
      withExtension: "json",
      subdirectory: "Resources"
    ) else {
      preconditionFailure("twitter.json benchmark payload is missing")
    }
    guard let data = try? Data(contentsOf: url) else {
      preconditionFailure("twitter.json benchmark payload could not be loaded")
    }
    return Array(data)
  }()

  static let documentHalf = Array(Self.makeDocument(bodyLength: 4_000).utf8)
  static let documentDouble = Array(Self.makeDocument(bodyLength: 16_000).utf8)

  private static func makeUserList(count: Int) -> String {
    let users = (0..<count)
      .map { index in
        """
        {"id":\(index),"name":"User Number \(index)","email":"user\(index)@example.com"}
        """
      }
      .joined(separator: ",")
    return "{\"users\":[\(users)],\"total\":\(count)}"
  }

  private static func makeMatrix(rows: Int, columns: Int) -> String {
    let rows = (0..<rows)
      .map { row in
        let values = (0..<columns).map { "\(row * columns + $0)" }.joined(separator: ",")
        return "[\(values)]"
      }
      .joined(separator: ",")
    return "{\"rows\":[\(rows)]}"
  }

  private static func makeCounts(count: Int, keyPrefix: String = Payloads.shortKeyPrefix) -> String {
    let entries = (0..<count)
      .map { "\"\(keyPrefix)\($0)\":\($0)" }
      .joined(separator: ",")
    return "{\"counts\":{\(entries)}}"
  }

  private static func makeRepeatedLongKeyDocument(count: Int) -> String {
    let entries = (0..<count)
      .map { "\"\(Self.repeatedLongKey)\":\($0)" }
      .joined(separator: ",")
    return "{\(entries)}"
  }

  private static func makeEscapedDocument(repetitions: Int) -> String {
    let body = String(repeating: #"a\nb\t"#, count: repetitions)
    return "{\"title\":\"Escapes\",\"body\":\"\(body)\"}"
  }

  private static func makeUnicodeEscapedDocument(repetitions: Int) -> String {
    // é, €, and 😀 as a surrogate pair, all through the \u path.
    let esc = "\u{5C}"
    let unit = "\(esc)u00e9\(esc)u20ac\(esc)ud83d\(esc)ude00"
    let body = String(repeating: unit, count: repetitions)
    return "{\"title\":\"Unicode escapes\",\"body\":\"\(body)\"}"
  }

  private static func makeNonASCIIDocument(repetitions: Int) -> String {
    let body = String(repeating: "éαあ😀", count: repetitions)
    return "{\"title\":\"Non-ASCII\",\"body\":\"\(body)\"}"
  }

  private static func makePrettyUserList(count: Int) -> String {
    let users = (0..<count)
      .map { index in
        """
              {
                "id": \(index),
                "name": "User Number \(index)",
                "email": "user\(index)@example.com"
              }
        """
      }
      .joined(separator: ",\n")
    return """
      {
        "users": [
      \(users)
        ],
        "total": \(count)
      }
      """
  }

  private static func makeDocument(bodyLength: Int) -> String {
    let word = "streaming "
    var body = ""
    body.reserveCapacity(bodyLength + word.count)
    while body.count < bodyLength {
      body += word
    }
    return "{\"title\":\"A Benchmark Document\",\"body\":\"\(body)\"}"
  }
}
