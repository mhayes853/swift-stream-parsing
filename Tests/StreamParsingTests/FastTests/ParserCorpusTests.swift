import CustomDump
import Testing

import StreamParsing
import StreamParsingCore

// These payloads were the differential against the registration based parser, which ran the same
// input through both and required the same Partial. That parser is gone, so what survives is the
// corpus it covered and the answers it settled, now asserted directly. The two places the parsers
// disagreed are at the bottom, where the old one was wrong.

@StreamParseable
struct DiffProfile: Equatable {
  var id: Int = 0
  var name: String = ""
  var email: String = ""
  var age: Int = 0
  var score: Double = 0
  var isActive: Bool = false
}

@StreamParseable
struct DiffAddress: Equatable {
  var street: String = ""
  var city: String = ""
}

@StreamParseable
struct DiffCompany: Equatable {
  var name: String = ""
  var address: DiffAddress = DiffAddress()
}

@StreamParseable
struct DiffEmployee: Equatable {
  var id: Int = 0
  var name: String = ""
  var company: DiffCompany = DiffCompany()
}

@StreamParseable
struct DiffUser: Equatable {
  var id: Int = 0
  var name: String = ""
}

@StreamParseable
struct DiffUserList: Equatable {
  var users: [DiffUser] = []
  var total: Int = 0
}

@StreamParseable
struct DiffMatrix: Equatable {
  var rows: [[Int]] = []
}

@StreamParseable
struct DiffText: Equatable {
  var text: String = ""
}

// Chunk size is the axis the differential varied, because a token split across a call is where
// carry-over state shows up.
private func expectSameAtEveryChunkSize<Value: StreamParseableRoot>(
  _ json: String,
  as type: Value.Type,
  sourceLocation: SourceLocation = #_sourceLocation
) throws {
  var whole = Value.streamInitialValue()
  try parsePartial(json, into: &whole)

  for chunk in [7, 3, 1] {
    var chunked = Value.streamInitialValue()
    try parsePartial(json, into: &chunked, chunk: chunk)
    if let difference = diff(whole, chunked) {
      Issue.record(
        "Chunk size \(chunk) disagreed with the whole parse of \(json).\n\(difference)",
        sourceLocation: sourceLocation
      )
      return
    }
  }
}

@Suite
struct `Parser corpus tests` {
  @Test(arguments: [
    #"{"id":4,"name":"Blob Johnson","email":"blob@example.com","age":42,"score":98.25,"isActive":true}"#,
    #"{"id":0,"name":"","email":"","age":0,"score":0,"isActive":false}"#,
    #"  {  "id" : 4 , "name" : "Blob"  }  "#,
    #"{"id":-17,"score":-1.5e3}"#,
    #"{"unknown":1,"id":9}"#,
    #"{}"#
  ])
  func `Flat objects parse the same at every chunk size`(json: String) throws {
    try expectSameAtEveryChunkSize(json, as: DiffProfile.Partial.self)
  }

  @Test
  func `Flat object values are what the document says`() throws {
    var value = DiffProfile.Partial()
    try parsePartial(
      #"{"id":4,"name":"Blob Johnson","email":"b@e.com","age":42,"score":98.25,"isActive":true}"#,
      into: &value
    )
    #expect(value.id == 4)
    #expect(value.name == "Blob Johnson")
    #expect(value.email == "b@e.com")
    #expect(value.age == 42)
    #expect(value.score == 98.25)
    #expect(value.isActive == true)
  }

  @Test(arguments: [
    #"{"id":7,"name":"Blob Jr","company":{"name":"Point-Free","address":{"street":"123 Way","city":"Brooklyn"}}}"#,
    #"{"company":{"name":"Point-Free"}}"#
  ])
  func `Nested objects parse the same at every chunk size`(json: String) throws {
    try expectSameAtEveryChunkSize(json, as: DiffEmployee.Partial.self)
  }

  @Test
  func `Nested object values reach every depth`() throws {
    var value = DiffEmployee.Partial()
    try parsePartial(
      #"{"id":7,"company":{"name":"Point-Free","address":{"street":"123 Way","city":"Brooklyn"}}}"#,
      into: &value
    )
    #expect(value.id == 7)
    #expect(value.company?.name == "Point-Free")
    #expect(value.company?.address?.street == "123 Way")
    #expect(value.company?.address?.city == "Brooklyn")
  }

  @Test(arguments: [
    #"{"users":[{"id":1,"name":"A"},{"id":2,"name":"B"},{"id":3,"name":"C"}],"total":3}"#,
    #"{"users":[],"total":0}"#,
    #"{"users":[{"id":1,"name":""}],"total":1}"#
  ])
  func `Arrays of objects parse the same at every chunk size`(json: String) throws {
    try expectSameAtEveryChunkSize(json, as: DiffUserList.Partial.self)
  }

  @Test
  func `Arrays of objects keep their order and contents`() throws {
    var value = DiffUserList.Partial()
    try parsePartial(
      #"{"users":[{"id":1,"name":"A"},{"id":2,"name":"B"}],"total":2}"#, into: &value
    )
    #expect(value.total == 2)
    #expect(value.users?.map(\.id) == [1, 2])
    #expect(value.users?.map(\.name) == ["A", "B"])
  }

  @Test(arguments: [
    #"{"rows":[[1,2,3],[4,5,6]]}"#,
    #"{"rows":[[],[1]]}"#,
    #"{"rows":[]}"#
  ])
  func `Nested arrays parse the same at every chunk size`(json: String) throws {
    try expectSameAtEveryChunkSize(json, as: DiffMatrix.Partial.self)
  }

  @Test
  func `Nested array elements land in the right row`() throws {
    var value = DiffMatrix.Partial()
    try parsePartial(#"{"rows":[[1,2,3],[],[4]]}"#, into: &value)
    #expect(value.rows == [[1, 2, 3], [], [4]])
  }

  @Test(arguments: [
    (#"{"text":"plain"}"#, "plain"),
    (#"{"text":"a\nb\tc"}"#, "a\nb\tc"),
    (#"{"text":"quote \" and backslash \\"}"#, "quote \" and backslash \\"),
    (#"{"text":"slash \/"}"#, "slash /"),
    (#"{"text":"surrogate 😀"}"#, "surrogate 😀"),
    (#"{"text":""}"#, "")
  ])
  func `Strings and escapes decode`(json: String, expected: String) throws {
    var value = DiffText.Partial()
    try parsePartial(json, into: &value)
    #expect(value.text == expected)
    try expectSameAtEveryChunkSize(json, as: DiffText.Partial.self)
  }

  // An empty string produced nil until the differential caught it: the parser emits begin and end
  // with no chunk between them, and nothing materialized the destination.
  @Test
  func `An empty string is an empty value rather than nil`() throws {
    var value = DiffText.Partial()
    try parsePartial(#"{"text":""}"#, into: &value)
    #expect(value.text == "")
  }

  // MARK: - Where the registration based parser was wrong

  // It appended the trailing byte of a multi byte sequence as its own scalar, so U+20AC arrived
  // as U+00AC. The chunk boundary tests missed it because a consistently wrong value satisfies
  // "the same at every split".
  @Test(arguments: [
    (#"{"text":"unicode Aé€"}"#, "unicode Aé€"),
    (#"{"text":"raw Aé€😀"}"#, "raw Aé€😀")
  ])
  func `Multi byte UTF-8 decodes intact`(json: String, expected: String) throws {
    var value = DiffText.Partial()
    try parsePartial(json, into: &value)
    #expect(value.text == expected)
    try expectSameAtEveryChunkSize(json, as: DiffText.Partial.self)
  }

  // It materialized a nested partial only when a leaf wrote into one, leaving an empty object as
  // nil. Materializing on entry reports that the key was present and its value was an object.
  @Test(arguments: [#"{"company":{}}"#, #"{"company":{"address":{}}}"#])
  func `An empty nested object is materialized`(json: String) throws {
    var value = DiffEmployee.Partial()
    try parsePartial(json, into: &value)
    #expect(value.company != nil)
  }
}
