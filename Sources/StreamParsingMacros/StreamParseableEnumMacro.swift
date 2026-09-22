import StreamParsingMacroSupport
import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// Enum support, in the three lowerings tabulated on the `@StreamParseable` docc comment
// (`Sources/StreamParsing/Macros.swift`). Only the `String`-raw form can be read *mid-value*: a
// key and a number arrive whole, a string arrives in pieces. See `stringRawConversion`.
extension StreamParseableMacro {
  enum EnumRawKind {
    /// `enum S: String` — the raw value is the streamed string.
    case string
    /// `enum S: Int` and the other numeric raw types, whose `Partial` is the raw value itself.
    case scalar(String)
    /// No raw type: `Codable`'s case-name-keyed object form.
    case none
  }

  struct EnumCase {
    /// The case as written, backticks and all, for use in generated `self = .x` and `case .x`.
    let reference: String
    /// Every spelling that resolves to this case. One entry unless
    /// `@StreamParseableMember(keyNames:)` added aliases.
    let matchNames: [String]
    let isDefault: Bool
    /// The case's associated values, in declaration order. Empty for a case with none — a raw-
    /// value enum can never have any, since Swift itself rejects associated values on a case of
    /// an enum that declares a raw type.
    let associatedValues: [AssociatedValue]
  }

  /// One associated value of a case, keyed the same way `Codable`'s synthesis keys it: a written
  /// label if there is one, else a positional `_0`, `_1`, ... counted over *every* parameter in
  /// that case (labelled ones included) — verified against `JSONEncoder` directly, since nothing
  /// documents the numbering rule for a mix of labelled and unlabelled parameters.
  struct AssociatedValue {
    /// The label, or the synthesized `_N` — both the generated stored property's name and the
    /// wire-format object key.
    let label: String
    /// Whether the parameter was written with a label, which decides whether the generated
    /// case-construction call site writes `label:`.
    let isLabeled: Bool
    let type: TypeSyntax
  }

  static func associatedValues(in parameterClause: EnumCaseParameterClauseSyntax?) -> [AssociatedValue] {
    guard let parameterClause else { return [] }
    return parameterClause.parameters.enumerated().map { index, parameter in
      if let firstName = parameter.firstName, firstName.tokenKind != .wildcard {
        return AssociatedValue(
          label: StreamObjectGeneration.bareName(firstName), isLabeled: true, type: parameter.type
        )
      }
      return AssociatedValue(label: "_\(index)", isLabeled: false, type: parameter.type)
    }
  }

  // The numeric raw types whose `Partial` is the raw value itself, so the conversion is one
  // `init(rawValue:)`. Closed rather than permissive, because a macro cannot resolve types and
  // guessing wrong would silently parse a completely different document;
  // `diagnoseUnsupportedRawType` catches what this list does not claim.
  static let scalarRawTypeNames: Set<String> = [
    "Int", "Int8", "Int16", "Int32", "Int64",
    "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
    "Double", "Float"
  ]

  static func enumRawKind(for declaration: EnumDeclSyntax) -> EnumRawKind {
    // Swift requires the raw type to lead the inheritance clause, so only the first entry can be
    // one. Everything after it is a protocol.
    guard let first = declaration.inheritanceClause?.inheritedTypes.first else { return .none }
    let name = Self.lastComponent(of: first.type)
    if name == "String" { return .string }
    if Self.scalarRawTypeNames.contains(name) { return .scalar(name) }
    return .none
  }

  static func enumCases(
    in declaration: EnumDeclSyntax,
    rawKind: EnumRawKind,
    context: DiagnosticSink
  ) -> [EnumCase] {
    var cases = [EnumCase]()
    var sawDefault = false
    var seenMatchNames = Set<String>()
    var seenPayloadTypes = Set<String>()
    for member in declaration.memberBlock.members {
      guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }

      let isDefaultDecl =
        Self.attribute(named: "StreamParseableDefault", in: caseDecl.attributes) != nil
      if isDefaultDecl, caseDecl.elements.count > 1 {
        Self.diagnoseAmbiguousDefaultCase(in: caseDecl, context: context)
      }
      if isDefaultDecl, sawDefault {
        Self.diagnoseDuplicateDefaultCase(in: caseDecl, context: context)
      }

      for element in caseDecl.elements {
        let associatedValues = Self.associatedValues(in: element.parameterClause)
        let bareName = StreamObjectGeneration.bareName(element.name)
        // The raw value, where one is written, is the string this case answers to. Where one is
        // not, the case name is — which is both Swift's own default for a `String` raw value and
        // the `CodingKey` `Codable` derives for the raw-less form, so one rule covers both.
        var defaultName = bareName
        if case .string = rawKind, let rawValue = element.rawValue?.value {
          // `case none = ""` is an ordinary sentinel raw value, so an empty literal is kept.
          if let literal = rawValue.as(StringLiteralExprSyntax.self)?.representedLiteralValue {
            defaultName = literal
          } else {
            Self.diagnoseNonLiteralRawValue(in: element, context: context)
          }
        }

        let keyNames = Self.keyNames(
          for: caseDecl.attributes, defaultName: defaultName, context: context
        )

        // `@StreamParseableMember` means "alias" for a `String`-raw case and "rename" for a
        // raw-less one. A raw-raw case emits its raw value as its partial, so that spelling must
        // stay matchable or the type would not round trip; renaming it is done by writing the raw
        // value. A raw-less case has no wire form of its own, so naming its key replaces it.
        var matchNames = keyNames
        if case .string = rawKind, !matchNames.contains(defaultName) {
          matchNames.insert(defaultName, at: 0)
        }

        // A second case answering to a name already taken emits an unreachable arm, and two
        // cases whose names differ only in case share one generated payload type.
        for name in matchNames where !seenMatchNames.insert(name).inserted {
          context.diagnose(
            Self.error(element, "Name '\(name)' is already claimed by another case.")
          )
        }
        if case .none = rawKind {
          if bareName == "unresolved" || bareName == "ambiguous" {
            context.diagnose(
              Self.error(
                element,
                """
                Case '\(bareName)' collides with the generated 'ResolvedView.\(bareName)' \
                sentinel. Rename the case, or give it a key with @StreamParseableMember.
                """
              )
            )
          }
          let payloadType = StreamEnumGeneration.defaultPayloadTypeName(forCaseNamed: bareName)
          if !associatedValues.isEmpty, !seenPayloadTypes.insert(payloadType).inserted {
            context.diagnose(
              Self.error(
                element,
                """
                Case '\(bareName)' generates the payload type \
                '\(payloadType)', which another case already \
                generates. Case names that differ only in capitalisation cannot both carry a \
                payload.
                """
              )
            )
          }
        }

        cases.append(
          EnumCase(
            reference: element.name.trimmedDescription,
            matchNames: matchNames,
            isDefault: isDefaultDecl && !sawDefault,
            associatedValues: associatedValues
          )
        )
        if isDefaultDecl { sawDefault = true }
      }
    }
    return cases
  }
}

// MARK: - Expansion

// Generation itself is `StreamEnumGeneration`'s; the macro reads the declaration, diagnoses it,
// and places the result. `streamPartialValue` goes out through the member role, the rest through
// the extension, matching the struct lowering.
extension StreamParseableMacro {
  static func enumMemberExpansion(
    declaration: EnumDeclSyntax,
    in context: DiagnosticSink
  ) throws -> [DeclSyntax] {
    guard !Self.hasExistingStreamPartialValue(in: declaration.memberBlock.members) else {
      return []
    }
    let rawKind = Self.enumRawKind(for: declaration)
    let cases = Self.enumCases(in: declaration, rawKind: rawKind, context: context)
    let generation = Self.enumGeneration(for: declaration, rawKind: rawKind, cases: cases)
    return [Self.splitConversions(generation.conversionsSyntax()).streamPartialValue]
  }

  static func enumExtensionExpansion(
    of node: AttributeSyntax,
    declaration: EnumDeclSyntax,
    type: some TypeSyntaxProtocol,
    in context: DiagnosticSink,
    expansionContext: some MacroExpansionContext
  ) throws -> [ExtensionDeclSyntax] {
    let rawKind = Self.enumRawKind(for: declaration)
    let cases = Self.enumCases(in: declaration, rawKind: rawKind, context: context)
    Self.diagnoseUnsupportedRawType(in: declaration, rawKind: rawKind, context: context)
    if Self.argument(named: "partialMembers", of: node) != nil {
      Self.diagnosePartialMembersOnEnum(in: node, context: context)
    }
    if !cases.contains(where: \.isDefault), !Self.namesAnInitialValue(in: declaration) {
      Self.diagnoseMissingDefaultCase(in: declaration, context: context)
    }

    let generation = Self.enumGeneration(for: declaration, rawKind: rawKind, cases: cases)
    var members =
      Self.hasExistingPartial(in: declaration.memberBlock.members)
      ? MemberBlockItemListSyntax([]) : try generation.partialSyntax(in: expansionContext)
    members.append(contentsOf: Self.splitConversions(generation.conversionsSyntax()).rest)
    // The fully qualified name, so a nested enum extends `Outer.Inner`.
    return [
      try ExtensionDeclSyntax(
        "extension \(raw: type.trimmedDescription)\(raw: Self.conformanceClause(for: declaration))"
      ) {
        members
      }
    ]
  }

  static func enumGeneration(
    for declaration: EnumDeclSyntax,
    rawKind: EnumRawKind,
    cases: [EnumCase]
  ) -> StreamEnumGeneration {
    let representation: StreamEnumRepresentation =
      switch rawKind {
      case .string: .stringRawValue
      case .scalar(let rawType): .numericRawValue(TypeSyntax("\(raw: rawType)"))
      case .none: .caseKeyedObject
      }
    let generationCases = cases.map { enumCase in
      StreamParseableEnumCase(
        name: .identifier(enumCase.reference),
        keys: enumCase.matchNames,
        associatedValues: enumCase.associatedValues.map { value in
          StreamParseableField(
            name: value.isLabeled ? .identifier(value.label) : .wildcardToken(),
            type: value.type,
            keys: [value.label]
          )
        }
      )
    }
    return StreamEnumGeneration(
      diagnosedCases: generationCases,
      representation: representation,
      defaultCase: cases.first(where: \.isDefault).map { .identifier($0.reference) },
      configuration: StreamGenerationConfiguration(
        viewMode: .packageDefault,
        accessLevel: Self.generatedAccessLevel(for: declaration.modifiers)
      )
    )
  }
}

// MARK: - Diagnostics

extension StreamParseableMacro {
  // Whether the enum says, in its own declaration, what a total conversion falls back to. An
  // enum that names neither a default case nor `StreamInitializable` cannot conform, and saying
  // so here beats a missing-requirement error inside an expansion. Deliberately syntactic, so a
  // conformance added in a far away extension is invisible: the message names the fix.
  static func namesAnInitialValue(in declaration: EnumDeclSyntax) -> Bool {
    Self.inherits(declaration, named: "StreamInitializable")
      || declaration.memberBlock.members.contains { member in
        guard let function = member.decl.as(FunctionDeclSyntax.self) else { return false }
        return function.name.text == "streamInitialValue" && function.modifiers.contains(.static)
          && function.signature.parameterClause.parameters.isEmpty
      }
  }

  static func diagnoseMissingDefaultCase(
    in declaration: EnumDeclSyntax,
    context: DiagnosticSink
  ) {
    context.diagnose(
      Self.error(
        declaration.name,
        """
        @StreamParseable requires an enum to name a fallback case, because \
        'streamValueOrInitial' has to produce one when the stream produced nothing this type \
        can represent. Mark a case with @StreamParseableDefault, or declare \
        'StreamInitializable' conformance on '\(declaration.name.text)' itself.
        """
      )
    )
  }
}

// MARK: - Self-referential payloads

extension StreamParseableMacro {
  // A payload naming the enum, however wrapped (`E?`, `[E]`, `[String: E]`, `Optional<E>`), nests
  // `Partial` inside itself exactly as `indirect` does, and would build its schema from itself.
  // Syntactic, like `indirect`: recursion through another declared type is not visible here.
  static func diagnoseSelfReferentialPayloads(
    _ declaration: EnumDeclSyntax,
    lexicalContext: [Syntax],
    in context: DiagnosticSink
  ) -> Bool {
    let names = Self.selfReferenceNames(for: declaration, lexicalContext: lexicalContext)
    var found = false
    for member in declaration.memberBlock.members {
      guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
      for element in caseDecl.elements {
        for parameter in element.parameterClause?.parameters ?? [] {
          let finder = SelfReferenceFinder(names: names)
          finder.walk(parameter.type)
          guard finder.found else { continue }
          found = true
          context.diagnose(
            Self.error(
              parameter.type,
              """
              Case '\(StreamObjectGeneration.bareName(element.name))' has a payload that contains \
              '\(declaration.name.text)' itself. @StreamParseable does not support recursive \
              enums, because the generated 'Partial' would contain itself.
              """
            )
          )
        }
      }
    }
    return found
  }

  // `Self`, the bare name, and every qualified spelling the enclosing types allow (`B.E`,
  // `A.B.E`). The innermost lexical context is usually the enum itself, so it is skipped.
  static func selfReferenceNames(
    for declaration: EnumDeclSyntax,
    lexicalContext: [Syntax]
  ) -> Set<String> {
    let name = declaration.name.text
    var names: Set<String> = ["Self", name]
    var path = name
    for (index, node) in lexicalContext.enumerated() {
      if index == 0, node.as(EnumDeclSyntax.self)?.name.text == name { continue }
      let component: String
      if let type = node.as(ExtensionDeclSyntax.self) {
        component = type.extendedType.trimmedDescription
      } else if node.is(StructDeclSyntax.self) || node.is(EnumDeclSyntax.self)
        || node.is(ClassDeclSyntax.self) || node.is(ActorDeclSyntax.self),
        let named = node.asProtocol(NamedDeclSyntax.self)
      {
        component = named.name.text
      } else {
        // A function or closure: a local type has no qualified spelling.
        break
      }
      path = component + "." + path
      names.insert(path)
    }
    return names
  }
}

// Finds a type named by `names`. A member type's base is not walked: `E.Kind` is a type nested
// in `E`, not `E`. Generic arguments, optionals, arrays, dictionaries and tuples are.
private final class SelfReferenceFinder: SyntaxVisitor {
  let names: Set<String>
  var found = false

  init(names: Set<String>) {
    self.names = names
    super.init(viewMode: .sourceAccurate)
  }

  override func visit(_ node: IdentifierTypeSyntax) -> SyntaxVisitorContinueKind {
    if self.names.contains(node.name.text) { self.found = true }
    return .visitChildren
  }

  override func visit(_ node: MemberTypeSyntax) -> SyntaxVisitorContinueKind {
    if self.names.contains("\(node.baseType.trimmedDescription).\(node.name.text)") {
      self.found = true
    }
    if let arguments = node.genericArgumentClause { self.walk(arguments) }
    return .skipChildren
  }
}

extension StreamParseableMacro {
  static func diagnoseNonLiteralRawValue(
    in element: EnumCaseElementSyntax,
    context: DiagnosticSink
  ) {
    context.diagnose(
      Self.error(
        element,
        """
        @StreamParseable requires a string literal raw value. Case '\(element.name.text)' \
        declares one the macro cannot read, so it has no text to match against.
        """
      )
    )
  }

  // The one place the closed raw-type list can go wrong, caught where it is visible: raw values
  // on an enum whose raw type the macro did not recognise means it is about to generate the
  // object lowering for a type that is not written as one.
  static func diagnoseUnsupportedRawType(
    in declaration: EnumDeclSyntax,
    rawKind: EnumRawKind,
    context: DiagnosticSink
  ) {
    guard case .none = rawKind else { return }
    let hasRawValues = declaration.memberBlock.members.contains { member in
      member.decl.as(EnumCaseDeclSyntax.self)?.elements.contains { $0.rawValue != nil } ?? false
    }
    guard hasRawValues, let inherited = declaration.inheritanceClause?.inheritedTypes.first else {
      return
    }
    context.diagnose(
      Self.error(
        inherited,
        """
        @StreamParseable does not support '\(inherited.type.trimmedDescription)' as a raw \
        value type. Supported raw types are String and the standard integer and floating \
        point types; an enum with no raw type parses Codable's case-name-keyed object form.
        """
      )
    )
  }

  static func diagnoseAmbiguousDefaultCase(
    in caseDecl: EnumCaseDeclSyntax,
    context: DiagnosticSink
  ) {
    context.diagnose(
      Self.error(
        caseDecl,
        """
        @StreamParseableDefault must mark a single case. This declaration names \
        \(caseDecl.elements.count).
        """
      )
    )
  }

  static func diagnoseDuplicateDefaultCase(
    in caseDecl: EnumCaseDeclSyntax,
    context: DiagnosticSink
  ) {
    context.diagnose(
      Self.error(
        caseDecl,
        "@StreamParseableDefault is already declared on an earlier case."
      )
    )
  }

  static func diagnosePartialMembersOnEnum(
    in node: AttributeSyntax,
    context: DiagnosticSink
  ) {
    context.diagnose(
      Self.error(
        node,
        """
        @StreamParseable(partialMembers:) does not apply to an enum. An enum's partial has a \
        fixed shape: absence is what says a case did not arrive, so its members are always \
        optional.
        """
      )
    )
  }
}
