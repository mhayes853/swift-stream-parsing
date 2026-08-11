import StreamParsing
import Testing

@Suite
struct `JSON chunk boundary tests` {
  @Test(arguments: [
    #"{"id":4,"name":"Blob Johnson","email":"blob@example.com","age":42,"score":98.25,"isActive":true}"#,
    #"{"id":0,"name":"","email":"","age":0,"score":0,"isActive":false}"#,
    #"  {  "id" : 4 , "name" : "Blob"  }  "#,
  ])
  func `Flat objects parse identically at every split`(json: String) throws {
    try expectChunkBoundaryEquivalence(json, as: ChunkProfile.Partial.self)
  }

  @Test(arguments: [
    #"{"id":7,"name":"Blob Jr","company":{"name":"Point-Free","address":{"street":"123 Functional Way","city":"Brooklyn","postalCode":"11201"}}}"#,
    #"{"company":{"address":{}}}"#,
  ])
  func `Nested objects parse identically at every split`(json: String) throws {
    try expectChunkBoundaryEquivalence(json, as: ChunkEmployee.Partial.self)
  }

  @Test(arguments: [
    #"{"users":[{"id":1,"name":"A"},{"id":2,"name":"B"},{"id":3,"name":"C"}],"total":3}"#,
    #"{"users":[],"total":0}"#,
    #"{"users":[{"id":1,"name":""}],"total":1}"#,
  ])
  func `Arrays of objects parse identically at every split`(json: String) throws {
    try expectChunkBoundaryEquivalence(json, as: ChunkUserList.Partial.self)
  }

  // Escapes carry state across a boundary in a way plain content does not: the backslash, the
  // escape selector and the four hex digits can each land in a different chunk.
  @Test(arguments: [
    #"{"text":"a\nb"}"#,
    #"{"text":"a\\b"}"#,
    #"{"text":"a\"b"}"#,
    #"{"text":"Aé€"}"#,
    #"{"text":"😀"}"#,
    #"{"text":"tab\there and A mixed"}"#,
  ])
  func `Escapes parse identically at every split`(json: String) throws {
    try expectChunkBoundaryEquivalence(json, as: ChunkText.Partial.self)
  }

  // A number is the one token whose value depends on digits accumulated across chunks.
  @Test(arguments: [
    #"{"value":0}"#,
    #"{"value":-1}"#,
    #"{"value":1234567890123456789}"#,
    #"{"value":-9223372036854775808}"#,
  ])
  func `Integers parse identically at every split`(json: String) throws {
    try expectChunkBoundaryEquivalence(json, as: ChunkInteger.Partial.self)
  }

  @Test(arguments: [
    #"{"value":0.0}"#,
    #"{"value":-98.25}"#,
    #"{"value":1e10}"#,
    #"{"value":1.5e-8}"#,
    #"{"value":123456789.123456789}"#,
  ])
  func `Doubles parse identically at every split`(json: String) throws {
    try expectChunkBoundaryEquivalence(json, as: ChunkDouble.Partial.self)
  }

  @Test(arguments: [
    #"{"flag":true}"#,
    #"{"flag":false}"#,
  ])
  func `Literals parse identically at every split`(json: String) throws {
    try expectChunkBoundaryEquivalence(json, as: ChunkFlag.Partial.self)
  }

  @Test(arguments: [
    #"{"counts":{"a":1,"b":2,"c":3}}"#,
    #"{"counts":{}}"#,
  ])
  func `Dictionaries parse identically at every split`(json: String) throws {
    try expectChunkBoundaryEquivalence(json, as: ChunkCounts.Partial.self)
  }

  @Test(arguments: [
    #"{"rows":[[1,2,3],[4,5,6]]}"#,
    #"{"rows":[[],[1]]}"#,
  ])
  func `Nested arrays parse identically at every split`(json: String) throws {
    try expectChunkBoundaryEquivalence(json, as: ChunkMatrix.Partial.self)
  }

  @Test(arguments: [
    #"{"id":}"#,
    #"{"id" 4}"#,
    #"{"id":4,}"#,
    #"{"id":01}"#,
    #"{"id":4"#,
    #"{"name":"unterminated}"#,
  ])
  func `Malformed input fails identically at every split`(json: String) {
    expectChunkBoundaryFailureEquivalence(json, as: ChunkProfile.Partial.self)
  }

  // The parser currently accepts unknown escape sequences and takes the escaped character
  // literally, where RFC 8259 requires rejecting them. Pinned here so the leniency is a
  // decision rather than an accident, and so a future conformance pass has to change this
  // test deliberately.
  @Test
  func `Unknown escape sequences are currently accepted`() throws {
    try expectChunkBoundaryEquivalence(#"{"name":"bad \q escape"}"#, as: ChunkProfile.Partial.self)
  }
}

// MARK: - Models

@StreamParseable
struct ChunkProfile: Equatable {
  var id: Int = 0
  var name: String = ""
  var email: String = ""
  var age: Int = 0
  var score: Double = 0
  var isActive: Bool = false
}

@StreamParseable
struct ChunkAddress: Equatable {
  var street: String = ""
  var city: String = ""
  var postalCode: String = ""
}

@StreamParseable
struct ChunkCompany: Equatable {
  var name: String = ""
  var address: ChunkAddress = ChunkAddress()
}

@StreamParseable
struct ChunkEmployee: Equatable {
  var id: Int = 0
  var name: String = ""
  var company: ChunkCompany = ChunkCompany()
}

@StreamParseable
struct ChunkUser: Equatable {
  var id: Int = 0
  var name: String = ""
}

@StreamParseable
struct ChunkUserList: Equatable {
  var users: [ChunkUser] = []
  var total: Int = 0
}

@StreamParseable
struct ChunkText: Equatable {
  var text: String = ""
}

@StreamParseable
struct ChunkInteger: Equatable {
  var value: Int = 0
}

@StreamParseable
struct ChunkDouble: Equatable {
  var value: Double = 0
}

@StreamParseable
struct ChunkFlag: Equatable {
  var flag: Bool = false
}

@StreamParseable
struct ChunkCounts: Equatable {
  var counts: [String: Int] = [:]
}

@StreamParseable
struct ChunkMatrix: Equatable {
  var rows: [[Int]] = []
}
