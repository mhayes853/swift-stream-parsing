import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public enum StreamParseableMacro: ExtensionMacro, MemberMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingMembersOf declaration: some DeclGroupSyntax,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    let structDecl = try Self.requireStructDecl(declaration: declaration)

    let properties = Self.storedProperties(in: structDecl, context: context)
    let accessModifier = Self.accessModifier(for: structDecl)
    let hasStreamPartialValue = Self.hasExistingStreamPartialValue(in: structDecl)
    let modifierPrefix = Self.modifierPrefix(for: accessModifier)
    let streamPartialValuePropertySection =
      !hasStreamPartialValue
      ? Self.streamPartialValueProperty(from: properties, modifierPrefix: modifierPrefix)
      : ""
    return ["\(raw: streamPartialValuePropertySection)"]
  }

  public static func expansion(
    of node: AttributeSyntax,
    attachedTo declaration: some DeclGroupSyntax,
    providingExtensionsOf type: some TypeSyntaxProtocol,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [ExtensionDeclSyntax] {
    let structDecl = try Self.requireStructDecl(declaration: declaration)

    let typeName = structDecl.name.text
    let properties = Self.storedProperties(in: structDecl, context: context)
    let hasExistingPartial = Self.hasExistingPartial(in: structDecl)
    let accessModifier = Self.accessModifier(for: structDecl)
    let membersMode = Self.partialMembersMode(from: node)

    if hasExistingPartial {
      return [
        try ExtensionDeclSyntax(
          """
          extension \(raw: typeName): StreamParsingCore.StreamParseable {}
          """
        )
      ]
    }

    let partialStruct = Self.partialStructDecl(
      for: properties,
      accessModifier: accessModifier,
      membersMode: membersMode,
      baseTypeName: typeName
    )
    return [
      try ExtensionDeclSyntax(
        """
        extension \(raw: typeName): StreamParsingCore.StreamParseable {
          \(partialStruct)
        }
        """
      )
    ]
  }

  private static func requireStructDecl(
    declaration: some DeclGroupSyntax
  ) throws -> StructDeclSyntax {
    guard let structDecl = declaration.as(StructDeclSyntax.self) else {
      throw MacroExpansionErrorMessage(
        "@StreamParseable can only be applied to struct declarations."
      )
    }
    return structDecl
  }

  private static func isStatic(_ variableDecl: VariableDeclSyntax) -> Bool {
    variableDecl.modifiers.contains { $0.name.tokenKind == .keyword(.static) }
  }

  private static func hasExistingPartial(in declaration: StructDeclSyntax) -> Bool {
    declaration.memberBlock.members.contains { member in
      guard let structDecl = member.decl.as(StructDeclSyntax.self) else {
        return false
      }

      return structDecl.name.text == "Partial"
    }
  }

  private static func hasExistingStreamPartialValue(
    in declaration: StructDeclSyntax
  ) -> Bool {
    for member in declaration.memberBlock.members {
      guard let variableDecl = member.decl.as(VariableDeclSyntax.self),
        !self.isStatic(variableDecl)
      else {
        continue
      }

      for binding in variableDecl.bindings {
        guard
          let identifierPattern = binding.pattern.as(IdentifierPatternSyntax.self),
          identifierPattern.identifier.text == "streamPartialValue"
        else {
          continue
        }

        return true
      }
    }

    return false
  }

  private static func partialStructDecl(
    for properties: [StoredProperty],
    accessModifier: String?,
    membersMode: PartialMembersMode,
    baseTypeName: String
  ) -> DeclSyntax {
    let modifierPrefix = Self.modifierPrefix(for: accessModifier)
    let propertyLines = Self.partialStructProperties(
      from: properties,
      modifierPrefix: modifierPrefix,
      membersMode: membersMode
    )
    let initializerLines = Self.partialStructInitializer(
      from: properties,
      modifierPrefix: modifierPrefix,
      membersMode: membersMode
    )
    let schemaLines = Self.partialStructSchema(
      from: properties,
      modifierPrefix: modifierPrefix,
      membersMode: membersMode
    )
    let snapshotLines = Self.partialStructSnapshot(
      from: properties,
      modifierPrefix: modifierPrefix
    )
    return """
      \(raw: modifierPrefix)struct Partial: StreamParsingCore.StreamParseable,
        StreamParsingCore.StreamParseableObject {
        \(raw: modifierPrefix)typealias Partial = Self

      \(raw: propertyLines)

        \(raw: initializerLines)

        \(raw: modifierPrefix)static func streamInitialValue() -> Self {
          Self()
        }

        \(raw: snapshotLines)

        \(raw: schemaLines)
      }
      """
  }

  // Every member is rebuilt rather than copied, because a member that holds a heap buffer shares
  // it with the value being parsed and the sink writes into that buffer through a raw pointer.
  // Scalars take the protocol's default and copy nothing.
  private static func partialStructSnapshot(
    from properties: [StoredProperty],
    modifierPrefix: String
  ) -> String {
    let active = properties.filter { !$0.isIgnored }
    guard !active.isEmpty else {
      return """
        \(modifierPrefix)func streamSnapshot() -> Self {
            Self()
          }
        """
    }
    let arguments = active.enumerated()
      .map { index, property in
        let comma = index == active.count - 1 ? "" : ","
        return "      \(property.name): self.\(property.name).streamSnapshot()\(comma)"
      }
      .joined(separator: "\n")
    return """
      \(modifierPrefix)func streamSnapshot() -> Self {
          Self(
      \(arguments)
          )
        }
      """
  }

  // Computed at expansion time rather than matched at runtime. Zero padding discriminates keys
  // shorter than the word, so only those can skip the length check.
  private static func paddedLeadingWord(for key: String) -> UInt64 {
    var word: UInt64 = 0
    for (offset, byte) in Array(key.utf8).prefix(8).enumerated() {
      word |= UInt64(byte) << (offset * 8)
    }
    return word
  }

  private static func keyWordLiteral(for key: String) -> String {
    let word = Self.paddedLeadingWord(for: key)
    let digits = Array("0123456789ABCDEF")
    var hex = ""
    for shift in stride(from: 60, through: 0, by: -4) {
      hex.append(digits[Int((word >> UInt64(shift)) & 0xF)])
    }
    var grouped = [String]()
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 4)
      grouped.append(String(hex[index..<next]))
      index = next
    }
    return "0x" + grouped.joined(separator: "_")
  }

  private enum FieldShape {
    case scalarOrObject(String)
    case array(String)
    case dictionary(String)
  }

  private static func fieldShape(for type: TypeSyntax) -> FieldShape {
    var unwrapped = type
    if let optional = type.as(OptionalTypeSyntax.self) { unwrapped = optional.wrappedType }
    if let array = unwrapped.as(ArrayTypeSyntax.self) {
      return .array(array.element.trimmedDescription)
    }
    if let dictionary = unwrapped.as(DictionaryTypeSyntax.self) {
      return .dictionary(dictionary.value.trimmedDescription)
    }
    return .scalarOrObject(unwrapped.trimmedDescription)
  }

  private static func schemaExpression(for type: TypeSyntax) -> String {
    var unwrapped = type
    if let optional = type.as(OptionalTypeSyntax.self) { unwrapped = optional.wrappedType }
    if let array = unwrapped.as(ArrayTypeSyntax.self) {
      let element = array.element.trimmedDescription
      return
        "_streamArraySchema(\(element).Partial.self, element: \(Self.schemaExpression(for: array.element)))"
    }
    if let dictionary = unwrapped.as(DictionaryTypeSyntax.self) {
      let value = dictionary.value.trimmedDescription
      return
        "_streamDictionarySchema(\(value).Partial.self, value: \(Self.schemaExpression(for: dictionary.value)))"
    }
    return "_streamSchema(for: \(unwrapped.trimmedDescription).Partial.self)"
  }

  private static func partialStructSchema(
    from properties: [StoredProperty],
    modifierPrefix: String,
    membersMode: PartialMembersMode
  ) -> String {
    let active = properties.filter { !$0.isIgnored }

    var matchCases = [String]()
    var applyStringCases = [String]()
    var applyNumberCases = [String]()
    var applyBooleanCases = [String]()
    var applyNullCases = [String]()
    var enterCases = [String]()

    for (index, property) in active.enumerated() {
      for key in property.keyNames {
        let word = Self.keyWordLiteral(for: key)
        // Zero padding only discriminates keys shorter than the word. A key of exactly eight
        // bytes shares its word with any longer key having the same prefix, so it needs the
        // length check too.
        let guardClause = key.utf8.count >= 8 ? " where key.count == \(key.utf8.count)" : ""
        matchCases.append(
          "    case \(word)\(guardClause): return \(index)  // \"\(key)\""
        )
      }

      let target = "p.pointee.\(property.name)"
      switch Self.fieldShape(for: property.type) {
      case .scalarOrObject:
        // Emitted into every scalar switch: the macro cannot tell from syntax which token kind
        // the type accepts, so overload resolution decides and the dead cases optimize away.
        applyStringCases.append(
          "    case \(index): return streamApply(&\(target), utf8: bytes)"
        )
        applyNumberCases.append(
          "    case \(index): return streamApply(&\(target), bytes: bytes, info: info)"
        )
        applyBooleanCases.append(
          "    case \(index): return streamApply(&\(target), boolean: value)"
        )
        applyNullCases.append(
          "    case \(index): return StreamParsing.streamApplyNull(&\(target))"
        )
        enterCases.append("    case \(index): return _streamEnterField(&\(target))")
      case .array(let element):
        let elementSchema = Self.schemaExpression(
          for: TypeSyntax(stringLiteral: element)
        )
        enterCases.append(
          """
              case \(index):
                return _streamEnterArrayField(&\(target), element: \(elementSchema))
          """
        )
      case .dictionary(let value):
        let valueSchema = Self.schemaExpression(
          for: TypeSyntax(stringLiteral: value)
        )
        enterCases.append(
          """
              case \(index):
                return _streamEnterDictionaryField(&\(target), value: \(valueSchema))
          """
        )
      }
    }

    func switchBody(_ cases: [String]) -> String {
      cases.isEmpty ? "" : cases.joined(separator: "\n") + "\n"
    }

    return """
      \(modifierPrefix)static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
          switch key.paddedLeadingWord() {
      \(switchBody(matchCases))    default: return -1
          }
        }

        \(modifierPrefix)static func streamApplyString(
          _ storage: UnsafeMutableRawPointer, _ field: Int32,
          _ bytes: Span<UInt8>
        ) -> Bool {
          let p = storage.assumingMemoryBound(to: Self.self)
          switch field {
      \(switchBody(applyStringCases))    default: return false
          }
        }

        \(modifierPrefix)static func streamApplyNumber(
          _ storage: UnsafeMutableRawPointer, _ field: Int32,
          _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
        ) -> Bool {
          let p = storage.assumingMemoryBound(to: Self.self)
          switch field {
      \(switchBody(applyNumberCases))    default: return false
          }
        }

        \(modifierPrefix)static func streamApplyBoolean(
          _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
        ) -> Bool {
          let p = storage.assumingMemoryBound(to: Self.self)
          switch field {
      \(switchBody(applyBooleanCases))    default: return false
          }
        }

        \(modifierPrefix)static func streamApplyNull(
          _ storage: UnsafeMutableRawPointer, _ field: Int32
        ) -> Bool {
          let p = storage.assumingMemoryBound(to: Self.self)
          switch field {
      \(switchBody(applyNullCases))    default: return false
          }
        }

        \(modifierPrefix)static func streamEnterField(
          _ storage: UnsafeMutableRawPointer, _ field: Int32
        ) -> StreamParsingCore.StreamFrame? {
          let p = storage.assumingMemoryBound(to: Self.self)
          switch field {
      \(switchBody(enterCases))    default: return nil
          }
        }

        \(modifierPrefix)static let streamSchema = StreamParsingCore.StreamSchema(
          shape: .object,
          matchField: Self.streamMatchField,
          applyString: Self.streamApplyString,
          applyNumber: Self.streamApplyNumber,
          applyBoolean: Self.streamApplyBoolean,
          applyNull: Self.streamApplyNull,
          enterField: Self.streamEnterField
        )
      """
  }

  private static func partialStructProperties(
    from properties: [StoredProperty],
    modifierPrefix: String,
    membersMode: PartialMembersMode
  ) -> String {
    let lines = properties.filter { !$0.isIgnored }
      .map { property in
        let optionalSuffix = membersMode.shouldEmitOptionalMembers ? "?" : ""
        return
          "  \(modifierPrefix)var \(property.name): \(Self.partialTypeName(for: property))\(optionalSuffix)"
      }
    return lines.joined(separator: "\n")
  }

  // A dictionary member becomes a StreamDictionary so the parser can hold a pointer into a
  // value while it streams. Dictionary relocates its values on insertion, which would make
  // partial updates impossible.
  private static func partialTypeName(for property: StoredProperty) -> String {
    if case .dictionary(let value) = Self.fieldShape(for: property.type) {
      return "StreamParsingCore.StreamDictionary<\(value).Partial>"
    }
    return "\(property.typeName).Partial"
  }

  private static func partialStructInitializer(
    from properties: [StoredProperty],
    modifierPrefix: String,
    membersMode: PartialMembersMode
  ) -> String {
    let activeProperties = properties.filter { !$0.isIgnored }
    let parameters =
      activeProperties
      .map { property in
        let optionalSuffix = membersMode.shouldEmitOptionalMembers ? "?" : ""
        return
          "\(property.name): \(Self.partialTypeName(for: property))\(optionalSuffix) = \(membersMode.defaultValueSyntax)"
      }
      .joined(separator: ",\n    ")
    let assignments =
      activeProperties
      .map { property in
        "    self.\(property.name) = \(property.name)"
      }
      .joined(separator: "\n")
    return """
      \(modifierPrefix)init(
          \(parameters)
        ) {
      \(assignments)
        }
      """
  }

  private static func streamPartialValueProperty(
    from properties: [StoredProperty],
    modifierPrefix: String
  ) -> String {
    let activeProperties = properties.filter { !$0.isIgnored }
    guard !activeProperties.isEmpty else {
      return """
          \(modifierPrefix)var streamPartialValue: Partial {
            Partial()
          }
        """
    }

    let argumentLines = activeProperties.enumerated()
      .map { index, property in
        let suffix = index == activeProperties.count - 1 ? "" : ","
        if case .dictionary = Self.fieldShape(for: property.type) {
          let mapped = "self.\(property.name).mapValues(\\.streamPartialValue)"
          return
            "    \(property.name): StreamParsingCore.StreamDictionary(\(mapped))\(suffix)"
        }
        return "    \(property.name): self.\(property.name).streamPartialValue\(suffix)"
      }
      .joined(separator: "\n")

    return """
      \(modifierPrefix)var streamPartialValue: Partial {
        Partial(
      \(argumentLines)
        )
      }
      """
  }

  private static func accessModifier(for declaration: StructDeclSyntax) -> String? {
    for modifier in declaration.modifiers {
      switch modifier.name.tokenKind {
      case .keyword(.public):
        return "public"
      case .keyword(.fileprivate):
        return "fileprivate"
      case .keyword(.private):
        return nil
      default:
        continue
      }
    }
    return nil
  }

  private static func modifierPrefix(for accessModifier: String?) -> String {
    accessModifier.map { "\($0) " } ?? ""
  }

  private static func isOptionalType(_ type: TypeSyntax) -> Bool {
    type.is(OptionalTypeSyntax.self) || type.is(ImplicitlyUnwrappedOptionalTypeSyntax.self)
  }

  private static func partialMembersMode(from node: AttributeSyntax) -> PartialMembersMode {
    guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else { return .optional }
    let modeArgument = arguments.first { $0.label?.text == "partialMembers" } ?? arguments.first
    guard let expression = modeArgument?.expression else { return .optional }
    return PartialMembersMode.parse(from: expression) ?? .optional
  }
}

// MARK: - StoredProperty

extension StreamParseableMacro {
  private struct StoredProperty {
    let name: String
    let type: TypeSyntax
    let typeName: String
    let keyNames: [String]
    let isIgnored: Bool
  }

  private struct KeyNamesResult {
    let names: [String]
    let diagnostics: [Diagnostic]
  }

  private static func storedProperties(
    in declaration: StructDeclSyntax,
    context: some MacroExpansionContext
  ) -> [StoredProperty] {
    var properties = [StoredProperty]()
    for member in declaration.memberBlock.members {
      guard let variableDecl = member.decl.as(VariableDeclSyntax.self) else {
        continue
      }
      properties.append(contentsOf: self.storedProperties(from: variableDecl, context: context))
    }
    return properties
  }

  private static func storedProperties(
    from variableDecl: VariableDeclSyntax,
    context: some MacroExpansionContext
  ) -> [StoredProperty] {
    if self.isStatic(variableDecl) {
      self.diagnoseUnsupportedStreamParseableMember(in: variableDecl, context: context)
      return []
    }

    var properties = [StoredProperty]()
    for binding in variableDecl.bindings {
      if self.isComputedProperty(binding) {
        self.diagnoseUnsupportedStreamParseableMember(in: variableDecl, context: context)
        continue
      }

      guard let identifierPattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
        continue
      }

      guard let type = binding.typeAnnotation?.type else {
        self.diagnoseMissingTypeAnnotation(in: binding, context: context)
        continue
      }

      properties.append(
        self.storedProperty(
          from: variableDecl,
          propertyName: identifierPattern.identifier.text,
          type: type,
          context: context
        )
      )
    }
    return properties
  }

  private static func storedProperty(
    from variableDecl: VariableDeclSyntax,
    propertyName: String,
    type: TypeSyntax,
    context: some MacroExpansionContext
  ) -> StoredProperty {
    let isIgnored = self.streamParseableIgnoredAttribute(in: variableDecl) != nil
    let hasStreamParseableMember = self.streamParseableMemberAttribute(in: variableDecl) != nil
    if isIgnored, hasStreamParseableMember {
      Self.diagnoseConflictingStreamParseableMemberAndIgnored(
        in: variableDecl,
        context: context
      )
    }

    let keyInfo =
      isIgnored
      ? KeyNamesResult(names: [propertyName], diagnostics: [])
      : Self.keyNames(for: variableDecl, defaultName: propertyName)
    let typeName = type.trimmedDescription
    for diagnostic in keyInfo.diagnostics {
      context.diagnose(diagnostic)
    }
    return StoredProperty(
      name: propertyName,
      type: type,
      typeName: typeName,
      keyNames: keyInfo.names,
      isIgnored: isIgnored
    )
  }

  private static func diagnoseMissingTypeAnnotation(
    in binding: PatternBindingSyntax,
    context: some MacroExpansionContext
  ) {
    context.diagnose(
      Diagnostic(
        node: binding,
        message: MacroExpansionErrorMessage(
          "Stored properties must declare an explicit type."
        )
      )
    )
  }

  private static func diagnoseUnsupportedStreamParseableMember(
    in variableDecl: VariableDeclSyntax,
    context: some MacroExpansionContext
  ) {
    guard let attribute = self.streamParseableMemberAttribute(in: variableDecl) else { return }
    context.diagnose(
      Diagnostic(
        node: attribute,
        message: MacroExpansionErrorMessage(
          "Only stored properties are supported."
        )
      )
    )
  }

  private static func diagnoseConflictingStreamParseableMemberAndIgnored(
    in variableDecl: VariableDeclSyntax,
    context: some MacroExpansionContext
  ) {
    guard let attribute = Self.streamParseableMemberAttribute(in: variableDecl) else { return }
    context.diagnose(
      Diagnostic(
        node: attribute,
        message: MacroExpansionErrorMessage(
          "@StreamParseableMember and @StreamParseableIgnored cannot be applied to the same property."
        )
      )
    )
  }

  private static func isComputedProperty(_ binding: PatternBindingSyntax) -> Bool {
    guard let accessorBlock = binding.accessorBlock else { return false }
    switch accessorBlock.accessors {
    case .getter:
      return true
    case .accessors(let accessors):
      for accessor in accessors {
        switch accessor.accessorSpecifier.tokenKind {
        case .keyword(.get), .keyword(.set):
          return true
        default:
          continue
        }
      }
      return false
    }
  }

  private static func keyNames(
    for variableDecl: VariableDeclSyntax,
    defaultName: String
  ) -> KeyNamesResult {
    let attributes = self.streamParseableMemberAttributes(in: variableDecl)
    guard !attributes.isEmpty else {
      return KeyNamesResult(names: [defaultName], diagnostics: [])
    }

    var names = [String]()
    var diagnostics = [Diagnostic]()

    for attribute in attributes {
      guard let arguments = attribute.arguments?.as(LabeledExprListSyntax.self) else {
        continue
      }

      if let keyExpression = self.argumentExpression(in: arguments, named: "key") {
        if let keyName = self.stringLiteralValue(from: keyExpression) {
          names.append(keyName)
        } else {
          diagnostics.append(
            Diagnostic(
              node: attribute,
              message: MacroExpansionErrorMessage(
                "@StreamParseableMember(key:) requires a string literal."
              )
            )
          )
        }
        continue
      }

      if let keyNamesExpression = self.argumentExpression(in: arguments, named: "keyNames") {
        if let keyNames = self.stringArrayValues(from: keyNamesExpression),
          !keyNames.isEmpty
        {
          names.append(contentsOf: keyNames)
        } else {
          diagnostics.append(
            Diagnostic(
              node: attribute,
              message: MacroExpansionErrorMessage(
                "@StreamParseableMember(keyNames:) requires a string array literal."
              )
            )
          )
        }
      }
    }

    return KeyNamesResult(
      names: names.isEmpty ? [defaultName] : names,
      diagnostics: diagnostics
    )
  }

  private static func streamParseableMemberAttribute(
    in variableDecl: VariableDeclSyntax
  ) -> AttributeSyntax? {
    self.streamParseableMemberAttributes(in: variableDecl).first
  }

  private static func streamParseableMemberAttributes(
    in variableDecl: VariableDeclSyntax
  ) -> [AttributeSyntax] {
    variableDecl.attributes
      .compactMap { $0.as(AttributeSyntax.self) }
      .filter { $0.attributeName.trimmedDescription == "StreamParseableMember" }
  }

  private static func streamParseableIgnoredAttribute(
    in variableDecl: VariableDeclSyntax
  ) -> AttributeSyntax? {
    variableDecl.attributes
      .compactMap { $0.as(AttributeSyntax.self) }
      .first { $0.attributeName.trimmedDescription == "StreamParseableIgnored" }
  }

  private static func argumentExpression(
    in arguments: LabeledExprListSyntax,
    named name: String
  ) -> ExprSyntax? {
    arguments.first { $0.label?.text == name }?.expression
  }

  private static func stringLiteralValue(from expression: ExprSyntax) -> String? {
    guard let literal = expression.as(StringLiteralExprSyntax.self) else { return nil }
    let segments = literal.segments.compactMap {
      $0.as(StringSegmentSyntax.self)?.content.text
    }
    let value = segments.joined()
    return value.isEmpty ? nil : value
  }

  private static func stringArrayValues(from expression: ExprSyntax) -> [String]? {
    guard let arrayExpression = expression.as(ArrayExprSyntax.self) else { return nil }
    let values = arrayExpression.elements.compactMap {
      self.stringLiteralValue(from: $0.expression)
    }
    return values.isEmpty ? nil : values
  }
}

// MARK: - PartialMembersMode

extension StreamParseableMacro {
  private enum PartialMembersMode: Hashable {
    case optional
    case initialParseableValue

    var defaultValueSyntax: String {
      switch self {
      case .optional: "nil"
      case .initialParseableValue: ".streamInitialValue()"
      }
    }

    var shouldEmitOptionalMembers: Bool {
      self == .optional
    }

    static func parse(from expression: ExprSyntax) -> Self? {
      switch self.memberName(from: expression) {
      case "optional": .optional
      case "initialParseableValue", "streamInitialValue": .initialParseableValue
      default: nil
      }
    }

    private static func memberName(from expression: ExprSyntax) -> String? {
      if let memberAccess = expression.as(MemberAccessExprSyntax.self) {
        return memberAccess.declName.baseName.text
      }
      if let reference = expression.as(DeclReferenceExprSyntax.self) {
        return reference.baseName.text
      }
      return nil
    }
  }
}
