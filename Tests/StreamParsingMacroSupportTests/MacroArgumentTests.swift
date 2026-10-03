import StreamParsingMacroSupport
import SwiftParser
import SwiftSyntax
import Testing

private func arguments(_ source: String) -> StreamMacroArguments {
  var parser = Parser(source)
  return StreamMacroArguments(parsing: AttributeSyntax.parse(from: &parser))
}

// Each error's message and the source of the node it is diagnosed at.
private func errors(_ source: String) -> [[String]] {
  arguments(source).errors.map { [$0.message, $0.node.trimmedDescription] }
}

@Suite
struct MacroArgumentTests {
  @Test
  func unwrittenArgumentsStayNil() {
    for source in ["@M", "@M()", "@M(other: 1, .string)", "@M(initialCapacity: nil)"] {
      let parsed = arguments(source)
      #expect(parsed.partialMembers == nil)
      #expect(parsed.partialStrings == nil)
      #expect(parsed.keyDecodingStrategy == nil)
      #expect(parsed.schemaCache == nil)
      #expect(parsed.keys == nil)
      #expect(parsed.initialCapacity == nil)
      #expect(parsed.completedConversion == nil)
      #expect(parsed.errors.isEmpty)
    }
  }

  @Test
  func readsEveryOptionAnAttributeWrites() {
    let parsed = arguments(
      """
      @M(
        partialMembers: .streamInitialValue, partialStrings: StreamPartialStrings.string,
        keyDecodingStrategy: .custom { $0 }, schemaCache: .shared, keyNames: ["a", "b"],
        initialCapacity: 0x20, completedConversion: Strategies.UnixSeconds.self, ignored: 1
      )
      """
    )
    #expect(parsed.partialMembers == .streamInitialValue)
    #expect(parsed.partialStrings == .string)
    #expect(parsed.keyDecodingStrategy?.trimmedDescription == ".custom { $0 }")
    #expect(parsed.schemaCache?.trimmedDescription == ".shared")
    #expect(parsed.keys == ["a", "b"])
    #expect(parsed.initialCapacity == 32)
    #expect(parsed.completedConversion?.trimmedDescription == "Strategies.UnixSeconds")
    #expect(parsed.errors.isEmpty)
  }

  @Test
  func spellings() {
    #expect(arguments("@M(partialMembers: .optional)").partialMembers == .optional)
    #expect(arguments("@M(partialStrings: .streamString)").partialStrings == .streamString)
    #expect(arguments(#"@M(key: "created_at")"#).keys == ["created_at"])
    #expect(arguments(##"@M(key: #"a"b"#)"##).keys == [#"a"b"#])
    #expect(arguments("@M(initialCapacity: 1_024)").initialCapacity == 1024)
    #expect(arguments("@M(initialCapacity: 0o17)").initialCapacity == 15)
    #expect(arguments("@M(initialCapacity: 0b101)").initialCapacity == 5)
  }

  @Test
  func unreadableSpellingsAreCollectedAndLeaveTheirOptionNil() {
    let parsed = arguments("@M(partialStrings: storage, initialCapacity: 4)")
    #expect(parsed.partialStrings == nil)
    #expect(parsed.initialCapacity == 4)
    #expect(
      errors("@M(partialStrings: storage, initialCapacity: 4)")
        == [["@M(partialStrings:) requires .streamString or .string.", "storage"]]
    )
    #expect(
      errors("@M(partialMembers: .required)")
        == [["@M(partialMembers:) requires .optional or .streamInitialValue.", ".required"]]
    )
    #expect(
      errors("@M(completedConversion: UnixSeconds)")
        == [["@M(completedConversion:) requires a strategy type followed by .self.", "UnixSeconds"]]
    )
    let capacity = "@M(initialCapacity:) requires a nonnegative integer literal."
    #expect(errors("@M(initialCapacity: -1)") == [[capacity, "-1"]])
    #expect(errors("@M(initialCapacity: n)") == [[capacity, "n"]])
    #expect(
      errors("@M(initialCapacity: 99999999999999999999)") == [[capacity, "99999999999999999999"]]
    )
  }

  @Test
  func unreadableKeys() {
    let key = "@M(key:) requires a string literal."
    #expect(errors("@M(key: name)") == [[key, "name"]])
    #expect(errors(#"@M(key: "a\(1)b")"#) == [[key, #""a\(1)b""#]])
    #expect(errors(#"@M(key: "")"#) == [["@M(key:) must not be empty.", #""""#]])
    let keyNames = "@M(keyNames:) requires a string array literal."
    #expect(errors("@M(keyNames: [])") == [[keyNames, "[]"]])
    #expect(errors(#"@M(keyNames: ["a", b])"#) == [[keyNames, #"["a", b]"#]])
    #expect(errors(#"@M(keyNames: ["a", "\(b)"])"#) == [[keyNames, #"["a", "\(b)"]"#]])
    #expect(
      errors(#"@M(keyNames: ["a", ""])"#)
        == [["@M(keyNames:) must not contain an empty name.", #"["a", ""]"#]]
    )
    let both = #"@M(key: "a", keyNames: ["b"])"#
    #expect(arguments(both).keys == nil)
    #expect(errors(both) == [["@M takes either key: or keyNames:, not both.", both]])
  }
}
