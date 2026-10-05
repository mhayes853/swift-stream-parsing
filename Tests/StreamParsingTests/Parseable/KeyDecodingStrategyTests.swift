import StreamParsing
import Testing

// Built-in strategies are applied as the macro expands, anything else when the schema is built.
// Both have to produce the keys `StreamKeyDecodingStrategy.key(for:)` does, and the parser must
// not be able to tell a converted key from one written out.

@StreamParseable(keyDecodingStrategy: .convertFromSnakeCase)
private struct SnakeUser: Equatable {
  var userID: Int
  var screenName: String
  var profileImageURL: String
  @StreamParseableMember(key: "full_text")
  var text: String
  @StreamParseableMember(keyNames: ["follower_count", "followers"])
  var followerCount: Int
  var nested: CamelNested
}

// A member type follows its own strategy, not the parent's.
@StreamParseable
private struct CamelNested: Equatable {
  var innerValue: Int
}

@StreamParseable(keyDecodingStrategy: StreamKeyDecodingStrategy.convertFromScreamingSnakeCase)
private struct ScreamingModel: Equatable {
  var createdAt: String
}

@StreamParseable(keyDecodingStrategy: StreamParsing.StreamKeyDecodingStrategy.convertFromKebabCase)
private struct KebabModel: Equatable {
  var contentType: String
}

@StreamParseable(keyDecodingStrategy: .convertFromPascalCase)
private struct PascalModel: Equatable {
  var userID: Int
  var displayName: String
}

@StreamParseable(keyDecodingStrategy: .useDefaultKeys)
private struct DefaultKeysModel: Equatable {
  var userID: Int
}

@StreamParseable(
  keyDecodingStrategy: .custom {
    "x_" + StreamKeyDecodingStrategy.convertFromSnakeCase.key(for: $0)
  }
)
private struct PrefixedModel: Equatable {
  var requestID: String
  var retryCount: Int
  @StreamParseableMember(key: "id")
  var identifier: Int
}

extension StreamKeyDecodingStrategy {
  fileprivate static let uppercased = StreamKeyDecodingStrategy.custom { $0.uppercased() }
}

@StreamParseable(keyDecodingStrategy: .uppercased)
private struct NamedStrategyModel: Equatable {
  var name: String
}

// Past `StreamFieldTable.indexThreshold`, so the converted keys are matched through the hash
// index rather than the scan.
@StreamParseable(keyDecodingStrategy: .custom { $0.uppercased() })
private struct WideModel: Equatable {
  var a0: Int = 0
  var a1: Int = 0
  var a2: Int = 0
  var a3: Int = 0
  var a4: Int = 0
  var a5: Int = 0
  var a6: Int = 0
  var a7: Int = 0
  var a8: Int = 0
  var b0: Int = 0
  var b1: Int = 0
  var b2: Int = 0
  var b3: Int = 0
  var b4: Int = 0
  var b5: Int = 0
  var b6: Int = 0
  var b7: Int = 0
  var lastValue: Int = 0
}

@StreamParseable(keyDecodingStrategy: .custom { $0.uppercased() })
private struct Page<Item: StreamParseable> {
  var pageItems: [Item]
  var pageNumber: Int
}

@StreamParseable(keyDecodingStrategy: .convertFromSnakeCase)
private enum Activity: Equatable {
  @StreamParseableDefault
  case unknownActivity
  case userJoined(userName: String, joinedAt: Int)
  case itemAdded(Int)
  @StreamParseableMember(key: "renamedEvent")
  case renamed
}

@StreamParseable(keyDecodingStrategy: .custom { $0.uppercased() })
private enum Figure: Equatable {
  @StreamParseableDefault
  case none
  case square(sideLength: Double)
}

@StreamParseable(keyDecodingStrategy: .custom { _ in "same" })
private struct CollidingModel {
  var first: Int
  var second: Int
}

private func parse<T: StreamParseable>(
  _ json: String,
  as type: T.Type
) throws -> T? where T.Partial: StreamPartial {
  var partial = T.Partial.streamInitialValue()
  try parsePartial(json, into: &partial)
  return T(streamPartial: partial)
}

@Suite
struct `Key Decoding Strategy Tests` {
  @Test
  func `Built-in strategies convert declared names`() {
    // Each case reaches its own conversion; `StreamParsingMacroSupportTests.KeyDecodingTests`
    // covers the rules name by name, through the same implementation.
    let expected: [(StreamKeyDecodingStrategy, String)] = [
      (.useDefaultKeys, "myURLValue"),
      (.convertFromSnakeCase, "my_url_value"),
      (.convertFromScreamingSnakeCase, "MY_URL_VALUE"),
      (.convertFromKebabCase, "my-url-value"),
      (.convertFromPascalCase, "MyURLValue"),
    ]
    for (strategy, key) in expected {
      #expect(strategy.key(for: "myURLValue") == key)
    }
  }

  @Test
  func `Custom strategies run their closure`() {
    let strategy = StreamKeyDecodingStrategy.custom { "k_" + $0 }
    #expect(strategy.key(for: "name") == "k_name")
  }

  @Test
  func `Snake case reads converted keys and leaves written keys alone`() throws {
    let json = """
      {"user_id":1,"screen_name":"swift","profile_image_url":"https://a","full_text":"hi",\
      "followers":9,"nested":{"innerValue":2}}
      """
    let expected = SnakeUser(
      userID: 1, screenName: "swift", profileImageURL: "https://a", text: "hi",
      followerCount: 9, nested: CamelNested(innerValue: 2)
    )
    #expect(try parse(json, as: SnakeUser.self) == expected)
  }

  @Test
  func `A converted key no longer matches the declared name`() throws {
    var stream = PartialsStream(initialValue: SnakeUser.Partial(), from: .json())
    try stream.next(Array(#"{"userID":1,"text":"x","user_id":2}"#.utf8))
    #expect(stream.current.userID == 2)
    #expect(stream.current.text == nil)
  }

  @Test
  func `The other built-in strategies`() throws {
    #expect(
      try parse(#"{"CREATED_AT":"now"}"#, as: ScreamingModel.self)
        == ScreamingModel(createdAt: "now")
    )
    #expect(
      try parse(#"{"content-type":"json"}"#, as: KebabModel.self)
        == KebabModel(contentType: "json")
    )
    #expect(
      try parse(#"{"UserID":4,"DisplayName":"A"}"#, as: PascalModel.self)
        == PascalModel(userID: 4, displayName: "A")
    )
    #expect(try parse(#"{"userID":5}"#, as: DefaultKeysModel.self) == DefaultKeysModel(userID: 5))
  }

  @Test
  func `Custom strategies convert keys when the schema is built`() throws {
    #expect(
      try parse(#"{"x_request_id":"r","x_retry_count":3,"id":7}"#, as: PrefixedModel.self)
        == PrefixedModel(requestID: "r", retryCount: 3, identifier: 7)
    )
    #expect(
      try parse(#"{"NAME":"n"}"#, as: NamedStrategyModel.self) == NamedStrategyModel(name: "n")
    )
  }

  @Test
  func `Converted keys past the index threshold`() throws {
    var stream = PartialsStream(initialValue: WideModel.Partial(), from: .json())
    try stream.next(Array(#"{"A0":1,"B7":2,"LASTVALUE":3,"lastValue":4}"#.utf8))
    #expect(stream.current.a0 == 1)
    #expect(stream.current.b7 == 2)
    #expect(stream.current.lastValue == 3)
    #expect(stream.current.a1 == nil)
  }

  @Test
  func `A schema with converted keys answers matchField from its table`() {
    let schema = PrefixedModel.Partial.streamSchema
    let fields: [(String, Int32)] = [
      ("x_request_id", 0), ("x_retry_count", 1), ("id", 2), ("requestID", -1),
    ]
    for (key, field) in fields {
      let matched = Array(key.utf8).withUnsafeBufferPointer {
        schema.matchField(Span(_unsafeElements: $0))
      }
      #expect(matched == field)
    }
  }

  @Test
  func `Converted keys through optional and generic wrappers`() throws {
    var stream = PartialsStream(initialValue: [PrefixedModel?].Partial(), from: .json())
    try stream.next(Array(#"[{"x_request_id":"a","x_retry_count":1,"id":1},null]"#.utf8))
    try stream.finish()
    #expect(
      [PrefixedModel?](streamPartial: stream.current)
        == [PrefixedModel(requestID: "a", retryCount: 1, identifier: 1), nil]
    )

    let page = try parse(#"{"PAGEITEMS":[1,2],"PAGENUMBER":3}"#, as: Page<Int>.self)
    #expect(page?.pageItems == [1, 2])
    #expect(page?.pageNumber == 3)
  }

  @Test
  func `Enums convert case names and labels, not positions`() throws {
    #expect(
      try parse(#"{"user_joined":{"user_name":"a","joined_at":3}}"#, as: Activity.self)
        == .userJoined(userName: "a", joinedAt: 3)
    )
    #expect(try parse(#"{"item_added":{"_0":5}}"#, as: Activity.self) == .itemAdded(5))
    #expect(try parse(#"{"renamedEvent":{}}"#, as: Activity.self) == .renamed)
    #expect(try parse(#"{"SQUARE":{"SIDELENGTH":2}}"#, as: Figure.self) == .square(sideLength: 2))
  }

  @Test
  func `Two names a custom strategy converts to one key stop the program`() async {
    await #expect(processExitsWith: .failure) {
      _ = CollidingModel.Partial.streamSchema
    }
  }
}
