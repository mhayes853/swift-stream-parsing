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
    /// The bare identifier, which is the JSON key in the raw-less form and the default raw value
    /// in the `String`-raw one.
    let bareName: String
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
          label: StreamParseableMacro.unescaped(firstName), isLabeled: true, type: parameter.type
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

      let isDefaultDecl = Self.streamParseableDefaultAttribute(in: caseDecl.attributes) != nil
      if isDefaultDecl, caseDecl.elements.count > 1 {
        Self.diagnoseAmbiguousDefaultCase(in: caseDecl, context: context)
      }
      if isDefaultDecl, sawDefault {
        Self.diagnoseDuplicateDefaultCase(in: caseDecl, context: context)
      }

      for element in caseDecl.elements {
        let associatedValues = Self.associatedValues(in: element.parameterClause)
        let bareName = StreamParseableMacro.unescaped(element.name)
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

        let keyInfo = Self.keyNames(for: caseDecl.attributes, defaultName: defaultName)
        for diagnostic in keyInfo.diagnostics {
          context.diagnose(diagnostic)
        }

        // `@StreamParseableMember` means "alias" for a `String`-raw case and "rename" for a
        // raw-less one. A raw-raw case emits its raw value as its partial, so that spelling must
        // stay matchable or the type would not round trip; renaming it is done by writing the raw
        // value. A raw-less case has no wire form of its own, so naming its key replaces it.
        var matchNames = keyInfo.names
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
          if !associatedValues.isEmpty,
            !seenPayloadTypes.insert(Self.payloadTypeName(forCaseNamed: bareName)).inserted
          {
            context.diagnose(
              Self.error(
                element,
                """
                Case '\(bareName)' generates the payload type \
                '\(Self.payloadTypeName(forCaseNamed: bareName))', which another case already \
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
            bareName: bareName,
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
    Self.diagnoseUnsupportedRawType(in: declaration, rawKind: rawKind, context: context)
    let accessModifier = Self.accessModifier(for: declaration.modifiers)
    let prefix = Self.modifierPrefix(for: accessModifier)

    let body: String
    // Not for the raw-less form: under library evolution an inlinable `switch self` over a
    // non-frozen enum is an error ("may have additional unknown values").
    var inlinable = Self.isInlinable(accessModifier)
    switch rawKind {
    case .string:
      body = "self.rawValue.streamPartialValue"
    case .scalar:
      body = "self.rawValue"
    case .none:
      inlinable = false
      guard !cases.isEmpty else { return [] }
      let arms = cases
        .map { enumCase in
          let member = Self.memberIdentifier(for: enumCase.bareName)
          guard !enumCase.associatedValues.isEmpty else {
            return """
              case .\(enumCase.reference):
                return Partial(\(member): StreamParsingCore.StreamEmptyObject())
            """
          }
          let payloadType = Self.payloadTypeName(for: enumCase)
          let bindings = enumCase.associatedValues
            .map { "let \(Self.memberIdentifier(for: $0.label))" }
            .joined(separator: ", ")
          let payloadArguments = enumCase.associatedValues
            .map { value in
              let name = Self.memberIdentifier(for: value.label)
              return "\(name): \(name).streamPartialValue"
            }
            .joined(separator: ", ")
          return """
            case .\(enumCase.reference)(\(bindings)):
              return Partial(\(member): \(payloadType).Partial(\(payloadArguments)))
          """
        }
        .joined(separator: "\n")
      body = """
        switch self {
        \(arms)
          }
        """
    }

    return [
      """
      \(raw: Self.inlinableAttribute(inlinable))\(raw: prefix)var streamPartialValue: Partial {
        \(raw: body)
      }
      """
    ]
  }

  static func enumExtensionExpansion(
    of node: AttributeSyntax,
    declaration: EnumDeclSyntax,
    type: some TypeSyntaxProtocol,
    in context: DiagnosticSink
  ) throws -> [ExtensionDeclSyntax] {
    // The fully qualified name, so a nested enum extends `Outer.Inner`.
    let typeName = type.trimmedDescription
    let conformance = Self.conformanceClause(for: declaration)
    let rawKind = Self.enumRawKind(for: declaration)
    let cases = Self.enumCases(in: declaration, rawKind: rawKind, context: context)
    Self.diagnoseUnsupportedRawType(in: declaration, rawKind: rawKind, context: context)
    if Self.hasExplicitPartialMembersArgument(node) {
      Self.diagnosePartialMembersOnEnum(in: node, context: context)
    }

    let accessModifier = Self.accessModifier(for: declaration.modifiers)
    let prefix = Self.modifierPrefix(for: accessModifier)
    let inlinable = Self.isInlinable(accessModifier)
    let inline = Self.inlinableAttribute(inlinable)
    let hasExistingPartial = Self.hasExistingPartial(in: declaration.memberBlock.members)

    let partialSection: String
    switch rawKind {
    case _ where hasExistingPartial:
      partialSection = ""
    case .string:
      partialSection = "\(prefix)typealias Partial = StreamParsingCore.StreamString\n"
    case .scalar(let rawType):
      partialSection = "\(prefix)typealias Partial = \(rawType)\n"
    case .none:
      // Every case becomes an optional member. A no-payload case's member holds the empty object
      // its `{}` payload is; a case with associated values gets a per-case payload type instead
      // (`payloadWrapperDecl`), keyed the same way `Codable`'s synthesis keys the object it
      // wraps them in. Either way the struct lowering builds the whole partial — field table,
      // schema, view and all — from the member list. Nothing about the object form is special
      // enough to need its own generator.
      let properties = cases.map { enumCase -> StoredProperty in
        let payloadName =
          enumCase.associatedValues.isEmpty
          ? "StreamParsingCore.StreamEmptyObject"
          : Self.payloadTypeName(for: enumCase)
        return StoredProperty(
          name: enumCase.bareName,
          type: "\(raw: payloadName)",
          keyNames: enumCase.matchNames,
          initialCapacity: nil,
          isIgnored: false,
          hasDefaultValue: false
        )
      }
      // `ResolvedView`/`resolved` go in as members of `View` itself, not a second extension of
      // it: an `@attached(extension)` macro can only extend the type it is attached to, so an
      // extension naming `Partial.View` is silently rewritten back to the enum.
      let partialDeclText = try Self.partialStructDecl(
        for: properties,
        accessModifier: accessModifier,
        membersMode: .optional,
        extraViewMembers: cases.isEmpty
          ? ""
          : Self.resolvedViewDecl(cases: cases, modifierPrefix: prefix, inlinable: inlinable)
      )
      .description
      // `.description` renders flush left, and only the first line of a `\(raw:)` interpolation
      // picks up the surrounding indentation.
      let partialStructText = Self.reindented(partialDeclText, by: 2)
      let payloadWrapperTexts = try cases
        .filter { !$0.associatedValues.isEmpty }
        .map {
          try Self.reindented(
            Self.payloadWrapperDecl(for: $0, accessModifier: accessModifier), by: 2
          )
        }
      partialSection =
        ([partialStructText] + payloadWrapperTexts)
        .joined(separator: "\n\n") + "\n"
    }

    let conversion: String
    switch rawKind {
    case .string:
      conversion = Self.stringRawConversion(cases: cases, modifierPrefix: prefix, inlinable: inlinable)
    case .scalar:
      conversion = Self.scalarRawConversion(modifierPrefix: prefix, inlinable: inlinable)
    case .none:
      conversion = Self.objectConversion(cases: cases, modifierPrefix: prefix, inlinable: inlinable)
    }

    let defaultCase = cases.first { $0.isDefault }
    if defaultCase == nil, !Self.namesAnInitialValue(in: declaration) {
      Self.diagnoseMissingDefaultCase(in: declaration, context: context)
    }
    let valueOrInitial =
      defaultCase.map { enumCase in
        """


          \(inline)\(prefix)static func streamValueOrInitial(from partial: Partial) -> Self {
        \(Self.defaultCaseFallbackBody(for: enumCase))
          }
        """
      } ?? ""

    return [
      try ExtensionDeclSyntax(
        """
        extension \(raw: typeName)\(raw: conformance) {
          \(raw: partialSection)
          \(raw: conversion)\(raw: valueOrInitial)
        }
        """
      )
    ]
  }
}

// MARK: - Conversions

extension StreamParseableMacro {
  // The `String`-raw matcher, in two stages.
  //
  // Stage one is the exact match a complete value hits: the same little-endian word switch the
  // macro emits for object keys, which the compiler turns into a jump table.
  //
  // Stage two is the prefix chain, reached only on a miss. A partial carries no end-of-string
  // signal, so a mid-flight read must assume something; the assumption is the shortest case still
  // consistent with the bytes in hand, implemented by emitting the chain sorted by length
  // ascending. (The caller-visible consequence is documented on `@StreamParseable` itself.)
  static func stringRawConversion(
    cases: [EnumCase], modifierPrefix: String, inlinable: Bool
  ) -> String {
    let inline = Self.inlinableAttribute(inlinable)
    var candidates = [(name: String, reference: String)]()
    for enumCase in cases {
      for name in enumCase.matchNames {
        candidates.append((name, enumCase.reference))
      }
    }

    let exactArms = candidates
      .map { candidate in
        let match = StreamUTF8Match(candidate.name)
        let condition = streamRemainingUTF8Condition(match,
          byteCount: DeclReferenceExprSyntax(baseName: .identifier("streamCount"))
        ) { offset in
          ExprSyntax("partial.paddedWord(at: \(raw: offset))")
        }
        return """
              case \(streamUTF8WordLiteral(match.value, at: 0)) where \(condition):
                self = .\(candidate.reference)
                return
          """
      }
      .joined(separator: "\n")

    // Stable within a length, so declaration order breaks ties rather than whatever order a sort
    // happens to produce.
    let prefixArms = candidates
      .enumerated()
      .sorted {
        let left = $0.element.name.utf8.count
        let right = $1.element.name.utf8.count
        return left == right ? $0.offset < $1.offset : left < right
      }
      .map { _, candidate in
        """
              if partial.isPrefix(of: \(StringLiteralExprSyntax(content: candidate.name).trimmedDescription)) {
                self = .\(candidate.reference)
                return
              }
          """
      }
      .joined(separator: "\n")

    // An empty accumulation is a prefix of every case, so shortest-wins would resolve it to some
    // case the instant the opening quote arrived — a definite answer on no evidence, which then
    // *changes* as the real bytes land. Declining instead keeps the progression monotone
    // (nil, then the case), and `streamValueOrInitial` still supplies the default for anyone who
    // wants one. The guard is omitted when a case actually spells `""`, since then zero bytes are
    // a value rather than an absence.
    var lines = [String]()
    let countIsRead = !exactArms.isEmpty
    if countIsRead { lines.append("    let streamCount = partial.utf8Count") }
    if !candidates.contains(where: { $0.name.isEmpty }) {
      let count = countIsRead ? "streamCount" : "partial.utf8Count"
      lines.append("    guard \(count) > 0 else { return nil }")
    }
    if countIsRead {
      lines.append("    switch partial.paddedLeadingWord() {")
      lines.append(exactArms)
      lines.append("    default:")
      lines.append("      break")
      lines.append("    }")
    }
    if !prefixArms.isEmpty { lines.append(prefixArms) }
    lines.append("    return nil")
    let body = lines.joined(separator: "\n")

    return """
      \(inline)\(modifierPrefix)init?(_ partial: Partial) {
          self.init(streamPartial: partial)
        }

        \(inline)\(modifierPrefix)init?(streamPartial partial: Partial) {
      \(body)
        }
      """
  }

  static func scalarRawConversion(modifierPrefix: String, inlinable: Bool) -> String {
    let inline = Self.inlinableAttribute(inlinable)
    // `Partial` *is* the raw value for every numeric raw type, so there is nothing to accumulate
    // and nothing to match: a number arrives whole, and the only question is whether the case list
    // covers it. That is exactly `init(rawValue:)`.
    return """
    \(inline)\(modifierPrefix)init?(_ partial: Partial) {
        self.init(streamPartial: partial)
      }

      \(inline)\(modifierPrefix)init?(streamPartial partial: Partial) {
        self.init(rawValue: partial)
      }
    """
  }

  // The raw-less form. Which case arrived is which member is non-`nil`, and *exactly* one must
  // be, matching what `JSONDecoder` accepts for the same document. Two passes rather than one,
  // because a payload-bearing case can also fail by having arrived incomplete: the first pass
  // only counts, and the second extracts the one identified payload or declines outright.
  // Both halves of the two-pass resolve, for both readers. `objectConversion` and
  // `resolvedViewDecl` run the identical count-then-switch protocol over the identical member
  // list; only how a member is reached and how each arm reads differ, so only the arm bodies do.
  static func caseArms(
    _ cases: [EnumCase],
    _ arm: (_ index: Int, _ enumCase: EnumCase, _ member: String) -> String
  ) -> String {
    cases.enumerated()
      .map { arm($0.offset, $0.element, Self.memberIdentifier(for: $0.element.bareName)) }
      .joined(separator: "\n")
  }

  static func objectConversion(cases: [EnumCase], modifierPrefix: String, inlinable: Bool) -> String {
    let inline = Self.inlinableAttribute(inlinable)
    let countArms = Self.caseArms(cases) { index, _, member in
      """
            if partial.\(member) != nil {
              streamMatched = \(index)
              streamMatches += 1
            }
        """
    }

    let resolveArms = Self.caseArms(cases) { index, enumCase, member in
      guard !enumCase.associatedValues.isEmpty else {
        return """
              case \(index):
                self = .\(enumCase.reference)
          """
      }
      let payloadType = Self.payloadTypeName(for: enumCase)
      let arguments = Self.caseConstructorArguments(for: enumCase.associatedValues, from: "streamValue")
      return """
            case \(index):
              guard let streamValue = \(payloadType).Value(streamPartial: partial.\(member)!)
              else { return nil }
              self = .\(enumCase.reference)(\(arguments))
        """
    }

    return """
      \(inline)\(modifierPrefix)init?(_ partial: Partial) {
          self.init(streamPartial: partial)
        }

        \(inline)\(modifierPrefix)init?(streamPartial partial: Partial) {
          var streamMatched = -1
          var streamMatches = 0
      \(countArms)
          guard streamMatches == 1 else { return nil }
          switch streamMatched {
      \(resolveArms)
          default:
            return nil
          }
        }
      """
  }

  // A JSON key becomes a Swift member name, which it is not always already: a key may be a Swift
  // keyword, contain characters an identifier cannot, or be empty. Backticks cover the keyword
  // case, which is the only one a case name can produce on its own; anything else is a key the
  // user named explicitly and is left to the compiler to reject at the member declaration, where
  // the error points at something they wrote.
  static func memberIdentifier(for key: String) -> String {
    guard !key.isEmpty else { return "_streamEmptyKey" }
    let isIdentifier =
      !key.first!.isNumber
      && key.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    return isIdentifier && !Self.swiftKeywords.contains(key) ? key : "`\(key)`"
  }

  static let swiftKeywords: Set<String> = [
    "associatedtype", "borrowing", "case", "catch", "class", "consuming", "continue", "default",
    "defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "false", "fileprivate",
    "for", "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "let",
    "nil", "operator", "private", "protocol", "public", "repeat", "rethrows", "return", "self",
    "Self", "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try",
    "typealias", "var", "where", "while"
  ]
}

// MARK: - Associated values

extension StreamParseableMacro {
  // The argument list for constructing a case from its payload's extracted fields — shared
  // between `objectConversion`'s resolved arm and a payload-bearing default case's fallback,
  // since both start from a value with one stored property per associated value and need to
  // call the case constructor with the same labels back.
  static func caseConstructorArguments(for associatedValues: [AssociatedValue], from source: String)
    -> String
  {
    associatedValues
      .map { value in
        let name = Self.memberIdentifier(for: value.label)
        return value.isLabeled ? "\(value.label): \(source).\(name)" : "\(source).\(name)"
      }
      .joined(separator: ", ")
  }

  // A default case with no payload can fall back to its bare `.case` the way it always has. One
  // with associated values has nothing to fall back to *until* its own payload is filled in the
  // same recursive way a struct member with an initial value is — `<Case>Payload.Value` already
  // has that for free from `conversionMembers`, so this calls it rather than repeating the rule.
  static func defaultCaseFallbackBody(for enumCase: EnumCase) -> String {
    guard !enumCase.associatedValues.isEmpty else {
      return "    Self(streamPartial: partial) ?? .\(enumCase.reference)"
    }
    let member = Self.memberIdentifier(for: enumCase.bareName)
    let payloadType = Self.payloadTypeName(for: enumCase)
    let arguments = Self.caseConstructorArguments(
      for: enumCase.associatedValues, from: "streamDefaultValue"
    )
    return """
          if let streamMatched = Self(streamPartial: partial) {
            return streamMatched
          }
          let streamDefaultValue = \(payloadType).Value.streamValueOrInitial(
            from: partial.\(member) ?? \(payloadType).Partial.streamInitialValue()
          )
          return .\(enumCase.reference)(\(arguments))
      """
  }

  // The generated per-case payload namespace's name. Upper-cased because it is a type: a case is
  // spelled `text`, its payload type `TextPayload`. The suffix is what keeps it from colliding
  // with a Swift keyword, so no backticking is needed even for `case \`default\``.
  static func payloadTypeName(for enumCase: EnumCase) -> String {
    Self.payloadTypeName(forCaseNamed: enumCase.bareName)
  }

  static func payloadTypeName(forCaseNamed bareName: String) -> String {
    guard let first = bareName.first else { return "Payload" }
    return first.uppercased() + bareName.dropFirst() + "Payload"
  }

  // Re-indents every line but the first by `spaces`. A raw `\(raw:)` interpolation of a
  // `DeclSyntax` only picks up the surrounding indentation on its first line — see the note at
  // `partialSection`'s construction — and this is the same fix-up applied to text this file
  // builds by hand instead (a plain `String` interpolation gets none of that for free, not even
  // the first line).
  static func reindented(_ text: String, by spaces: Int) -> String {
    let pad = String(repeating: " ", count: spaces)
    return text
      .split(separator: "\n", omittingEmptySubsequences: false)
      .enumerated()
      .map { $0.offset == 0 || $0.element.isEmpty ? String($0.element) : pad + $0.element }
      .joined(separator: "\n")
  }

  // A payload-bearing case's associated values become a `<Case>Payload` namespace holding the
  // usual field-table `Partial` plus a `Value` struct with the same stored properties. Two types
  // rather than one because `conversionMembers` assigns into a real nominal type, and reusing it
  // here is what avoids a second implementation of per-field extraction.
  static func payloadWrapperDecl(
    for enumCase: EnumCase, accessModifier: String?
  ) throws -> String {
    let modifierPrefix = Self.modifierPrefix(for: accessModifier)
    let payloadTypeName = Self.payloadTypeName(for: enumCase)
    let properties = enumCase.associatedValues.map { value in
      StoredProperty(
        name: value.label,
        type: value.type,
        keyNames: [value.label],
        initialCapacity: nil,
        isIgnored: false,
        hasDefaultValue: false
      )
    }
    let partialText = Self.reindented(
      try Self.partialStructDecl(
        for: properties,
        accessModifier: accessModifier,
        membersMode: .optional,
      )
      .description,
      by: 2
    )
    let valueProperties = properties
      .map { "    \(modifierPrefix)var \($0.memberName): \($0.type.trimmedDescription)" }
      .joined(separator: "\n")
    // `conversionMembers`'s `_streamValue`/`_streamValueOrInitial` calls resolve through a
    // protocol extension on `StreamParseable` itself, so `Value` has to actually conform —
    // `streamPartialValue` included, even though nothing here ever calls it back.
    let inlinable = Self.isInlinable(accessModifier)
    let valuePartialValue = Self.reindented(
      Self.streamPartialValueProperty(
        from: properties, modifierPrefix: modifierPrefix, inlinable: inlinable
      ),
      by: 4
    )
    let valueConversion = Self.reindented(
      Self.conversionMembers(
        from: properties, modifierPrefix: modifierPrefix, membersMode: .optional,
        inlinable: inlinable
      ),
      by: 4
    )

    return """
      \(modifierPrefix)enum \(payloadTypeName) {
        \(partialText)

        \(modifierPrefix)struct Value: StreamParsingCore.StreamParseable {
      \(valueProperties)

          \(modifierPrefix)typealias Partial = \(payloadTypeName).Partial

          \(valuePartialValue)

          \(valueConversion)
        }
      }
      """
  }

  // The read side groups every case's view under one switch, so a case can be read mid-stream
  // without materialising an owned snapshot. It follows `View`: nonescapable with `LifetimeView`,
  // otherwise an explicitly unsafe escapable pointer projection.
  //
  // Two constraints shape what is emitted here. Multi-pattern `case` labels are not implemented
  // for a `~Copyable` match on Swift 6.3/6.4, so every arm is single-pattern. And this must live
  // on `View`, reaching through the caller-supplied `_streamStorage` — a `Partial` value's own
  // address via `withUnsafePointer(to:)` dangles the moment the getter returns.
  static func resolvedViewDecl(cases: [EnumCase], modifierPrefix: String, inlinable: Bool) -> String {
    let inline = Self.inlinableAttribute(inlinable)
    let countArms = Self.caseArms(cases) { index, _, member in
      """
            if self._streamStorage.pointee.\(member) != nil { streamMatched = \(index); streamMatches += 1 }
        """
    }

#if LifetimeView
    let resolveArms = Self.caseArms(cases) { index, enumCase, member in
      guard !enumCase.associatedValues.isEmpty else {
        return """
              case \(index):
                return .\(enumCase.reference)
          """
      }
      let payloadType = Self.payloadTypeName(for: enumCase)
      return """
            case \(index):
              guard let streamAddress = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.\(member))
              else { return .unresolved }
              return _overrideLifetime(
                .\(enumCase.reference)(\(payloadType).Partial.streamView(streamAddress)),
                borrowing: self
              )
        """
    }
#else
    let resolveArms = Self.caseArms(cases) { index, enumCase, member in
      guard !enumCase.associatedValues.isEmpty else {
        return """
              case \(index):
                return .\(enumCase.reference)
          """
      }
      let payloadType = Self.payloadTypeName(for: enumCase)
      return """
            case \(index):
              guard let streamAddress = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.\(member))
              else { return .unresolved }
              return .\(enumCase.reference)(\(payloadType).Partial.streamView(streamAddress))
        """
    }
#endif

    let viewCases = cases
      .map { enumCase in
        enumCase.associatedValues.isEmpty
          ? "    case \(enumCase.reference)"
          : "    case \(enumCase.reference)(\(Self.payloadTypeName(for: enumCase)).Partial.View)"
      }
      .joined(separator: "\n")

#if LifetimeView
    return """
      \(modifierPrefix)enum ResolvedView: ~Copyable, ~Escapable {
        case unresolved
        case ambiguous
      \(viewCases)
        }

        \(inline)\(modifierPrefix)var resolved: ResolvedView {
          @_lifetime(borrow self)
          get {
            var streamMatched = -1
            var streamMatches = 0
      \(countArms)
            guard streamMatches == 1 else {
              if streamMatches == 0 { return .unresolved }
              return .ambiguous
            }
            switch streamMatched {
      \(resolveArms)
            default:
              return .unresolved
            }
          }
        }
      """
#else
    return """
      @unsafe \(modifierPrefix)enum ResolvedView: ~Copyable {
        case unresolved
        case ambiguous
      \(viewCases)
        }

        \(inline)\(modifierPrefix)var resolved: ResolvedView {
          get {
            var streamMatched = -1
            var streamMatches = 0
      \(countArms)
            guard streamMatches == 1 else {
              if streamMatches == 0 { return .unresolved }
              return .ambiguous
            }
            switch streamMatched {
      \(resolveArms)
            default:
              return .unresolved
            }
          }
        }
      """
#endif
  }
}

// MARK: - Diagnostics

extension StreamParseableMacro {
  // Whether the enum says, in its own declaration, what a total conversion falls back to. An
  // enum that names neither a default case nor `StreamInitializable` cannot conform, and saying
  // so here beats a missing-requirement error inside an expansion. Deliberately syntactic, so a
  // conformance added in a far away extension is invisible: the message names the fix.
  static func namesAnInitialValue(in declaration: EnumDeclSyntax) -> Bool {
    let inherited = declaration.inheritanceClause?.inheritedTypes ?? []
    if inherited.contains(where: { Self.lastComponent(of: $0.type) == "StreamInitializable" }) {
      return true
    }
    return declaration.memberBlock.members.contains { member in
      guard let function = member.decl.as(FunctionDeclSyntax.self),
        function.name.text == "streamInitialValue",
        function.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) }),
        function.signature.parameterClause.parameters.isEmpty
      else {
        return false
      }
      return true
    }
  }

  static func diagnoseMissingDefaultCase(
    in declaration: EnumDeclSyntax,
    context: DiagnosticSink
  ) {
    context.diagnose(
      Diagnostic(
        node: declaration.name,
        message: MacroExpansionErrorMessage(
          """
          @StreamParseable requires an enum to name a fallback case, because \
          'streamValueOrInitial' has to produce one when the stream produced nothing this type \
          can represent. Mark a case with @StreamParseableDefault, or declare \
          'StreamInitializable' conformance on '\(declaration.name.text)' itself.
          """
        )
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
              Case '\(Self.unescaped(element.name))' has a payload that contains \
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
      Diagnostic(
        node: element,
        message: MacroExpansionErrorMessage(
          """
          @StreamParseable requires a string literal raw value. Case '\(element.name.text)' \
          declares one the macro cannot read, so it has no text to match against.
          """
        )
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
      Diagnostic(
        node: inherited,
        message: MacroExpansionErrorMessage(
          """
          @StreamParseable does not support '\(inherited.type.trimmedDescription)' as a raw \
          value type. Supported raw types are String and the standard integer and floating \
          point types; an enum with no raw type parses Codable's case-name-keyed object form.
          """
        )
      )
    )
  }

  static func diagnoseAmbiguousDefaultCase(
    in caseDecl: EnumCaseDeclSyntax,
    context: DiagnosticSink
  ) {
    context.diagnose(
      Diagnostic(
        node: caseDecl,
        message: MacroExpansionErrorMessage(
          """
          @StreamParseableDefault must mark a single case. This declaration names \
          \(caseDecl.elements.count).
          """
        )
      )
    )
  }

  static func diagnoseDuplicateDefaultCase(
    in caseDecl: EnumCaseDeclSyntax,
    context: DiagnosticSink
  ) {
    context.diagnose(
      Diagnostic(
        node: caseDecl,
        message: MacroExpansionErrorMessage(
          "@StreamParseableDefault is already declared on an earlier case."
        )
      )
    )
  }

  static func diagnosePartialMembersOnEnum(
    in node: AttributeSyntax,
    context: DiagnosticSink
  ) {
    context.diagnose(
      Diagnostic(
        node: node,
        message: MacroExpansionErrorMessage(
          """
          @StreamParseable(partialMembers:) does not apply to an enum. An enum's partial has a \
          fixed shape: absence is what says a case did not arrive, so its members are always \
          optional.
          """
        )
      )
    )
  }
}
