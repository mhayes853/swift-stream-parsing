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

  // Three container fields per element rather than per document. 200 elements, so 600 container
  // field entries against the 1 that `userList` and `wideRows` each make.
  static let entryList = Array(Self.makeEntryList(count: 200).utf8)

  // Literals are 3.4% of `twitter`'s bytes and under 0.6% of every other real document's, so no
  // corpus payload can resolve a change to the literal path. This one is 62% literal bytes: a
  // feature-flag object, which is the shape that actually is.
  static let literals = Array(Self.makeLiterals(count: 600).utf8)

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

  // MARK: - Depth

  // Depth is capped at 64 by the container bitmask, and a frame is pushed and popped per level.
  // Nothing else in the suite nests past three, so these are the only measurements of that spine.
  static let deepObjects63 = Array(Self.makeDeepObjects(depth: 63).utf8)
  static let deepObjects16 = Array(Self.makeDeepObjects(depth: 16).utf8)
  static let deepArrays63 = Array(Self.makeDeepArrays(depth: 63).utf8)

  // MARK: - Schema width

  // Key matching is a scan over precomputed leading words, so its cost is in the member count of
  // the type being parsed into, not in the payload. These hit the first member, the last, and a
  // key the schema does not declare at all.
  static let wideFirst = Array(Self.makeWideDocument(hitting: .first).utf8)
  static let wideLast = Array(Self.makeWideDocument(hitting: .last).utf8)
  static let wideMiss = Array(Self.makeWideDocument(hitting: .absent).utf8)

  // MARK: - Numbers in situ

  // The number strategy benchmarks are micro-benchmarks over bare corpora. These are the same
  // token shapes inside a document, through the real parser: 17-19 digit ids are what the
  // eight-digit block was chosen for, and floats with exponents are what `canada.json` is.
  static let largeIntegers = Array(Self.makeNumberArray(count: 2_000) { index in
    "\(1_000_000_000_000_000_000 &+ UInt64(index) &* 7_919)"
  }.utf8)

  static let floats = Array(Self.makeNumberArray(count: 2_000) { index in
    "\(index % 180 - 90).\(index % 1_000_000)e\(index % 17 - 8)"
  }.utf8)

  // MARK: - Real world

  static let twitter = Self.resource("twitter")

  // The rest of the yyjson_benchmark corpus. Each covers a shape the synthetic payloads only
  // approximate: `canada` is float-heavy geometry, `citm_catalog` is deeply nested with heavily
  // repeated keys, `gsoc-2018` is large with long strings, `twitterescaped` is the same document
  // as `twitter` with every non-ASCII character written as a `\u` escape, and `github_events`
  // is a small API response.
  static let canada = Self.resource("canada")
  static let citmCatalog = Self.resource("citm_catalog")
  static let gsoc2018 = Self.resource("gsoc-2018")
  static let githubEvents = Self.resource("github_events")
  static let twitterEscaped = Self.resource("twitterescaped")

  // An assistant message response: many content blocks of markdown prose and fenced code, so the
  // payload is dominated by long strings carrying `\n` and `\"` escapes, with tool-use objects
  // and small integers between them. This is the shape the convenience layer exists for, and the
  // only benchmark payload that is both large and escape-heavy.
  static let llmMessage = Self.resource("llm_message")

  // Forces every payload to initialize before any benchmark runs. Called once from the
  // registration closure; see the note there for why this is not optional.
  static func warmUp() {
    let all: [[UInt8]] = [
      Self.flat, Self.nested, Self.userList, Self.userList10, Self.userList400, Self.matrix,
      Self.counts, Self.entryList, Self.literals, Self.countsLongKeys,
      Self.repeatedLongKeyDocument, Self.document, Self.escapedString, Self.unicodeEscapedString,
      Self.nonASCIIString, Self.prettyUserList, Self.deepObjects63, Self.deepObjects16,
      Self.deepArrays63, Self.wideFirst, Self.wideLast, Self.wideMiss, Self.largeIntegers,
      Self.floats, Self.twitter, Self.canada, Self.citmCatalog, Self.gsoc2018, Self.githubEvents,
      Self.twitterEscaped, Self.llmMessage
    ]
    var total = 0
    for payload in all { total &+= payload.count }
    for payload in Self.countsByKeyCount.values { total &+= payload.count }
    precondition(total > 0)
  }

  private static func resource(_ name: String) -> [UInt8] {
    guard let url = Bundle.module.url(
      forResource: name,
      withExtension: "json",
      subdirectory: "Resources"
    ) else {
      preconditionFailure("\(name).json benchmark payload is missing")
    }
    guard let data = try? Data(contentsOf: url) else {
      preconditionFailure("\(name).json benchmark payload could not be loaded")
    }
    return Array(data)
  }

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

  private static func makeEntryList(count: Int) -> String {
    let entries = (0..<count)
      .map { index in
        """
        {"id":\(index),"entities":{"hashtags":["tag\(index)","swift"],\
        "mentions":[\(index),\(index &+ 1)],"sizes":{"small":\(index),"large":\(index &* 2)}}}
        """
      }
      .joined(separator: ",")
    return "{\"entries\":[\(entries)]}"
  }

  private static func makeCounts(count: Int, keyPrefix: String = Payloads.shortKeyPrefix) -> String {
    let entries = (0..<count)
      .map { "\"\(keyPrefix)\($0)\":\($0)" }
      .joined(separator: ",")
    return "{\"counts\":{\(entries)}}"
  }

  private static func makeLiterals(count: Int) -> String {
    let values = ["true", "false", "null"]
    let entries = (0..<count)
      .map { "\"f\($0)\":\(values[$0 % values.count])" }
      .joined(separator: ",")
    return "{\(entries)}"
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

  private static func makeDeepObjects(depth: Int) -> String {
    String(repeating: "{\"a\":", count: depth) + "1" + String(repeating: "}", count: depth)
  }

  private static func makeDeepArrays(depth: Int) -> String {
    String(repeating: "[", count: depth) + "1" + String(repeating: "]", count: depth)
  }

  enum WideHit {
    case first
    case last
    case absent
  }

  // Repeated so the scan is measured rather than the parse around it, and every entry hits the
  // same member so a run reports one position on the curve instead of its average.
  private static func makeWideDocument(hitting hit: WideHit, count: Int = 256) -> String {
    let key =
      switch hit {
      case .first: Self.wideKeys.first!
      case .last: Self.wideKeys.last!
      case .absent: "not_a_declared_member"
      }
    let entries = (0..<count).map { "{\"\(key)\":\($0)}" }.joined(separator: ",")
    return "{\"rows\":[\(entries)]}"
  }

  // Matches `BenchmarkWide`'s members in declaration order.
  static let wideKeys = (0..<48).map { "field\($0)" }

  private static func makeNumberArray(count: Int, token: (Int) -> String) -> String {
    "{\"values\":[\((0..<count).map(token).joined(separator: ","))]}"
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
