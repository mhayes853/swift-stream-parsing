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
    let partial = generation.structDeclarationSyntax(
      in: context,
      additionalMembers: { references in
        DeclSyntax("var recognizedFields: [StreamParsingCore.StreamFieldID] = []")
        DeclSyntax("var nameWasEmpty: [Bool] = []")
        DeclSyntax("static var nameField: StreamParsingCore.StreamFieldID { \(references.fields[0].identifier) }")
        DeclSyntax("static var idField: StreamParsingCore.StreamFieldID { \(references.fields[1].identifier) }")
        DeclSyntax("static var tagsField: StreamParsingCore.StreamFieldID { \(references.fields[2].identifier) }")
        DeclSyntax("mutating func resetTracking() { recognizedFields.removeAll() }")
        DeclSyntax("enum TrackingMode { case enabled, disabled }")
        DeclSyntax("subscript(index: Int) -> StreamParsingCore.StreamFieldID { recognizedFields[index] }")
        DeclSyntax("init(tracking: TrackingMode) { self.init() }")
        DeclSyntax("#if DEBUG\nvar debugMarker: Bool { true }\n#endif")
      },
      additionalViewMembers: { _ in
        DeclSyntax("var marker: Int { 42 }")
      },
      onFieldRecognized: { event in
        "\(event.partial).recognizedFields.append(\(event.field))"
        """
        if \(event.field) == \(event.fields[0].identifier) {
          \(event.partial).nameWasEmpty.append(\(event.partial).name == nil)
        }
        """
      }
    )
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
    let generation = try StreamObjectGeneration(fields: keys.enumerated().map { index, key in
      StreamParseableField(
        name: .identifier("field\(index)"),
        type: IdentifierTypeSyntax(name: .identifier("Int")),
        keys: [key]
      )
    })
    return [DeclSyntax(try generation.structDeclarationSyntax(
      in: context,
      additionalMembers: { references in
        DeclSyntax("var recognizedFields: [StreamParsingCore.StreamFieldID] = []")
        let cases = references.fields.enumerated().map { index, field in
          "case \(index): return \(field.identifier.trimmedDescription)"
        }.joined(separator: "\n")
        DeclSyntax("""
          static func identifier(at index: Int) -> StreamParsingCore.StreamFieldID {
            switch index {
            \(raw: cases)
            default: preconditionFailure()
            }
          }
          """)
      },
      onFieldRecognized: { event in
        "\(event.partial).recognizedFields.append(\(event.field))"
      }
    ))]

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
    return [DeclSyntax(try generation.structDeclarationSyntax(
      in: context,
      additionalMembers: { references in
        DeclSyntax("private var recognizedCount = 0")
        DeclSyntax("public var count: Int { recognizedCount }")
        DeclSyntax("public static var valueField: StreamParsingCore.StreamFieldID { \(references.fields[0].identifier) }")
      },
      onFieldRecognized: { event in
        "\(event.partial).recognizedCount += 1"
      }
    ))]
  }
}

@main
struct SupportPlugin: CompilerPlugin {
  let providingMacros: [Macro.Type] = [
    SupportPartialMacro.self, SupportFullPartialMacro.self, SupportMatcherMacro.self
  ]
}
