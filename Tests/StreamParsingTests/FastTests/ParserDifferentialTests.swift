import CustomDump
import Testing

import StreamParsing
import StreamParsingCore

// Runs the same payload through both parsers into the same Partial type and requires the same
// result. This is only possible while both exist, and it is the highest confidence check
// available for a rewrite of this size: it compares against the behaviour that shipped rather
// than against what the new implementation was written to do.

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

func parseWithOldParser<Value: StreamParseableValue>(
  _ json: String, as type: Value.Type, chunk: Int
) throws -> Value {
  var parser = JSONStreamParser<Value>()
  parser.registerHandlers()
  var value = Value.initialParseableValue()
  let bytes = Array(json.utf8)
  var i = 0
  while i < bytes.count {
    let count = min(chunk, bytes.count - i)
    try parser.parse(bytes: bytes[i..<(i + count)], into: &value)
    i += count
  }
  try parser.finish(reducer: &value)
  return value
}

private func parseWithNewParser<Value: StreamParseableObject>(
  _ json: String, as type: Value.Type, chunk: Int
) throws -> Value {
  var value = Value.streamInitialValue()
  try parsePartial(json, into: &value, chunk: chunk)
  return value
}

private func expectSameResult<Value>(
  _ json: String,
  as type: Value.Type,
  sourceLocation: SourceLocation = #_sourceLocation
) throws where Value: StreamParseableValue & StreamParseableObject {
  for chunk in [Int.max, 7, 1] {
    let old = try parseWithOldParser(json, as: Value.self, chunk: chunk)
    let new = try parseWithNewParser(json, as: Value.self, chunk: chunk)
    if let difference = diff(old, new) {
      Issue.record(
        """
        Parsers disagreed on \(json) at chunk \(chunk == .max ? "whole" : "\(chunk)").
        \(difference)
        """,
        sourceLocation: sourceLocation
      )
      return
    }
  }
}

@Suite
struct `Parser differential tests` {
  @Test(arguments: [
    #"{"id":4,"name":"Blob Johnson","email":"blob@example.com","age":42,"score":98.25,"isActive":true}"#,
    #"{"id":0,"name":"","email":"","age":0,"score":0,"isActive":false}"#,
    #"  {  "id" : 4 , "name" : "Blob"  }  "#,
    #"{"id":-17,"score":-1.5e3}"#,
    #"{"unknown":1,"id":9}"#,
    #"{}"#,
  ])
  func `Flat objects agree`(json: String) throws {
    try expectSameResult(json, as: DiffProfile.Partial.self)
  }

  @Test(arguments: [
    #"{"id":7,"name":"Blob Jr","company":{"name":"Point-Free","address":{"street":"123 Way","city":"Brooklyn"}}}"#,
    #"{"company":{"name":"Point-Free"}}"#,
  ])
  func `Nested objects agree`(json: String) throws {
    try expectSameResult(json, as: DiffEmployee.Partial.self)
  }

  @Test(arguments: [
    #"{"users":[{"id":1,"name":"A"},{"id":2,"name":"B"},{"id":3,"name":"C"}],"total":3}"#,
    #"{"users":[],"total":0}"#,
    #"{"users":[{"id":1,"name":""}],"total":1}"#,
  ])
  func `Arrays of objects agree`(json: String) throws {
    try expectSameResult(json, as: DiffUserList.Partial.self)
  }

  @Test(arguments: [
    #"{"rows":[[1,2,3],[4,5,6]]}"#,
    #"{"rows":[[],[1]]}"#,
    #"{"rows":[]}"#,
  ])
  func `Nested arrays agree`(json: String) throws {
    try expectSameResult(json, as: DiffMatrix.Partial.self)
  }

  @Test(arguments: [
    #"{"text":"plain"}"#,
    #"{"text":"a\nb\tc"}"#,
    #"{"text":"quote \" and backslash \\"}"#,
    #"{"text":"slash \/"}"#,
    #"{"text":"surrogate 😀"}"#,
    #"{"text":""}"#,
  ])
  func `Strings and escapes agree`(json: String) throws {
    try expectSameResult(json, as: DiffText.Partial.self)
  }
}

// Cases where the parsers deliberately differ. Recorded rather than reconciled, so the change
// is a decision instead of a regression, and so removing the old parser does not quietly change
// behaviour nobody noticed.
@Suite
struct `Parser divergence tests` {
  // The old parser mangles multi byte UTF-8: it appends the trailing byte of a sequence as its
  // own scalar, so U+20AC comes out as U+00AC. The chunk boundary tests did not catch this
  // because they only require the same value at every split, and a consistently wrong value
  // satisfies that.
  @Test(arguments: [
    (#"{"text":"unicode Aé€"}"#, "unicode Aé€"),
    (#"{"text":"raw Aé€😀"}"#, "raw Aé€😀"),
  ])
  func `The new parser decodes multi byte UTF-8 the old one corrupts`(
    json: String, expected: String
  ) throws {
    var new = DiffText.Partial()
    try parsePartial(json, into: &new)
    #expect(new.text == expected)

    let old = try parseWithOldParser(json, as: DiffText.Partial.self, chunk: .max)
    #expect(old.text != expected, "The old parser was expected to be wrong here")
  }

  // The old parser materializes a nested partial only when a leaf writes into it, so an empty
  // object leaves the member nil. The new one materializes on entry, which reports that the key
  // was present and its value was an object.
  @Test(arguments: [#"{"company":{}}"#, #"{"company":{"address":{}}}"#])
  func `The new parser materializes empty nested objects`(json: String) throws {
    var new = DiffEmployee.Partial()
    try parsePartial(json, into: &new)
    #expect(new.company != nil)

    let old = try parseWithOldParser(json, as: DiffEmployee.Partial.self, chunk: .max)
    #expect(old.company == nil)
  }
}
