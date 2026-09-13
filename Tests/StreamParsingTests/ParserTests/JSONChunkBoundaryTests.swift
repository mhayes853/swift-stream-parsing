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
    // A `\u` escape is decoded whole when all six of its bytes are in the chunk and byte by byte
    // when they are not, and a surrogate pair the same at twelve, so both forms have to agree at
    // every one of those boundaries -- including the two inside the pair.
    #"{"text":"\u0041"}"#,
    #"{"text":"\u00e9"}"#,
    #"{"text":"\u20ac"}"#,
    #"{"text":"a\u0041b"}"#,
    #"{"text":"\ud83d\ude00"}"#,
    #"{"text":"a\ud83d\ude00b"}"#,
    #"{"text":"\u00e9\u20ac\ud83d\ude00"}"#,
    #"{"text":"\u0000"}"#,
    #"{"text":"x\n\u00e9\t\ud83d\ude00\\y"}"#,
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

  // The registration based parser accepted an unknown escape and took the escaped character
  // literally, where RFC 8259 requires rejecting it. That gap is closed: the escape is rejected,
  // and rejected at the same point no matter where the chunk boundary falls.
  @Test
  func `Unknown escape sequences are rejected`() {
    expectChunkBoundaryFailureEquivalence(
      #"{"name":"bad \q escape"}"#, as: ChunkProfile.Partial.self
    )
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
