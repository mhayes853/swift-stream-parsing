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
    guard !Self.hasExistingStreamPartialValue(in: structDecl.memberBlock.members) else {
      return []
    }
    let properties = Self.storedProperties(in: structDecl, context: sink)
    // The partial mode only picks the unlabelled initializer, which the extension emits.
    return [
      try Self.conversions(
        for: properties,
        accessLevel: Self.generatedAccessLevel(for: structDecl.modifiers),
        membersMode: .optional
      )
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
        !Self.diagnoseGenericContext(enumDecl, lexicalContext: context.lexicalContext, in: sink),
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
    let genericParameters = Self.genericParameters(
      of: structDecl, lexicalContext: context.lexicalContext
    )

    // The fully qualified name, so a nested type extends `Outer.Inner` rather than a name that
    // does not exist at file scope.
    let typeName = type.trimmedDescription
    let properties = Self.storedProperties(in: structDecl, context: sink)
    let hasExistingPartial = Self.hasExistingPartial(in: structDecl.memberBlock.members)
    let accessLevel = Self.generatedAccessLevel(for: structDecl.modifiers)
    let membersMode = Self.partialMembersMode(from: node, context: sink)
    let conformance = Self.conformanceClause(for: structDecl)
    var conversionMembers = try Self.conversions(
      for: properties,
      accessLevel: accessLevel,
      membersMode: membersMode
    )
    .rest
    conversionMembers[conversionMembers.startIndex].leadingTrivia = []
    let conversionSource = conversionMembers.indented(by: .spaces(2)).description

    // A hand written `Partial` still gets the conversions, on the same terms as
    // `streamPartialValue`: they are written from the stored properties, so a `Partial` that
    // mirrors them works and one that does not says so where it differs.
    if hasExistingPartial {
      return [
        try ExtensionDeclSyntax(
          """
          extension \(raw: typeName)\(raw: conformance) {
            \(raw: conversionSource)
          }
          """
        )
      ]
    }

    let partialStruct = try Self.objectGeneration(
      for: properties,
      accessLevel: accessLevel,
      membersMode: membersMode,
      genericParameters: genericParameters
    )
    .structDeclarationSyntax(in: context)
    return [
      try ExtensionDeclSyntax(
        """
        extension \(raw: typeName)\(raw: conformance) {
          \(partialStruct)

          \(raw: conversionSource)
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
    Self.inherits(declaration, named: "StreamParseable") ? "" : ": \(TypeSyntax.streamParseable)"
  }

  /// Whether the declaration's own inheritance clause names `name`, however qualified.
  static func inherits(_ declaration: some DeclGroupSyntax, named name: String) -> Bool {
    declaration.inheritanceClause?.inheritedTypes
      .contains { Self.lastComponent(of: $0.type) == name } ?? false
  }

  static func error(_ node: some SyntaxProtocol, _ message: String) -> Diagnostic {
    Diagnostic(node: node, message: MacroExpansionErrorMessage(message))
  }

  // An enum's lowerings still hold `static let`s, which a generic context cannot declare ("static
  // stored properties not supported in generic types"), so say so instead of expanding into code
  // that cannot compile. Structs take the generic lowering instead.
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

  // The same limit for an enum nested in a generic type, which is generic without saying so.
  static func diagnoseGenericContext(
    _ declaration: EnumDeclSyntax,
    lexicalContext: [Syntax],
    in context: DiagnosticSink
  ) -> Bool {
    guard !Self.enclosingGenericParameters(lexicalContext, skipping: declaration.name.text).isEmpty
    else { return false }
    context.diagnose(
      Self.error(
        declaration.name,
        "@StreamParseable does not support enums nested in generic types."
      )
    )
    return true
  }

  // The generic parameters in scope for a struct's `Partial`: its own, then those of every type
  // enclosing it. An extension of a generic type declares none it can see, so a type nested there
  // is still expanded as concrete; nothing syntactic can tell.
  static func genericParameters(
    of declaration: StructDeclSyntax,
    lexicalContext: [Syntax]
  ) -> [TokenSyntax] {
    let own = declaration.genericParameterClause?.parameters.map(\.name.trimmed) ?? []
    return own + Self.enclosingGenericParameters(lexicalContext, skipping: declaration.name.text)
  }

  // The innermost lexical context may be the declaration itself, which is skipped by name.
  static func enclosingGenericParameters(
    _ lexicalContext: [Syntax],
    skipping name: String
  ) -> [TokenSyntax] {
    var parameters = [TokenSyntax]()
    for (index, node) in lexicalContext.enumerated() {
      if index == 0, node.asProtocol(NamedDeclSyntax.self)?.name.text == name { continue }
      let clause: GenericParameterClauseSyntax?
      if let type = node.as(StructDeclSyntax.self) {
        clause = type.genericParameterClause
      } else if let type = node.as(EnumDeclSyntax.self) {
        clause = type.genericParameterClause
      } else if let type = node.as(ClassDeclSyntax.self) {
        clause = type.genericParameterClause
      } else if let type = node.as(ActorDeclSyntax.self) {
        clause = type.genericParameterClause
      } else {
        continue
      }
      parameters += clause?.parameters.map(\.name.trimmed) ?? []
    }
    return parameters
  }

  static func isIndirect(_ declaration: EnumDeclSyntax) -> Bool {
    declaration.modifiers.contains(.indirect)
      || declaration.memberBlock.members.contains {
        $0.decl.as(EnumCaseDeclSyntax.self)?.modifiers.contains(.indirect) ?? false
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

  // The last component of a possibly qualified type name, so `Swift.String` reads as `String`.
  static func lastComponent(of type: some TypeSyntaxProtocol) -> String {
    if let member = type.as(MemberTypeSyntax.self) { return member.name.text }
    if let identifier = type.as(IdentifierTypeSyntax.self) { return identifier.name.text }
    return type.trimmedDescription
  }

  static func hasExistingStreamPartialValue(
    in members: MemberBlockItemListSyntax
  ) -> Bool {
    members.contains { member in
      guard let variableDecl = member.decl.as(VariableDeclSyntax.self),
        !variableDecl.modifiers.contains(.static)
      else { return false }
      return variableDecl.bindings.contains {
        $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text == "streamPartialValue"
      }
    }
  }

  // `streamPartialValue` goes out through the member role, the rest through the extension so a
  // struct's memberwise initializer survives. Both lowerings generate it first.
  static func splitConversions(
    _ members: MemberBlockItemListSyntax
  ) -> (streamPartialValue: DeclSyntax, rest: MemberBlockItemListSyntax) {
    var streamPartialValue = members.first!.decl
    streamPartialValue.trailingTrivia = []
    return (streamPartialValue, MemberBlockItemListSyntax(members.dropFirst()))
  }

  static func objectGeneration(
    for properties: [StoredProperty],
    accessLevel: StreamGeneratedAccessLevel,
    membersMode: StreamPartialMembers,
    genericParameters: [TokenSyntax] = []
  ) -> StreamObjectGeneration {
    let fields = properties.compactMap { property -> StreamParseableField? in
      guard !property.isIgnored else { return nil }
      return StreamParseableField(
        name: .identifier(property.name),
        type: property.type,
        keys: property.keyNames,
        initialCapacity: property.initialCapacity.map {
          ExprSyntax(IntegerLiteralExprSyntax(literal: .integerLiteral(String($0))))
        },
        completedConversion: property.completedConversion.map { TypeSyntax(stringLiteral: $0) },
        defaultValue: property.defaultExpression.map { ExprSyntax("\(raw: $0)") }
      )
    }
    return StreamObjectGeneration(
      diagnosedFields: fields,
      partialMembers: membersMode,
      configuration: StreamGenerationConfiguration(
        viewMode: .packageDefault,
        accessLevel: accessLevel,
        inlining: .automatic,
        genericParameters: genericParameters
      )
    )
  }

  // Both directions come from `StreamObjectGeneration.conversionsSyntax`. The plan comes from
  // `diagnosedFields:`, so a missing converted default has already been diagnosed here and
  // recovers as `?? (nil)` rather than throwing.
  static func conversions(
    for properties: [StoredProperty],
    accessLevel: StreamGeneratedAccessLevel,
    membersMode: StreamPartialMembers
  ) throws -> (streamPartialValue: DeclSyntax, rest: MemberBlockItemListSyntax) {
    // The plan only knows the partial's visibility. A property less visible than its type
    // cannot be read from an inlinable getter, and only the host can see that.
    let readable = properties.allSatisfy {
      $0.isIgnored || $0.isReadableInline(from: accessLevel)
    }
    // The generation has no alias to emit (the name is `Partial`), so the first member is
    // always `streamPartialValue`.
    return Self.splitConversions(
      try Self.objectGeneration(for: properties, accessLevel: accessLevel, membersMode: membersMode)
        .conversionsSyntax(
          unparsedMembers: properties
            .filter { $0.isIgnored && !$0.hasDefaultValue }
            .map { StreamUnparsedMember(name: .identifier($0.name)) },
          partialValueInlining: readable ? nil : .never
        )
    )
  }

  // The getter's access, with `open`, which means nothing on a value type's members, read as
  // `public`. `private(set)` names only the setter, which no generated member uses.
  static func declaredAccess(of modifiers: DeclModifierListSyntax) -> String {
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

  // Generated members have to be at least as visible as the conformance. A private type's are
  // internal, which its own visibility already limits.
  static func generatedAccessLevel(
    for modifiers: DeclModifierListSyntax
  ) -> StreamGeneratedAccessLevel {
    switch Self.declaredAccess(of: modifiers) {
    case "public": .public
    case "package": .package
    case "fileprivate": .fileprivate
    default: .internal
    }
  }

  static func partialMembersMode(
    from node: AttributeSyntax,
    context: DiagnosticSink
  ) -> StreamPartialMembers {
    guard let expression = Self.argument(named: "partialMembers", of: node) else { return .optional }
    // The mode is read from the syntax, not evaluated, so anything but one of the two member
    // names is unreadable rather than merely unusual.
    switch expression.as(MemberAccessExprSyntax.self)?.declName.baseName.text {
    case "optional": return .optional
    case "streamInitialValue": return .streamInitialValue
    default:
      context.diagnose(
        Self.error(
          expression,
          "@StreamParseable(partialMembers:) requires .optional or .streamInitialValue."
        )
      )
      return .optional
    }
  }
}

extension DeclModifierListSyntax {
  func contains(_ keyword: Keyword) -> Bool {
    self.contains { $0.name.tokenKind == .keyword(keyword) }
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
    /// The declaration's own access level and `@usableFromInline`, which decide whether an
    /// inlinable member may read it.
    let access: String
    let isUsableFromInline: Bool
    let completedConversion: String?
    let defaultExpression: String?

    // Whether the declaration supplies its own value. A generated initializer must leave such a
    // property alone: it is already initialized, and if it is a `let` it cannot be assigned twice.
    var hasDefaultValue: Bool { self.defaultExpression != nil }

    func isReadableInline(from typeAccess: StreamGeneratedAccessLevel) -> Bool {
      if self.isUsableFromInline { return true }
      switch self.access {
      case "public": return true
      case "package": return typeAccess == .package
      default: return false
      }
    }
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
    if variableDecl.modifiers.contains(.static) {
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
        context.diagnose(Self.error(binding, "Stored properties must declare an explicit type."))
        continue
      }

      properties.append(
        self.storedProperty(
          from: variableDecl,
          propertyName: StreamObjectGeneration.bareName(identifierPattern.identifier),
          type: type,
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
    defaultExpression: String?,
    context: DiagnosticSink
  ) -> StoredProperty {
    let hasDefaultValue = defaultExpression != nil
    let hasIgnoredAttribute =
      Self.attribute(named: "StreamParseableIgnored", in: variableDecl.attributes) != nil
    // A `let` that supplies its own value is already initialized and cannot be assigned again, so
    // it is left out of `Partial` the way `Codable` leaves it out.
    let isImmutable = variableDecl.bindingSpecifier.tokenKind == .keyword(.let)
    let isIgnored = hasIgnoredAttribute || (isImmutable && hasDefaultValue)
    if hasIgnoredAttribute,
      let attribute = Self.attribute(named: "StreamParseableMember", in: variableDecl.attributes)
    {
      context.diagnose(
        Self.error(
          attribute,
          "@StreamParseableMember and @StreamParseableIgnored cannot be applied to the same property."
        )
      )
    }

    let keyNames =
      isIgnored
      ? [propertyName]
      : Self.keyNames(for: variableDecl.attributes, defaultName: propertyName, context: context)
    let capacity = isIgnored ? nil : Self.initialCapacity(for: variableDecl, context: context)
    if hasIgnoredAttribute, !hasDefaultValue, !type.streamIsOptional {
      context.diagnose(
        Self.error(
          variableDecl,
          """
          Ignored property '\(propertyName)' must be optional or have a default value. \
          It is absent from 'Partial', so the generated initializer has nothing to set it from.
          """
        )
      )
    }
    var conversion: String?
    if let (_, expression) = Self.memberArgument(
      named: "completedConversion",
      of: variableDecl,
      repeated: "completedConversion: can only be specified once per property.",
      context: context
    ) {
      if let member = expression.as(MemberAccessExprSyntax.self),
        member.declName.baseName.text == "self", let base = member.base
      {
        conversion = base.trimmedDescription
      } else {
        context.diagnose(Self.error(expression, "completedConversion: requires a strategy type followed by .self."))
      }
    }
    if conversion != nil, !isIgnored {
      if capacity != nil {
        context.diagnose(Self.error(variableDecl, "initialCapacity: is not supported with completedConversion:."))
      }
      if !type.streamIsOptional, defaultExpression == nil {
        context.diagnose(Self.error(variableDecl, "A nonoptional converted member requires an explicit default for init(orInitial:)."))
      }
    }
    return StoredProperty(
      name: propertyName,
      type: type,
      keyNames: keyNames,
      initialCapacity: capacity,
      isIgnored: isIgnored,
      access: Self.declaredAccess(of: variableDecl.modifiers),
      isUsableFromInline: Self.attribute(named: "usableFromInline", in: variableDecl.attributes) != nil,
      completedConversion: conversion,
      defaultExpression: defaultExpression
    )
  }

  private static func diagnoseUnsupportedStreamParseableMember(
    in variableDecl: VariableDeclSyntax,
    message: String,
    context: DiagnosticSink
  ) {
    guard let attribute = Self.attribute(named: "StreamParseableMember", in: variableDecl.attributes)
    else { return }
    context.diagnose(Self.error(attribute, message))
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
    defaultName: String,
    context: DiagnosticSink
  ) -> [String] {
    var names = [String]()
    for attribute in Self.attributes(named: "StreamParseableMember", in: declAttributes) {
      let keyExpression = Self.argument(named: "key", of: attribute)
      let keyNamesExpression = Self.argument(named: "keyNames", of: attribute)
      let diagnose = { context.diagnose(Self.error(attribute, $0)) }
      if keyExpression != nil, keyNamesExpression != nil {
        diagnose("@StreamParseableMember takes either key: or keyNames:, not both.")
      } else if let keyExpression {
        guard let keyName = keyExpression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
        else {
          diagnose("@StreamParseableMember(key:) requires a string literal.")
          continue
        }
        guard !keyName.isEmpty else {
          diagnose("@StreamParseableMember(key:) must not be empty.")
          continue
        }
        names.append(keyName)
      } else if let keyNamesExpression {
        guard let keyNames = Self.stringArrayValues(from: keyNamesExpression) else {
          diagnose("@StreamParseableMember(keyNames:) requires a string array literal.")
          continue
        }
        guard !keyNames.contains(where: \.isEmpty) else {
          diagnose("@StreamParseableMember(keyNames:) must not contain an empty name.")
          continue
        }
        names.append(contentsOf: keyNames)
      }
    }
    return names.isEmpty ? [defaultName] : names
  }

  static func initialCapacity(
    for variableDecl: VariableDeclSyntax,
    context: DiagnosticSink
  ) -> Int? {
    guard
      let (attribute, expression) = Self.memberArgument(
        named: "initialCapacity",
        of: variableDecl,
        repeated: "@StreamParseableMember(initialCapacity:) can only be specified once per property.",
        context: context
      )
    else { return nil }
    guard let value = Self.integerLiteralValue(expression) else {
      context.diagnose(
        Self.error(
          attribute,
          "@StreamParseableMember(initialCapacity:) requires a nonnegative integer literal."
        )
      )
      return nil
    }
    return value
  }

  // The `name:` argument of the first `@StreamParseableMember` that writes one. Every later one
  // is diagnosed with `repeated`. An explicit `nil`, which the optional overloads default to,
  // counts as unwritten.
  private static func memberArgument(
    named name: String,
    of variableDecl: VariableDeclSyntax,
    repeated: String,
    context: DiagnosticSink
  ) -> (attribute: AttributeSyntax, expression: ExprSyntax)? {
    var found: (attribute: AttributeSyntax, expression: ExprSyntax)?
    for attribute in Self.attributes(named: "StreamParseableMember", in: variableDecl.attributes) {
      guard let expression = Self.argument(named: name, of: attribute),
        !expression.is(NilLiteralExprSyntax.self)
      else { continue }
      guard found == nil else {
        context.diagnose(Self.error(attribute, repeated))
        continue
      }
      found = (attribute, expression)
    }
    return found
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

  static func attribute(named name: String, in attributes: AttributeListSyntax) -> AttributeSyntax? {
    Self.attributes(named: name, in: attributes).first
  }

  static func argument(named name: String, of attribute: AttributeSyntax) -> ExprSyntax? {
    attribute.arguments?.as(LabeledExprListSyntax.self)?
      .first { $0.label?.text == name }?.expression
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
