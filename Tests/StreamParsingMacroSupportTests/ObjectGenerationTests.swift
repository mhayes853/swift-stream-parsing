import CustomDump
import StreamParsingMacroSupport
import SwiftSyntax
import SwiftSyntaxBuilder
import Testing

@Suite
struct `StreamObjectGeneration tests` {
  @Test
  func `Standard Generated Names Are Available As Tokens`() {
    expectNoDifference(TokenSyntax.streamView.text, "View")
    expectNoDifference(TokenSyntax.streamPartial.text, "Partial")
  }

  @Test
  func `Package Default View Mode Follows The Package Trait`() {
    #if LifetimeView
      expectNoDifference(StreamViewMode.packageDefault, .lifetime)
    #else
      expectNoDifference(StreamViewMode.packageDefault, .unsafe)
    #endif
  }

  @Test
  func `Concrete Type Syntax Builds Granular Components`() throws {
    let payloadType = IdentifierTypeSyntax(name: TokenSyntax.identifier("Payload"))
    let generation = try StreamObjectGeneration(
      fields: [
        StreamParseableField(
          name: TokenSyntax.identifier("payload"),
          type: payloadType,
          keys: ["payload", "value"]
        )
      ]
    )

    expectNoDifference(
      generation.storageMembers().trimmedDescription,
      "var payload: Payload.Partial?"
    )
    self.expectContains(generation.matchFieldFunction().description, "Self.StreamField.payload")
    self.expectContains(
      generation.applyFunction(for: .string).description,
      "streamApply(&p.pointee.payload, utf8: bytes)"
    )
    self.expectContains(generation.fieldIdentifiers().description, "enum StreamField")
    self.expectContains(generation.schemaProperty().description, "static let streamSchema")
  }

  @Test
  func `Custom Names Compose A Complete Lifetime Declaration`() throws {
    let generation = try StreamObjectGeneration(
      fields: [
        StreamParseableField(
          name: TokenSyntax.identifier("name"),
          type: IdentifierTypeSyntax(name: TokenSyntax.identifier("String")),
          keys: ["name"]
        )
      ],
      configuration: StreamGenerationConfiguration(
        viewMode: .lifetime,
        accessLevel: .public,
        inlining: .always,
        names: StreamGeneratedNames(
          partialType: TokenSyntax.identifier("Accumulator"),
          viewType: TokenSyntax.identifier("Borrowed")
        )
      )
    )
    let declaration = try generation.partialDeclaration(
      additionalViewMembers: MemberBlockItemListSyntax {
        try VariableDeclSyntax("var isPresent: Bool { true }")
      }
    ) {
      try VariableDeclSyntax("static let marker = 1")
    }
    let source = declaration.description

    self.expectContains(source, "public struct Accumulator")
    self.expectContains(source, "@frozen public struct Borrowed: ~Copyable, ~Escapable")
    self.expectContains(source, "UnsafeMutablePointer<Accumulator>")
    self.expectContains(source, "@_lifetime(borrow storage)")
    self.expectContains(source, "@_lifetime(borrow self)")
    self.expectContains(source, "var isPresent: Bool")
    self.expectContains(source, "static let marker = 1")
  }

  @Test
  func `Unsafe Views Omit Lifetime Syntax`() throws {
    let generation = try StreamObjectGeneration(
      fields: [
        StreamParseableField(
          name: TokenSyntax.identifier("value"),
          type: IdentifierTypeSyntax(name: TokenSyntax.identifier("Int")),
          keys: ["value"]
        )
      ],
      configuration: StreamGenerationConfiguration(viewMode: .unsafe)
    )
    let source = generation.viewDeclaration().description

    self.expectContains(source, "@unsafe struct View: ~Copyable")
    expectNoDifference(source.contains("~Escapable"), false)
    expectNoDifference(source.contains("@_lifetime"), false)
  }

  @Test
  func `Optional Escaped Aliased And Converted Fields Retain Their Syntax`() throws {
    let generation = try StreamObjectGeneration(
      fields: [
        StreamParseableField(
          name: TokenSyntax.identifier("`default`"),
          type: TypeSyntax("Swift.Optional<Model.Value>"),
          keys: ["default", "legacy_default"],
          completedConversion: TypeSyntax("Conversions.Value")
        ),
        StreamParseableField(
          name: TokenSyntax.identifier("items"),
          type: TypeSyntax("[Model.Item]"),
          keys: ["items"],
          initialCapacity: IntegerLiteralExprSyntax(literal: .integerLiteral("32"))
        )
      ],
      partialMembers: .streamInitialValue
    )
    let storage = generation.storageMembers().description
    let fields = generation.fieldTableProperty().description
    let schema = generation.schemaMembers().description

    self.expectContains(
      storage,
      "var `default`: StreamParsingCore.ConvertedPartial<Conversions.Value>?"
    )
    self.expectContains(storage, "var items: [Model.Item].Partial")
    self.expectContains(fields, "key: \"legacy_default\"")
    self.expectContains(fields, "initialCapacity: 32")
    self.expectContains(schema, "_streamWithConverted(&p.pointee.`default`)")
  }

  @Test
  func `Empty Objects Generate Coherent Components`() throws {
    let generation = try StreamObjectGeneration(fields: [StreamParseableField]())

    expectNoDifference(generation.storageMembers().isEmpty, true)
    self.expectContains(generation.initializer().description, "init(")
    self.expectContains(generation.matchFieldFunction().description, "default: return -1")
    expectNoDifference(
      generation.applyFunction(for: .null).description.contains("assumingMemoryBound"),
      false
    )
    self.expectContains(generation.partialDeclaration().description, "struct Partial")
  }

  private func expectContains(
    _ value: String,
    _ expectedSubstring: String
  ) {
    expectNoDifference(
      value.contains(expectedSubstring),
      true,
      "Expected generated source to contain '\(expectedSubstring)'."
    )
  }
}
