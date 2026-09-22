import SwiftDiagnostics
import SwiftParser
import StreamParsingMacroSupport
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Both macro roles run the same readers over the same declaration, so only one of them may
/// diagnose or every message is emitted twice. The extension role gets a live sink; the member
/// role gets a discarding one.
struct DiagnosticSink {
  private let emit: ((Diagnostic) -> Void)?

  init(_ context: some MacroExpansionContext) {
    self.emit = { context.diagnose($0) }
  }

  init() {
    self.emit = nil
  }

  func diagnose(_ diagnostic: Diagnostic) {
    self.emit?(diagnostic)
  }
}

public enum StreamParseableMacro: ExtensionMacro, MemberMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingMembersOf declaration: some DeclGroupSyntax,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    let sink = DiagnosticSink()
    if let enumDecl = declaration.as(EnumDeclSyntax.self) {
      guard enumDecl.genericParameterClause == nil, !Self.isIndirect(enumDecl),
        !Self.diagnoseSelfReferentialPayloads(
          enumDecl, lexicalContext: context.lexicalContext, in: sink
        )
      else { return [] }
      return try Self.enumMemberExpansion(declaration: enumDecl, in: sink)
    }
    let structDecl = try Self.requireStructDecl(declaration: declaration)
    guard structDecl.genericParameterClause == nil else { return [] }

    guard !Self.hasExistingStreamPartialValue(in: structDecl.memberBlock.members) else {
      return []
    }
    let properties = Self.storedProperties(in: structDecl, context: sink)
    let accessModifier = Self.accessModifier(for: structDecl.modifiers)
    // The partial mode only picks the unlabelled initializer, which the extension emits.
    return [
      try Self.conversions(for: properties, accessModifier: accessModifier, membersMode: .optional)
        .streamPartialValue
    ]
  }

  public static func expansion(
    of node: AttributeSyntax,
    attachedTo declaration: some DeclGroupSyntax,
    providingExtensionsOf type: some TypeSyntaxProtocol,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [ExtensionDeclSyntax] {
    let sink = DiagnosticSink(context)
    if let enumDecl = declaration.as(EnumDeclSyntax.self) {
      guard !Self.diagnoseGenericParameters(enumDecl.genericParameterClause, in: sink),
        !Self.diagnoseIndirectEnum(enumDecl, in: sink),
        !Self.diagnoseSelfReferentialPayloads(
          enumDecl, lexicalContext: context.lexicalContext, in: sink
        )
      else {
        return []
      }
      return try Self.enumExtensionExpansion(
        of: node, declaration: enumDecl, type: type, in: sink, expansionContext: context
      )
    }
    let structDecl = try Self.requireStructDecl(declaration: declaration)
    guard !Self.diagnoseGenericParameters(structDecl.genericParameterClause, in: sink) else {
      return []
    }

    // The fully qualified name, so a nested type extends `Outer.Inner` rather than a name that
    // does not exist at file scope.
    let typeName = type.trimmedDescription
    let properties = Self.storedProperties(in: structDecl, context: sink)
    let hasExistingPartial = Self.hasExistingPartial(in: structDecl.memberBlock.members)
    let accessModifier = Self.accessModifier(for: structDecl.modifiers)
    let membersMode = Self.partialMembersMode(from: node, context: sink)
    let conformance = Self.conformanceClause(for: structDecl)
    let conversionMembers = try Self.conversions(
      for: properties,
      accessModifier: accessModifier,
      membersMode: membersMode
    )
    .initializers

    // A hand written `Partial` still gets the conversions, on the same terms as
    // `streamPartialValue`: they are written from the stored properties, so a `Partial` that
    // mirrors them works and one that does not says so where it differs.
    if hasExistingPartial {
      return [
        try ExtensionDeclSyntax(
          """
          extension \(raw: typeName)\(raw: conformance) {
            \(raw: conversionMembers)
          }
          """
        )
      ]
    }

    let partialStruct = try Self.partialStructDecl(
      for: properties,
      accessModifier: accessModifier,
      membersMode: membersMode,
      in: context
    )
    return [
      try ExtensionDeclSyntax(
        """
        extension \(raw: typeName)\(raw: conformance) {
          \(partialStruct)

          \(raw: conversionMembers)
        }
        """
      )
    ]
  }
}

extension StreamParseableMacro {
  private static func requireStructDecl(
    declaration: some DeclGroupSyntax
  ) throws -> StructDeclSyntax {
    guard let structDecl = declaration.as(StructDeclSyntax.self) else {
      throw MacroExpansionErrorMessage(
        "@StreamParseable can only be applied to struct or enum declarations."
      )
    }
    return structDecl
  }

  private static func isStatic(_ variableDecl: VariableDeclSyntax) -> Bool {
    variableDecl.modifiers.contains { $0.name.tokenKind == .keyword(.static) }
  }

  // Any named declaration, not just a struct: an enum's `Partial` is a typealias in two of the
  // three lowerings, and a hand written `enum`/`class Partial` has to suppress the generated one
  // too or the expansion is an invalid redeclaration.
  static func hasExistingPartial(in members: MemberBlockItemListSyntax) -> Bool {
    members.contains { $0.decl.asProtocol(NamedDeclSyntax.self)?.name.text == "Partial" }
  }

  // Omitted when the type already states the conformance, which would otherwise be a redundant
  // one. Read from the declaration rather than the `conformingTo:` list, because a test harness
  // that expands the macro directly never computes that list.
  static func conformanceClause(for declaration: some DeclGroupSyntax) -> String {
    let stated =
      declaration.inheritanceClause?.inheritedTypes
      .contains { Self.lastComponent(of: $0.type) == "StreamParseable" } ?? false
    return stated ? "" : ": \(TypeSyntax.streamParseable)"
  }

  static func error(_ node: some SyntaxProtocol, _ message: String) -> Diagnostic {
    Diagnostic(node: node, message: MacroExpansionErrorMessage(message))
  }

  // A `Partial` nested in a generic context cannot hold the `static let`s it needs ("static
  // stored properties not supported in generic types"), so say so instead of expanding into code
  // that cannot compile.
  static func diagnoseGenericParameters(
    _ clause: GenericParameterClauseSyntax?,
    in context: DiagnosticSink
  ) -> Bool {
    guard let clause else { return false }
    context.diagnose(
      Self.error(clause, "@StreamParseable does not support generic types.")
    )
    return true
  }

  static func isIndirect(_ declaration: EnumDeclSyntax) -> Bool {
    let isIndirectCase = { (modifiers: DeclModifierListSyntax) in
      modifiers.contains { $0.name.tokenKind == .keyword(.indirect) }
    }
    if isIndirectCase(declaration.modifiers) { return true }
    return declaration.memberBlock.members.contains {
      guard let caseDecl = $0.decl.as(EnumCaseDeclSyntax.self) else { return false }
      return isIndirectCase(caseDecl.modifiers)
    }
  }

  // A recursive case's payload nests `Partial` inside itself ("value type cannot have a stored
  // property that recursively contains it"), which no amount of generated code can fix.
  static func diagnoseIndirectEnum(
    _ declaration: EnumDeclSyntax,
    in context: DiagnosticSink
  ) -> Bool {
    guard Self.isIndirect(declaration) else { return false }
    context.diagnose(
      Self.error(
        declaration.name,
        """
        @StreamParseable does not support indirect enums, because a recursive case's payload \
        would nest 'Partial' inside itself.
        """
      )
    )
    return true
  }

  // A token's text keeps the backticks of an escaped identifier. The name underneath is what the
  // JSON key and every derived identifier are built from; `memberIdentifier` re-escapes where an
  // identifier is emitted.
  static func unescaped(_ token: TokenSyntax) -> String {
    let text = token.text
    guard text.count > 2, text.hasPrefix("`"), text.hasSuffix("`") else { return text }
    return String(text.dropFirst().dropLast())
  }

  // The last component of a possibly qualified type name, so `Swift.String` reads as `String`.
  static func lastComponent(of type: some TypeSyntaxProtocol) -> String {
    if let member = type.as(MemberTypeSyntax.self) { return member.name.text }
    if let identifier = type.as(IdentifierTypeSyntax.self) { return identifier.name.text }
    return type.trimmedDescription
  }

  static func hasExistingStreamPartialValue(
    in members: MemberBlockItemListSyntax
  ) -> Bool {
    for member in members {
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

  static func partialStructDecl(
    for properties: [StoredProperty],
    accessModifier: String?,
    membersMode: PartialMembersMode,
    extraViewMembers: String = "",
    in context: some MacroExpansionContext
  ) throws -> DeclSyntax {
    let generation = Self.objectGeneration(
      for: properties,
      accessModifier: accessModifier,
      membersMode: membersMode
    )
    let viewMembers: MemberBlockItemListSyntax = if extraViewMembers.isEmpty {
      MemberBlockItemListSyntax([])
    } else {
      try StructDeclSyntax(
        """
        struct _StreamViewMembers {
        \(raw: extraViewMembers)
        }
        """
      ).memberBlock.members
    }
    return DeclSyntax(
      try generation.structDeclarationSyntax(
        in: context,
        additionalViewMembers: { viewMembers }
      )
    )
  }

  static func objectGeneration(
    for properties: [StoredProperty],
    accessModifier: String?,
    membersMode: PartialMembersMode
  ) -> StreamObjectGeneration {
    let fields = properties.compactMap { property -> StreamParseableField? in
      guard !property.isIgnored else { return nil }
      return StreamParseableField(
        name: TokenSyntax.identifier(property.memberName),
        type: property.type,
        keys: property.keyNames,
        initialCapacity: property.initialCapacity.map {
          ExprSyntax(IntegerLiteralExprSyntax(literal: .integerLiteral(String($0))))
        },
        completedConversion: property.completedConversion.map { TypeSyntax(stringLiteral: $0) },
        defaultValue: property.defaultExpression.map { ExprSyntax("\(raw: $0)") }
      )
    }
    let accessLevel: StreamGeneratedAccessLevel = switch accessModifier {
    case "fileprivate": .fileprivate
    case "package": .package
    case "public": .public
    default: .internal
    }
    let mode: StreamPartialMembers = switch membersMode {
    case .optional: .optional
    case .streamInitialValue: .streamInitialValue
    }
    return StreamObjectGeneration(
      diagnosedFields: fields,
      partialMembers: mode,
      configuration: StreamGenerationConfiguration(
        viewMode: .packageDefault,
        accessLevel: accessLevel,
        inlining: .automatic
      )
    )
  }

  // Both directions come from `StreamObjectGeneration.conversionsSyntax`. `streamPartialValue`
  // goes out through the member expansion, the rest through the extension so the memberwise
  // initializer survives. The plan comes from `diagnosedFields:`, so a missing converted default
  // has already been diagnosed here and recovers as `?? (nil)` rather than throwing.
  static func conversions(
    for properties: [StoredProperty],
    accessModifier: String?,
    membersMode: PartialMembersMode
  ) throws -> (streamPartialValue: DeclSyntax, initializers: String) {
    // The plan only knows the partial's visibility. A property less visible than its type
    // cannot be read from an inlinable getter, and only the host can see that.
    let readable = properties.allSatisfy {
      $0.isIgnored || $0.isReadableInline(from: accessModifier)
    }
    let members = try Self.objectGeneration(
      for: properties,
      accessModifier: accessModifier,
      membersMode: membersMode
    )
    .conversionsSyntax(
      unparsedMembers: properties
        .filter { $0.isIgnored && !$0.hasDefaultValue }
        .map { StreamUnparsedMember(name: .identifier($0.memberName)) },
      partialValueInlining: readable ? nil : .never
    )
    // The generation has no alias to emit (the name is `Partial`), so the first member is
    // always `streamPartialValue`.
    var streamPartialValue = members.first!.decl
    streamPartialValue.trailingTrivia = []
    var initializers = MemberBlockItemListSyntax(members.dropFirst())
    initializers[initializers.startIndex].leadingTrivia = []
    return (streamPartialValue, initializers.indented(by: .spaces(2)).description)
  }

  static func accessModifier(for modifiers: DeclModifierListSyntax) -> String? {
    for modifier in modifiers {
      switch modifier.name.tokenKind {
      // `open` has no meaning on a value type's members, but a type may still be declared with
      // it; the generated members have to be at least as visible as the conformance.
      case .keyword(.public), .keyword(.open):
        return "public"
      case .keyword(.package):
        return "package"
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

  static func modifierPrefix(for accessModifier: String?) -> String {
    accessModifier.map { "\($0) " } ?? ""
  }

  // Only a public or package type's members are emitted `@inlinable`: the attribute exists to
  // cross a module boundary, so an internal type's expansion stays exactly what it was.
  static func isInlinable(_ accessModifier: String?) -> Bool {
    accessModifier == "public" || accessModifier == "package"
  }

  static func inlinableAttribute(_ inlinable: Bool) -> String {
    inlinable ? "@inlinable " : ""
  }

  static func hasExplicitPartialMembersArgument(_ node: AttributeSyntax) -> Bool {
    guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else { return false }
    return arguments.contains { $0.label?.text == "partialMembers" }
  }

  static func partialMembersMode(
    from node: AttributeSyntax,
    context: DiagnosticSink
  ) -> PartialMembersMode {
    guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else { return .optional }
    let modeArgument = arguments.first { $0.label?.text == "partialMembers" }
    guard let expression = modeArgument?.expression else { return .optional }
    // The mode is read from the syntax, not evaluated, so anything but one of the two member
    // names is unreadable rather than merely unusual.
    guard let mode = PartialMembersMode.parse(from: expression) else {
      context.diagnose(
        Self.error(
          expression,
          "@StreamParseable(partialMembers:) requires .optional or .streamInitialValue."
        )
      )
      return .optional
    }
    return mode
  }
}

// MARK: - StoredProperty

extension StreamParseableMacro {
  struct StoredProperty {
    /// The bare name, with no backticks: the default JSON key, and the stem of every derived
    /// identifier (`streamContainerSchema_x`).
    let name: String
    let type: TypeSyntax
    let keyNames: [String]
    let initialCapacity: Int?
    let isIgnored: Bool
    // Whether the declaration supplies its own value. A generated initializer must leave such a
    // property alone: it is already initialized, and if it is a `let` it cannot be assigned twice.
    let hasDefaultValue: Bool
    /// The declaration's own access level and `@usableFromInline`, which decide whether an
    /// inlinable member may read it. `nil` for a generated property, as visible as its type.
    var access: String? = nil
    var isUsableFromInline = false
    var completedConversion: String? = nil
    var defaultExpression: String? = nil

    /// `name`, re-escaped wherever the identifier itself is emitted.
    var memberName: String { StreamParseableMacro.memberIdentifier(for: self.name) }

    func isReadableInline(from typeAccess: String?) -> Bool {
      if self.isUsableFromInline { return true }
      switch self.access {
      case nil, "public": return true
      case "package": return typeAccess == "package"
      default: return false
      }
    }
  }

  struct KeyNamesResult {
    let names: [String]
    let diagnostics: [Diagnostic]
  }

  struct InitialCapacityResult {
    let value: Int?
    let diagnostics: [Diagnostic]
  }

  private static func storedProperties(
    in declaration: StructDeclSyntax,
    context: DiagnosticSink
  ) -> [StoredProperty] {
    var properties = [StoredProperty]()
    var seenKeys = Set<String>()
    for member in declaration.memberBlock.members {
      guard let variableDecl = member.decl.as(VariableDeclSyntax.self) else {
        continue
      }
      let declared = self.storedProperties(from: variableDecl, context: context)
      // A duplicate key emits a second, permanently unreachable `case` arm: Swift does not
      // diagnose duplicate integer patterns that carry a `where` clause.
      for property in declared where !property.isIgnored {
        for key in property.keyNames where !seenKeys.insert(key).inserted {
          context.diagnose(
            Self.error(variableDecl, "Key '\(key)' is already claimed by another property.")
          )
        }
      }
      properties.append(contentsOf: declared)
    }
    return properties
  }

  private static func storedProperties(
    from variableDecl: VariableDeclSyntax,
    context: DiagnosticSink
  ) -> [StoredProperty] {
    if self.isStatic(variableDecl) {
      self.diagnoseUnsupportedStreamParseableMember(
        in: variableDecl,
        message: "Static properties are not parsed by @StreamParseable.",
        context: context
      )
      return []
    }

    var properties = [StoredProperty]()
    let bindings = Array(variableDecl.bindings)
    for (index, binding) in bindings.enumerated() {
      if self.isComputedProperty(binding) {
        self.diagnoseUnsupportedStreamParseableMember(
          in: variableDecl,
          message: "Only stored properties are supported.",
          context: context
        )
        continue
      }

      guard let identifierPattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
        continue
      }

      // `var a, b: Int` annotates only the last binding; the earlier ones share that type.
      guard
        let type = bindings[index...].lazy.compactMap({ $0.typeAnnotation?.type }).first
      else {
        self.diagnoseMissingTypeAnnotation(in: binding, context: context)
        continue
      }

      properties.append(
        self.storedProperty(
          from: variableDecl,
          propertyName: Self.unescaped(identifierPattern.identifier),
          type: type,
          hasDefaultValue: binding.initializer != nil,
          defaultExpression: binding.initializer?.value.trimmedDescription,
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
    hasDefaultValue: Bool,
    defaultExpression: String?,
    context: DiagnosticSink
  ) -> StoredProperty {
    let hasIgnoredAttribute = self.streamParseableIgnoredAttribute(in: variableDecl.attributes) != nil
    // A `let` that supplies its own value is already initialized and cannot be assigned again, so
    // it is left out of `Partial` the way `Codable` leaves it out.
    let isImmutable = variableDecl.bindingSpecifier.tokenKind == .keyword(.let)
    let isIgnored = hasIgnoredAttribute || (isImmutable && hasDefaultValue)
    let hasStreamParseableMember =
      self.streamParseableMemberAttribute(in: variableDecl.attributes) != nil
    if hasIgnoredAttribute, hasStreamParseableMember {
      Self.diagnoseConflictingStreamParseableMemberAndIgnored(
        in: variableDecl,
        context: context
      )
    }

    let keyInfo =
      isIgnored
      ? KeyNamesResult(names: [propertyName], diagnostics: [])
      : Self.keyNames(for: variableDecl.attributes, defaultName: propertyName)
    for diagnostic in keyInfo.diagnostics {
      context.diagnose(diagnostic)
    }
    let capacityInfo =
      isIgnored
      ? InitialCapacityResult(value: nil, diagnostics: [])
      : Self.initialCapacity(for: variableDecl)
    for diagnostic in capacityInfo.diagnostics {
      context.diagnose(diagnostic)
    }
    if hasIgnoredAttribute, !hasDefaultValue, !type.streamIsOptional {
      Self.diagnoseUnsettableIgnoredMember(
        in: variableDecl,
        propertyName: propertyName,
        context: context
      )
    }
    var conversion: String?
    for attribute in Self.streamParseableMemberAttributes(in: variableDecl.attributes) {
      guard let arguments = attribute.arguments?.as(LabeledExprListSyntax.self),
        let expression = Self.argumentExpression(in: arguments, named: "completedConversion")
      else { continue }
      guard conversion == nil else {
        context.diagnose(Self.error(attribute, "completedConversion: can only be specified once per property."))
        continue
      }
      guard let member = expression.as(MemberAccessExprSyntax.self),
        member.declName.baseName.text == "self", let base = member.base
      else {
        context.diagnose(Self.error(expression, "completedConversion: requires a strategy type followed by .self."))
        continue
      }
      conversion = base.trimmedDescription
    }
    if conversion != nil, !isIgnored {
      if capacityInfo.value != nil {
        context.diagnose(Self.error(variableDecl, "initialCapacity: is not supported with completedConversion:."))
      }
      if !type.streamIsOptional, defaultExpression == nil {
        context.diagnose(Self.error(variableDecl, "A nonoptional converted member requires an explicit default for init(orInitial:)."))
      }
    }
    return StoredProperty(
      name: propertyName,
      type: type,
      keyNames: keyInfo.names,
      initialCapacity: capacityInfo.value,
      isIgnored: isIgnored,
      hasDefaultValue: hasDefaultValue,
      access: Self.declaredAccess(of: variableDecl.modifiers),
      isUsableFromInline: !Self.attributes(named: "usableFromInline", in: variableDecl.attributes)
        .isEmpty,
      completedConversion: conversion,
      defaultExpression: defaultExpression
    )
  }

  // The getter's access: `private(set)` names only the setter, which no inlinable member uses.
  private static func declaredAccess(of modifiers: DeclModifierListSyntax) -> String {
    for modifier in modifiers where modifier.detail == nil {
      switch modifier.name.tokenKind {
      case .keyword(.public), .keyword(.open): return "public"
      case .keyword(.package): return "package"
      case .keyword(.fileprivate): return "fileprivate"
      case .keyword(.private): return "private"
      default: continue
      }
    }
    return "internal"
  }

  private static func diagnoseUnsettableIgnoredMember(
    in variableDecl: VariableDeclSyntax,
    propertyName: String,
    context: DiagnosticSink
  ) {
    context.diagnose(
      Diagnostic(
        node: variableDecl,
        message: MacroExpansionErrorMessage(
          """
          Ignored property '\(propertyName)' must be optional or have a default value. \
          It is absent from 'Partial', so the generated initializer has nothing to set it from.
          """
        )
      )
    )
  }

  private static func diagnoseMissingTypeAnnotation(
    in binding: PatternBindingSyntax,
    context: DiagnosticSink
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
    message: String,
    context: DiagnosticSink
  ) {
    guard let attribute = self.streamParseableMemberAttribute(in: variableDecl.attributes) else { return }
    context.diagnose(Self.error(attribute, message))
  }

  private static func diagnoseConflictingStreamParseableMemberAndIgnored(
    in variableDecl: VariableDeclSyntax,
    context: DiagnosticSink
  ) {
    guard let attribute = Self.streamParseableMemberAttribute(in: variableDecl.attributes) else { return }
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

  static func keyNames(
    for declAttributes: AttributeListSyntax,
    defaultName: String
  ) -> KeyNamesResult {
    let attributes = self.streamParseableMemberAttributes(in: declAttributes)
    guard !attributes.isEmpty else {
      return KeyNamesResult(names: [defaultName], diagnostics: [])
    }

    var names = [String]()
    var diagnostics = [Diagnostic]()

    for attribute in attributes {
      guard let arguments = attribute.arguments?.as(LabeledExprListSyntax.self) else {
        continue
      }
      let keyExpression = self.argumentExpression(in: arguments, named: "key")
      let keyNamesExpression = self.argumentExpression(in: arguments, named: "keyNames")

      if keyExpression != nil, keyNamesExpression != nil {
        diagnostics.append(
          Self.error(
            attribute, "@StreamParseableMember takes either key: or keyNames:, not both."
          )
        )
        continue
      }

      if let keyExpression {
        guard let keyName = keyExpression.as(StringLiteralExprSyntax.self)?.representedLiteralValue else {
          diagnostics.append(
            Self.error(attribute, "@StreamParseableMember(key:) requires a string literal.")
          )
          continue
        }
        guard !keyName.isEmpty else {
          diagnostics.append(
            Self.error(attribute, "@StreamParseableMember(key:) must not be empty.")
          )
          continue
        }
        names.append(keyName)
        continue
      }

      if let keyNamesExpression {
        guard let keyNames = self.stringArrayValues(from: keyNamesExpression),
          !keyNames.isEmpty
        else {
          diagnostics.append(
            Self.error(
              attribute, "@StreamParseableMember(keyNames:) requires a string array literal."
            )
          )
          continue
        }
        guard !keyNames.contains(where: \.isEmpty) else {
          diagnostics.append(
            Self.error(
              attribute, "@StreamParseableMember(keyNames:) must not contain an empty name."
            )
          )
          continue
        }
        names.append(contentsOf: keyNames)
      }
    }

    return KeyNamesResult(
      names: names.isEmpty ? [defaultName] : names,
      diagnostics: diagnostics
    )
  }

  static func initialCapacity(
    for variableDecl: VariableDeclSyntax
  ) -> InitialCapacityResult {
    var value: Int?
    var sawCapacity = false
    var diagnostics = [Diagnostic]()

    for attribute in self.streamParseableMemberAttributes(in: variableDecl.attributes) {
      guard let arguments = attribute.arguments?.as(LabeledExprListSyntax.self),
        let expression = self.argumentExpression(in: arguments, named: "initialCapacity")
      else { continue }

      // The key/keyNames overloads use an optional argument so they can default the hint away.
      // Treat an explicitly written `nil` the same as the omitted default.
      if expression.is(NilLiteralExprSyntax.self) { continue }

      guard !sawCapacity else {
        diagnostics.append(
          Diagnostic(
            node: attribute,
            message: MacroExpansionErrorMessage(
              "@StreamParseableMember(initialCapacity:) can only be specified once per property."
            )
          )
        )
        continue
      }
      sawCapacity = true

      guard let parsed = Self.integerLiteralValue(expression) else {
        diagnostics.append(
          Diagnostic(
            node: attribute,
            message: MacroExpansionErrorMessage(
              "@StreamParseableMember(initialCapacity:) requires a nonnegative integer literal."
            )
          )
        )
        continue
      }

      value = parsed
    }

    return InitialCapacityResult(value: value, diagnostics: diagnostics)
  }

  private static func integerLiteralValue(_ expression: ExprSyntax) -> Int? {
    guard let literal = expression.as(IntegerLiteralExprSyntax.self) else { return nil }
    let text = String(literal.literal.text.filter { $0 != "_" })
    if text.hasPrefix("0x") || text.hasPrefix("0X") {
      return Int(text.dropFirst(2), radix: 16)
    }
    if text.hasPrefix("0o") || text.hasPrefix("0O") {
      return Int(text.dropFirst(2), radix: 8)
    }
    if text.hasPrefix("0b") || text.hasPrefix("0B") {
      return Int(text.dropFirst(2), radix: 2)
    }
    return Int(text, radix: 10)
  }

  // Keyed off an attribute list rather than a `VariableDeclSyntax`, because an enum case
  // carries the same attributes in the same place and one reader serves both.
  static func attributes(named name: String, in attributes: AttributeListSyntax) -> [AttributeSyntax] {
    attributes
      .compactMap { $0.as(AttributeSyntax.self) }
      .filter { $0.attributeName.trimmedDescription == name }
  }

  static func streamParseableMemberAttributes(
    in attributes: AttributeListSyntax
  ) -> [AttributeSyntax] {
    self.attributes(named: "StreamParseableMember", in: attributes)
  }

  static func streamParseableMemberAttribute(
    in attributes: AttributeListSyntax
  ) -> AttributeSyntax? {
    self.streamParseableMemberAttributes(in: attributes).first
  }

  private static func streamParseableIgnoredAttribute(
    in attributes: AttributeListSyntax
  ) -> AttributeSyntax? {
    self.attributes(named: "StreamParseableIgnored", in: attributes).first
  }

  static func streamParseableDefaultAttribute(
    in attributes: AttributeListSyntax
  ) -> AttributeSyntax? {
    self.attributes(named: "StreamParseableDefault", in: attributes).first
  }

  private static func argumentExpression(
    in arguments: LabeledExprListSyntax,
    named name: String
  ) -> ExprSyntax? {
    arguments.first { $0.label?.text == name }?.expression
  }

  // Interpolation declines rather than silently dropping the interpolated segment: `"a\(1)b"`
  // used to read as the key `ab`. An empty literal is returned as such, so callers that care can
  // say "must not be empty" instead of "not a literal".
  private static func stringArrayValues(from expression: ExprSyntax) -> [String]? {
    guard let arrayExpression = expression.as(ArrayExprSyntax.self) else { return nil }
    var values = [String]()
    for element in arrayExpression.elements {
      guard let value = element.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue else { return nil }
      values.append(value)
    }
    return values.isEmpty ? nil : values
  }
}

// MARK: - PartialMembersMode

extension StreamParseableMacro {
  enum PartialMembersMode: Hashable {
    case optional
    case streamInitialValue

    var defaultValueSyntax: String {
      switch self {
      case .optional: "nil"
      case .streamInitialValue: ".streamInitialValue()"
      }
    }

    static func parse(from expression: ExprSyntax) -> Self? {
      switch self.memberName(from: expression) {
      case "optional": .optional
      case "streamInitialValue": .streamInitialValue
      default: nil
      }
    }

    private static func memberName(from expression: ExprSyntax) -> String? {
      expression.as(MemberAccessExprSyntax.self)?.declName.baseName.text
    }
  }
}
