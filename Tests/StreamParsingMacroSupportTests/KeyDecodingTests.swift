import StreamParsingMacroSupport
import SwiftBasicFormat
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing

// The conversion rules, name by name. `StreamKeyDecodingStrategy.key(for:)` runs the same
// implementation, so `StreamParsingTests.KeyDecodingStrategyTests` only checks it reaches it.
private let conversions:
  [(name: String, snake: String, screaming: String, kebab: String, pascal: String)] = [
  ("createdAt", "created_at", "CREATED_AT", "created-at", "CreatedAt"),
  ("userID", "user_id", "USER_ID", "user-id", "UserID"),
  ("myURLValue", "my_url_value", "MY_URL_VALUE", "my-url-value", "MyURLValue"),
  ("URLValue", "url_value", "URL_VALUE", "url-value", "URLValue"),
  ("line2Text", "line2_text", "LINE2_TEXT", "line2-text", "Line2Text"),
  ("sha256Hash", "sha256_hash", "SHA256_HASH", "sha256-hash", "Sha256Hash"),
  ("user_id", "user_id", "USER_ID", "user-id", "User_id"),
  ("user_ID", "user_id", "USER_ID", "user-id", "User_ID"),
  ("a__b", "a__b", "A__B", "a--b", "A__b"),
  ("_id", "_id", "_ID", "_id", "_Id"),
  ("value_", "value_", "VALUE_", "value_", "Value_"),
  ("__", "__", "__", "__", "__"),
  ("x", "x", "X", "x", "X"),
  ("ID", "id", "ID", "id", "ID"),
  ("éclairFlavor", "éclair_flavor", "ÉCLAIR_FLAVOR", "éclair-flavor", "ÉclairFlavor"),
]

private func configuration(_ strategy: ExprSyntax?) -> StreamGenerationConfiguration {
  StreamGenerationConfiguration(keyDecodingStrategy: strategy)
}

private func field(_ name: String, type: String = "Int") -> StreamParseableField {
  StreamParseableField(name: .identifier(name), type: TypeSyntax("\(raw: type)"))
}

@Suite
struct KeyDecodingTests {
  @Test
  func builtInSpellingsConvertDuringGeneration() {
    for conversion in conversions {
      let name = conversion.name
      #expect(configuration(nil).decodedKey(for: name) == name)
      #expect(configuration(".useDefaultKeys").decodedKey(for: name) == name)
      #expect(configuration(".convertFromSnakeCase").decodedKey(for: name) == conversion.snake)
      #expect(
        configuration(".convertFromScreamingSnakeCase").decodedKey(for: name)
          == conversion.screaming
      )
      #expect(configuration(".convertFromKebabCase").decodedKey(for: name) == conversion.kebab)
      #expect(configuration(".convertFromPascalCase").decodedKey(for: name) == conversion.pascal)
    }
  }

  @Test
  func qualifiedSpellingsAreBuiltIn() {
    #expect(
      configuration("StreamKeyDecodingStrategy.convertFromSnakeCase").decodedKey(for: "aB") == "a_b"
    )
    #expect(
      configuration("StreamParsing.StreamKeyDecodingStrategy.convertFromSnakeCase")
        .decodedKey(for: "aB") == "a_b"
    )
  }

  @Test
  func otherExpressionsAreLeftToTheSchemaBuild() {
    for expression: ExprSyntax in [
      ".custom { $0 }", ".openAI", "Strategies.openAI", "Other.convertFromSnakeCase",
      "strategy", ".convertFromSnakeCase(1)",
    ] {
      #expect(configuration(expression).decodedKey(for: "aB") == nil)
    }
  }

  @Test
  func decodedKeysAreKnownUnlessACustomStrategyConverts() {
    let explicit = StreamParseableField(
      name: .identifier("text"), type: TypeSyntax("String"), explicitKeys: ["full_text", "text"]
    )
    for strategy: ExprSyntax? in [nil, ".useDefaultKeys", ".convertFromSnakeCase"] {
      let keys = configuration(strategy).decodedKeys(for: explicit)
      #expect(keys.map(\.knownKey) == ["full_text", "text"])
      #expect(keys.map(\.expression.description) == [#""full_text""#, #""text""#])
    }
    #expect(configuration(nil).decodedKeys(for: field("createdAt")).map(\.knownKey) == ["createdAt"])
    let snake = configuration(".convertFromSnakeCase")
    #expect(snake.decodedKeys(for: field("createdAt")).map(\.knownKey) == ["created_at"])
    #expect(snake.decodedKey(converting: "userJoined").expression.description == #""user_joined""#)
  }

  @Test
  func customStrategyKeysAreExpressionsThatConvertAtRunTime() {
    let house = configuration(".custom { \"x_\" + $0 }")
    let converted = house.decodedKeys(for: field("createdAt"))
    #expect(converted.map(\.knownKey) == [nil])
    #expect(
      converted.map(\.expression.description) == [
        #"(.custom { "x_" + $0 } as StreamParsing.StreamKeyDecodingStrategy).key(for: "createdAt")"#
      ]
    )
    #expect(!Parser.parse(source: "_ = \(converted[0].expression)").hasError)
    let explicit = StreamParseableField(
      name: .identifier("text"), type: TypeSyntax("String"), explicitKeys: ["full_text"]
    )
    #expect(house.decodedKeys(for: explicit).map(\.knownKey) == ["full_text"])
    #expect(house.decodedKey(converting: "a\"b").expression.description.hasSuffix(##".key(for: #"a"b"#)"##))
  }

  @Test
  func decodedKeysCompareByMeaning() {
    let snake = configuration(".convertFromSnakeCase")
    #expect(snake.decodedKey(converting: "createdAt") == configuration(nil).decodedKey(converting: "created_at"))
    let house = configuration(".house")
    #expect(house.decodedKey(converting: "a") == configuration(".house").decodedKey(converting: "a"))
    #expect(house.decodedKey(converting: "a") != configuration(".other").decodedKey(converting: "a"))
    #expect(house.decodedKey(converting: "a") != configuration(nil).decodedKey(converting: "a"))
  }

  @Test
  func builtInStrategyEmitsLiteralKeysAndTheWordSwitch() throws {
    let explicit = StreamParseableField(
      name: .identifier("text"), type: TypeSyntax("String"), explicitKeys: ["fullText"]
    )
    let generation = try StreamObjectGeneration(
      fields: [field("createdAt"), explicit],
      configuration: configuration(".convertFromSnakeCase")
    )
    #expect(generation.fields.map(\.explicitKeys) == [nil, ["fullText"]])
    #expect(generation.partialFields.map(\.keys) == [["created_at"], ["fullText"]])
    let source = try generation.structDeclarationSyntax(in: BasicMacroExpansionContext())
      .description
    #expect(!Parser.parse(source: source).hasError)
    #expect(source.contains(#"key: "created_at""#))
    #expect(source.contains(#"key: "fullText""#))
    #expect(source.contains("matchField: Self.streamMatchField"))
    #expect(!source.contains("streamKeyDecodingStrategy"))
  }

  @Test
  func customStrategyConvertsWhenTheSchemaIsBuilt() throws {
    let explicit = StreamParseableField(
      name: .identifier("text"), type: TypeSyntax("String"), explicitKeys: ["full_text"]
    )
    let generation = try StreamObjectGeneration(
      fields: [field("createdAt"), explicit],
      configuration: configuration(".custom { $0.uppercased() }")
    )
    #expect(generation.fields.map(\.explicitKeys) == [nil, ["full_text"]])
    let source = try generation.structDeclarationSyntax(in: BasicMacroExpansionContext())
      .description
    #expect(!Parser.parse(source: source).hasError)
    #expect(
      source.contains(
        """
        let streamKeyDecodingStrategy = \
        (.custom { $0.uppercased() } as StreamParsing.StreamKeyDecodingStrategy)
        """
      )
    )
    #expect(source.contains(#"key: streamKeyDecodingStrategy.key(for: "createdAt")"#))
    #expect(source.contains(#"key: "full_text""#))
    #expect(!source.contains("streamMatchField"))
  }

  @Test
  func duplicateConvertedKeysAreRejectedWhenKnown() {
    #expect(throws: StreamObjectGenerationError.duplicateKey("foo_bar")) {
      try StreamObjectGeneration(
        fields: [field("fooBar"), field("foo_bar")],
        configuration: configuration(".convertFromSnakeCase")
      )
    }
    // Only the built schema knows what a custom strategy makes of them.
    #expect(throws: Never.self) {
      try StreamObjectGeneration(
        fields: [field("fooBar"), field("foo_bar")],
        configuration: configuration(".custom { _ in \"same\" }")
      )
    }
  }

  @Test
  func enumCasesAndLabelsConvertButPositionsDoNot() throws {
    let generation = try StreamEnumGeneration(
      cases: [
        StreamParseableEnumCase(
          name: .identifier("userJoined"),
          associatedValues: [
            field("userName", type: "String"),
            StreamParseableField(name: .wildcardToken(), type: TypeSyntax("Int")),
          ]
        ),
        StreamParseableEnumCase(name: .identifier("renamed"), explicitKeys: ["renamedEvent"]),
      ],
      representation: .caseKeyedObject,
      configuration: configuration(".convertFromSnakeCase")
    )
    #expect(generation.partialFields?.map(\.keys) == [["user_joined"], ["renamedEvent"]])
    let source = try generation.partialSyntax(in: BasicMacroExpansionContext()).description
    #expect(!Parser.parse(source: source).hasError)
    #expect(source.contains(#"key: "user_name""#))
    #expect(source.contains(#"key: "_1""#))
  }

  @Test
  func rawValueEnumsIgnoreTheStrategy() throws {
    let generation = try StreamEnumGeneration(
      cases: [StreamParseableEnumCase(name: .identifier("inProgress"))],
      representation: .stringRawValue,
      configuration: configuration(".convertFromSnakeCase")
    )
    let source = generation.conversionsSyntax().description
    #expect(source.contains(#""inProgress""#))
    #expect(!source.contains("in_progress"))
  }
}
