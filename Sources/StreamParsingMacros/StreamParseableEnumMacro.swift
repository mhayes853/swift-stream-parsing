import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// Enum support, in three lowerings picked from how the enum is spelled. Each one matches what
// `Codable` already does with the same declaration, so nothing new has to be learned about the
// wire format:
//
// | spelling            | wire          | `Partial`          | discriminator        |
// | ------------------- | ------------- | ------------------ | -------------------- |
// | `enum S: String`    | `"live"`      | `StreamString`     | the streamed value   |
// | `enum S: Int`       | `5`           | `Int`              | the number           |
// | `enum S` (raw-less) | `{"live":{}}` | a generated struct | the object key       |
//
// The three differ in exactly one place that matters here: only the `String`-raw form can be read
// *mid-value*. A key arrives whole and a number arrives whole, so those two resolve or do not.
// A string value arrives in chunks with no end-of-string signal reaching the destination, so a
// partial read has to answer from a prefix. See `stringRawConversion`.
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
        return AssociatedValue(label: firstName.text, isLabeled: true, type: parameter.type)
      }
      return AssociatedValue(label: "_\(index)", isLabeled: false, type: parameter.type)
    }
  }

  // The numeric raw types whose `Partial` is the raw value itself, so the conversion is one
  // `init(rawValue:)` and there is nothing to match.
  //
  // A closed list rather than "anything that is not a known protocol", because a macro cannot
  // resolve types: guessing wrong in the permissive direction would silently give an enum with an
  // unrecognised raw type the *object* lowering, which parses a completely different document.
  // `diagnoseUnsupportedRawType` catches that case instead, by noticing raw values on an enum this
  // list did not claim.
  static let scalarRawTypeNames: Set<String> = [
    "Int", "Int8", "Int16", "Int32", "Int64",
    "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
    "Double", "Float"
  ]

  // `stringLiteralValue` reports an empty literal as "not a literal", which is right where it is
  // used for a *key* — naming a member's key `""` is a mistake worth catching — and wrong here,
  // because `case none = ""` is an ordinary raw value that real schemas do use as a sentinel. The
  // matcher already handles it: an empty candidate suppresses the empty-input guard, so zero
  // accumulated bytes reach the exact-match switch and resolve to that case instead of declining.
  static func enumRawStringValue(from expression: ExprSyntax) -> String? {
    guard let literal = expression.as(StringLiteralExprSyntax.self) else { return nil }
    return literal.segments
      .compactMap { $0.as(StringSegmentSyntax.self)?.content.text }
      .joined()
  }

  static func enumRawKind(for declaration: EnumDeclSyntax) -> EnumRawKind {
    // Swift requires the raw type to lead the inheritance clause, so only the first entry can be
    // one. Everything after it is a protocol.
    guard let first = declaration.inheritanceClause?.inheritedTypes.first else { return .none }
    let name = first.type.trimmedDescription
    if name == "String" { return .string }
    if Self.scalarRawTypeNames.contains(name) { return .scalar(name) }
    return .none
  }

  static func enumCases(
    in declaration: EnumDeclSyntax,
    rawKind: EnumRawKind,
    context: some MacroExpansionContext
  ) -> [EnumCase] {
    var cases = [EnumCase]()
    var sawDefault = false
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
        let bareName = element.name.text
        // The raw value, where one is written, is the string this case answers to. Where one is
        // not, the case name is — which is both Swift's own default for a `String` raw value and
        // the `CodingKey` `Codable` derives for the raw-less form, so one rule covers both.
        var defaultName = bareName
        if case .string = rawKind, let rawValue = element.rawValue?.value {
          if let literal = Self.enumRawStringValue(from: rawValue) {
            defaultName = literal
          } else {
            Self.diagnoseNonLiteralRawValue(in: element, context: context)
          }
        }

        let keyInfo = Self.keyNames(for: caseDecl.attributes, defaultName: defaultName)
        for diagnostic in keyInfo.diagnostics {
          context.diagnose(diagnostic)
        }

        // `@StreamParseableMember` means two different things here, because the two lowerings
        // differ in whether the case has a wire form of its own.
        //
        // A `String`-raw case *emits* its raw value — `streamPartialValue` is `self.rawValue`,
        // matching what `Codable` writes — so the raw value must stay a spelling the matcher
        // accepts or the type would not round trip through its own partial. Extra names are
        // therefore additive aliases, and renaming is done the Swift way, by writing the raw
        // value. A raw-less case has no such form: the key is a name, so naming it again
        // replaces it, exactly as `CodingKeys` does and exactly as the attribute does on a
        // struct's stored property.
        var matchNames = keyInfo.names
        if case .string = rawKind, !matchNames.contains(defaultName) {
          matchNames.insert(defaultName, at: 0)
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
    of node: AttributeSyntax,
    declaration: EnumDeclSyntax,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    guard !Self.hasExistingStreamPartialValue(in: declaration.memberBlock.members) else {
      return []
    }
    let rawKind = Self.enumRawKind(for: declaration)
    let cases = Self.enumCases(in: declaration, rawKind: rawKind, context: context)
    Self.diagnoseUnsupportedRawType(in: declaration, rawKind: rawKind, context: context)
    let prefix = Self.modifierPrefix(for: Self.accessModifier(for: declaration.modifiers))

    let body: String
    switch rawKind {
    case .string:
      body = "self.rawValue.streamPartialValue"
    case .scalar:
      body = "self.rawValue"
    case .none:
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
      \(raw: prefix)var streamPartialValue: Partial {
        \(raw: body)
      }
      """
    ]
  }

  static func enumExtensionExpansion(
    of node: AttributeSyntax,
    declaration: EnumDeclSyntax,
    in context: some MacroExpansionContext
  ) throws -> [ExtensionDeclSyntax] {
    let typeName = declaration.name.text
    let rawKind = Self.enumRawKind(for: declaration)
    let cases = Self.enumCases(in: declaration, rawKind: rawKind, context: context)
    Self.diagnoseUnsupportedRawType(in: declaration, rawKind: rawKind, context: context)
    if Self.hasExplicitPartialMembersArgument(node) {
      Self.diagnosePartialMembersOnEnum(in: node, context: context)
    }

    let accessModifier = Self.accessModifier(for: declaration.modifiers)
    let prefix = Self.modifierPrefix(for: accessModifier)
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
        let typeName =
          enumCase.associatedValues.isEmpty
          ? "StreamParsingCore.StreamEmptyObject"
          : Self.payloadTypeName(for: enumCase)
        return StoredProperty(
          name: Self.memberIdentifier(for: enumCase.bareName),
          type: "\(raw: typeName)",
          keyNames: enumCase.matchNames,
          initialCapacity: nil,
          isIgnored: false,
          hasDefaultValue: false
        )
      }
      // `ResolvedView`/`resolved` have to be genuine members of `Partial.View`, not a second
      // extension of it: an `@attached(extension)` macro can only extend the exact type it is
      // attached to (`typeName` itself) — a returned `ExtensionDeclSyntax` naming anything else
      // is silently rewritten back to `typeName`, which is what turned `self` inside the getter
      // into `typeName` instead of `typeName.Partial.View` the first time this was tried,
      // surfacing as "enum case 'x' cannot be used as an instance member" once unqualified
      // lookup fell through to the enclosing enum's cases. Splicing the text in before `View`'s
      // own closing brace — found by searching backward from `streamView`'s `-> View {`, the one
      // point in `partialStructDecl`'s fixed output that always immediately follows it — is what
      // keeps this a member instead, addressed through the same already-live `storage` pointer
      // every per-member `View` accessor reaches through.
      var partialDeclText = Self.partialStructDecl(
        for: properties,
        accessModifier: accessModifier,
        membersMode: .optional,
        baseTypeName: typeName
      )
      .description
      if !cases.isEmpty,
        let streamViewSignature = Self.firstRange(of: "-> View {", in: partialDeclText),
        let viewClosingBrace = partialDeclText[..<streamViewSignature.lowerBound].lastIndex(of: "}")
      {
        let resolvedView = Self.resolvedViewDecl(cases: cases, modifierPrefix: prefix)
        partialDeclText.insert(contentsOf: "\n\(resolvedView)\n", at: viewClosingBrace)
      }
      // `.description` renders a declaration flush left, and only the *first* line of a
      // `\(raw:)` interpolation picks up the surrounding indentation. Nudging the rest by hand is
      // what keeps a nested declaration lined up under the extension the way one interpolated as
      // syntax gets re-indented for free.
      let partialStructText = Self.reindented(partialDeclText, by: 2)
      let payloadWrapperTexts = cases
        .filter { !$0.associatedValues.isEmpty }
        .map { Self.reindented(Self.payloadWrapperDecl(for: $0, accessModifier: accessModifier), by: 2) }
      partialSection =
        ([partialStructText] + payloadWrapperTexts)
        .joined(separator: "\n\n") + "\n"
    }

    let conversion: String
    switch rawKind {
    case .string:
      conversion = Self.stringRawConversion(cases: cases, modifierPrefix: prefix)
    case .scalar:
      conversion = Self.scalarRawConversion(modifierPrefix: prefix)
    case .none:
      conversion = Self.objectConversion(cases: cases, modifierPrefix: prefix)
    }

    let defaultCase = cases.first { $0.isDefault }
    if defaultCase == nil, !Self.namesAnInitialValue(in: declaration) {
      Self.diagnoseMissingDefaultCase(in: declaration, context: context)
    }
    let valueOrInitial =
      defaultCase.map { enumCase in
        """


          /// Falls back to the case marked `@StreamParseableDefault` when the stream did not
          /// produce a value this type can represent.
          \(prefix)static func streamValueOrInitial(from partial: Partial) -> Self {
        \(Self.defaultCaseFallbackBody(for: enumCase))
          }
        """
      } ?? ""

    return [
      try ExtensionDeclSyntax(
        """
        extension \(raw: typeName): StreamParsingCore.StreamParseable {
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
  // **Stage one is the exact match**, and it is the same code the macro already emits for object
  // keys: a `switch` on the leading eight bytes as one little-endian word, with the count and any
  // further words in the `where` clause. That is what a complete value naming a case hits, which
  // is very nearly every conversion, and the compiler turns a switch over dense integer patterns
  // into a jump table. No `String` is materialised and no string comparison runs.
  //
  // **Stage two is the prefix chain**, reached only when stage one missed — a value still
  // arriving, or one naming no case at all. There is no end-of-string signal on a partial (see
  // `StreamString`: it carries a byte count and nothing about whether the parser is done), so a
  // mid-flight read cannot distinguish "live" the whole value from "live" on its way to
  // "livestream". Something has to be assumed, and the assumption is **the shortest case still
  // consistent with the bytes in hand**. Emitting the chain sorted by length ascending is what
  // implements that: the first candidate that still matches is by construction the shortest one,
  // with no comparison logic at runtime.
  //
  // The consequence is worth naming because it is visible to callers: given `live` and
  // `livestream`, a read at four bytes answers `.live` and a later read answers `.livestream`. A
  // case can be *superseded*, not merely filled in. That is inherent to resolving without an end
  // signal, not an artefact of this encoding.
  static func stringRawConversion(cases: [EnumCase], modifierPrefix: String) -> String {
    var candidates = [(name: String, reference: String)]()
    for enumCase in cases {
      for name in enumCase.matchNames {
        candidates.append((name, enumCase.reference))
      }
    }

    let exactArms = candidates
      .map { candidate in
        let word = Self.keyWordLiteral(for: candidate.name)
        let guardClause = Self.enumMatchGuard(for: candidate.name)
        return """
              case \(word)\(guardClause):
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
              if partial.isPrefix(of: \(Self.stringLiteral(candidate.name))) {
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
      \(modifierPrefix)init?(_ partial: Partial) {
          self.init(streamPartial: partial)
        }

        /// Resolves the case the accumulated raw value names, or the shortest case that value is
        /// still a prefix of.
        ///
        /// A partial string cannot say whether it is finished, so a value that names one case and
        /// is a prefix of a longer one resolves to the shorter and may later be superseded.
        \(modifierPrefix)init?(streamPartial partial: Partial) {
      \(body)
        }
      """
  }

  static func scalarRawConversion(modifierPrefix: String) -> String {
    // `Partial` *is* the raw value for every numeric raw type, so there is nothing to accumulate
    // and nothing to match: a number arrives whole, and the only question is whether the case list
    // covers it. That is exactly `init(rawValue:)`.
    """
    \(modifierPrefix)init?(_ partial: Partial) {
        self.init(streamPartial: partial)
      }

      /// Fails when the stream produced a raw value no case declares.
      \(modifierPrefix)init?(streamPartial partial: Partial) {
        self.init(rawValue: partial)
      }
    """
  }

  // The raw-less form. Which case arrived is which member is non-`nil`, because entering a
  // container materialises the member it is entered through even when the container is empty —
  // `{"live":{}}` therefore sets `live` and nothing else.
  //
  // Requiring *exactly* one is what `JSONDecoder` does with the same document: `{}` and
  // `{"live":{},"unknown":{}}` are both "invalid number of keys found, expected one". Counting
  // rather than returning on the first hit is what makes the second of those decline instead of
  // silently answering with whichever case was declared first.
  //
  // Resolving happens in two passes rather than one, because a case with associated values adds
  // a second way to fail: the key can arrive without its payload being complete yet (an object
  // that named the case but is still streaming its fields). The first pass only counts, exactly
  // as the no-payload form always has; the second, reached only once exactly one case is
  // identified, is the one place a payload gets extracted, and it declines the whole conversion
  // rather than let an incomplete payload look like "no case arrived".
  static func objectConversion(cases: [EnumCase], modifierPrefix: String) -> String {
    let countArms = cases.enumerated()
      .map { index, enumCase in
        let member = Self.memberIdentifier(for: enumCase.bareName)
        return """
              if partial.\(member) != nil {
                streamMatched = \(index)
                streamMatches += 1
              }
          """
      }
      .joined(separator: "\n")

    let resolveArms = cases.enumerated()
      .map { index, enumCase in
        guard !enumCase.associatedValues.isEmpty else {
          return """
                case \(index):
                  self = .\(enumCase.reference)
            """
        }
        let member = Self.memberIdentifier(for: enumCase.bareName)
        let payloadType = Self.payloadTypeName(for: enumCase)
        let arguments = Self.caseConstructorArguments(for: enumCase.associatedValues, from: "streamValue")
        return """
              case \(index):
                guard let streamValue = \(payloadType).Value(streamPartial: partial.\(member)!)
                else { return nil }
                self = .\(enumCase.reference)(\(arguments))
          """
      }
      .joined(separator: "\n")

    return """
      \(modifierPrefix)init?(_ partial: Partial) {
          self.init(streamPartial: partial)
        }

        /// Fails unless exactly one case's key arrived, matching what `JSONDecoder` accepts for
        /// the same document — and, for a case with associated values, unless that one case's own
        /// payload has everything it needs yet.
        \(modifierPrefix)init?(streamPartial partial: Partial) {
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

  // The exact-match `where` clause. The same shape as `keyMatchGuard`, reading a `StreamString`
  // instead of a key span: the count is load bearing below eight bytes too, because a decoded NUL
  // in the value is otherwise indistinguishable from `paddedWord`'s zero padding.
  static func enumMatchGuard(for name: String) -> String {
    let count = name.utf8.count
    var conditions = ["streamCount == \(count)"]
    var offset = 8
    while offset < count {
      conditions.append(
        "partial.paddedWord(at: \(offset)) == \(Self.keyWordLiteral(for: name, at: offset))"
      )
      offset += 8
    }
    return " where " + conditions.joined(separator: " && ")
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

  // `Value` and its `Partial` are implementation detail — nothing outside this expansion names
  // either — so the doc comments `conversionMembers` writes for a *user's* type are noise here.
  // They stay on the struct lowering, where they document API someone actually calls.
  static func stripped(_ text: String) -> String {
    text
      .split(separator: "\n", omittingEmptySubsequences: false)
      .filter { !$0.drop(while: { $0 == " " }).hasPrefix("///") }
      .joined(separator: "\n")
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

  // `Collection.firstRange(of:)` needs a newer platform floor than this package supports, so this
  // is the manual substring search that stands in for it — only ever called against text this
  // file itself generated, never user input, so a naive scan is fine.
  static func firstRange(of needle: String, in haystack: String) -> Range<String.Index>? {
    guard !needle.isEmpty else { return nil }
    var searchStart = haystack.startIndex
    while searchStart < haystack.endIndex {
      guard let end = haystack.index(searchStart, offsetBy: needle.count, limitedBy: haystack.endIndex)
      else {
        return nil
      }
      if haystack[searchStart..<end] == needle {
        return searchStart..<end
      }
      searchStart = haystack.index(after: searchStart)
    }
    return nil
  }

  // A payload-bearing case's associated values become a small, self-contained namespace: a
  // field-table `Partial` — built exactly the way the top-level struct lowering builds one, from
  // a synthesized `[StoredProperty]` list keyed by each parameter's label or, unlabeled, a
  // positional `_0`, `_1`, ... matching what `Codable`'s own synthesis keys it with — and a plain
  // `Value` struct whose stored properties match those same labels, wired to that `Partial`
  // through `conversionMembers`, unchanged. Two types rather than one because `conversionMembers`
  // generates `self.<name> = ...` assignments, which needs a real nominal type with those stored
  // properties to assign into; reusing it here is what avoids a second, parallel implementation
  // of per-field scalar/container extraction.
  //
  // Named `<Case>Payload`, nested nowhere in particular — a sibling of `Partial` in the same
  // extension, which is what lets `Partial`'s own member for this case simply be
  // `<Case>Payload.Partial?`.
  static func payloadWrapperDecl(for enumCase: EnumCase, accessModifier: String?) -> String {
    let modifierPrefix = Self.modifierPrefix(for: accessModifier)
    let payloadTypeName = Self.payloadTypeName(for: enumCase)
    let properties = enumCase.associatedValues.map { value in
      StoredProperty(
        name: Self.memberIdentifier(for: value.label),
        type: value.type,
        keyNames: [value.label],
        initialCapacity: nil,
        isIgnored: false,
        hasDefaultValue: false
      )
    }
    let partialText = Self.reindented(
      Self.partialStructDecl(
        for: properties,
        accessModifier: accessModifier,
        membersMode: .optional,
        baseTypeName: payloadTypeName
      )
      .description,
      by: 2
    )
    let valueProperties = properties
      .map { "    \(modifierPrefix)var \($0.name): \($0.type.trimmedDescription)" }
      .joined(separator: "\n")
    // `conversionMembers`'s `_streamValue`/`_streamValueOrInitial` calls resolve through a
    // protocol extension on `StreamParseable` itself, so `Value` has to actually conform —
    // `streamPartialValue` included, even though nothing here ever calls it back.
    let valuePartialValue = Self.reindented(
      Self.streamPartialValueProperty(from: properties, modifierPrefix: modifierPrefix),
      by: 4
    )
    let valueConversion = Self.reindented(
      Self.stripped(
        Self.conversionMembers(
          from: properties, modifierPrefix: modifierPrefix, membersMode: .optional
        )
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

  // The read side: a `~Copyable & ~Escapable` enum grouping every case's borrowed view under one
  // switch, so a caller can read whichever case is present mid-stream without materialising an
  // owned snapshot. A no-payload case is bare; a payload case wraps `<Case>Payload.Partial.View`,
  // which already exists for free — `partialStructDecl` always builds a `View` for whatever it
  // is building, regardless of what the struct is for.
  //
  // Constructing a payload case follows the exact idiom `partialStructView` already uses for its
  // own per-member view accessors: take the member's address with `_streamMemberAddress` (`nil`
  // if the member never got a prepare, which can't happen once `streamMatches == 1` already
  // proved it did), then `_overrideLifetime(..., borrowing: self)` to re-tie the ephemeral
  // address-derived lifetime to the real borrow of `self`. Verified end to end in a throwaway
  // scratch package before this was written: a `~Copyable & ~Escapable` enum can hold
  // heterogeneous concrete `~Escapable` per-case payloads and construct/borrow-check correctly on
  // both the CI-matched Swift 6.3.3 and the default 6.4 toolchain — with one constraint that
  // shaped the switch below: multi-pattern `case` labels (`case .a, .b:`) are not implemented for
  // a `~Copyable` match on either toolchain, so every arm here is single-pattern.
  // Lives on `View`, not `Partial`: `_streamMemberAddress` needs a real, externally supplied
  // address to hand back out, and the only place one of those already exists is `storage`, the
  // pointer `streamView(_:)`'s caller handed in — exactly what every per-member `View` accessor
  // already reaches through (`partialStructView`, `StreamParseableMacro.swift`). A `Partial`
  // *value*'s own address, gotten via `withUnsafePointer(to: self)`, is only valid inside that
  // call — returning a view built from it is a dangling pointer the moment the getter returns,
  // which is exactly what crashed the first version of this under real parsing load.
  static func resolvedViewDecl(cases: [EnumCase], modifierPrefix: String) -> String {
    let countArms = cases.enumerated()
      .map { index, enumCase in
        let member = Self.memberIdentifier(for: enumCase.bareName)
        return """
              if self.storage.pointee.\(member) != nil { streamMatched = \(index); streamMatches += 1 }
          """
      }
      .joined(separator: "\n")

    let resolveArms = cases.enumerated()
      .map { index, enumCase in
        guard !enumCase.associatedValues.isEmpty else {
          return """
                case \(index):
                  return .\(enumCase.reference)
            """
        }
        let member = Self.memberIdentifier(for: enumCase.bareName)
        let payloadType = Self.payloadTypeName(for: enumCase)
        return """
              case \(index):
                guard let streamAddress = StreamParsingCore._streamMemberAddress(&self.storage.pointee.\(member))
                else { return .unresolved }
                return _overrideLifetime(
                  .\(enumCase.reference)(\(payloadType).Partial.streamView(streamAddress)),
                  borrowing: self
                )
          """
      }
      .joined(separator: "\n")

    let viewCases = cases
      .map { enumCase in
        enumCase.associatedValues.isEmpty
          ? "    case \(enumCase.reference)"
          : "    case \(enumCase.reference)(\(Self.payloadTypeName(for: enumCase)).Partial.View)"
      }
      .joined(separator: "\n")

    return """
      /// One case's borrowed, mid-stream view — or `.unresolved`/`.ambiguous` when zero or more
      /// than one case's key has arrived yet.
      \(modifierPrefix)enum ResolvedView: ~Copyable, ~Escapable {
        case unresolved
        case ambiguous
      \(viewCases)
        }

        \(modifierPrefix)var resolved: ResolvedView {
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
  }
}

// MARK: - Diagnostics

extension StreamParseableMacro {
  // Whether the enum says, in its own declaration, what a total conversion should fall back to.
  //
  // `StreamParseable` requires `streamValueOrInitial`, and there is no answer an enum can be
  // given for free: unlike a struct, whose members each supply their own initial value, an enum
  // is one choice and something has to name it. So this is not a style check — an enum that names
  // neither cannot conform, and the point of asking here is to say *that* rather than let the
  // compiler report a missing requirement inside a macro expansion.
  //
  // Deliberately syntactic, and therefore deliberately narrow: a conformance added in a far away
  // extension is invisible here and would be a false positive, so the fix the message names is to
  // put it where this can see it. Both spellings that do are accepted.
  static func namesAnInitialValue(in declaration: EnumDeclSyntax) -> Bool {
    let inherited = declaration.inheritanceClause?.inheritedTypes ?? []
    if inherited.contains(where: { $0.type.trimmedDescription.hasSuffix("StreamInitializable") }) {
      return true
    }
    return declaration.memberBlock.members.contains { member in
      guard let function = member.decl.as(FunctionDeclSyntax.self) else { return false }
      return function.name.text == "streamInitialValue"
    }
  }

  static func diagnoseMissingDefaultCase(
    in declaration: EnumDeclSyntax,
    context: some MacroExpansionContext
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

extension StreamParseableMacro {
  static func diagnoseNonLiteralRawValue(
    in element: EnumCaseElementSyntax,
    context: some MacroExpansionContext
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
    context: some MacroExpansionContext
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
    context: some MacroExpansionContext
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
    context: some MacroExpansionContext
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
    context: some MacroExpansionContext
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
