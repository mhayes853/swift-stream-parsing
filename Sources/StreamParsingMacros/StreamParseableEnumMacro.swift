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
        if element.parameterClause != nil {
          Self.diagnoseAssociatedValues(in: element, context: context)
          continue
        }

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
            isDefault: isDefaultDecl && !sawDefault
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
          return """
            case .\(enumCase.reference):
              return Partial(\(member): StreamParsingCore.StreamEmptyObject())
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
      // Every case becomes an optional member holding the empty object its `{}` payload is, and
      // the struct lowering builds the whole partial — field table, schema, view and all — from
      // that. Nothing about the object form is special enough to need its own generator.
      let properties = cases.map { enumCase in
        StoredProperty(
          name: Self.memberIdentifier(for: enumCase.bareName),
          type: "StreamParsingCore.StreamEmptyObject",
          keyNames: enumCase.matchNames,
          initialCapacity: nil,
          isIgnored: false,
          hasDefaultValue: false
        )
      }
      // `.description` renders the declaration flush left, and only the *first* line of a
      // `\(raw:)` interpolation picks up the surrounding indentation. Nudging the rest by hand is
      // what keeps the nested struct lined up under the extension the way the struct lowering's
      // does, where the same value is interpolated as syntax and re-indented for free.
      partialSection =
        Self.partialStructDecl(
          for: properties,
          accessModifier: accessModifier,
          membersMode: .optional,
          baseTypeName: typeName
        )
        .description
        .split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
        .map { $0.offset == 0 || $0.element.isEmpty ? String($0.element) : "  " + $0.element }
        .joined(separator: "\n") + "\n"
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
            Self(streamPartial: partial) ?? .\(enumCase.reference)
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
  static func objectConversion(cases: [EnumCase], modifierPrefix: String) -> String {
    let arms = cases
      .map { enumCase in
        let member = Self.memberIdentifier(for: enumCase.bareName)
        return """
              if partial.\(member) != nil {
                streamMatched = .\(enumCase.reference)
                streamMatches += 1
              }
          """
      }
      .joined(separator: "\n")

    return """
      \(modifierPrefix)init?(_ partial: Partial) {
          self.init(streamPartial: partial)
        }

        /// Fails unless exactly one case's key arrived, matching what `JSONDecoder` accepts for
        /// the same document.
        \(modifierPrefix)init?(streamPartial partial: Partial) {
          var streamMatched: Self?
          var streamMatches = 0
      \(arms)
          guard streamMatches == 1, let streamMatched else { return nil }
          self = streamMatched
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
  static func diagnoseAssociatedValues(
    in element: EnumCaseElementSyntax,
    context: some MacroExpansionContext
  ) {
    context.diagnose(
      Diagnostic(
        node: element,
        message: MacroExpansionErrorMessage(
          """
          @StreamParseable does not support enum cases with associated values. \
          Case '\(element.name.text)' declares one.
          """
        )
      )
    )
  }

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
