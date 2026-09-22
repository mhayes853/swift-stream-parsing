import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// How an enum appears in the stream.
#if compiler(>=6.2.3)
@nonexhaustive
#endif
public enum StreamEnumRepresentation: Hashable, Sendable {
  /// A string such as `"live"`, matched against each case's keys. A partial string resolves to
  /// the shortest case it is a prefix of, so `live` may later become `livestream`.
  case stringRawValue
  /// A number such as `5`. The raw type is its own partial, so conversion is `init(rawValue:)`.
  case numericRawValue(TypeSyntax)
  /// An object keyed by case, as `Codable` encodes an enum without a raw type:
  /// `{"text":{"body":"hi"}}`. Associated values are keyed by label, or `_0`, `_1`, ....
  case caseKeyedObject
}

/// Describes one case of a generated stream enum.
public struct StreamParseableEnumCase: Sendable {
  /// The Swift case identifier, including backticks when already escaped.
  public var name: TokenSyntax
  /// `.stringRawValue`: the raw value and its aliases. `.caseKeyedObject`: the object keys.
  /// `.numericRawValue` ignores them.
  public var keys: [String]
  /// One field per associated value, in declaration order. A wildcard name (`_`) is an
  /// unlabelled value: it is named `_<position>`, and keyed that way when it has no keys.
  public var associatedValues: [StreamParseableField]
  /// The namespace holding the case's payload `Partial` and `Value`. `nil` uses `<Case>Payload`.
  /// Ignored for a case without associated values.
  public var payloadTypeName: TokenSyntax?

  /// Creates a case description.
  public init(
    name: TokenSyntax,
    keys: some Sequence<String>,
    associatedValues: [StreamParseableField] = [],
    payloadTypeName: TokenSyntax? = nil
  ) {
    self.name = name
    self.keys = Array(keys)
    self.associatedValues = associatedValues
    self.payloadTypeName = payloadTypeName
  }

  /// Creates a case whose only key is its name, without backticks.
  public init(
    name: TokenSyntax,
    associatedValues: [StreamParseableField] = [],
    payloadTypeName: TokenSyntax? = nil
  ) {
    self.init(
      name: name,
      keys: [StreamObjectGeneration.bareName(name)],
      associatedValues: associatedValues,
      payloadTypeName: payloadTypeName
    )
  }
}

/// A reusable plan for generating a stream enum's partial and conversions.
public struct StreamEnumGeneration: Sendable {
  /// The cases in stable generated order.
  public let cases: [StreamParseableEnumCase]
  /// The wire representation.
  public let representation: StreamEnumRepresentation
  /// The case `init(orInitial:)` falls back to. Without one, the host must adopt
  /// `TypeSyntax.streamInitializable` to supply `streamValueOrInitial(from:)`.
  public let defaultCase: TokenSyntax?
  /// Options shared by every generated component.
  public let configuration: StreamGenerationConfiguration

  /// The top-level partial of `.caseKeyedObject`, with one field per case.
  private let object: StreamObjectGeneration?
  /// `cases`, resolved for generation.
  private let entries: [Entry]

  private struct Entry: Sendable {
    /// The case name, escaped where needed; also its member name in an object partial.
    let name: String
    let keys: [String]
    /// `nil` for a case without associated values or under a raw-value representation.
    let payload: Payload?
  }

  private struct Payload: Sendable {
    let typeName: String
    /// Whether each associated value is labelled, parallel to `generation.fields`.
    let isLabeled: [Bool]
    /// The payload partial, with one field per associated value and positional names resolved.
    let generation: StreamObjectGeneration
  }

  /// Creates and validates an enum generation plan.
  ///
  /// Throws `StreamObjectGenerationError`: `.duplicateKey` for a key claimed by two cases,
  /// `.incompatibleInliningAccess`, and the object-field errors for a case's associated values,
  /// including `.missingCompletedConversionDefault`. Names that don't compile, such as a
  /// duplicate case or payload type, are left to the compiler.
  public init(
    cases: [StreamParseableEnumCase],
    representation: StreamEnumRepresentation,
    defaultCase: TokenSyntax? = nil,
    configuration: StreamGenerationConfiguration = StreamGenerationConfiguration()
  ) throws {
    try self.init(
      cases: cases,
      representation: representation,
      defaultCase: defaultCase,
      configuration: configuration,
      isValidated: true
    )
  }

  /// Creates a recovery plan after the caller has diagnosed invalid source.
  ///
  /// Skips validation so a macro can emit its own diagnostics and recovery expansion.
  public init(
    diagnosedCases cases: [StreamParseableEnumCase],
    representation: StreamEnumRepresentation,
    defaultCase: TokenSyntax? = nil,
    configuration: StreamGenerationConfiguration = StreamGenerationConfiguration()
  ) {
    try! self.init(
      cases: cases,
      representation: representation,
      defaultCase: defaultCase,
      configuration: configuration,
      isValidated: false
    )
  }

  private init(
    cases: [StreamParseableEnumCase],
    representation: StreamEnumRepresentation,
    defaultCase: TokenSyntax?,
    configuration: StreamGenerationConfiguration,
    isValidated: Bool
  ) throws {
    self.cases = cases
    self.representation = representation
    self.defaultCase = defaultCase
    self.configuration = configuration

    func generation(_ fields: [StreamParseableField]) throws -> StreamObjectGeneration {
      guard isValidated else {
        return StreamObjectGeneration(diagnosedFields: fields, configuration: configuration)
      }
      let generation = try StreamObjectGeneration(fields: fields, configuration: configuration)
      try generation.validateConversions(unparsedMembers: [])
      return generation
    }

    guard case .caseKeyedObject = representation else {
      // A raw-value enum validates like an object keyed by its raw values, without keeping it.
      if case .stringRawValue = representation {
        _ = try generation(
          cases.map { StreamParseableField(name: $0.name, type: TypeSyntax("Never"), keys: $0.keys) }
        )
      } else {
        _ = try generation([])
      }
      self.object = nil
      self.entries = cases.map {
        Entry(name: StreamObjectGeneration.memberName($0.name), keys: $0.keys, payload: nil)
      }
      return
    }

    self.entries = try cases.map { enumCase in
      var payload: Payload?
      if !enumCase.associatedValues.isEmpty {
        // An unlabelled value is `_<position>`, counting every associated value, as `Codable` does.
        let fields = enumCase.associatedValues.enumerated().map { index, value in
          var field = value
          if value.name.tokenKind == .wildcard {
            field.name = .identifier("_\(index)")
            if field.keys.isEmpty { field.keys = ["_\(index)"] }
          }
          return field
        }
        payload = Payload(
          typeName: enumCase.payloadTypeName?.trimmedDescription
            ?? Self.defaultPayloadTypeName(forCaseNamed: StreamObjectGeneration.bareName(enumCase.name)),
          isLabeled: enumCase.associatedValues.map { $0.name.tokenKind != .wildcard },
          generation: try generation(fields)
        )
      }
      return Entry(
        name: StreamObjectGeneration.memberName(enumCase.name),
        keys: enumCase.keys,
        payload: payload
      )
    }
    // A case without a payload holds the empty object its `{}` is.
    self.object = try generation(
      zip(cases, self.entries).map { enumCase, entry in
        StreamParseableField(
          name: enumCase.name,
          type: TypeSyntax("\(raw: entry.payload?.typeName ?? "StreamParsingCore.StreamEmptyObject")"),
          keys: enumCase.keys
        )
      }
    )
  }

  /// Case names and the `StreamFieldID` expressions their keys report to `onFieldRecognized`,
  /// in declaration order. Aliases share an identifier. Empty for raw-value representations,
  /// which have no object fields.
  public var fieldIdentifiers: [(name: TokenSyntax, identifier: ExprSyntax)] {
    self.object?.fieldIdentifiers ?? []
  }

  private var access: String { self.configuration.accessPrefix }
  private var inline: String { self.configuration.inlinableAttribute() }

  // MARK: - Partial

  /// Generates the partial representation.
  ///
  /// Raw-value representations produce `typealias Partial`. `.caseKeyedObject` produces the
  /// partial struct, whose view gains `ResolvedView` and `resolved`, followed by one namespace per
  /// case with associated values, holding that payload's `Partial` and `Value`.
  ///
  /// The hooks apply to the top-level object partial exactly as in
  /// `StreamObjectGeneration.structDeclarationSyntax`. `ResolvedView` and `resolved` are reserved
  /// view member names. A raw-value partial is a library type, so non-empty hooks throw
  /// `StreamObjectGenerationError.hooksRequireObjectRepresentation`.
  public func partialSyntax(
    in context: some MacroExpansionContext,
    @MemberBlockItemListBuilder additionalMembers:
      () throws -> MemberBlockItemListSyntax = { [] },
    @MemberBlockItemListBuilder additionalViewMembers:
      () throws -> MemberBlockItemListSyntax = { [] },
    @CodeBlockItemListBuilder onFieldRecognized:
      (ExprSyntax, ExprSyntax) throws -> CodeBlockItemListSyntax = { _, _ in [] }
  ) throws -> MemberBlockItemListSyntax {
    guard let object = self.object else {
      guard try additionalMembers().isEmpty, try additionalViewMembers().isEmpty,
        try onFieldRecognized(ExprSyntax("self"), ExprSyntax("field")).isEmpty
      else {
        throw StreamObjectGenerationError.hooksRequireObjectRepresentation
      }
      let partial =
        if case .numericRawValue(let type) = self.representation {
          type.trimmedDescription
        } else {
          "StreamParsingCore.StreamString"
        }
      return streamParsedMembers("\(self.access)typealias Partial = \(partial)")
    }

    let resolved = streamParsedMembers(self.resolvedViewSource())
    let partial = try object.structDeclarationSyntax(
      in: context,
      additionalMembers: additionalMembers,
      additionalViewMembers: {
        resolved
        try additionalViewMembers()
      },
      onFieldRecognized: onFieldRecognized
    )
    var sources = [partial.trimmedDescription]
    for payload in self.entries.compactMap(\.payload) {
      let generation = payload.generation
      let stored = generation.fields
        .map { "\(self.access)var \(StreamObjectGeneration.memberName($0.name)): \($0.type.trimmedDescription)" }
        .joined(separator: "\n")
      // `Value` has one stored property per associated value, so the conversions that rebuild a
      // struct from its partial also rebuild the payload a case is constructed from. Validated in
      // `init`, so the conversions cannot throw.
      sources.append(
        """
        \(self.access)enum \(payload.typeName) {
        \(streamIndented(try generation.structDeclarationSyntax(in: context).trimmedDescription, by: 2))

          \(self.access)struct Value: \(TypeSyntax.streamParseable) {
        \(streamIndented(stored, by: 4))

            \(self.access)typealias Partial = \(payload.typeName).Partial

        \(streamIndented(try! generation.conversionsSyntax().trimmedDescription, by: 4))
          }
        }
        """
      )
    }
    return streamParsedMembers(sources.joined(separator: "\n\n"))
  }

  // The read side groups every case's view under one switch, so a case can be read mid-stream
  // without materialising a snapshot. Multi-pattern `case` labels are not implemented for a
  // `~Copyable` match on Swift 6.3/6.4, so every arm is single-pattern. It lives on `View`,
  // reaching through the view's storage: a `Partial` value's own address via
  // `withUnsafePointer(to:)` would dangle once the getter returns.
  private func resolvedViewSource() -> String {
    guard !self.entries.isEmpty else { return "" }
    let mode = self.configuration.viewMode
    let viewCases = self.entries
      .map { entry in
        entry.payload.map { "  case \(entry.name)(\($0.typeName).Partial.View)" }
          ?? "  case \(entry.name)"
      }
      .joined(separator: "\n")
    let resolveArms = self.entries.enumerated()
      .map { index, entry in
        guard let payload = entry.payload else {
          return "case \(index):\n  return .\(entry.name)"
        }
        let view = ".\(entry.name)(\(payload.typeName).Partial.streamView(streamAddress))"
        return """
          case \(index):
            guard let streamAddress = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.\(entry.name)) else {
              return .unresolved
            }
            return \(mode.borrowedView(view))
          """
      }
      .joined(separator: "\n")
    return """
      \(mode.unsafeAttribute)\(self.access)enum ResolvedView: \(mode.viewConstraints) {
        case unresolved
        case ambiguous
      \(viewCases)
      }

      \(self.inline)\(self.access)var resolved: ResolvedView {
        \(mode.lifetimeAttribute(borrowing: "self", indentation: "  "))get {
      \(streamIndented(self.countArms(storage: "self._streamStorage.pointee"), by: 4))
          guard streamMatches == 1 else {
            if streamMatches == 0 {
              return .unresolved
            }
            return .ambiguous
          }
          switch streamMatched {
      \(streamIndented(resolveArms, by: 4))
          default:
            return .unresolved
          }
        }
      }
      """
  }

  /// Counts the present case members, remembering the last. Exactly one must be present, which
  /// is what `JSONDecoder` accepts for the same document.
  private func countArms(storage: String) -> String {
    let arms = self.entries.enumerated().map { index, entry in
      """
      if \(storage).\(entry.name) != nil {
        streamMatched = \(index)
        streamMatches += 1
      }
      """
    }
    return (["var streamMatched = -1", "var streamMatches = 0"] + arms).joined(separator: "\n")
  }

  // MARK: - Conversions

  /// Generates `streamPartialValue`, `init?(_:)`, and `init?(streamPartial:)`, plus
  /// `init(orInitial:)` and `streamValueOrInitial(from:)` when there is a default case.
  ///
  /// `streamPartialValue` follows `partialValueInlining`, or when it is `nil`,
  /// `configuration.inlining` for raw values and `.never` for `.caseKeyedObject`: an inlinable
  /// `switch self` over a public enum that isn't `@frozen` does not compile under library
  /// evolution. The other members follow `configuration.inlining`.
  public func conversionsSyntax(
    partialValueInlining: StreamInliningMode? = nil
  ) -> MemberBlockItemListSyntax {
    var sources = [
      self.streamPartialValueSource(inlining: partialValueInlining),
      self.configuration.unlabelledInitializerSource(isStrict: true),
      streamDeclarationSource(
        "\(self.inline)\(self.access)init?(streamPartial partial: Partial)",
        body: self.strictBody()
      ),
    ]
    if let defaultCase = self.defaultCase {
      sources.append(
        streamDeclarationSource(
          "\(self.inline)\(self.access)init(orInitial partial: Partial)",
          body: self.fallbackBody(defaultCase)
        )
      )
      sources.append(self.configuration.streamValueOrInitialSource)
    }
    return streamParsedMembers(sources.joined(separator: "\n\n"))
  }

  private func streamPartialValueSource(inlining: StreamInliningMode?) -> String {
    let body: String
    var inlining = inlining
    switch self.representation {
    case .stringRawValue:
      body = "self.rawValue.streamPartialValue"
    case .numericRawValue:
      body = "self.rawValue"
    default:
      inlining = inlining ?? .never
      let arms = self.entries.map { entry -> String in
        guard let payload = entry.payload else {
          return "case .\(entry.name):\n  return Partial(\(entry.name): StreamParsingCore.StreamEmptyObject())"
        }
        let fields = payload.generation.fields
        let names = fields.map { StreamObjectGeneration.memberName($0.name) }
        let arguments = zip(fields, names)
          .map { "\($1): \(StreamObjectGeneration.partialValueExpression(for: $0, value: $1))" }
          .joined(separator: ", ")
        return """
          case .\(entry.name)(\(names.map { "let \($0)" }.joined(separator: ", "))):
            return Partial(\(entry.name): \(payload.typeName).Partial(\(arguments)))
          """
      }
      body = arms.isEmpty ? "switch self {}" : "switch self {\n\(arms.joined(separator: "\n"))\n}"
    }
    return streamDeclarationSource(
      "\(self.configuration.inlinableAttribute(inlining))\(self.access)var streamPartialValue: Partial",
      body: body
    )
  }

  private func strictBody() -> String {
    switch self.representation {
    case .stringRawValue: self.stringMatchBody()
    case .numericRawValue: "self.init(rawValue: partial)"
    default: self.objectResolveBody()
    }
  }

  // The `String`-raw matcher, in two stages. Stage one is the exact match a complete value hits:
  // the little-endian word switch also used for object keys, which the compiler turns into a
  // jump table. Stage two, reached only on a miss, is the prefix chain. A partial carries no
  // end-of-string signal, so a mid-flight read assumes the shortest case still consistent with
  // the bytes in hand, by emitting the chain sorted by length.
  private func stringMatchBody() -> String {
    let candidates = self.entries.flatMap { entry in entry.keys.map { (key: $0, name: entry.name) } }
    let exactArms = candidates.map { candidate in
      let label = streamWordCaseLabel(
        candidate.key,
        input: "partial",
        byteCount: DeclReferenceExprSyntax(baseName: .identifier("streamCount"))
      )
      return "\(label):\n  self = .\(candidate.name)\n  return"
    }
    // Stable within a length, so declaration order breaks ties.
    let prefixArms = candidates.enumerated()
      .sorted {
        let left = $0.element.key.utf8.count
        let right = $1.element.key.utf8.count
        return left == right ? $0.offset < $1.offset : left < right
      }
      .map { _, candidate in
        """
        if partial.isPrefix(of: \(StringLiteralExprSyntax(content: candidate.key).trimmedDescription)) {
          self = .\(candidate.name)
          return
        }
        """
      }

    // An empty accumulation is a prefix of every case, so shortest-wins would resolve it the
    // instant the opening quote arrived and then change as the real bytes land. Declining keeps
    // the progression monotone. The guard is omitted when a case spells `""`, where zero bytes
    // are a value rather than an absence.
    var lines = [String]()
    if !exactArms.isEmpty { lines.append("let streamCount = partial.utf8Count") }
    if !candidates.contains(where: { $0.key.isEmpty }) {
      let count = exactArms.isEmpty ? "partial.utf8Count" : "streamCount"
      lines.append("guard \(count) > 0 else {\n  return nil\n}")
    }
    if !exactArms.isEmpty {
      lines.append("switch partial.paddedLeadingWord() {")
      lines.append(contentsOf: exactArms)
      lines.append("default:\n  break\n}")
    }
    lines.append(contentsOf: prefixArms)
    lines.append("return nil")
    return lines.joined(separator: "\n")
  }

  // Which case arrived is which member is non-`nil`. The first pass only counts, because a
  // payload-bearing case can also fail by having arrived incomplete; the second extracts the one
  // identified payload or declines.
  private func objectResolveBody() -> String {
    let arms = self.entries.enumerated()
      .map { index, entry in
        guard let payload = entry.payload else {
          return "case \(index):\n  self = .\(entry.name)"
        }
        return """
          case \(index):
            guard let streamValue = \(payload.typeName).Value(streamPartial: partial.\(entry.name)!) else {
              return nil
            }
            self = .\(entry.name)(\(Self.caseArguments(payload, from: "streamValue")))
          """
      }
      .joined(separator: "\n")
    return """
      \(self.countArms(storage: "partial"))
      guard streamMatches == 1 else {
        return nil
      }
      switch streamMatched {
      \(arms)
      default:
        return nil
      }
      """
  }

  // A default case without a payload falls back to itself. One with associated values fills its
  // payload the way a struct fills absent members, through the payload `Value`'s total conversion.
  private func fallbackBody(_ defaultCase: TokenSyntax) -> String {
    let name = StreamObjectGeneration.memberName(defaultCase)
    guard let payload = self.entries.first(where: { $0.name == name })?.payload else {
      return "self = Self(streamPartial: partial) ?? .\(name)"
    }
    return """
      if let streamMatched = Self(streamPartial: partial) {
        self = streamMatched
        return
      }
      let streamDefaultValue = \(payload.typeName).Value.streamValueOrInitial(
        from: partial.\(name) ?? \(payload.typeName).Partial.streamInitialValue()
      )
      self = .\(name)(\(Self.caseArguments(payload, from: "streamDefaultValue")))
      """
  }

  /// Arguments constructing a case from a payload `Value`, labelled where the case declares one.
  private static func caseArguments(_ payload: Payload, from source: String) -> String {
    zip(payload.generation.fields, payload.isLabeled)
      .map { field, isLabeled in
        let value = "\(source).\(StreamObjectGeneration.memberName(field.name))"
        return isLabeled ? "\(StreamObjectGeneration.bareName(field.name)): \(value)" : value
      }
      .joined(separator: ", ")
  }

  /// `text` becomes `TextPayload`. The suffix keeps it clear of Swift keywords.
  package static func defaultPayloadTypeName(forCaseNamed bareName: String) -> String {
    guard let first = bareName.first else { return "Payload" }
    return first.uppercased() + bareName.dropFirst() + "Payload"
  }
}
