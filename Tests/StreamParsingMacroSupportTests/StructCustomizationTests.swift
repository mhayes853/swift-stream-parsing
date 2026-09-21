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
  func contextsSupplyCoordinatedReferencesAndHygienicHooks() throws {
    let generation = try self.generation()
    var identifiers: [String] = []
    let declaration = generation.structDeclaration(
      in: BasicMacroExpansionContext(),
      additionalMembers: { context in
        let _ = #expect(context.partialType.trimmedDescription == "Accumulator")
        let _ = #expect(context.viewType.trimmedDescription == "Accumulator.Borrowed")
        let _ = #expect(context.fields.map(\.name.text) == ["name"])
        let _ = { identifiers = context.fields.map(\.identifier.trimmedDescription) }()
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
      additionalViewMembers: { context in
        let _ = #expect(context.fields.map(\.identifier.trimmedDescription) == identifiers)
        DeclSyntax("var marker: Int { 42 }")
      },
      onFieldRecognized: { event in
        let _ = #expect(event.fields.map(\.identifier.trimmedDescription) == identifiers)
        let _ = #expect(event.field.trimmedDescription != "streamRecognizedField")
        "\(event.partial).tracking += 1"
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
    let declaration = try self.generation().structDeclaration(in: BasicMacroExpansionContext())
    #expect(!declaration.description.contains("onFieldRecognized:"))
    #expect(!declaration.description.contains("streamDidRecognizeField"))
  }

  @Test(arguments: [0, 1, 2])
  func customizationBuilderFailuresPropagate(builder: Int) throws {
    let generation = try self.generation()
    func failIfSelected(_ index: Int) throws {
      if builder == index { throw BuilderFailure() }
    }
    #expect(throws: BuilderFailure.self) {
      try generation.structDeclaration(
        in: BasicMacroExpansionContext(),
        additionalMembers: { _ in
          let _ = try failIfSelected(0)
        },
        additionalViewMembers: { _ in
          let _ = try failIfSelected(1)
        },
        onFieldRecognized: { _ in
          let _ = try failIfSelected(2)
        }
      )
    }
  }
}
