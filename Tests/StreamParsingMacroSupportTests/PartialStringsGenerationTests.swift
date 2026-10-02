import CustomDump
import StreamParsingMacroSupport
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing

@Suite
struct `StreamObjectGeneration string storage tests` {
  private func field(
    _ name: String, _ type: String, strings: StreamPartialStrings = .string
  ) -> StreamParseableField {
    StreamParseableField(name: .identifier(name), type: TypeSyntax("\(raw: type)"), partialStrings: strings)
  }

  @Test
  func `String Leaves Are Spelled Out In Storage`() throws {
    let generation = try StreamObjectGeneration(fields: [
      self.field("plain", "String"),
      self.field("qualified", "Swift.String?"),
      self.field("twice", "String??"),
      self.field("list", "[String]"),
      self.field("generic", "Array<String?>"),
      self.field("nested", "[String: [String]]?"),
      self.field("spelled", "Dictionary<String, String>"),
      self.field("items", "[Item]"),
      self.field("count", "Int"),
      self.field("kept", "String", strings: .streamString),
    ])
    expectNoDifference(generation.partialFields.map(\.storageType.trimmedDescription), [
      "String?",
      "String?",
      "String??",
      "StreamParsingCore.StreamArray<String>?",
      "StreamParsingCore.StreamArray<String?>?",
      "StreamParsingCore.StreamDictionary<StreamParsingCore.StreamArray<String>>?",
      "StreamParsingCore.StreamDictionary<String>?",
      // No `String` leaf: the usual expansion, untouched.
      "[Item].Partial?",
      "Int.Partial?",
      "String.Partial?",
    ])
    let source = try generation.structDeclarationSyntax(in: BasicMacroExpansionContext()).description
    #expect(source.contains("_streamArraySchema(String.self, element: _streamSchema(for: String.self))"))
    #expect(source.contains("_streamOptionalArraySchema(String.self, element: _streamSchema(for: String.self))"))
  }

  @Test
  func `Conversions Rewrap Containers Without Failing`() throws {
    let generation = try StreamObjectGeneration(fields: [
      self.field("name", "String"),
      self.field("rows", "[[String]]"),
      self.field("tags", "[String: String]?"),
    ])
    let source = try generation.conversionsSyntax().description
    #expect(source.contains("name: self.name"))
    #expect(source.contains("rows: StreamParsingCore.StreamArray(self.rows.lazy.map { StreamParsingCore.StreamArray($0) })"))
    #expect(source.contains("tags: self.tags.map { StreamParsingCore.StreamDictionary($0) }"))
    #expect(source.contains("Self._streamStoredValue({ $0.name }, partial.name)"))
    #expect(source.contains("Self._streamStoredValue({ $0.rows }, partial.rows.map { $0.map { Swift.Array($0) } })"))
    #expect(source.contains("Self._streamStoredValue({ $0.tags }, partial.tags.map { Swift.Dictionary($0) }, orInitial: nil)"))
    #expect(source.contains("orInitial: \"\")"))
    #expect(source.contains("orInitial: [])"))
  }

  @Test
  func `A Converted Field Rejects String Storage`() {
    let converted = StreamParseableField(
      name: .identifier("name"), type: TypeSyntax("String"), completedConversion: TypeSyntax("Trimmed"),
      partialStrings: .string
    )
    #expect(throws: StreamObjectGenerationError.partialStringsWithCompletedConversion(field: "name")) {
      try StreamObjectGeneration(fields: [converted])
    }
  }
}
