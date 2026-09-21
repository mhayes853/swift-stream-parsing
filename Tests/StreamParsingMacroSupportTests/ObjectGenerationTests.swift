import CustomDump
import StreamParsingMacroSupport
import SwiftSyntax
import SwiftSyntaxMacroExpansion
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
  func `Concrete Type Syntax Builds A Complete Struct`() throws {
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
      try generation.structDeclaration(in: BasicMacroExpansionContext()).description.contains("var payload: Payload.Partial?"),
      true
    )
    self.expectContains(try generation.structDeclaration(in: BasicMacroExpansionContext()).description, "Self.StreamField.payload")
    self.expectContains(
      try generation.structDeclaration(in: BasicMacroExpansionContext()).description,
      "streamApply(&p.pointee.payload, utf8: bytes)"
    )
    self.expectContains(try generation.structDeclaration(in: BasicMacroExpansionContext()).description, "enum StreamField")
    self.expectContains(try generation.structDeclaration(in: BasicMacroExpansionContext()).description, "static let streamSchema")
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
    let declaration = try generation.structDeclaration(
      in: BasicMacroExpansionContext(),
      additionalMembers: { _ in
        try VariableDeclSyntax("static let marker = 1")
      },
      additionalViewMembers: { _ in
        try VariableDeclSyntax("var isPresent: Bool { true }")
      }
    )
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
    let source = try generation.structDeclaration(in: BasicMacroExpansionContext()).description

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
    let storage = try generation.structDeclaration(in: BasicMacroExpansionContext()).description
    let fields = try generation.structDeclaration(in: BasicMacroExpansionContext()).description
    let schema = try generation.structDeclaration(in: BasicMacroExpansionContext()).description

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

    expectNoDifference(try generation.structDeclaration(in: BasicMacroExpansionContext()).description.contains("enum StreamField"), false)
    self.expectContains(try generation.structDeclaration(in: BasicMacroExpansionContext()).description, "init(")
    self.expectContains(try generation.structDeclaration(in: BasicMacroExpansionContext()).description, "default: return -1")
    expectNoDifference(
      try generation.structDeclaration(in: BasicMacroExpansionContext()).description.contains("let p = storage.assumingMemoryBound"),
      false
    )
    self.expectContains(try generation.structDeclaration(in: BasicMacroExpansionContext()).description, "struct Partial")
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
