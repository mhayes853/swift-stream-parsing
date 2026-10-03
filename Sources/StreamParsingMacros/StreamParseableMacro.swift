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

  /// The options `attribute` writes, with each unreadable one diagnosed.
  func arguments(of attribute: AttributeSyntax) -> StreamMacroArguments {
    let arguments = StreamMacroArguments(parsing: attribute)
    for error in arguments.errors {
      self.diagnose(error.diagnostic)
    }
    return arguments
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
      // Every case the extension role declines has to be declined here too, or the lone
      // `streamPartialValue` adds "cannot find type 'Partial'" to the real diagnostic.
      guard enumDecl.genericParameterClause == nil,
        !Self.diagnoseGenericContext(enumDecl, lexicalContext: context.lexicalContext, in: sink),
        !Self.isIndirect(enumDecl),
        !Self.diagnoseSelfReferentialPayloads(
          enumDecl, lexicalContext: context.lexicalContext, in: sink
        )
      else { return [] }
      return try Self.enumMemberExpansion(
        declaration: enumDecl, lexicalContext: context.lexicalContext,
        partialStrings: sink.arguments(of: node).partialStrings ?? .streamString, in: sink
      )
    }
    let structDecl = try Self.requireStructDecl(declaration: declaration)
    guard !Self.hasExistingStreamPartialValue(in: structDecl.memberBlock.members) else {
      return []
    }
    // `streamPartialValue` spells each member's storage, so it reads the string storage too.
    let properties = Self.storedProperties(
      in: structDecl, partialStrings: sink.arguments(of: node).partialStrings ?? .streamString,
      context: sink
    )
    // The partial mode only picks the unlabelled initializer, which the extension emits.
    return [
      try Self.conversions(
        for: properties,
        accessLevel: Self.generatedAccessLevel(
          for: structDecl, lexicalContext: context.lexicalContext
        ),
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
    let arguments = sink.arguments(of: node)
    let properties = Self.storedProperties(
      in: structDecl, keyDecodingStrategy: arguments.keyDecodingStrategy,
      partialStrings: arguments.partialStrings ?? .streamString, context: sink
    )
    let hasExistingPartial = Self.hasExistingPartial(in: structDecl.memberBlock.members)
    let accessLevel = Self.generatedAccessLevel(
      for: structDecl, lexicalContext: context.lexicalContext
    )
    let membersMode = arguments.partialMembers ?? .optional
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
      genericParameters: genericParameters,
      schemaCache: arguments.schemaCache,
      keyDecodingStrategy: arguments.keyDecodingStrategy
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
    genericParameters: [TokenSyntax] = [],
    schemaCache: ExprSyntax? = nil,
    keyDecodingStrategy: ExprSyntax? = nil
  ) -> StreamObjectGeneration {
    let fields = properties.compactMap { property -> StreamParseableField? in
      guard !property.isIgnored else { return nil }
      return StreamParseableField(
        name: .identifier(property.name),
        type: property.type,
        keys: property.keyNames,
        convertsKeys: property.convertsKeys,
        initialCapacity: property.initialCapacity.map {
          ExprSyntax(IntegerLiteralExprSyntax(literal: .integerLiteral(String($0))))
        },
        completedConversion: property.completedConversion.map { TypeSyntax(stringLiteral: $0) },
        partialStrings: property.partialStrings,
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
        genericParameters: genericParameters,
        schemaCache: schemaCache,
        keyDecodingStrategy: keyDecodingStrategy
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

  // The same, for the declaration as it sits in its lexical context. A type that writes no access
  // modifier of its own directly inside `public extension` is public, so its conformance is too,
  // and its generated members have to follow the extension's modifier rather than default to
  // internal. Only the nearest context counts: a type's members never inherit from further out.
  static func generatedAccessLevel(
    for declaration: some DeclGroupSyntax & NamedDeclSyntax,
    lexicalContext: [Syntax]
  ) -> StreamGeneratedAccessLevel {
    guard !Self.hasExplicitAccess(declaration.modifiers),
      let enclosing = Self.enclosingContext(lexicalContext, skipping: declaration.name.text)?
        .as(ExtensionDeclSyntax.self)
    else {
      return Self.generatedAccessLevel(for: declaration.modifiers)
    }
    return Self.generatedAccessLevel(for: enclosing.modifiers)
  }

  // Whether the getter's access is written at all; `private(set)` alone is not.
  private static func hasExplicitAccess(_ modifiers: DeclModifierListSyntax) -> Bool {
    modifiers.contains { modifier in
      guard modifier.detail == nil else { return false }
      switch modifier.name.tokenKind {
      case .keyword(.public), .keyword(.open), .keyword(.package), .keyword(.internal),
        .keyword(.fileprivate), .keyword(.private):
        return true
      default:
        return false
      }
    }
  }

  // The innermost lexical context around the declaration, which may itself be first and is
  // skipped by name, as in `enclosingGenericParameters`.
  private static func enclosingContext(_ lexicalContext: [Syntax], skipping name: String) -> Syntax? {
    for (index, node) in lexicalContext.enumerated() {
      if index == 0, node.asProtocol(NamedDeclSyntax.self)?.name.text == name { continue }
      return node
    }
    return nil
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
    /// identifier (`streamObjectMemberSchema_x`).
    let name: String
    let type: TypeSyntax
    let keyNames: [String]
    /// Whether `keyNames` is the name alone, for the type's key decoding strategy to convert. A
    /// key written with `@StreamParseableMember` is never converted.
    let convertsKeys: Bool
    let initialCapacity: Int?
    let isIgnored: Bool
    /// The declaration's own access level and `@usableFromInline`, which decide whether an
    /// inlinable member may read it.
    let access: String
    let isUsableFromInline: Bool
    let completedConversion: String?
    /// The type's `partialStrings:`, or this member's own `@StreamParseableMember(partialStrings:)`.
    let partialStrings: StreamPartialStrings
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
    keyDecodingStrategy: ExprSyntax? = nil,
    partialStrings: StreamPartialStrings,
    context: DiagnosticSink
  ) -> [StoredProperty] {
    var properties = [StoredProperty]()
    var seenKeys = Set<String>()
    let keyDecoding = StreamGenerationConfiguration(keyDecodingStrategy: keyDecodingStrategy)
    for member in declaration.memberBlock.members {
      guard let variableDecl = member.decl.as(VariableDeclSyntax.self) else {
        continue
      }
      let declared = self.storedProperties(
        from: variableDecl, partialStrings: partialStrings, context: context
      )
      // A duplicate key emits a second, permanently unreachable `case` arm: Swift does not
      // diagnose duplicate integer patterns that carry a `where` clause.
      for property in declared where !property.isIgnored {
        for name in property.keyNames {
          Self.claimKey(
            of: name, converting: property.convertsKeys, by: keyDecoding, in: &seenKeys,
            claimant: "property", at: variableDecl, context: context
          )
        }
      }
      properties.append(contentsOf: declared)
    }
    return properties
  }

  private static func storedProperties(
    from variableDecl: VariableDeclSyntax,
    partialStrings: StreamPartialStrings,
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
    // A lazy property is derived, like a computed one: its initializer sets it on first read, so
    // the generated initializers never have to, and that first read is mutating, so the
    // non-mutating `streamPartialValue` getter cannot make it. Skipped the same way, and diagnosed
    // only where `@StreamParseableMember` asks for it to be parsed.
    if variableDecl.modifiers.contains(.lazy) {
      self.diagnoseUnsupportedStreamParseableMember(
        in: variableDecl,
        message: "Lazy properties are not parsed by @StreamParseable.",
        context: context
      )
      return []
    }

    var properties = [StoredProperty]()
    let bindings = Array(variableDecl.bindings)
    // A `let` with an initial value is left out of `Partial` (see `storedProperty`), so a
    // `@StreamParseableMember` on one would be dropped without a word, key and all. Once per
    // declaration, and only when no binding in it is parsed; `@StreamParseableIgnored` alongside
    // is already its own diagnostic.
    if variableDecl.bindingSpecifier.tokenKind == .keyword(.let),
      bindings.allSatisfy({ $0.initializer != nil }),
      Self.attribute(named: "StreamParseableIgnored", in: variableDecl.attributes) == nil
    {
      self.diagnoseUnsupportedStreamParseableMember(
        in: variableDecl,
        message: """
          A 'let' with an initial value is not parsed; make it 'var' or remove \
          @StreamParseableMember.
          """,
        context: context
      )
    }
    for (index, binding) in bindings.enumerated() {
      if self.isComputedProperty(binding) {
        self.diagnoseUnsupportedStreamParseableMember(
          in: variableDecl,
          message: "Only stored properties are supported.",
          context: context
        )
        continue
      }

      // A tuple pattern binds several properties at once, which the macro does not split, so they
      // would be absent from `Partial` and left unassigned by the generated initializers. A `let`
      // with an initial value is the exception: it is left out of `Partial` anyway.
      guard let identifierPattern = binding.pattern.as(IdentifierPatternSyntax.self) else {
        let isInitializedLet =
          variableDecl.bindingSpecifier.tokenKind == .keyword(.let) && binding.initializer != nil
        if !isInitializedLet {
          context.diagnose(
            Self.error(binding.pattern, "Stored properties must bind a single name.")
          )
        }
        continue
      }

      guard let type = Self.declaredType(ofBindingAt: index, in: bindings) else {
        context.diagnose(Self.error(binding, "Stored properties must declare an explicit type."))
        continue
      }

      properties.append(
        self.storedProperty(
          from: variableDecl,
          propertyName: StreamObjectGeneration.bareName(identifierPattern.identifier),
          type: type,
          defaultExpression: binding.initializer?.value.trimmedDescription,
          partialStrings: partialStrings,
          context: context
        )
      )
    }
    return properties
  }

  // `var a, b: Int` annotates only the last binding; the earlier ones share that type. Swift
  // carries an annotation back only over plain names with neither a type nor an initializer, and
  // only from a single name that has no initializer itself, so `var name = "Blob", age: Int`
  // leaves `name` untyped rather than an `Int`.
  private static func declaredType(
    ofBindingAt index: Int,
    in bindings: [PatternBindingSyntax]
  ) -> TypeSyntax? {
    if let type = bindings[index].typeAnnotation?.type { return type }
    guard bindings[index].initializer == nil else { return nil }
    for binding in bindings[(index + 1)...] {
      guard binding.pattern.is(IdentifierPatternSyntax.self) else { return nil }
      if let type = binding.typeAnnotation?.type {
        return binding.initializer == nil ? type : nil
      }
      guard binding.initializer == nil else { return nil }
    }
    return nil
  }

  private static func storedProperty(
    from variableDecl: VariableDeclSyntax,
    propertyName: String,
    type: TypeSyntax,
    defaultExpression: String?,
    partialStrings typePartialStrings: StreamPartialStrings,
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

    let members = Self.memberAttributes(in: variableDecl.attributes, context: context)
    let explicitKeyNames = isIgnored ? nil : Self.explicitKeyNames(in: members)
    let capacity =
      isIgnored
      ? nil
      : Self.memberArgument(
        named: "initialCapacity",
        of: members,
        repeated: "@StreamParseableMember(initialCapacity:) can only be specified once per property.",
        context: context
      )?.arguments.initialCapacity
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
    let conversion = Self.memberArgument(
      named: "completedConversion",
      of: members,
      repeated: "@StreamParseableMember(completedConversion:) can only be specified once per property.",
      context: context
    )?.arguments.completedConversion?.trimmedDescription
    let memberPartialStrings =
      isIgnored
      ? nil
      : Self.memberPartialStrings(
        of: members, in: variableDecl, type: type, hasConversion: conversion != nil,
        context: context
      )
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
      keyNames: explicitKeyNames ?? [propertyName],
      convertsKeys: !isIgnored && explicitKeyNames == nil,
      initialCapacity: capacity,
      isIgnored: isIgnored,
      access: Self.declaredAccess(of: variableDecl.modifiers),
      isUsableFromInline: Self.attribute(named: "usableFromInline", in: variableDecl.attributes) != nil,
      completedConversion: conversion,
      partialStrings: memberPartialStrings ?? typePartialStrings,
      defaultExpression: defaultExpression
    )
  }

  // A member's own `partialStrings:`. Diagnosed beside a `completedConversion:`, whose `Source` is
  // the storage, and warned where the type spells no `String` for it to reach -- an alias, say,
  // which keeps `StreamString` whatever is written.
  private static func memberPartialStrings(
    of members: [MemberAttribute],
    in variableDecl: VariableDeclSyntax,
    type: TypeSyntax,
    hasConversion: Bool,
    context: DiagnosticSink
  ) -> StreamPartialStrings? {
    guard
      let member = Self.memberArgument(
        named: "partialStrings",
        of: members,
        repeated: "@StreamParseableMember(partialStrings:) can only be specified once per property.",
        context: context
      ),
      let storage = member.arguments.partialStrings
    else { return nil }
    if hasConversion {
      context.diagnose(
        Self.error(variableDecl, "partialStrings: is not supported with completedConversion:.")
      )
    } else if !StreamObjectGeneration.containsStringLeaf(type) {
      context.diagnose(
        Diagnostic(
          node: member.attribute,
          message: MacroExpansionWarningMessage(
            """
            partialStrings: has no effect, because '\(type.trimmedDescription)' does not spell \
            String. The macro reads the type as written and cannot see through an alias.
            """
          )
        )
      )
    }
    return storage
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

  /// A `@StreamParseableMember` and the options it writes.
  struct MemberAttribute {
    let attribute: AttributeSyntax
    let arguments: StreamMacroArguments
  }

  /// Every `@StreamParseableMember` in `attributes`, each read once, so an unreadable argument is
  /// diagnosed once however many of the options are then asked for.
  static func memberAttributes(
    in attributes: AttributeListSyntax,
    context: DiagnosticSink
  ) -> [MemberAttribute] {
    Self.attributes(named: "StreamParseableMember", in: attributes).map {
      MemberAttribute(attribute: $0, arguments: context.arguments(of: $0))
    }
  }

  /// The keys the `@StreamParseableMember`s write out, or `nil` when the declaration is read from
  /// its name, which a key decoding strategy converts.
  static func explicitKeyNames(in members: [MemberAttribute]) -> [String]? {
    let names = members.flatMap { $0.arguments.keys ?? [] }
    return names.isEmpty ? nil : names
  }

  /// Claims the key `name` is read from in `seen`, and diagnoses one already claimed. A key a
  /// strategy converts only when the schema is built is unknown here; the built table checks it.
  static func claimKey(
    of name: String,
    converting: Bool,
    by keyDecoding: StreamGenerationConfiguration,
    in seen: inout Set<String>,
    noun: String = "Key",
    claimant: String,
    at node: some SyntaxProtocol,
    context: DiagnosticSink
  ) {
    guard let key = converting ? keyDecoding.decodedKey(for: name) : name,
      !seen.insert(key).inserted
    else { return }
    let origin = key == name ? "" : " (converted from '\(name)')"
    context.diagnose(
      Self.error(node, "\(noun) '\(key)'\(origin) is already claimed by another \(claimant).")
    )
  }

  // The first of `members` that writes `name:`, whose value is that option's, `nil` where it is
  // unreadable. Every later one is diagnosed with `repeated`. An explicit `nil`, which the
  // optional overloads default to, counts as unwritten.
  private static func memberArgument(
    named name: String,
    of members: [MemberAttribute],
    repeated: String,
    context: DiagnosticSink
  ) -> MemberAttribute? {
    var found: MemberAttribute?
    for member in members {
      guard let expression = Self.argument(named: name, of: member.attribute),
        !expression.is(NilLiteralExprSyntax.self)
      else { continue }
      guard found == nil else {
        context.diagnose(Self.error(member.attribute, repeated))
        continue
      }
      found = member
    }
    return found
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
}
