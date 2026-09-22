import SwiftSyntax
import SwiftSyntaxBuilder

/// A stored property of the whole type that is absent from the partial and has no initializer.
///
/// Every generated conversion initializer assigns it `value`. A property that declares its own
/// initializer is already set and must not be listed; for a `let`, a second assignment does not
/// compile.
public struct StreamUnparsedMember: Sendable {
  /// The Swift member identifier, including backticks when already escaped.
  public var name: TokenSyntax
  /// The expression assigned by the conversion initializers.
  public var value: ExprSyntax

  /// Creates an unparsed member assigned `value`, which is `nil` by default.
  public init(name: TokenSyntax, value: some ExprSyntaxProtocol = NilLiteralExprSyntax()) {
    self.name = name
    self.value = ExprSyntax(value)
  }
}

extension StreamObjectGeneration {
  /// Generates the members that make the whole type `StreamParseable` against this plan's
  /// partial: `streamPartialValue`, `init?(streamPartial:)`, `init(orInitial:)`,
  /// `streamValueOrInitial(from:)`, and an unlabelled `init(_:)`.
  ///
  /// Place the result in an extension of the whole type rather than its body: initializers
  /// declared in the body suppress the memberwise initializer. Each field's `name` must name a
  /// stored property of the whole type whose type is the field's `type`.
  ///
  /// The unlabelled initializer follows `partialMembers`: with `.optional`, absence is visible,
  /// so it is the failable strict conversion; with `.streamInitialValue`, it is the total one.
  /// A configured partial type name other than `Partial` also emits `typealias Partial`.
  ///
  /// `init(orInitial:)` falls back to each member's stream initial value, recursively. A
  /// converted member has no such value, so a nonoptional one falls back to its `defaultValue`.
  ///
  /// - Parameters:
  ///   - unparsedMembers: Stored properties absent from the partial that have no initializer.
  ///   - partialValueInlining: Inlining for `streamPartialValue`, the only generated member that
  ///     reads the whole type's stored properties. `nil` uses `configuration.inlining`. The plan
  ///     doesn't check that those properties are readable from an inlinable context; a host
  ///     whose properties are less visible than the type passes `.never`.
  /// - Throws: `StreamObjectGenerationError.missingCompletedConversionDefault` for a nonoptional
  ///   converted field without a `defaultValue`, and `.duplicateField` for an unparsed member
  ///   that repeats a name. A plan created with `diagnosedFields:` skips these checks and emits
  ///   recovery syntax instead.
  public func conversionsSyntax(
    unparsedMembers: [StreamUnparsedMember] = [],
    partialValueInlining: StreamInliningMode? = nil
  ) throws -> MemberBlockItemListSyntax {
    if self.isValidated {
      try self.validateConversions(unparsedMembers: unparsedMembers)
    }
    let partialName = self.configuration.names.partialType.trimmedDescription
    let typealiasDeclaration =
      partialName == TokenSyntax.streamPartial.text
      ? "" : "\(self.access)typealias Partial = \(partialName)\n\n"
    var members = self.members(
      typealiasDeclaration
        + self.streamPartialValueSource(inlining: partialValueInlining ?? self.configuration.inlining)
        + "\n\n"
        + self.initializersSource(unparsedMembers: unparsedMembers)
    )
    // The list ends where its last declaration does, so a host controls the spacing around it.
    members[members.index(before: members.endIndex)].trailingTrivia = []
    return members
  }

  private func validateConversions(unparsedMembers: [StreamUnparsedMember]) throws {
    for field in self.fields
    where field.completedConversion != nil && !field.type.streamIsOptional
      && field.defaultValue == nil
    {
      throw StreamObjectGenerationError.missingCompletedConversionDefault(
        field: Self.bareName(field.name)
      )
    }
    // A repeated name still compiles: its later assignment silently replaces the parsed value.
    var names = Set(self.fields.map { Self.bareName($0.name) })
    for member in unparsedMembers {
      let name = Self.bareName(member.name)
      guard names.insert(name).inserted else {
        throw StreamObjectGenerationError.duplicateField(name)
      }
    }
  }

  // MARK: - Whole to partial

  private func streamPartialValueSource(inlining: StreamInliningMode) -> String {
    let inline = self.isInlinable(inlining) ? "@inlinable " : ""
    guard !self.fields.isEmpty else {
      return """
        \(inline)\(self.access)var streamPartialValue: Partial {
          Partial()
        }
        """
    }
    let arguments = self.fields
      .map { "    \(Self.memberName($0.name)): \(self.partialValueExpression(for: $0))" }
      .joined(separator: ",\n")
    return """
      \(inline)\(self.access)var streamPartialValue: Partial {
        Partial(
      \(arguments)
        )
      }
      """
  }

  private func partialValueExpression(for field: StreamParseableField) -> String {
    let member = "self.\(Self.memberName(field.name))"
    let isOptional = field.type.streamIsOptional
    if let conversion = field.completedConversion {
      let wrapper = "StreamParsingCore.ConvertedPartial<\(conversion.trimmedDescription)>"
      return isOptional ? "\(member).map { \(wrapper)(value: $0) }" : "\(wrapper)(value: \(member))"
    }
    // Only the `[K: V]` spelling: `Dictionary<K, V>` goes through `Dictionary.streamPartialValue`,
    // which inserts keys sorted where `mapValues` keeps hash order. The two are kept distinct so
    // existing expansions keep their key order.
    if field.type.streamUnwrappedOptionalType.is(DictionaryTypeSyntax.self) {
      // The values are converted and rewrapped rather than using `Dictionary.streamPartialValue`.
      // An optional member maps through the optional; `mapValues` on it does not compile.
      let converted = "StreamParsingCore.StreamDictionary($0.mapValues(\\.streamPartialValue))"
      return isOptional
        ? "\(member).map { \(converted) }"
        : "StreamParsingCore.StreamDictionary(\(member).mapValues(\\.streamPartialValue))"
    }
    return "\(member).streamPartialValue"
  }

  // MARK: - Partial to whole

  // Nothing here spells a member's type: `_streamValue`/`_streamValueOrInitial` bind it from the
  // property itself, so the type used to derive the partial member is checked, not trusted.
  // Only the delegating members can be `@inlinable`: under library evolution an inlinable
  // initializer that assigns stored properties does not compile.
  private func initializersSource(unparsedMembers: [StreamUnparsedMember]) -> String {
    let unparsedLines = unparsedMembers.map {
      "  self.\(Self.memberName($0.name)) = \($0.value.trimmedDescription)"
    }

    let strictBody: String
    if self.fields.isEmpty {
      strictBody = unparsedLines.joined(separator: "\n")
    } else {
      let bindings = self.fields
        .map { field -> String in
          let name = Self.memberName(field.name)
          guard field.completedConversion != nil else {
            return "    let \(name) = Self._streamValue({ $0.\(name) }, partial.\(name))"
          }
          let helper =
            field.type.streamIsOptional ? "_streamOptionalConvertedValue" : "_streamConvertedValue"
          return "    let \(name) = \(helper)(partial.\(name))"
        }
        .joined(separator: ",\n")
      let stores = self.fields.map {
        let name = Self.memberName($0.name)
        return "  self.\(name) = \(name)"
      }
      strictBody = """
          guard
        \(bindings)
          else {
            return nil
          }
        \((stores + unparsedLines).joined(separator: "\n"))
        """
    }

    let totalAssignments = self.fields
      .map { field -> String in
        let name = Self.memberName(field.name)
        guard field.completedConversion != nil else {
          return "  self.\(name) = Self._streamValueOrInitial({ $0.\(name) }, partial.\(name))"
        }
        let fallback =
          field.type.streamIsOptional ? "nil" : (field.defaultValue?.trimmedDescription ?? "nil")
        return "  self.\(name) = _streamConvertedValue(partial.\(name)) ?? (\(fallback))"
      }
    let totalBody = (totalAssignments + unparsedLines).joined(separator: "\n")

    let unlabelled =
      self.partialMembers == .optional
      ? """
        \(self.inline)\(self.access)init?(_ partial: Partial) {
          self.init(streamPartial: partial)
        }
        """
      : """
        \(self.inline)\(self.access)init(_ partial: Partial) {
          self.init(orInitial: partial)
        }
        """

    return """
      \(unlabelled)

      \(self.access)init?(streamPartial partial: Partial) {
      \(strictBody)
      }

      \(self.access)init(orInitial partial: Partial) {
      \(totalBody)
      }

      \(self.inline)\(self.access)static func streamValueOrInitial(from partial: Partial) -> Self {
        Self(orInitial: partial)
      }
      """
  }
}
