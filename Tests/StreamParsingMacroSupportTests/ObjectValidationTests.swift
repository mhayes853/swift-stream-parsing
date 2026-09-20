import CustomDump
import StreamParsingMacroSupport
import SwiftParser
import SwiftSyntax
import Testing

@Suite
struct `StreamObjectGeneration validation tests` {
  @Test
  func `Conflicting Fields And Keys Are Rejected`() {
    let first = self.field(name: "first", key: "value")
    #expect(throws: StreamObjectGenerationError.duplicateField("first")) {
      try StreamObjectGeneration(fields: [first, first])
    }
    #expect(throws: StreamObjectGenerationError.duplicateKey("value")) {
      try StreamObjectGeneration(fields: [first, self.field(name: "second", key: "value")])
    }
    #expect(throws: StreamObjectGenerationError.emptyFieldName) {
      try StreamObjectGeneration(fields: [self.field(name: "", key: "value")])
    }
    #expect(throws: StreamObjectGenerationError.invalidFieldName("bad`name")) {
      try StreamObjectGeneration(fields: [self.field(name: "bad`name", key: "value")])
    }
  }

  @Test
  func `Field Equality Preserves Byte Exact Keys`() {
    let composed = self.field(name: "name", key: "é")
    var decomposed = composed
    decomposed.keys = ["e\u{301}"]
    expectNoDifference(composed == decomposed, false)
    expectNoDifference(Set([composed, decomposed]).count, 2)
  }

  @Test
  func `Canonical Unicode Keys Keep Distinct Byte Routes`() throws {
    let generation = try StreamObjectGeneration(fields: [
      self.field(name: "composed", key: "é"),
      self.field(name: "decomposed", key: "e\u{301}")
    ])
    let source = generation.matchFieldFunction().description
    expectNoDifference(source.contains("key.count == 2"), true)
    expectNoDifference(source.contains("key.count == 3"), true)
  }

  @Test
  func `Incompatible Inlining Access Is Rejected`() {
    #expect(throws: StreamObjectGenerationError.incompatibleInliningAccess) {
      try StreamObjectGeneration(
        fields: [self.field(name: "value", key: "value")],
        configuration: StreamGenerationConfiguration(inlining: .always)
      )
    }
  }

  @Test
  func `Concrete Conversion Type Nodes Need No Wrapping`() throws {
    let field = StreamParseableField(
      name: TokenSyntax.identifier("value"),
      type: IdentifierTypeSyntax(name: TokenSyntax.identifier("Date")),
      keys: ["value"],
      completedConversion: IdentifierTypeSyntax(name: TokenSyntax.identifier("EpochSeconds"))
    )
    let generation = try StreamObjectGeneration(fields: [field])
    expectNoDifference(
      generation.storageMembers().trimmedDescription,
      "var value: StreamParsingCore.ConvertedPartial<EpochSeconds>?"
    )
  }

  @Test
  func `Concrete Capacity And Conversion Nodes Need No Wrapping`() {
    let field = StreamParseableField(
      name: TokenSyntax.identifier("value"),
      type: IdentifierTypeSyntax(name: TokenSyntax.identifier("Date")),
      keys: ["value"],
      initialCapacity: IntegerLiteralExprSyntax(literal: .integerLiteral("8")),
      completedConversion: IdentifierTypeSyntax(name: TokenSyntax.identifier("EpochSeconds"))
    )
    #expect(
      throws: StreamObjectGenerationError.initialCapacityWithCompletedConversion(field: "value")
    ) {
      try StreamObjectGeneration(fields: [field])
    }
  }

  @Test(arguments: [StreamViewMode.lifetime, .unsafe])
  func `Complete Declarations Survive Serialization`(mode: StreamViewMode) throws {
    let generation = try StreamObjectGeneration(
      fields: [
        self.field(name: "default", key: "\n\0\"\\"),
        self.field(name: "two names", key: "other")
      ],
      configuration: StreamGenerationConfiguration(viewMode: mode, accessLevel: .public)
    )
    let source = generation.partialDeclaration().description
    expectNoDifference(Parser.parse(source: source).hasError, false)
    expectNoDifference(source.contains("var `default`:"), true)
  }

  @Test
  func `Empty Keys Are Checked Before Loading The Leading Word`() throws {
    let generation = try StreamObjectGeneration(fields: [self.field(name: "empty", key: "")])
    let source = generation.matchFieldFunction().description
    let emptyCheck = try #require(source.range(of: "guard !key.isEmpty"))
    let load = try #require(source.range(of: "paddedLeadingWord"))
    expectNoDifference(emptyCheck.lowerBound < load.lowerBound, true)
    expectNoDifference(
      Parser.parse(source: generation.partialDeclaration().description).hasError,
      false
    )
  }

  @Test
  func `Renaming A Complete Partial Updates Its Storage References`() throws {
    let generation = try StreamObjectGeneration(fields: [self.field(name: "value", key: "value")])
    let source = generation.partialDeclaration(named: TokenSyntax.identifier("Storage")).description
    expectNoDifference(source.contains("struct Storage:"), true)
    expectNoDifference(source.contains("UnsafeMutablePointer<Storage>"), true)
    expectNoDifference(Parser.parse(source: source).hasError, false)
  }

  private func field(name: String, key: String) -> StreamParseableField {
    StreamParseableField(
      name: TokenSyntax.identifier(name),
      type: IdentifierTypeSyntax(name: TokenSyntax.identifier("String")),
      keys: [key]
    )
  }
}
