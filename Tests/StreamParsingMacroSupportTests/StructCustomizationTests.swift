import StreamParsingMacroSupport
import SwiftParser
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacroExpansion
import Testing

@Suite
struct StructCustomizationTests {
  private struct BuilderFailure: Error {}

  private func generation() throws -> StreamObjectGeneration {
    try StreamObjectGeneration(
      fields: [StreamParseableField(
        name: .identifier("name"),
        type: IdentifierTypeSyntax(name: .identifier("String")),
        keys: ["name", "display_name"]
      )],
      configuration: StreamGenerationConfiguration(names: StreamGeneratedNames(
        partialType: .identifier("Accumulator"), viewType: .identifier("Borrowed")
      ))
    )
  }

  @Test
  func fieldIdentifiersAndHooksComposeWithoutContextWrappers() throws {
    let generation = try self.generation()
    let identifiers = generation.fieldIdentifiers.map(\.identifier.trimmedDescription)
    #expect(generation.configuration.names.partialType.text == "Accumulator")
    #expect(generation.configuration.names.viewType.text == "Borrowed")
    #expect(generation.fieldIdentifiers.map(\.name.text) == ["name"])
    let declaration = generation.structDeclarationSyntax(
      in: BasicMacroExpansionContext(),
      additionalMembers: {
        VariableDeclSyntax(
          bindingSpecifier: .keyword(.var),
          bindings: PatternBindingListSyntax {
            PatternBindingSyntax(
              pattern: IdentifierPatternSyntax(identifier: .identifier("tracking")),
              initializer: InitializerClauseSyntax(value: IntegerLiteralExprSyntax(0))
            )
          }
        )
        DeclSyntax("func transform<T>(_ value: T) -> T { value }")
        DeclSyntax("enum Mode { case enabled }")
        DeclSyntax("var streamRecognizedField: Int { 10 }")
        DeclSyntax("mutating func streamDidRecognizeField() {}")
      },
      additionalViewMembers: {
        let _ = #expect(generation.fieldIdentifiers.map(\.identifier.trimmedDescription) == identifiers)
        DeclSyntax("var marker: Int { 42 }")
      },
      onFieldRecognized: { partial, field in
        let _ = #expect(generation.fieldIdentifiers.map(\.identifier.trimmedDescription) == identifiers)
        let _ = #expect(field.trimmedDescription != "streamRecognizedField")
        "\(partial).tracking += 1"
      }
    )
    let source = declaration.description
    #expect(!Parser.parse(source: source).hasError)
    #expect(source.contains("onFieldRecognized:"))
    #expect(source.contains("var tracking = 0"))
    #expect(source.contains("func transform<T>"))
    #expect(source.contains("self.tracking += 1"))
    #expect(source.contains("var marker: Int"))
  }

  @Test
  func noCustomizationInstallsNoHandler() throws {
    let declaration = try self.generation().structDeclarationSyntax(in: BasicMacroExpansionContext())
    #expect(!declaration.description.contains("onFieldRecognized:"))
    #expect(!declaration.description.contains("streamDidRecognizeField"))
  }

  @Test
  func partialCustomizationAddsDeclarationSyntaxAndKeepsExistingMembers() throws {
    var attributes = Parser.parse(source: "@available(*, deprecated)\nstruct Placeholder {}").statements
      .first!.item.as(StructDeclSyntax.self)!.attributes
    attributes[attributes.startIndex].trailingTrivia = []
    let declaration = try self.generation().structDeclarationSyntax(
      in: BasicMacroExpansionContext(),
      partialCustomization: StreamPartialCustomization(
        attributes: attributes,
        conformances: [TypeSyntax("CustomPartialProtocol")],
        members: MemberBlockItemListSyntax {
          DeclSyntax("var convertedName: String? { name.map(String.init(streamPartial:)) }")
        }
      ),
      additionalMembers: { DeclSyntax("var legacyMember: Int { 1 }") }
    )
    let source = declaration.description
    #expect(!Parser.parse(source: source).hasError)
    #expect(source.contains("@available(*, deprecated)"))
    #expect(source.contains("Sendable, CustomPartialProtocol"))
    #expect(source.contains("var convertedName: String?"))
    #expect(source.contains("var legacyMember: Int"))
  }

  @Test(arguments: [0, 1, 2])
  func customizationBuilderFailuresPropagate(builder: Int) throws {
    let generation = try self.generation()
    func failIfSelected(_ index: Int) throws {
      if builder == index { throw BuilderFailure() }
    }
    #expect(throws: BuilderFailure.self) {
      try generation.structDeclarationSyntax(
        in: BasicMacroExpansionContext(),
        additionalMembers: {
          let _ = try failIfSelected(0)
        },
        additionalViewMembers: {
          let _ = try failIfSelected(1)
        },
        onFieldRecognized: { _, _ in
          let _ = try failIfSelected(2)
        }
      )
    }
  }
}
