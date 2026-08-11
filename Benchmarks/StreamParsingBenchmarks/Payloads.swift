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

  static let matrix = Array(Self.makeMatrix(rows: 40, columns: 25).utf8)

  static let counts = Array(Self.makeCounts(count: 100).utf8)

  static let document = Array(Self.makeDocument(bodyLength: 8_000).utf8)

  /// Half and double sized variants of ``document``, used to check how string accumulation
  /// scales with the length of a single value.
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

  private static func makeCounts(count: Int) -> String {
    let entries = (0..<count)
      .map { "\"key_number_\($0)\":\($0)" }
      .joined(separator: ",")
    return "{\"counts\":{\(entries)}}"
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
