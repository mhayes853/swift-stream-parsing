import StreamParsingMacroSupport
import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// A downstream macro supplies its own field model and adds its own view API.
struct SupportPartialMacro: MemberMacro {
  static func expansion(
    of node: AttributeSyntax,
    providingMembersOf declaration: some DeclGroupSyntax,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    let fields = [
      StreamParseableField(
        name: TokenSyntax.identifier("name"),
        type: IdentifierTypeSyntax(name: TokenSyntax.identifier("String")),
        keys: ["customer_name", "name"]
      ),
      StreamParseableField(
        name: TokenSyntax.identifier("id"),
        type: IdentifierTypeSyntax(name: TokenSyntax.identifier("Int")),
        keys: ["customer_id"]
      ),
      StreamParseableField(
        name: TokenSyntax.identifier("tags"),
        type: ArrayTypeSyntax(
          element: IdentifierTypeSyntax(name: TokenSyntax.identifier("String"))
        ),
        keys: ["tags"]
      )
    ]
    let generation = try StreamObjectGeneration(fields: fields)
    let partial = try StructDeclSyntax(
      "struct Partial: StreamParsingCore.StreamParseable, StreamParsingCore.StreamParseableObject, Sendable"
    ) {
      DeclSyntax("typealias Partial = Self")
      generation.storageMembers()
      generation.initializer()
      generation.initialValueMembers()
      generation.observationMembers()
      generation.schemaMembers()
      generation.viewDeclaration {
        DeclSyntax("var marker: Int { 42 }")
      }
      generation.streamViewFunction()
    }
    return [DeclSyntax(partial)]
  }
}

struct SupportMatcherMacro: MemberMacro {
  static func expansion(
    of node: AttributeSyntax,
    providingMembersOf declaration: some DeclGroupSyntax,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    let keys = [
      "", "a", "a\0", "customer_name", "customer_id", "é", "e\u{301}", "abcdefghijklmno\0"
    ]
    let branches = keys.enumerated()
      .map { index, key in
        StreamUTF8Branch(matching: [key]) {
          CodeBlockItemSyntax("result = \(raw: index)")
        }
      }
    let matcher = try StreamUTF8Matcher(branches: branches)
    let strategies: [(String, StreamUTF8Matcher.Strategy)] = [
      ("switchMatch", .switchTree), ("ifMatch", .ifElseTree)
    ]
    return try strategies.map { name, strategy in
      let statements = matcher.statements(
        matching: DeclReferenceExprSyntax(baseName: TokenSyntax.identifier("bytes")),
        strategy: strategy,
        in: context
      ) {
        CodeBlockItemSyntax("result = -1")
      }
      return DeclSyntax(
        try FunctionDeclSyntax("static func \(raw: name)(_ bytes: Span<UInt8>) -> Int") {
          CodeBlockItemSyntax("var result = -2")
          statements
          ReturnStmtSyntax(
            expression: DeclReferenceExprSyntax(baseName: TokenSyntax.identifier("result"))
          )
        }
      )
    }
  }
}

struct SupportFullPartialMacro: MemberMacro {
  static func expansion(
    of node: AttributeSyntax,
    providingMembersOf declaration: some DeclGroupSyntax,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    let generation = try StreamObjectGeneration(
      fields: [
        StreamParseableField(
          name: TokenSyntax.identifier("default"),
          type: TypeSyntax("Swift.Optional<Int>"),
          keys: ["value", "a\0"]
        )
      ],
      configuration: StreamGenerationConfiguration(
        accessLevel: .public,
        names: StreamGeneratedNames(
          partialType: TokenSyntax.identifier("Accumulator"),
          viewType: TokenSyntax.identifier("Borrowed")
        )
      )
    )
    return [DeclSyntax(generation.partialDeclaration())]
  }
}

@main
struct SupportPlugin: CompilerPlugin {
  let providingMacros: [Macro.Type] = [
    SupportPartialMacro.self, SupportFullPartialMacro.self, SupportMatcherMacro.self
  ]
}
