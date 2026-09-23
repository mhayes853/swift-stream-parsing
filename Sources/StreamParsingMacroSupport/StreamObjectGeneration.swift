import SwiftBasicFormat
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// The declarations produced by this module refer to public symbols vended by `StreamParsing`.
// A source file that inserts them must import `StreamParsing`, which reexports
// `StreamParsingCore`.

extension TokenSyntax {
  /// The conventional nested stream view type name.
  public static var streamView: Self { Self.identifier("View") }
  /// The conventional nested partial-storage type name.
  public static var streamPartial: Self { Self.identifier("Partial") }
}

// Fully qualified library protocols that generated declarations conform to.
extension TypeSyntax {
  /// `StreamParseable`, adopted by the whole type and by its generated partial.
  public static var streamParseable: Self { "StreamParsingCore.StreamParseable" }
  /// `StreamParseableObject`, adopted by a generated object partial.
  public static var streamParseableObject: Self { "StreamParsingCore.StreamParseableObject" }
  /// `StreamInitializable`, adopted by an enum without a default case to supply its fallback.
  public static var streamInitializable: Self { "StreamParsingCore.StreamInitializable" }
}

/// Selects the ownership model emitted for a stream view.
public enum StreamViewMode: Hashable, Sendable {
  /// Emits a compiler-checked, nonescapable view.
  case lifetime
  /// Emits an `@unsafe` pointer-backed view.
  case unsafe

  /// The mode selected by this package's `LifetimeView` trait.
  public static var packageDefault: Self {
    #if LifetimeView
      .lifetime
    #else
      .unsafe
    #endif
  }
}

/// Selects the initial representation of partial members.
public enum StreamPartialMembers: Hashable, Sendable {
  /// Makes required source properties optional in partial storage.
  case optional
  /// Initializes required properties using their stream initial value.
  case streamInitialValue

}

/// A scalar operation supported by `StreamSchema`.
private enum StreamApplyOperation: Hashable, Sendable {
  case string
  case number
  case boolean
  case null
}

/// An access level for generated declarations.
public enum StreamGeneratedAccessLevel: Hashable, Sendable {
  case `internal`
  case `fileprivate`
  case package
  case `public`

}

/// Controls `@inlinable` on generated performance-sensitive declarations.
public enum StreamInliningMode: Hashable, Sendable {
  /// Inline declarations whose access crosses a module boundary.
  case automatic
  /// Requires public or package access so generated inlinable bodies can name their storage.
  case always
  case never
}

/// Names shared by coordinated partial and view generation.
public struct StreamGeneratedNames: Sendable {
  /// The generated partial-storage type name.
  public var partialType: TokenSyntax
  /// The generated view type name.
  public var viewType: TokenSyntax

  /// Creates a set of coordinated generated names.
  public init(partialType: TokenSyntax = .streamPartial, viewType: TokenSyntax = .streamView) {
    self.partialType = partialType
    self.viewType = viewType
  }
}

/// Parses generated member source, dropping whitespace ahead of the first member.
func streamParsedMembers(_ source: String) -> MemberBlockItemListSyntax {
  guard !source.allSatisfy(\.isWhitespace) else {
    return MemberBlockItemListSyntax([])
  }
  var parsed = try! StructDeclSyntax("struct _StreamGenerated {\n\(raw: source)\n}")
    .memberBlock.members
  if let firstIndex = parsed.indices.first {
    parsed[firstIndex].leadingTrivia = Trivia(
      pieces: parsed[firstIndex].leadingTrivia.drop(while: \.isWhitespace)
    )
  }
  return parsed
}

/// Options shared by every component of an object generation.
public struct StreamGenerationConfiguration: Sendable {
  /// The ownership model emitted for views.
  public var viewMode: StreamViewMode
  /// The visibility of generated conformance members.
  public var accessLevel: StreamGeneratedAccessLevel
  /// The policy for generated `@inlinable` attributes.
  public var inlining: StreamInliningMode
  /// Names shared by the generated declarations.
  public var names: StreamGeneratedNames

  /// Creates a generation configuration.
  public init(
    viewMode: StreamViewMode = .packageDefault,
    accessLevel: StreamGeneratedAccessLevel = .internal,
    inlining: StreamInliningMode = .automatic,
    names: StreamGeneratedNames = StreamGeneratedNames()
  ) {
    self.viewMode = viewMode
    self.accessLevel = accessLevel
    self.inlining = inlining
    self.names = names
  }

  /// The access modifier and its trailing space, or nothing for internal access.
  var accessPrefix: String {
    switch self.accessLevel {
    case .internal: ""
    case .fileprivate: "fileprivate "
    case .package: "package "
    case .public: "public "
    }
  }

  func isInlinable(_ inlining: StreamInliningMode) -> Bool {
    switch inlining {
    case .automatic: self.accessLevel == .public || self.accessLevel == .package
    case .always: true
    case .never: false
    }
  }

  /// `@inlinable ` when `inlining`, or `nil` for the configured policy, inlines.
  func inlinableAttribute(_ inlining: StreamInliningMode? = nil) -> String {
    self.isInlinable(inlining ?? self.inlining) ? "@inlinable " : ""
  }
}

extension StreamViewMode {
  /// Suppressed conformances of a view type.
  var viewConstraints: String { self == .lifetime ? "~Copyable, ~Escapable" : "~Copyable" }
  /// The attribute an unsafe view type is declared with.
  var unsafeAttribute: String { self == .unsafe ? "@unsafe " : "" }

  /// `@_lifetime(borrow <source>)` and a line break followed by `indentation`; nothing for
  /// unsafe views.
  func lifetimeAttribute(borrowing source: String, indentation: String = "") -> String {
    self == .lifetime ? "@_lifetime(borrow \(source))\n\(indentation)" : ""
  }

  /// `view`, with lifetime views tied to `self`.
  func borrowedView(_ view: String) -> String {
    self == .lifetime ? "_overrideLifetime(\(view), borrowing: self)" : view
  }
}

/// Describes one property in generated stream partial storage.
public struct StreamParseableField: Sendable {
  /// The Swift member identifier, including backticks when already escaped.
  public var name: TokenSyntax
  /// The completed property's declared type.
  public var type: TypeSyntax
  /// Byte-exact decoded keys that select this field.
  public var keys: [String]
  /// An optional initial capacity expression for streaming containers.
  public var initialCapacity: ExprSyntax?
  /// A type conforming to `StreamCompletedValueConversion`.
  public var completedConversion: TypeSyntax?
  /// The whole type's declared default for this property.
  ///
  /// Only `conversionsSyntax` reads it: `init(orInitial:)` falls back to it for a nonoptional
  /// field with a `completedConversion`, which has no stream initial value to use instead.
  public var defaultValue: ExprSyntax?

  /// Creates a field description from general SwiftSyntax nodes.
  public init(
    name: TokenSyntax,
    type: some TypeSyntaxProtocol,
    keys: some Sequence<String>,
    initialCapacity: (any ExprSyntaxProtocol)? = nil,
    completedConversion: (any TypeSyntaxProtocol)? = nil,
    defaultValue: (any ExprSyntaxProtocol)? = nil
  ) {
    self.name = name
    self.type = TypeSyntax(type)
    self.keys = Array(keys)
    self.initialCapacity = initialCapacity.map { ExprSyntax($0) }
    self.completedConversion = completedConversion.map { TypeSyntax($0) }
    self.defaultValue = defaultValue.map { ExprSyntax($0) }
  }

  /// Creates a field whose only key is its name, without backticks.
  ///
  /// A wildcard name (`_`), which only an enum's unlabelled associated value may use, gets no
  /// key; the enum generation assigns its positional `_<index>` name and key.
  public init(
    name: TokenSyntax,
    type: some TypeSyntaxProtocol,
    initialCapacity: (any ExprSyntaxProtocol)? = nil,
    completedConversion: (any TypeSyntaxProtocol)? = nil,
    defaultValue: (any ExprSyntaxProtocol)? = nil
  ) {
    self.init(
      name: name,
      type: type,
      keys: name.tokenKind == .wildcard ? [] : [StreamObjectGeneration.bareName(name)],
      initialCapacity: initialCapacity,
      completedConversion: completedConversion,
      defaultValue: defaultValue
    )
  }
}

/// A stored field as emitted in a generated object `Partial`.
public struct StreamPartialFieldDescriptor: Sendable {
  /// The generated member identifier, escaped with backticks when needed.
  public let memberName: TokenSyntax
  /// The member name without backticks.
  public let unescapedName: String
  /// The exact generated property type, including any optional wrapper.
  public let storageType: TypeSyntax
  /// Byte-exact decoded keys that route to this member, in their supplied order.
  public let keys: [String]

  /// Creates a descriptor for a stored field in a generated `Partial`.
  public init(memberName: TokenSyntax, unescapedName: String, storageType: TypeSyntax, keys: [String]) {
    self.memberName = memberName
    self.unescapedName = unescapedName
    self.storageType = storageType
    self.keys = keys
  }
}

/// Additive syntax for a generated object or enum payload `Partial` struct.
///
/// Members are appended after generated members. The caller is responsible for avoiding names
/// and conformances already supplied by the generator.
public struct StreamPartialCustomization {
  /// Attributes applied to the `Partial` declaration itself.
  public var attributes: AttributeListSyntax
  /// Protocols added after the generated conformances.
  public var conformances: [TypeSyntax]
  /// Properties, initializers, methods, and other declarations inside `Partial`.
  public var members: MemberBlockItemListSyntax

  public init(
    attributes: AttributeListSyntax = AttributeListSyntax([]),
    conformances: [TypeSyntax] = [],
    members: MemberBlockItemListSyntax = MemberBlockItemListSyntax([])
  ) {
    self.attributes = attributes
    self.conformances = conformances
    self.members = members
  }

  var isEmpty: Bool {
    self.attributes.isEmpty && self.conformances.isEmpty && self.members.isEmpty
  }
}

/// An invalid combination in an object-generation description.
#if compiler(>=6.2.3)
@nonexhaustive
#endif
public enum StreamObjectGenerationError: Error, Equatable, Sendable, CustomStringConvertible {
  /// Explicit inlining requires public or package access for the generated storage.
  case incompatibleInliningAccess
  /// A field has no identifier text.
  case emptyFieldName
  /// A field name isn't a Swift identifier token.
  case invalidFieldName(String)
  /// More than one field uses the same Swift identifier.
  case duplicateField(String)
  /// More than one field claims the same byte-exact decoded key.
  case duplicateKey(String)
  /// A converted field also specifies a container capacity.
  case initialCapacityWithCompletedConversion(field: String)
  /// A nonoptional converted field has no `defaultValue` for `init(orInitial:)`.
  case missingCompletedConversionDefault(field: String)
  /// Members or a recognition hook were supplied for a raw-value enum, whose partial is a
  /// library type.
  case hooksRequireObjectRepresentation

  /// A human-readable explanation of the invalid description.
  public var description: String {
    switch self {
    case .incompatibleInliningAccess:
      "Explicit inlining requires public or package access."
    case .emptyFieldName: "A stream field name must not be empty."
    case .invalidFieldName(let name): "The stream field name '\(name)' is not a Swift identifier."
    case .duplicateField(let name): "The stream field '\(name)' occurs more than once."
    case .duplicateKey(let key): "The stream key '\(key)' occurs more than once."
    case .initialCapacityWithCompletedConversion(let field):
      "The stream field '\(field)' cannot combine initialCapacity with completedConversion."
    case .missingCompletedConversionDefault(let field):
      "The nonoptional converted stream field '\(field)' requires a defaultValue for init(orInitial:)."
    case .hooksRequireObjectRepresentation:
      "Partial members and recognition hooks require the case-keyed object enum representation."
    }
  }
}

/// A reusable plan for generating object partial-storage syntax.
public struct StreamObjectGeneration: Sendable {
  /// The fields in stable generated order.
  public let fields: [StreamParseableField]
  /// The generated `Partial` storage fields, in the same order as `fields`.
  ///
  /// `storageType` reflects `partialMembers`, converted values, and container lowering. These
  /// descriptors describe emitted syntax rather than resolving Swift type aliases.
  public var partialFields: [StreamPartialFieldDescriptor] {
    self.fields.map { field in
      StreamPartialFieldDescriptor(
        memberName: .identifier(Self.memberName(field.name)),
        unescapedName: Self.bareName(field.name),
        storageType: TypeSyntax("\(raw: self.memberType(field))"),
        keys: field.keys
      )
    }
  }

  /// The representation used for required partial members.
  public let partialMembers: StreamPartialMembers
  /// Options shared by every generated component.
  public let configuration: StreamGenerationConfiguration
  private var schemaPlan: SchemaPlan
  /// Whether the plan came from the validating initializer. Recovery plans skip the checks
  /// `conversionsSyntax` would otherwise throw for.
  let isValidated: Bool

  /// Creates and validates an object generation plan.
  public init(
    fields: some Sequence<StreamParseableField>,
    partialMembers: StreamPartialMembers = .optional,
    configuration: StreamGenerationConfiguration = StreamGenerationConfiguration()
  ) throws {
    let fields = Array(fields)
    if configuration.inlining == .always,
      configuration.accessLevel != .public, configuration.accessLevel != .package
    {
      throw StreamObjectGenerationError.incompatibleInliningAccess
    }
    var names = Set<String>()
    var keys = Set<[UInt8]>()
    for field in fields {
      let name = Self.bareName(field.name)
      guard !name.isEmpty else { throw StreamObjectGenerationError.emptyFieldName }
      guard Self.isValidMemberName(field.name) else {
        throw StreamObjectGenerationError.invalidFieldName(name)
      }
      guard names.insert(name).inserted else {
        throw StreamObjectGenerationError.duplicateField(name)
      }
      if field.completedConversion != nil, field.initialCapacity != nil {
        throw StreamObjectGenerationError.initialCapacityWithCompletedConversion(field: name)
      }
      for key in field.keys {
        guard keys.insert(Array(key.utf8)).inserted else {
          throw StreamObjectGenerationError.duplicateKey(key)
        }
      }
    }
    self.init(
      fields: fields,
      partialMembers: partialMembers,
      configuration: configuration,
      isValidated: true
    )
  }

  /// Creates a recovery plan after the caller has diagnosed invalid source.
  ///
  /// Skips validation so a macro can emit its own diagnostics and recovery expansion.
  /// The resulting syntax may contain the errors present in the supplied fields.
  public init(
    diagnosedFields fields: some Sequence<StreamParseableField>,
    partialMembers: StreamPartialMembers = .optional,
    configuration: StreamGenerationConfiguration = StreamGenerationConfiguration()
  ) {
    self.init(
      fields: Array(fields),
      partialMembers: partialMembers,
      configuration: configuration,
      isValidated: false
    )
  }

  private init(
    fields: [StreamParseableField],
    partialMembers: StreamPartialMembers,
    configuration: StreamGenerationConfiguration,
    isValidated: Bool
  ) {
    self.fields = fields
    self.partialMembers = partialMembers
    self.configuration = configuration
    self.isValidated = isValidated
    self.schemaPlan = SchemaPlan()
    self.schemaPlan = self.buildPlan()
  }

  /// Generates the stored properties of the partial representation.
  private func storageMembers() -> MemberBlockItemListSyntax {
    self.members(
      self.fields
        .map {
          "\(self.access)var \(Self.memberName($0.name)): \(self.memberType($0))"
        }
        .joined(separator: "\n")
    )
  }

  /// Generates the partial representation's memberwise initializer.
  private func initializer() -> InitializerDeclSyntax {
    let parameters = self.fields
      .map {
        "\(Self.memberName($0.name)): \(self.memberType($0)) = \((self.partialMembers == .optional ? "nil" : ".streamInitialValue()"))"
      }
      .joined(separator: ",\n  ")
    let assignments = self.fields
      .map {
        "  self.\(Self.memberName($0.name)) = \(Self.memberName($0.name))"
      }
      .joined(separator: "\n")
    return self.declaration(
      """
      \(self.access)init(
        \(parameters)
      ) {
      \(assignments)
      }
      """,
      as: InitializerDeclSyntax.self
    )
  }

  /// Generates the cached initial-value template and its conformance witness.
  private func initialValueMembers() -> MemberBlockItemListSyntax {
    let templateAccess = self.inlinable ? "@usableFromInline " : "private "
    return self.members(
      """
      \(templateAccess)static let _streamInitialValueTemplate: Self = Self()

      \(self.inline)\(self.access)static func streamInitialValue() -> Self {
        Self._streamInitialValueTemplate
      }
      """
    )
  }

  /// Generates observation metadata when the Embedded feature is unavailable.
  private func observationMembers() -> MemberBlockItemListSyntax {
    let paths = self.fields.map { "\\.\(Self.memberName($0.name))" }.joined(separator: ", ")
    return self.members(
      """
      #if !hasFeature(Embedded)
      \(self.access)static var streamObservationFields: [PartialKeyPath<Self>] {
        [\(paths)]
      }
      #endif
      """
    )
  }

  /// Generates a view with an already-built member list appended to it.
  private func viewDeclaration(
    additionalMembers: MemberBlockItemListSyntax = MemberBlockItemListSyntax([])
  ) -> StructDeclSyntax {
    let viewName = self.configuration.names.viewType.trimmedDescription
    let partialName = self.configuration.names.partialType.trimmedDescription
    let accessors = self.fields
      .map { field -> String in
        let fieldName = Self.memberName(field.name)
        let type = self.partialType(field)
        let mode = self.configuration.viewMode
        return """
            \(self.inline)\(self.access)var \(fieldName): \(type).View? {
              \(mode.lifetimeAttribute(borrowing: "self", indentation: "    "))get {
                guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.\(fieldName)) else {
                  return nil
                }
                return \(mode.borrowedView("\(type).streamView(address)"))
              }
            }
          """
      }
      .joined(separator: "\n\n")
    let frozen = self.inlinable ? "@frozen " : ""
    let mode = self.configuration.viewMode
    var declaration = self.declaration(
      """
      \(mode.unsafeAttribute)\(frozen)\(self.access)struct \(viewName): \(mode.viewConstraints) {
        \(self.access)let _streamStorage: UnsafeMutablePointer<\(partialName)>

        \(mode.lifetimeAttribute(borrowing: "storage", indentation: "  "))\(self.inline)\(self.access)init(_ storage: UnsafeMutableRawPointer) {
          self._streamStorage = storage.assumingMemoryBound(to: \(partialName).self)
        }

      \(accessors)
      }
      """,
      as: StructDeclSyntax.self
    )
    guard !additionalMembers.isEmpty else { return declaration }
    var members = self.terminated(declaration.memberBlock.members, nextIndentation: .spaces(2))
    members.append(contentsOf: additionalMembers.indented(by: .spaces(2)))
    declaration.memberBlock.members = members
    return declaration
  }

  /// Generates the view factory required by `StreamParseable`.
  private func streamViewFunction() -> FunctionDeclSyntax {
    let viewName = self.configuration.names.viewType.trimmedDescription
    let mode = self.configuration.viewMode
    let lifetime = mode == .lifetime ? mode.lifetimeAttribute(borrowing: "storage") : "@unsafe\n"
    return self.declaration(
      """
      \(lifetime)\(self.inline)\(self.access)static func streamView(_ storage: UnsafeMutableRawPointer) -> \(viewName) {
        \(viewName)(storage)
      }
      """,
      as: FunctionDeclSyntax.self
    )
  }

  /// Generates integer identifiers for fields. Empty objects produce an empty enum.
  private func fieldIdentifierDeclaration() -> EnumDeclSyntax {
    let constants = self.fields.enumerated()
      .map { index, field in
        self.inlinable
          ? "  @inlinable static var \(Self.memberName(field.name)): Int32 { \(index) }"
          : "  static let \(Self.memberName(field.name)): Int32 = \(index)"
      }
      .joined(separator: "\n")
    let access = self.inlinable ? "@usableFromInline " : "private "
    return self.declaration("\(access)enum StreamField {\n\(constants)\n}", as: EnumDeclSyntax.self)
  }

  /// Generates byte-exact key matching for the object schema.
  private func matchFieldFunction() -> FunctionDeclSyntax {
    let cases = self.schemaPlan.matches.joined(separator: "\n")
    let emptyField = self.fields.first(where: { field in
      field.keys.contains { $0.utf8.isEmpty }
    })
    let emptyGuard =
      emptyField.map {
        "guard !key.isEmpty else { return Self.StreamField.\(Self.memberName($0.name)) }\n  "
      } ?? ""
    return self.declaration(
      """
      \(self.inline)\(self.access)static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
        \(emptyGuard)switch key.paddedLeadingWord() {
      \(cases)
        default: return -1
        }
      }
      """,
      as: FunctionDeclSyntax.self
    )
  }

  /// Generates one scalar application callback for the object schema.
  private func applyFunction(for operation: StreamApplyOperation) -> FunctionDeclSyntax {
    let (name, valueParameters) =
      switch operation {
      case .string: ("streamApplyString", ",\n  _ bytes: Span<UInt8>")
      case .number:
        ("streamApplyNumber", ",\n  _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo")
      case .boolean: ("streamApplyBoolean", ", _ value: Bool")
      case .null: ("streamApplyNull", "")
      }
    let cases = self.schemaPlan.apply[operation, default: []].joined(separator: "\n")
    let binding = cases.isEmpty ? "" : "  let p = storage.assumingMemoryBound(to: Self.self)\n"
    return self.declaration(
      """
      \(self.inline)\(self.access)static func \(name)(
        _ storage: UnsafeMutableRawPointer, _ field: Int32\(valueParameters)
      ) -> StreamParsingCore.StreamApplyResult {
      \(binding)  switch field {
      \(cases)
        default: return .unsupported
        }
      }
      """,
      as: FunctionDeclSyntax.self
    )
  }

  /// Generates the field routing and offset table.
  private func fieldTableProperty() -> VariableDeclSyntax {
    let entries = self.schemaPlan.fields.joined(separator: "\n")
    return self.declaration(
      """
      \(self.access)static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
        of: Self.self, prototype: Self()
      ) { p in
        [
      \(entries)
        ]
      }
      """,
      as: VariableDeclSyntax.self
    )
  }

  /// Generates the complete object `StreamSchema` property.
  private func schemaProperty(recognitionHandler: TokenSyntax?) -> VariableDeclSyntax {
    let converted = self.fields.filter { $0.completedConversion != nil }
    let finish = self.finishStringArgument(for: converted)
    let recognition = recognitionHandler.map {
      "  onFieldRecognized: { storage, field in storage.assumingMemoryBound(to: Self.self).pointee.\($0.text)(field) },\n"
    } ?? ""
    return self.declaration(
      """
      \(self.access)static let streamSchema = StreamParsingCore.StreamSchema(
        shape: .object,
        matchField: Self.streamMatchField,
      \(recognition)  applyString: Self.streamApplyString,
        applyNumber: Self.streamApplyNumber,
        applyBoolean: Self.streamApplyBoolean,
        applyNull: Self.streamApplyNull,
      \(finish)  fields: Self.streamFields
      )
      """,
      as: VariableDeclSyntax.self
    )
  }

  /// Generates all members used by the object schema.
  private func schemaMembers(recognitionHandler: TokenSyntax?) -> MemberBlockItemListSyntax {
    var result = MemberBlockItemListSyntax([])
    if !self.fields.isEmpty {
      result.append(self.member(self.fieldIdentifierDeclaration()))
    }
    result.append(contentsOf: self.members(self.schemaPlan.containerSchemas.joined(separator: "\n")))
    result.append(self.member(self.matchFieldFunction()))
    for operation in [StreamApplyOperation.string, .number, .boolean, .null] {
      result.append(self.member(self.applyFunction(for: operation)))
    }
    result.append(self.member(self.fieldTableProperty()))
    result.append(self.member(self.schemaProperty(recognitionHandler: recognitionHandler)))
    return result
  }

  /// Field names and their `StreamFieldID` expressions, in declaration order.
  ///
  /// Aliases share the identifier of their declared field. The expressions can be
  /// used in added members and recognition handlers without depending on schema layout.
  public var fieldIdentifiers: [(name: TokenSyntax, identifier: ExprSyntax)] {
    self.fields.enumerated().map { index, field in
      (name: field.name, identifier: ExprSyntax("StreamParsingCore._streamFieldID(\(raw: index))"))
    }
  }

  /// Generates a complete stream-compatible struct and builds additive customizations.
  ///
  /// `partialCustomization` adds attributes, conformances, and members to the generated struct.
  /// Its members and `additionalMembers` are appended after generated members.
  /// Additional stored members must provide default values and satisfy `Sendable`.
  /// Recognition runs once per declared key, including aliases and repeats, before its
  /// value is applied. Unknown keys are not reported. An empty body installs no hook.
  /// The hook receives expressions for the mutable partial and recognized `StreamFieldID`.
  /// Use `fieldIdentifiers` to compare that identifier with a declared field.
  public func structDeclarationSyntax(
    in context: some MacroExpansionContext,
    partialCustomization: StreamPartialCustomization = StreamPartialCustomization(),
    @MemberBlockItemListBuilder additionalMembers:
      () throws -> MemberBlockItemListSyntax = { [] },
    @MemberBlockItemListBuilder additionalViewMembers:
      () throws -> MemberBlockItemListSyntax = { [] },
    @CodeBlockItemListBuilder onFieldRecognized:
      (ExprSyntax, ExprSyntax) throws -> CodeBlockItemListSyntax = { _, _ in [] }
  ) rethrows -> StructDeclSyntax {
    let format = BasicFormat(indentationWidth: .spaces(2))
    let additions = try additionalMembers().formatted(using: format).cast(MemberBlockItemListSyntax.self)
    let customizedMembers = partialCustomization.members.formatted(using: format)
      .cast(MemberBlockItemListSyntax.self)
    let viewAdditions = try additionalViewMembers().formatted(using: format).cast(MemberBlockItemListSyntax.self)
    let fieldParameter = context.makeUniqueName("streamRecognizedField")
    let body = try onFieldRecognized(
      ExprSyntax("self"), ExprSyntax(DeclReferenceExprSyntax(baseName: fieldParameter))
    )
    var handler: FunctionDeclSyntax?
    if !body.isEmpty {
      let name = context.makeUniqueName("streamDidRecognizeField")
      var declaration = self.declaration(
        "private mutating func \(name.text)(_ \(fieldParameter.text): StreamParsingCore.StreamFieldID) {}",
        as: FunctionDeclSyntax.self
      )
      declaration.body = CodeBlockSyntax(statements: body)
      handler = declaration.formatted(using: format).cast(FunctionDeclSyntax.self)
    }
    let partialName = self.configuration.names.partialType.trimmedDescription
    let view = self.viewDeclaration(additionalMembers: viewAdditions)
    var members = self.storageMembers()
    members.append(self.member(self.initializer()))
    members.append(contentsOf: self.initialValueMembers())
    members.append(contentsOf: self.observationMembers())
    members.append(self.member(view))
    let configuredViewName = self.configuration.names.viewType.trimmedDescription
    if configuredViewName != TokenSyntax.streamView.text {
      members.append(
        contentsOf: self.members("\(self.access)typealias View = \(configuredViewName)")
      )
    }
    members.append(self.member(self.streamViewFunction()))
    members.append(contentsOf: self.schemaMembers(recognitionHandler: handler?.name))
    if let handler {
      members.append(self.member(handler))
    }
    members.append(contentsOf: self.terminated(additions))
    members.append(contentsOf: self.terminated(customizedMembers))
    if let lastIndex = members.indices.last {
      members[lastIndex].trailingTrivia = .newline
    }
    var declaration = self.declaration(
      """
      \(self.access)struct \(partialName): \(TypeSyntax.streamParseable),
        \(TypeSyntax.streamParseableObject), Sendable {
        \(self.access)typealias Partial = Self
      }
      """,
      as: StructDeclSyntax.self
    )
    var declarationMembers = self.terminated(
      declaration.memberBlock.members,
      nextIndentation: .spaces(2)
    )
    declarationMembers.append(contentsOf: members.indented(by: .spaces(2)))
    declaration.memberBlock.members = declarationMembers
    for var attribute in partialCustomization.attributes {
      if !attribute.trailingTrivia.description.contains("\n") {
        attribute.trailingTrivia += .newline
      }
      declaration.attributes.append(attribute)
    }
    if !partialCustomization.conformances.isEmpty {
      var inheritedTypes = declaration.inheritanceClause!.inheritedTypes
      let lastIndex = inheritedTypes.index(before: inheritedTypes.endIndex)
      inheritedTypes[lastIndex].type = inheritedTypes[lastIndex].type.trimmed
      inheritedTypes[lastIndex].trailingComma = .commaToken(trailingTrivia: .space)
      for (index, type) in partialCustomization.conformances.enumerated() {
        let isLast = index == partialCustomization.conformances.count - 1
        inheritedTypes.append(InheritedTypeSyntax(
          type: type.trimmed,
          trailingComma: isLast ? nil : .commaToken(trailingTrivia: .space),
          trailingTrivia: isLast ? .space : nil
        ))
      }
      declaration.inheritanceClause!.inheritedTypes = inheritedTypes
    }
    return declaration
  }

}

extension StreamObjectGeneration {
  private struct SchemaPlan: Sendable {
    var matches = [String]()
    var fields = [String]()
    var containerSchemas = [String]()
    var apply = [StreamApplyOperation: [String]]()
  }

  enum FieldShape {
    case scalarOrObject
    case array(TypeSyntax)
    case dictionary(TypeSyntax)
  }

  var access: String { self.configuration.accessPrefix }
  var inlinable: Bool { self.configuration.isInlinable(self.configuration.inlining) }
  var inline: String { self.configuration.inlinableAttribute() }

  private func buildPlan() -> SchemaPlan {
    var result = SchemaPlan()
    for field in self.fields {
      let member = Self.memberName(field.name)
      let fieldID = "Self.StreamField.\(member)"
      for key in field.keys {
        let label = streamWordCaseLabel(key, input: "key", byteCount: ExprSyntax("key.count"))
        result.matches.append("  \(label): return \(fieldID)")
      }
      let target = "p.pointee.\(member)"
      let schema = self.schemaName(field)
      let capacity =
        field.initialCapacity.map { ", initialCapacity: \($0.trimmedDescription)" } ?? ""
      for key in field.keys {
        result.fields.append(
          """
              StreamParsingCore.StreamField(
                key: \(StringLiteralExprSyntax(content: key).trimmedDescription), index: \(fieldID),
                route: _streamFieldRoute(&\(target), schema: Self.\(schema)\(capacity)),
                offset: StreamParsingCore._streamFieldOffset(&\(target), in: p)
              ),
          """
        )
      }
      let container = self.containerSchema(for: field, named: schema)
      result.containerSchemas.append(container.declaration)
      let isContainer = container.isContainer
      for operation in [StreamApplyOperation.string, .number, .boolean, .null]
      where !isContainer || operation == .null {
        if field.completedConversion != nil, operation != .null {
          let (method, args) =
            switch operation {
            case .string: ("applyString", "bytes")
            case .number: ("applyNumber", "bytes, info")
            case .boolean: ("applyBoolean", "value")
            case .null: fatalError()
            }
          result.apply[operation, default: []]
            .append(
              "  case \(fieldID): return _streamWithConverted(&\(target)) { Self.\(schema)!.\(method)($0, StreamParsingCore.StreamSchema.wholeValueField, \(args)) }"
            )
        } else {
          let expression =
            switch operation {
            case .string: "streamApply(&\(target), utf8: bytes\(capacity))"
            case .number: "streamApply(&\(target), bytes: bytes, info: info)"
            case .boolean: "streamApply(&\(target), boolean: value)"
            case .null: "StreamParsing.streamApplyNull(&\(target))"
            }
          result.apply[operation, default: []].append("  case \(fieldID): return \(expression)")
        }
      }
    }
    return result
  }

  private func schemaName(_ field: StreamParseableField) -> String {
    Self.memberName(
      TokenSyntax.identifier("streamContainerSchema_\(Self.bareName(field.name))")
    )
  }

  private func finishStringArgument(for fields: [StreamParseableField]) -> String {
    guard !fields.isEmpty else { return "" }
    let branches =
      fields.map {
        let name = Self.memberName($0.name)
        return
          "case Self.StreamField.\(name): return _streamWithConverted(&p.pointee.\(name)) { Self.\(self.schemaName($0))!.finishString?($0, StreamParsingCore.StreamSchema.wholeValueField) ?? .applied }"
      }
      .joined(separator: "\n")
    return """
        finishString: { storage, field in
          let p = storage.assumingMemoryBound(to: Self.self)
          switch field {
          \(branches)
          default: return .applied
          }
        },

      """
  }

  private func containerSchema(
    for field: StreamParseableField,
    named schema: String
  ) -> (isContainer: Bool, declaration: String) {
    switch field.completedConversion == nil ? self.fieldShape(field.type) : .scalarOrObject {
    case .scalarOrObject:
      let access =
        field.completedConversion != nil && self.inlinable ? "@usableFromInline" : "private"
      return (
        false,
        "\(access) static let \(schema) = _streamContainerSchema(for: (\(self.partialType(field))).self)"
      )
    case .array, .dictionary:
      return (
        true,
        "private static let \(schema) = \(self.schemaExpression(field.type))"
      )
    }
  }

  private func partialType(_ field: StreamParseableField) -> String {
    if let conversion = field.completedConversion {
      return Self.convertedPartialType(conversion)
    }
    if case .dictionary(let value) = self.fieldShape(field.type) {
      return "StreamParsingCore.StreamDictionary<\(value.trimmedDescription).Partial>"
    }
    return "\(field.type.streamUnwrappedOptionalType.trimmedDescription).Partial"
  }

  static func convertedPartialType(_ conversion: TypeSyntax) -> String {
    "StreamParsingCore.ConvertedPartial<\(conversion.trimmedDescription)>"
  }

  private func memberType(_ field: StreamParseableField) -> String {
    let base = self.partialType(field)
    return (self.partialMembers == .optional) || field.type.streamIsOptional
      ? "\(base)?" : base
  }

  func fieldShape(_ type: TypeSyntax) -> FieldShape {
    let type = type.streamUnwrappedOptionalType
    if let array = type.as(ArrayTypeSyntax.self) { return .array(array.element) }
    if let dictionary = type.as(DictionaryTypeSyntax.self) { return .dictionary(dictionary.value) }
    if let arguments = streamGenericArguments(type), arguments.count == 1,
      streamTypeName(type) == "Array",
      case .type(let element) = arguments.first!.argument
    {
      return .array(element)
    }
    if let arguments = streamGenericArguments(type), arguments.count == 2,
      streamTypeName(type) == "Dictionary",
      case .type(let value) = arguments[arguments.index(after: arguments.startIndex)].argument
    {
      return .dictionary(value)
    }
    return .scalarOrObject
  }

  private func schemaExpression(_ type: TypeSyntax) -> String {
    switch self.fieldShape(type) {
    case .array(let element):
      self.containerSchemaExpression("Array", element: element, label: "element")
    case .dictionary(let value):
      self.containerSchemaExpression("Dictionary", element: value, label: "value")
    case .scalarOrObject:
      "_streamSchema(for: \(type.streamUnwrappedOptionalType.trimmedDescription).Partial.self)"
    }
  }

  private func containerSchemaExpression(
    _ kind: String,
    element: TypeSyntax,
    label: String
  ) -> String {
    let storage = element.streamUnwrappedOptionalType.trimmedDescription
    let builder =
      element.streamIsOptional ? "_streamOptional\(kind)Schema" : "_stream\(kind)Schema"
    return "\(builder)(\(storage).Partial.self, \(label): \(self.schemaExpression(element)))"
  }

  /// The name without enclosing backticks.
  package static func bareName(_ token: TokenSyntax) -> String {
    let text = token.text
    return text.count > 2 && text.hasPrefix("`") && text.hasSuffix("`")
      ? String(text.dropFirst().dropLast()) : text
  }

  /// The name as a member identifier, escaped with backticks where it needs them.
  static func memberName(_ token: TokenSyntax) -> String {
    let text = token.trimmedDescription
    if text.hasPrefix("`") && text.hasSuffix("`") { return text }
    return Self.isMemberIdentifier(text) ? text : "`\(text)`"
  }

  private static func isValidMemberName(_ token: TokenSyntax) -> Bool {
    Self.isMemberIdentifier(Self.memberName(token))
  }

  private static func isMemberIdentifier(_ text: String) -> Bool {
    guard let declaration = try? VariableDeclSyntax("var \(raw: text): Int") else { return false }
    return !Syntax(declaration).hasError
  }

  func members(_ source: String) -> MemberBlockItemListSyntax {
    self.terminated(streamParsedMembers(source))
  }

  private func terminated(
    _ members: MemberBlockItemListSyntax,
    nextIndentation: Trivia = []
  ) -> MemberBlockItemListSyntax {
    guard let lastIndex = members.indices.last else { return members }
    var result = members
    result[lastIndex].trailingTrivia = .newlines(2) + nextIndentation
    return result
  }

  private func member(_ declaration: some DeclSyntaxProtocol) -> MemberBlockItemSyntax {
    var declaration = DeclSyntax(declaration)
    declaration.trailingTrivia = .newlines(2)
    return MemberBlockItemSyntax(decl: declaration)
  }

  func declaration<T: DeclSyntaxProtocol>(_ source: String, as type: T.Type) -> T {
    let declaration = DeclSyntax("\(raw: source)")
    return declaration.as(T.self)!
  }
}
