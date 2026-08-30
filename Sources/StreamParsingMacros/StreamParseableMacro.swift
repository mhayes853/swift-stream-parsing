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
    let conversionMembers = Self.conversionMembers(
      from: properties,
      modifierPrefix: Self.modifierPrefix(for: accessModifier),
      membersMode: membersMode
    )

    // A hand written `Partial` still gets the conversions, on the same terms as
    // `streamPartialValue`: they are written from the stored properties, so a `Partial` that
    // mirrors them works and one that does not says so where it differs.
    if hasExistingPartial {
      return [
        try ExtensionDeclSyntax(
          """
          extension \(raw: typeName): StreamParsingCore.StreamParseable {
            \(raw: conversionMembers)
          }
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
    let viewLines = Self.partialStructView(
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

        \(raw: viewLines)

        \(raw: schemaLines)
      }
      """
  }

  private static func partialStructView(
    from properties: [StoredProperty],
    modifierPrefix: String
  ) -> String {
    let active = properties.filter { !$0.isIgnored }
    let accessors = active
      .map { property in
        let type = Self.partialTypeName(for: property)
        return """
            \(modifierPrefix)var \(property.name): \(type).View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.\(property.name)) else {
                    return nil
                  }
                  return _overrideLifetime(\(type).streamView(address), borrowing: self)
                }
              }
          """
      }
      .joined(separator: "\n\n")
    let body = active.isEmpty ? "" : "\n\(accessors)\n"
    return """
      \(modifierPrefix)struct View: ~Copyable, ~Escapable {
          \(modifierPrefix)let storage: UnsafeMutablePointer<Partial>

          @_lifetime(borrow storage)
          \(modifierPrefix)init(_ storage: UnsafeMutableRawPointer) {
            self.storage = storage.assumingMemoryBound(to: Partial.self)
          }
      \(body)  }

        @_lifetime(borrow storage)
        \(modifierPrefix)static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
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

  private static func keyWordLiteral(for key: String, at start: Int = 0) -> String {
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

  private static func stringLiteral(_ key: String) -> String {
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

  private static func keyMatchGuard(for key: String) -> String {
    let count = key.utf8.count
    var conditions = ["key.count == \(count)"]
    var offset = 8
    while offset < count {
      conditions.append(
        "key.paddedWord(at: \(offset)) == \(Self.keyWordLiteral(for: key, at: offset))"
      )
      offset += 8
    }
    return " where " + conditions.joined(separator: " && ")
  }

  private enum FieldShape {
    case scalarOrObject(String)
    case array(String)
    case dictionary(String)
  }

  private struct SchemaCases: Hashable, Sendable {
    var match = [String]()
    // One table entry per key name. See `StreamFieldTable.swift`.
    var fields = [String]()
    var applyString = [String]()
    var applyNumber = [String]()
    var applyBoolean = [String]()
    var applyNull = [String]()
    // One stored schema per container field. See `containerSchemaConstants`.
    var containerSchemas = [String]()
  }

  private static func fieldShape(for type: TypeSyntax) -> FieldShape {
    let unwrapped = Self.unwrappedType(type)
    if let array = unwrapped.as(ArrayTypeSyntax.self) {
      return .array(array.element.trimmedDescription)
    }
    if let dictionary = unwrapped.as(DictionaryTypeSyntax.self) {
      return .dictionary(dictionary.value.trimmedDescription)
    }
    return .scalarOrObject(unwrapped.trimmedDescription)
  }

  // Both the storage type and the schema are named from the *unwrapped* element or value type,
  // and an optional one picks the builder that opens its slot materialised.
  //
  // Naming them from different types is what made `[String?]` crash: the storage was
  // `StreamArray<StreamString?>`, whose `streamInitialValue()` is `nil`, while the element schema
  // was `StreamString`'s and wrote straight through the `.none` representation. The wrapped type
  // is the one both sides agree on, and `_streamOptionalArraySchema` carries the optionality by
  // opening the slot as `.some` and deriving an element schema that can null it.
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

  private static func fieldConstants(for properties: [StoredProperty]) -> String {
    guard !properties.isEmpty else { return "" }
    let constants = properties.enumerated()
      .map { index, property in "    static let \(property.name): Int32 = \(index)" }
      .joined(separator: "\n")
    return """
      private enum StreamField {
      \(constants)
        }
      """ + "\n\n  "
  }

  private static func schemaCases(for properties: [StoredProperty]) -> SchemaCases {
    var cases = SchemaCases()
    for property in properties {
      let field = "Self.StreamField.\(property.name)"
      for key in property.keyNames {
        let word = Self.keyWordLiteral(for: key)
        let guardClause = Self.keyMatchGuard(for: key)
        cases.match.append("    case \(word)\(guardClause): return \(field)")
      }

      let target = "p.pointee.\(property.name)"
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
      switch Self.fieldShape(for: property.type) {
      case .scalarOrObject:
        cases.applyString.append(
          "    case \(field): return streamApply(&\(target), utf8: bytes\(capacityArgument))"
        )
        cases.applyNumber.append(
          "    case \(field): return streamApply(&\(target), bytes: bytes, info: info)"
        )
        cases.applyBoolean.append(
          "    case \(field): return streamApply(&\(target), boolean: value)"
        )
        cases.applyNull.append(
          "    case \(field): return StreamParsing.streamApplyNull(&\(target))"
        )
        cases.containerSchemas.append(
          "private static let \(constant) = _streamContainerSchema(for: (\(Self.partialTypeName(for: property))).self)"
        )
      case .array, .dictionary:
        // A container field can be nulled like any other. Emitted through the same helper as a
        // scalar's, so an optional member clears and a non-optional one falls to the disfavoured
        // overload and stays the mismatch it was — where before neither reached a case at all and
        // `{"scores":null}` was a type mismatch however the member was declared.
        cases.applyNull.append(
          "    case \(field): return StreamParsing.streamApplyNull(&\(target))"
        )
        cases.containerSchemas.append(
          "private static let \(constant) = \(Self.schemaExpression(for: property.type))"
        )
      }
    }
    return cases
  }

  private static func partialStructSchema(
    from properties: [StoredProperty],
    modifierPrefix: String,
    membersMode: PartialMembersMode
  ) -> String {
    let active = properties.filter { !$0.isIgnored }
    let cases = Self.schemaCases(for: active)

    func switchBody(_ cases: [String]) -> String {
      cases.isEmpty ? "" : cases.joined(separator: "\n") + "\n"
    }

    func storageBinding(_ cases: [String]) -> String {
      cases.isEmpty ? "" : "    let p = storage.assumingMemoryBound(to: Self.self)\n"
    }

    return """
      \(Self.fieldConstants(for: active))\(Self.containerSchemaConstants(cases.containerSchemas))\(modifierPrefix)static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
          switch key.paddedLeadingWord() {
      \(switchBody(cases.match))    default: return -1
          }
        }

        \(modifierPrefix)static func streamApplyString(
          _ storage: UnsafeMutableRawPointer, _ field: Int32,
          _ bytes: Span<UInt8>
        ) -> StreamParsingCore.StreamApplyResult {
      \(storageBinding(cases.applyString))    switch field {
      \(switchBody(cases.applyString))    default: return .unsupported
          }
        }

        \(modifierPrefix)static func streamApplyNumber(
          _ storage: UnsafeMutableRawPointer, _ field: Int32,
          _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
        ) -> StreamParsingCore.StreamApplyResult {
      \(storageBinding(cases.applyNumber))    switch field {
      \(switchBody(cases.applyNumber))    default: return .unsupported
          }
        }

        \(modifierPrefix)static func streamApplyBoolean(
          _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
        ) -> StreamParsingCore.StreamApplyResult {
      \(storageBinding(cases.applyBoolean))    switch field {
      \(switchBody(cases.applyBoolean))    default: return .unsupported
          }
        }

        \(modifierPrefix)static func streamApplyNull(
          _ storage: UnsafeMutableRawPointer, _ field: Int32
        ) -> StreamParsingCore.StreamApplyResult {
      \(storageBinding(cases.applyNull))    switch field {
      \(switchBody(cases.applyNull))    default: return .unsupported
          }
        }

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
        return "  \(modifierPrefix)var \(property.name): \(type)"
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

  // Both spellings of an optional, because a member written `Optional<Int>` reached none of the
  // sugar-only tests: it kept the double optional after the sugared form stopped emitting one,
  // which is a worse place to be than uniformly wrong. `fieldShape` and `schemaExpression` unwrap
  // through here too, so a generically spelled optional array or dictionary routes as the
  // container it is.
  private static func unwrappedType(_ type: TypeSyntax) -> TypeSyntax {
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

  // The type a `Partial` stores for a property: one level of optionality, never two.
  //
  // It used to be two whenever the source property was itself optional. `partialTypeName` kept the
  // `?` — `Int?.Partial` is `Int?` — and the mode appended another, so the member was `Int??`
  // while every schema emitted for it described `Int`. Nothing bridged that gap: `streamApply` has
  // `inout T` and `inout T?` overloads and no `inout T??`, so a scalar written to such a member
  // fell through to the no-op overload and was reported as a type mismatch, and a container member
  // had its outer optional materialised around a `nil` inner and dropped its elements in silence.
  // Only `null` worked, because `Int??` is `StreamNullable`, and only `null` was tested.
  //
  // The mode still decides whether a *non*-optional property becomes optional here. An optional
  // one already is, in both modes: `.streamInitialValue` gives a member that starts nil rather
  // than one that cannot be null.
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
        return "\(property.name): \(type) = \(membersMode.defaultValueSyntax)"
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
          // `Dictionary`'s own `streamPartialValue` cannot be used here: the member is a
          // `StreamDictionary`, so the values are mapped and rewrapped. An optional member maps
          // through the optional rather than reaching for `mapValues` on it, which did not
          // compile at all.
          let converted = "StreamParsingCore.StreamDictionary($0.mapValues(\\.streamPartialValue))"
          let value =
            Self.isOptional(property.type)
            ? "self.\(property.name).map { \(converted) }"
            : "StreamParsingCore.StreamDictionary(self.\(property.name).mapValues(\\.streamPartialValue))"
          return "    \(property.name): \(value)\(suffix)"
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

  // MARK: - Partial to whole

  // The inverse direction, emitted into the extension rather than the member block. An
  // initializer declared in the type body suppresses the compiler's memberwise initializer; one
  // declared in an extension does not, and can still assign stored properties directly.
  //
  // Nothing here spells a member's type. Each conversion goes through `_streamValue` /
  // `_streamValueOrInitial`, whose first argument binds the destination type from the property
  // itself — so the type the macro derived for `Partial` is checked against the one the compiler
  // derives, instead of being derived a second time and trusted.
  private static func conversionMembers(
    from properties: [StoredProperty],
    modifierPrefix: String,
    membersMode: PartialMembersMode
  ) -> String {
    let active = properties.filter { !$0.isIgnored }
    // An ignored property is absent from `Partial`, so a generated initializer has nothing to
    // fill it from. One that initializes itself is already set; the rest are optional, because
    // `storedProperty(from:...)` refuses to accept any other kind.
    let ignoredLines =
      properties
      .filter { $0.isIgnored && !$0.hasDefaultValue }
      .map { "    self.\($0.name) = nil" }

    func assignments(_ helper: String) -> String {
      let lines =
        active.map { "    self.\($0.name) = Self.\(helper)({ $0.\($0.name) }, partial.\($0.name))" }
        + ignoredLines
      return lines.joined(separator: "\n")
    }

    let strictBody: String
    if active.isEmpty {
      strictBody = ignoredLines.joined(separator: "\n")
    } else {
      let bindings =
        active
        .map { "      let \($0.name) = Self._streamValue({ $0.\($0.name) }, partial.\($0.name))" }
        .joined(separator: ",\n")
      let stores = (active.map { "    self.\($0.name) = \($0.name)" } + ignoredLines)
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
      \(modifierPrefix)init?(_ partial: Partial) {
          self.init(streamPartial: partial)
        }
      """
    let totalInit = """
      \(modifierPrefix)init(_ partial: Partial) {
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

        \(modifierPrefix)static func streamValueOrInitial(from partial: Partial) -> Self {
          Self(orInitial: partial)
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
    let keyNames: [String]
    let initialCapacity: Int?
    let isIgnored: Bool
    // Whether the declaration supplies its own value. A generated initializer must leave such a
    // property alone: it is already initialized, and if it is a `let` it cannot be assigned twice.
    let hasDefaultValue: Bool
  }

  private struct KeyNamesResult {
    let names: [String]
    let diagnostics: [Diagnostic]
  }

  private struct InitialCapacityResult {
    let value: Int?
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
    if isIgnored, !hasDefaultValue, !Self.isOptional(type) {
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
      hasDefaultValue: hasDefaultValue
    )
  }

  private static func diagnoseUnsettableIgnoredMember(
    in variableDecl: VariableDeclSyntax,
    propertyName: String,
    context: some MacroExpansionContext
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

  private static func initialCapacity(
    for variableDecl: VariableDeclSyntax
  ) -> InitialCapacityResult {
    var value: Int?
    var sawCapacity = false
    var diagnostics = [Diagnostic]()

    for attribute in self.streamParseableMemberAttributes(in: variableDecl) {
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
