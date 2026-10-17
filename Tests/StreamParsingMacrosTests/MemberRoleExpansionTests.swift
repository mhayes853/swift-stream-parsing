import StreamParsingMacros
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import Testing

// The member role, expanded directly. `assertMacro` stops at the diagnostics when the extension
// role reports an error, so what the member role adds alongside that error is only visible here.
@Suite
struct `Member role expansion tests` {
  @Test
  func `Enum Nested In Generic Type Gets No Members`() throws {
    // The extension role diagnoses this and emits nothing, so a `streamPartialValue` here would
    // only add "cannot find type 'Partial'" next to that diagnostic.
    #expect(try self.members(of: "struct Outer<T>").isEmpty)
  }

  @Test
  func `Enum Nested In Concrete Type Gets StreamPartialValue`() throws {
    let members = try self.members(of: "struct Outer")
    #expect(members.count == 1)
    #expect(members.first?.as(VariableDeclSyntax.self)?.bindings.first?.pattern.trimmedDescription == "streamPartialValue")
  }

  private func members(of outer: String) throws -> [DeclSyntax] {
    let source = Parser.parse(
      source: """
        \(outer) {
          @StreamParseable
          enum Kind: String {
            @StreamParseableDefault
            case a
          }
        }
        """
    )
    let enumDecl = try #require(
      source.statements.first?.item.as(StructDeclSyntax.self)?
        .memberBlock.members.first?.decl.as(EnumDeclSyntax.self)
    )
    let attribute = try #require(enumDecl.attributes.first?.as(AttributeSyntax.self))
    // The same lexical context `assertMacro` and the compiler compute: outermost last.
    let context = BasicMacroExpansionContext(lexicalContext: attribute.allMacroLexicalContexts())
    return try StreamParseableMacro.expansion(
      of: attribute, providingMembersOf: enumDecl, conformingTo: [], in: context
    )
  }
}
