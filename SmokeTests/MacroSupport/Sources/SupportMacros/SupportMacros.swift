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
      additionalMembers: {
        DeclSyntax("var recognizedFields: [StreamParsingCore.StreamFieldID] = []")
        DeclSyntax("var nameWasEmpty: [Bool] = []")
        DeclSyntax("static var nameField: StreamParsingCore.StreamFieldID { \(generation.fieldIdentifiers[0].identifier) }")
        DeclSyntax("static var idField: StreamParsingCore.StreamFieldID { \(generation.fieldIdentifiers[1].identifier) }")
        DeclSyntax("static var tagsField: StreamParsingCore.StreamFieldID { \(generation.fieldIdentifiers[2].identifier) }")
        DeclSyntax("mutating func resetTracking() { recognizedFields.removeAll() }")
        DeclSyntax("enum TrackingMode { case enabled, disabled }")
        DeclSyntax("subscript(index: Int) -> StreamParsingCore.StreamFieldID { recognizedFields[index] }")
        DeclSyntax("init(tracking: TrackingMode) { self.init() }")
        DeclSyntax("#if DEBUG\nvar debugMarker: Bool { true }\n#endif")
      },
      additionalViewMembers: {
        DeclSyntax("var marker: Int { 42 }")
      },
      onFieldRecognized: { partial, field in
        "\(partial).recognizedFields.append(\(field))"
        """
        if \(field) == \(generation.fieldIdentifiers[0].identifier) {
          \(partial).nameWasEmpty.append(\(partial).name == nil)
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
      additionalMembers: {
        DeclSyntax("var recognizedFields: [StreamParsingCore.StreamFieldID] = []")
        let cases = generation.fieldIdentifiers.enumerated().map { index, field in
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
      onFieldRecognized: { partial, field in
        "\(partial).recognizedFields.append(\(field))"
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
    let generation = StreamObjectGeneration(
      diagnosedFields: [
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
      additionalMembers: {
        DeclSyntax("private var recognizedCount = 0")
        DeclSyntax("public var count: Int { recognizedCount }")
        DeclSyntax("public static var valueField: StreamParsingCore.StreamFieldID { \(generation.fieldIdentifiers[0].identifier) }")
      },
      onFieldRecognized: { partial, field in
        "\(partial).recognizedCount += 1"
      }
    ))]
  }
}

/// A downstream macro that also makes the whole type `StreamParseable`.
///
/// `total` is internal on a public type, so this host knows `streamPartialValue` cannot be
/// inlined and says so; the plan itself only sees the partial's access.
struct SupportModelMacro: ExtensionMacro {
  static func expansion(
    of node: AttributeSyntax,
    attachedTo declaration: some DeclGroupSyntax,
    providingExtensionsOf type: some TypeSyntaxProtocol,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [ExtensionDeclSyntax] {
    let generation = try StreamObjectGeneration(
      fields: [
        StreamParseableField(
          name: .identifier("number"),
          type: IdentifierTypeSyntax(name: .identifier("String"))
        ),
        StreamParseableField(
          name: .identifier("total"),
          type: IdentifierTypeSyntax(name: .identifier("Int")),
          completedConversion: IdentifierTypeSyntax(name: .identifier("Cents")),
          defaultValue: IntegerLiteralExprSyntax(-1)
        )
      ],
      configuration: StreamGenerationConfiguration(
        accessLevel: .public,
        names: StreamGeneratedNames(partialType: .identifier("Accumulator"))
      )
    )
    let partial = try generation.structDeclarationSyntax(in: context)
    let conversions = try generation.conversionsSyntax(
      unparsedMembers: [StreamUnparsedMember(name: .identifier("retries"), value: IntegerLiteralExprSyntax(3))],
      partialValueInlining: .never
    )
    return [
      try ExtensionDeclSyntax("extension \(type.trimmed): \(TypeSyntax.streamParseable)") {
        partial
        conversions
      }
    ]
  }
}

/// A downstream enum macro using what `@StreamParseable` cannot spell: a converted associated
/// value, a custom payload name, and partial hooks.
struct SupportActivityMacro: ExtensionMacro {
  static func expansion(
    of node: AttributeSyntax,
    attachedTo declaration: some DeclGroupSyntax,
    providingExtensionsOf type: some TypeSyntaxProtocol,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [ExtensionDeclSyntax] {
    let generation = try StreamEnumGeneration(
      cases: [
        StreamParseableEnumCase(name: .identifier("idle")),
        StreamParseableEnumCase(
          name: .identifier("charge"),
          associatedValues: [
            StreamParseableField(
              name: .identifier("total"),
              type: IdentifierTypeSyntax(name: .identifier("Int")),
              completedConversion: IdentifierTypeSyntax(name: .identifier("Cents")),
              defaultValue: IntegerLiteralExprSyntax(-1)
            ),
            StreamParseableField(name: .wildcardToken(), type: IdentifierTypeSyntax(name: .identifier("String")))
          ],
          payloadTypeName: .identifier("ChargeArguments")
        )
      ],
      representation: .caseKeyedObject,
      defaultCase: .identifier("idle"),
      configuration: StreamGenerationConfiguration(accessLevel: .public)
    )
    let partial = try generation.partialSyntax(
      in: context,
      additionalMembers: {
        DeclSyntax("public var recognized: [StreamParsingCore.StreamFieldID] = []")
        DeclSyntax("public static var chargeField: StreamParsingCore.StreamFieldID { \(generation.fieldIdentifiers[1].identifier) }")
      },
      onFieldRecognized: { partial, field in "\(partial).recognized.append(\(field))" }
    )
    return [
      try ExtensionDeclSyntax("extension \(type.trimmed): \(TypeSyntax.streamParseable)") {
        partial
        generation.conversionsSyntax()
      }
    ]
  }
}

@main
struct SupportPlugin: CompilerPlugin {
  let providingMacros: [Macro.Type] = [
    SupportPartialMacro.self, SupportFullPartialMacro.self, SupportMatcherMacro.self,
    SupportModelMacro.self, SupportActivityMacro.self
  ]
}
