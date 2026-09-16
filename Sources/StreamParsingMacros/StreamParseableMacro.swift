import SwiftDiagnostics
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

    let properties = Self.storedProperties(in: structDecl, context: sink)
    let accessModifier = Self.accessModifier(for: structDecl.modifiers)
    let hasStreamPartialValue = Self.hasExistingStreamPartialValue(in: structDecl.memberBlock.members)
    let modifierPrefix = Self.modifierPrefix(for: accessModifier)
    let streamPartialValuePropertySection =
      !hasStreamPartialValue
      ? Self.streamPartialValueProperty(
        from: properties,
        modifierPrefix: modifierPrefix,
        inlinable: Self.isInlinable(accessModifier)
          && properties.allSatisfy { $0.isIgnored || $0.isReadableInline(from: accessModifier) }
      )
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
        of: node, declaration: enumDecl, type: type, in: sink
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
    let conversionMembers = Self.conversionMembers(
      from: properties,
      modifierPrefix: Self.modifierPrefix(for: accessModifier),
      membersMode: membersMode,
      inlinable: Self.isInlinable(accessModifier)
    )

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

    let partialStruct = Self.partialStructDecl(
      for: properties,
      accessModifier: accessModifier,
      membersMode: membersMode
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
    return stated ? "" : ": StreamParsingCore.StreamParseable"
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
    extraViewMembers: String = ""
  ) -> DeclSyntax {
    let modifierPrefix = Self.modifierPrefix(for: accessModifier)
    let inlinable = Self.isInlinable(accessModifier)
    let inline = Self.inlinableAttribute(inlinable)
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
    let observationPaths = properties.filter { !$0.isIgnored }
      .map { "\\.\($0.memberName)" }.joined(separator: ", ")
    let schemaLines = Self.partialStructSchema(
      from: properties,
      modifierPrefix: modifierPrefix,
      inlinable: inlinable
    )
    let viewLines = Self.partialStructView(
      from: properties,
      modifierPrefix: modifierPrefix,
      inlinable: inlinable,
      extraViewMembers: extraViewMembers
    )
    // An inlinable body cannot name a `private` declaration.
    let templateAccess = inlinable ? "@usableFromInline " : "private "
    return """
      \(raw: modifierPrefix)struct Partial: StreamParsingCore.StreamParseable,
        StreamParsingCore.StreamParseableObject, Sendable {
        \(raw: modifierPrefix)typealias Partial = Self

      \(raw: propertyLines)

        \(raw: initializerLines)

        // Cached rather than re-evaluated: `Self()` walks every default expression fresh, which
        // for a large nested struct is a long chain of small copies. Every member's own `Partial`
        // is `Sendable` (every leaf and every "Fast" container conforms), which is what makes
        // `Self` itself `Sendable` here and lets the template be a plain `static let`.
        \(raw: templateAccess)static let _streamInitialValueTemplate: Self = Self()

        \(raw: inline)\(raw: modifierPrefix)static func streamInitialValue() -> Self {
          Self._streamInitialValueTemplate
        }

        #if !hasFeature(Embedded)
        \(raw: modifierPrefix)static var streamObservationFields: [PartialKeyPath<Self>] {
          [\(raw: observationPaths)]
        }
        #endif

        \(raw: viewLines)

        \(raw: schemaLines)
      }
      """
  }

  private static func partialStructView(
    from properties: [StoredProperty],
    modifierPrefix: String,
    inlinable: Bool,
    extraViewMembers: String = ""
  ) -> String {
    let inline = Self.inlinableAttribute(inlinable)
    let active = properties.filter { !$0.isIgnored }
    let accessors = active
      .map { property in
        let type = Self.partialTypeName(for: property)
        return """
            \(inline)\(modifierPrefix)var \(property.memberName): \(type).View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.\(property.memberName)) else {
                    return nil
                  }
                  return _overrideLifetime(\(type).streamView(address), borrowing: self)
                }
              }
          """
      }
      .joined(separator: "\n\n")
    let body = active.isEmpty ? "" : "\n\(accessors)\n"
    // `extraViewMembers` is how the enum lowering gets `ResolvedView`/`resolved` in here: they
    // have to be real members of `View`, since an extension macro can only extend the type it is
    // attached to.
    let closing = extraViewMembers.isEmpty ? "  }" : "  \n\(extraViewMembers)\n}"
    // `_streamStorage`, not `storage`: a member named `storage` would otherwise redeclare it.
    // `@frozen` so the inlinable `init` stays legal under library evolution; it is one pointer.
    let frozen = inlinable ? "@frozen " : ""
    return """
      \(frozen)\(modifierPrefix)struct View: ~Copyable, ~Escapable {
          \(modifierPrefix)let _streamStorage: UnsafeMutablePointer<Partial>

          @_lifetime(borrow storage)
          \(inline)\(modifierPrefix)init(_ storage: UnsafeMutableRawPointer) {
            self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
          }
      \(body)\(closing)

        @_lifetime(borrow storage)
        \(inline)\(modifierPrefix)static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
          View(storage)
        }
      """
  }

  private static func paddedWord(for key: String, at start: Int = 0) -> UInt64 {
    var word: UInt64 = 0
    for (offset, byte) in Array(key.utf8).dropFirst(start).prefix(8).enumerated() {
      word |= UInt64(byte) << (offset * 8)
    }
    return word
  }

  static func keyWordLiteral(for key: String, at start: Int = 0) -> String {
    let word = Self.paddedWord(for: key, at: start)
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

  static func stringLiteral(_ key: String) -> String {
    var escaped = ""
    for scalar in key.unicodeScalars {
      switch scalar {
      case "\\": escaped += "\\\\"
      case "\"": escaped += "\\\""
      default: escaped.unicodeScalars.append(scalar)
      }
    }
    return "\"\(escaped)\""
  }

  // The exact-match `where` clause, shared by object keys (`keyMatchGuard`) and `String`-raw
  // values (`enumMatchGuard`). The count is load bearing below eight bytes too, because a decoded
  // NUL is otherwise indistinguishable from `paddedWord`'s zero padding.
  static func matchGuard(for name: String, count: String, word: String) -> String {
    let byteCount = name.utf8.count
    var conditions = ["\(count) == \(byteCount)"]
    var offset = 8
    while offset < byteCount {
      conditions.append("\(word)(at: \(offset)) == \(Self.keyWordLiteral(for: name, at: offset))")
      offset += 8
    }
    return " where " + conditions.joined(separator: " && ")
  }

  private static func keyMatchGuard(for key: String) -> String {
    Self.matchGuard(for: key, count: "key.count", word: "key.paddedWord")
  }

  private enum FieldShape {
    case scalarOrObject
    case array
    case dictionary(String)
  }

  // One of the four `streamApplyX` functions. They differ only in signature, in what a matched
  // field does with the value, and in whether a container field takes part: a container is only
  // ever nulled, never written a scalar.
  private struct ApplyFunction {
    let name: String
    /// The parameter list, laid out for the generated signature's four-space continuation.
    let parameters: String
    let body: (_ field: String, _ target: String, _ capacity: String) -> String
    let acceptsContainers: Bool
    var cases = [String]()
  }

  private struct SchemaCases {
    var match = [String]()
    // One table entry per key name. See `StreamFieldTable.swift`.
    var fields = [String]()
    // One stored schema per container field. See `containerSchemaConstants`.
    var containerSchemas = [String]()
    var applies = [
      ApplyFunction(
        name: "streamApplyString",
        parameters: "_ storage: UnsafeMutableRawPointer, _ field: Int32,\n    _ bytes: Span<UInt8>",
        body: { "    case \($0): return streamApply(&\($1), utf8: bytes\($2))" },
        acceptsContainers: false
      ),
      ApplyFunction(
        name: "streamApplyNumber",
        parameters: """
          _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
          """,
        body: { field, target, _ in
          "    case \(field): return streamApply(&\(target), bytes: bytes, info: info)"
        },
        acceptsContainers: false
      ),
      ApplyFunction(
        name: "streamApplyBoolean",
        parameters: "_ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool",
        body: { field, target, _ in
          "    case \(field): return streamApply(&\(target), boolean: value)"
        },
        acceptsContainers: false
      ),
      ApplyFunction(
        name: "streamApplyNull",
        parameters: "_ storage: UnsafeMutableRawPointer, _ field: Int32",
        body: { field, target, _ in
          "    case \(field): return StreamParsing.streamApplyNull(&\(target))"
        },
        // A container field can be nulled like any other: an optional member clears, and a
        // non-optional one falls to the disfavoured overload and stays the mismatch it was.
        acceptsContainers: true
      )
    ]
  }

  private static func fieldShape(for type: TypeSyntax) -> FieldShape {
    let unwrapped = Self.unwrappedType(type)
    if unwrapped.is(ArrayTypeSyntax.self) { return .array }
    if let dictionary = unwrapped.as(DictionaryTypeSyntax.self) {
      return .dictionary(dictionary.value.trimmedDescription)
    }
    return .scalarOrObject
  }

  // Storage type and schema are both named from the *unwrapped* element or value type — naming
  // them from different types is what made `[String?]` write through a `.none` representation.
  // An optional element picks the builder that opens its slot materialised instead.
  private static func schemaExpression(for type: TypeSyntax) -> String {
    let unwrapped = Self.unwrappedType(type)
    if let array = unwrapped.as(ArrayTypeSyntax.self) {
      return Self.containerSchemaExpression(
        "Array", element: array.element, builder: "_streamOptionalArraySchema", label: "element"
      )
    }
    if let dictionary = unwrapped.as(DictionaryTypeSyntax.self) {
      return Self.containerSchemaExpression(
        "Dictionary", element: dictionary.value, builder: "_streamOptionalDictionarySchema",
        label: "value"
      )
    }
    return "_streamSchema(for: \(unwrapped.trimmedDescription).Partial.self)"
  }

  private static func containerSchemaExpression(
    _ kind: String,
    element: TypeSyntax,
    builder optionalBuilder: String,
    label: String
  ) -> String {
    let storage = Self.unwrappedType(element).trimmedDescription
    let base = Self.schemaExpression(for: element)
    let builder = Self.isOptional(element) ? optionalBuilder : "_stream\(kind)Schema"
    return "\(builder)(\(storage).Partial.self, \(label): \(base))"
  }

  // A container field's schema, stored once per type rather than built once per container. These
  // are `private` because nothing outside `streamEnterField` reads them, and they are emitted
  // even when the type has no container fields costs nothing, since the list is empty then.
  private static func containerSchemaConstants(_ constants: [String]) -> String {
    guard !constants.isEmpty else { return "" }
    return constants.joined(separator: "\n  ") + "\n\n  "
  }

  // Computed when inlinable: another module sees an inlinable getter's constant, not a `let`'s.
  private static func fieldConstants(for properties: [StoredProperty], inlinable: Bool) -> String {
    guard !properties.isEmpty else { return "" }
    let constants = properties.enumerated()
      .map { index, property in
        inlinable
          ? "    @inlinable static var \(property.memberName): Int32 { \(index) }"
          : "    static let \(property.memberName): Int32 = \(index)"
      }
      .joined(separator: "\n")
    let access = inlinable ? "@usableFromInline" : "private"
    return """
      \(access) enum StreamField {
      \(constants)
        }
      """ + "\n\n  "
  }

  private static func schemaCases(for properties: [StoredProperty]) -> SchemaCases {
    var cases = SchemaCases()
    for property in properties {
      let field = "Self.StreamField.\(property.memberName)"
      for key in property.keyNames {
        let word = Self.keyWordLiteral(for: key)
        let guardClause = Self.keyMatchGuard(for: key)
        cases.match.append("    case \(word)\(guardClause): return \(field)")
      }

      let target = "p.pointee.\(property.memberName)"
      let constant = "streamContainerSchema_\(property.name)"
      let capacityArgument = property.initialCapacity.map { ", initialCapacity: \($0)" } ?? ""
      for key in property.keyNames {
        cases.fields.append(
          """
                StreamParsingCore.StreamField(
                  key: \(Self.stringLiteral(key)), index: \(field),
                  route: _streamFieldRoute(&\(target), schema: Self.\(constant)\(capacityArgument)),
                  offset: StreamParsingCore._streamFieldOffset(&\(target), in: p)
                ),
          """
        )
      }
      let isContainer: Bool
      switch Self.fieldShape(for: property.type) {
      case .scalarOrObject:
        isContainer = false
        cases.containerSchemas.append(
          "private static let \(constant) = _streamContainerSchema(for: (\(Self.partialTypeName(for: property))).self)"
        )
      case .array, .dictionary:
        isContainer = true
        cases.containerSchemas.append(
          "private static let \(constant) = \(Self.schemaExpression(for: property.type))"
        )
      }
      for index in cases.applies.indices where !isContainer || cases.applies[index].acceptsContainers {
        cases.applies[index].cases.append(
          cases.applies[index].body(field, target, capacityArgument)
        )
      }
    }
    return cases
  }

  private static func partialStructSchema(
    from properties: [StoredProperty],
    modifierPrefix: String,
    inlinable: Bool
  ) -> String {
    let inline = Self.inlinableAttribute(inlinable)
    let active = properties.filter { !$0.isIgnored }
    let cases = Self.schemaCases(for: active)

    func switchBody(_ cases: [String]) -> String {
      cases.isEmpty ? "" : cases.joined(separator: "\n") + "\n"
    }

    func storageBinding(_ cases: [String]) -> String {
      cases.isEmpty ? "" : "    let p = storage.assumingMemoryBound(to: Self.self)\n"
    }

    let applyFunctions = cases.applies
      .map { function in
        """
          \(inline)\(modifierPrefix)static func \(function.name)(
            \(function.parameters)
          ) -> StreamParsingCore.StreamApplyResult {
        \(storageBinding(function.cases))    switch field {
        \(switchBody(function.cases))    default: return .unsupported
            }
          }
        """
      }
      .joined(separator: "\n\n")

    return """
      \(Self.fieldConstants(for: active, inlinable: inlinable))\(Self.containerSchemaConstants(cases.containerSchemas))\(inline)\(modifierPrefix)static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
          switch key.paddedLeadingWord() {
      \(switchBody(cases.match))    default: return -1
          }
        }

      \(applyFunctions)

        \(modifierPrefix)static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
          of: Self.self, prototype: Self()
        ) { p in
          [
      \(switchBody(cases.fields))    ]
        }

        \(modifierPrefix)static let streamSchema = StreamParsingCore.StreamSchema(
          shape: .object,
          matchField: Self.streamMatchField,
          applyString: Self.streamApplyString,
          applyNumber: Self.streamApplyNumber,
          applyBoolean: Self.streamApplyBoolean,
          applyNull: Self.streamApplyNull,
          fields: Self.streamFields
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
        let type = Self.memberTypeName(for: property, membersMode: membersMode)
        return "  \(modifierPrefix)var \(property.memberName): \(type)"
      }
    return lines.joined(separator: "\n")
  }

  // The partial storage a property's *wrapped* type describes, with no optionality of its own.
  // Every schema the macro emits is built from the same unwrapped type, so keeping the two in step
  // is what makes the member the schema writes through and the member the type declares the same
  // member.
  private static func partialTypeName(for property: StoredProperty) -> String {
    if case .dictionary(let value) = Self.fieldShape(for: property.type) {
      return "StreamParsingCore.StreamDictionary<\(value).Partial>"
    }
    return "\(Self.unwrappedType(property.type).trimmedDescription).Partial"
  }

  // Both spellings of an optional (`Int?` and `Optional<Int>`), and every layer of it: `Int??`
  // unwrapped once left a member no schema described, so only `null` ever reached it.
  private static func unwrappedType(_ type: TypeSyntax) -> TypeSyntax {
    var current = type
    while true {
      let next = Self.unwrappedOnce(current)
      if next == current { return current }
      current = next
    }
  }

  private static func unwrappedOnce(_ type: TypeSyntax) -> TypeSyntax {
    if let optional = type.as(OptionalTypeSyntax.self) { return optional.wrappedType }
    let name: String
    let arguments: GenericArgumentListSyntax?
    if let identifier = type.as(IdentifierTypeSyntax.self) {
      name = identifier.name.text
      arguments = identifier.genericArgumentClause?.arguments
    } else if let member = type.as(MemberTypeSyntax.self) {
      name = member.name.text
      arguments = member.genericArgumentClause?.arguments
    } else {
      return type
    }
    guard name == "Optional",
      let arguments,
      arguments.count == 1,
      case .type(let wrapped) = arguments.first?.argument
    else {
      return type
    }
    return wrapped
  }

  private static func isOptional(_ type: TypeSyntax) -> Bool {
    Self.unwrappedType(type) != type
  }

  // The type a `Partial` stores for a property: one level of optionality, never two — there is
  // no `inout T??` overload of `streamApply`, so a doubly optional member is unwritable.
  //
  // The mode decides whether a *non*-optional property becomes optional here; an optional one
  // already is, in both modes.
  private static func memberTypeName(
    for property: StoredProperty,
    membersMode: PartialMembersMode
  ) -> String {
    let base = Self.partialTypeName(for: property)
    let isOptional = membersMode.shouldEmitOptionalMembers || Self.isOptional(property.type)
    return isOptional ? "\(base)?" : base
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
        let type = Self.memberTypeName(for: property, membersMode: membersMode)
        return "\(property.memberName): \(type) = \(membersMode.defaultValueSyntax)"
      }
      .joined(separator: ",\n    ")
    let assignments =
      activeProperties
      .map { property in
        "    self.\(property.memberName) = \(property.memberName)"
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

  static func streamPartialValueProperty(
    from properties: [StoredProperty],
    modifierPrefix: String,
    inlinable: Bool
  ) -> String {
    let inline = Self.inlinableAttribute(inlinable)
    let activeProperties = properties.filter { !$0.isIgnored }
    guard !activeProperties.isEmpty else {
      return """
          \(inline)\(modifierPrefix)var streamPartialValue: Partial {
            Partial()
          }
        """
    }

    let argumentLines = activeProperties.enumerated()
      .map { index, property in
        let suffix = index == activeProperties.count - 1 ? "" : ","
        if case .dictionary = Self.fieldShape(for: property.type) {
          // `Dictionary`'s own `streamPartialValue` cannot be used here: the member is a
          // `StreamDictionary`, so the values are mapped and rewrapped. An optional member maps
          // through the optional rather than reaching for `mapValues` on it, which did not
          // compile at all.
          let converted = "StreamParsingCore.StreamDictionary($0.mapValues(\\.streamPartialValue))"
          let value =
            Self.isOptional(property.type)
            ? "self.\(property.memberName).map { \(converted) }"
            : "StreamParsingCore.StreamDictionary(self.\(property.memberName).mapValues(\\.streamPartialValue))"
          return "    \(property.memberName): \(value)\(suffix)"
        }
        return "    \(property.memberName): self.\(property.memberName).streamPartialValue\(suffix)"
      }
      .joined(separator: "\n")

    return """
      \(inline)\(modifierPrefix)var streamPartialValue: Partial {
        Partial(
      \(argumentLines)
        )
      }
      """
  }

  // MARK: - Partial to whole

  // The inverse direction, emitted into the extension so the memberwise initializer survives.
  // Nothing here spells a member's type: `_streamValue`/`_streamValueOrInitial` bind it from the
  // property itself, so the type the macro derived for `Partial` is checked, not trusted.
  static func conversionMembers(
    from properties: [StoredProperty],
    modifierPrefix: String,
    membersMode: PartialMembersMode,
    inlinable: Bool
  ) -> String {
    // Only the delegating members: under library evolution an `@inlinable` struct initializer
    // that assigns stored properties does not compile (the memberwise `Partial.init` likewise).
    let inline = Self.inlinableAttribute(inlinable)
    let active = properties.filter { !$0.isIgnored }
    // An ignored property is absent from `Partial`, so a generated initializer has nothing to
    // fill it from. One that initializes itself is already set; the rest are optional, because
    // `storedProperty(from:...)` refuses to accept any other kind.
    let ignoredLines =
      properties
      .filter { $0.isIgnored && !$0.hasDefaultValue }
      .map { "    self.\($0.memberName) = nil" }

    func assignments(_ helper: String) -> String {
      let lines =
        active.map {
          "    self.\($0.memberName) = Self.\(helper)({ $0.\($0.memberName) }, partial.\($0.memberName))"
        }
        + ignoredLines
      return lines.joined(separator: "\n")
    }

    let strictBody: String
    if active.isEmpty {
      strictBody = ignoredLines.joined(separator: "\n")
    } else {
      let bindings =
        active
        .map {
          "      let \($0.memberName) = Self._streamValue({ $0.\($0.memberName) }, partial.\($0.memberName))"
        }
        .joined(separator: ",\n")
      let stores = (active.map { "    self.\($0.memberName) = \($0.memberName)" } + ignoredLines)
        .joined(separator: "\n")
      strictBody = """
            guard
        \(bindings)
            else {
              return nil
            }
        \(stores)
        """
    }

    // The unlabelled initializer is the one the mode names. With optional members absence is
    // visible, so it is the strict conversion and it can decline; with members that start at
    // their initial values absence is not expressible, so it is the total one and cannot.
    let decliningInit = """
      \(inline)\(modifierPrefix)init?(_ partial: Partial) {
          self.init(streamPartial: partial)
        }
      """
    let totalInit = """
      \(inline)\(modifierPrefix)init(_ partial: Partial) {
          self.init(orInitial: partial)
        }
      """
    let unlabelled = membersMode.shouldEmitOptionalMembers ? decliningInit : totalInit

    return """
      \(unlabelled)

        /// Fails when the stream did not produce a member this type has no way to do without.
        \(modifierPrefix)init?(streamPartial partial: Partial) {
      \(strictBody)
        }

        /// Fills members the stream did not produce with their initial values, keeping the ones
        /// it did.
        \(modifierPrefix)init(orInitial partial: Partial) {
      \(assignments("_streamValueOrInitial"))
        }

        \(inline)\(modifierPrefix)static func streamValueOrInitial(from partial: Partial) -> Self {
          Self(orInitial: partial)
        }
      """
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
    if hasIgnoredAttribute, !hasDefaultValue, !Self.isOptional(type) {
      Self.diagnoseUnsettableIgnoredMember(
        in: variableDecl,
        propertyName: propertyName,
        context: context
      )
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
        .isEmpty
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
        guard let keyName = self.stringLiteralValue(from: keyExpression) else {
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
  static func stringLiteralValue(from expression: ExprSyntax) -> String? {
    guard let literal = expression.as(StringLiteralExprSyntax.self) else { return nil }
    var value = ""
    for segment in literal.segments {
      guard let text = segment.as(StringSegmentSyntax.self)?.content.text else { return nil }
      value += text
    }
    return value
  }

  private static func stringArrayValues(from expression: ExprSyntax) -> [String]? {
    guard let arrayExpression = expression.as(ArrayExprSyntax.self) else { return nil }
    var values = [String]()
    for element in arrayExpression.elements {
      guard let value = self.stringLiteralValue(from: element.expression) else { return nil }
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

    var shouldEmitOptionalMembers: Bool {
      self == .optional
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
