import SwiftSyntax
import SwiftSyntaxBuilder

// The declarations produced by this module refer to public symbols vended by `StreamParsing`.
// A source file that inserts them must import `StreamParsing`, which reexports
// `StreamParsingCore`.

extension TokenSyntax {
  /// The conventional nested stream view type name.
  public static var streamView: Self { Self.identifier("View") }
  /// The conventional nested partial-storage type name.
  public static var streamPartial: Self { Self.identifier("Partial") }
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

  var defaultValue: String { self == .optional ? "nil" : ".streamInitialValue()" }
  var makesRequiredPropertiesOptional: Bool { self == .optional }
}

/// A scalar operation supported by `StreamSchema`.
public enum StreamApplyOperation: Hashable, Sendable {
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

  var prefix: String {
    switch self {
    case .internal: ""
    case .fileprivate: "fileprivate "
    case .package: "package "
    case .public: "public "
    }
  }
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
public struct StreamGeneratedNames: Hashable, Sendable {
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

/// Options shared by every component of an object generation.
public struct StreamGenerationConfiguration: Hashable, Sendable {
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

  var isInlinable: Bool {
    switch self.inlining {
    case .automatic: self.accessLevel == .public || self.accessLevel == .package
    case .always: true
    case .never: false
    }
  }
}

/// Describes one property in generated stream partial storage.
public struct StreamParseableField: Hashable, Sendable {
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

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.name == rhs.name && lhs.type == rhs.type
      && lhs.keys.map { Array($0.utf8) } == rhs.keys.map { Array($0.utf8) }
      && lhs.initialCapacity == rhs.initialCapacity
      && lhs.completedConversion == rhs.completedConversion
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(self.name)
    hasher.combine(self.type)
    hasher.combine(self.keys.map { Array($0.utf8) })
    hasher.combine(self.initialCapacity)
    hasher.combine(self.completedConversion)
  }

  /// Creates a field description from general SwiftSyntax nodes.
  public init(
    name: TokenSyntax,
    type: some TypeSyntaxProtocol,
    keys: some Sequence<String>,
    initialCapacity: ExprSyntax? = nil,
    completedConversion: TypeSyntax? = nil
  ) {
    self.name = name
    self.type = TypeSyntax(type)
    self.keys = Array(keys)
    self.initialCapacity = initialCapacity
    self.completedConversion = completedConversion
  }

  /// Creates a field description with a concrete initial-capacity expression.
  public init(
    name: TokenSyntax,
    type: some TypeSyntaxProtocol,
    keys: some Sequence<String>,
    initialCapacity: some ExprSyntaxProtocol,
    completedConversion: TypeSyntax? = nil
  ) {
    self.name = name
    self.type = TypeSyntax(type)
    self.keys = Array(keys)
    self.initialCapacity = ExprSyntax(initialCapacity)
    self.completedConversion = completedConversion
  }

  /// Creates a field using a concrete conversion-strategy type node.
  public init(
    name: TokenSyntax,
    type: some TypeSyntaxProtocol,
    keys: some Sequence<String>,
    initialCapacity: ExprSyntax? = nil,
    completedConversion: some TypeSyntaxProtocol
  ) {
    self.init(
      name: name,
      type: type,
      keys: keys,
      initialCapacity: initialCapacity,
      completedConversion: Optional.some(TypeSyntax(completedConversion))
    )
  }

  /// Creates a field using concrete capacity and conversion-strategy syntax nodes.
  public init(
    name: TokenSyntax,
    type: some TypeSyntaxProtocol,
    keys: some Sequence<String>,
    initialCapacity: some ExprSyntaxProtocol,
    completedConversion: some TypeSyntaxProtocol
  ) {
    self.init(
      name: name,
      type: type,
      keys: keys,
      initialCapacity: Optional.some(ExprSyntax(initialCapacity)),
      completedConversion: Optional.some(TypeSyntax(completedConversion))
    )
  }
}

/// An invalid combination in an object-generation description.
public enum StreamObjectGenerationError: Error, Hashable, Sendable, CustomStringConvertible {
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
    }
  }
}

/// A validated, reusable plan for generating object partial-storage syntax.
public struct StreamObjectGeneration: Hashable, Sendable {
  /// The fields in stable generated order.
  public let fields: [StreamParseableField]
  /// The representation used for required partial members.
  public let partialMembers: StreamPartialMembers
  /// Options shared by every generated component.
  public let configuration: StreamGenerationConfiguration
  private var schemaPlan: SchemaPlan

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
      uncheckedFields: fields,
      partialMembers: partialMembers,
      configuration: configuration
    )
  }

  /// Creates a plan for source that the macro target has already diagnosed.
  package init(
    uncheckedFields fields: some Sequence<StreamParseableField>,
    partialMembers: StreamPartialMembers = .optional,
    configuration: StreamGenerationConfiguration = StreamGenerationConfiguration()
  ) {
    let fields = Array(fields)
    self.fields = fields
    self.partialMembers = partialMembers
    self.configuration = configuration
    self.schemaPlan = SchemaPlan()
    self.schemaPlan = self.buildPlan()
  }

  /// Generates the stored properties of the partial representation.
  public func storageMembers() -> MemberBlockItemListSyntax {
    self.members(
      self.fields
        .map {
          "\(self.access)var \(Self.memberName($0.name)): \(self.memberType($0))"
        }
        .joined(separator: "\n")
    )
  }

  /// Generates the partial representation's memberwise initializer.
  public func initializer() -> InitializerDeclSyntax {
    let parameters = self.fields
      .map {
        "\(Self.memberName($0.name)): \(self.memberType($0)) = \(self.partialMembers.defaultValue)"
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
  public func initialValueMembers() -> MemberBlockItemListSyntax {
    let templateAccess = self.inlinable ? "@usableFromInline " : "private "
    return self.members(
      """
      // Cached rather than re-evaluated: `Self()` walks every default expression fresh, which
      // for a large nested struct is a long chain of small copies. Every member's own `Partial`
      // is `Sendable` (every leaf and every "Fast" container conforms), which is what makes
      // `Self` itself `Sendable` here and lets the template be a plain `static let`.
      \(templateAccess)static let _streamInitialValueTemplate: Self = Self()

      \(self.inline)\(self.access)static func streamInitialValue() -> Self {
        Self._streamInitialValueTemplate
      }
      """
    )
  }

  /// Generates observation metadata when the Embedded feature is unavailable.
  public func observationMembers() -> MemberBlockItemListSyntax {
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

  /// Generates the pointer-backed nested view declaration.
  public func viewDeclaration(named name: TokenSyntax? = nil) -> StructDeclSyntax {
    self.viewDeclaration(named: name, additionalMembers: MemberBlockItemListSyntax([]))
  }

  /// Generates a view and appends caller-supplied members to it.
  public func viewDeclaration(
    named name: TokenSyntax? = nil,
    @MemberBlockItemListBuilder additionalMembers: () throws -> MemberBlockItemListSyntax
  ) rethrows -> StructDeclSyntax {
    self.viewDeclaration(named: name, additionalMembers: try additionalMembers())
  }

  /// Generates a view with an already-built member list appended to it.
  public func viewDeclaration(
    named name: TokenSyntax? = nil,
    additionalMembers: MemberBlockItemListSyntax
  ) -> StructDeclSyntax {
    let viewName = (name ?? self.configuration.names.viewType).trimmedDescription
    let partialName = self.configuration.names.partialType.trimmedDescription
    let accessors = self.fields
      .map { field -> String in
        let fieldName = Self.memberName(field.name)
        let type = self.partialType(field)
        let lifetime =
          self.configuration.viewMode == .lifetime ? "    @_lifetime(borrow self)\n" : ""
        let value =
          self.configuration.viewMode == .lifetime
          ? "_overrideLifetime(\(type).streamView(address), borrowing: self)"
          : "\(type).streamView(address)"
        return """
            \(self.inline)\(self.access)var \(fieldName): \(type).View? {
          \(lifetime)    get {
                guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.\(fieldName)) else {
                  return nil
                }
                return \(value)
              }
            }
          """
      }
      .joined(separator: "\n\n")
    let frozen = self.inlinable ? "@frozen " : ""
    let unsafe = self.configuration.viewMode == .unsafe ? "@unsafe " : ""
    let constraints =
      self.configuration.viewMode == .lifetime ? "~Copyable, ~Escapable" : "~Copyable"
    let lifetime = self.configuration.viewMode == .lifetime ? "@_lifetime(borrow storage)\n  " : ""
    var declaration = self.declaration(
      """
      \(unsafe)\(frozen)\(self.access)struct \(viewName): \(constraints) {
        \(self.access)let _streamStorage: UnsafeMutablePointer<\(partialName)>

        \(lifetime)\(self.inline)\(self.access)init(_ storage: UnsafeMutableRawPointer) {
          self._streamStorage = storage.assumingMemoryBound(to: \(partialName).self)
        }

      \(accessors)
      }
      """,
      as: StructDeclSyntax.self
    )
    guard !additionalMembers.isEmpty else { return declaration }
    var members = self.terminated(declaration.memberBlock.members, nextIndentation: .spaces(2))
    members.append(contentsOf: self.indented(additionalMembers))
    declaration.memberBlock.members = members
    return declaration
  }

  /// Generates the view factory required by `StreamParseable`.
  public func streamViewFunction() -> FunctionDeclSyntax {
    let viewName = self.configuration.names.viewType.trimmedDescription
    let lifetime =
      self.configuration.viewMode == .lifetime ? "@_lifetime(borrow storage)\n" : "@unsafe\n"
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
  public func fieldIdentifiers() -> EnumDeclSyntax {
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

  /// Generates the schemas cached for fields that can contain nested values.
  public func containerSchemaMembers() -> MemberBlockItemListSyntax {
    self.members(self.schemaPlan.containerSchemas.joined(separator: "\n"))
  }

  /// Generates byte-exact key matching for the object schema.
  public func matchFieldFunction() -> FunctionDeclSyntax {
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
  public func applyFunction(for operation: StreamApplyOperation) -> FunctionDeclSyntax {
    let function = self.schemaPlan.apply[operation]!
    let binding =
      function.cases.isEmpty ? "" : "  let p = storage.assumingMemoryBound(to: Self.self)\n"
    let cases = function.cases.joined(separator: "\n")
    return self.declaration(
      """
      \(self.inline)\(self.access)static func \(function.name)(
        \(function.parameters)
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
  public func fieldTableProperty() -> VariableDeclSyntax {
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
  public func schemaProperty() -> VariableDeclSyntax {
    let converted = self.fields.filter { $0.completedConversion != nil }
    let finish = self.finishStringArgument(for: converted)
    return self.declaration(
      """
      \(self.access)static let streamSchema = StreamParsingCore.StreamSchema(
        shape: .object,
        matchField: Self.streamMatchField,
        applyString: Self.streamApplyString,
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
  public func schemaMembers() -> MemberBlockItemListSyntax {
    var result = MemberBlockItemListSyntax([])
    if !self.fields.isEmpty {
      result.append(self.member(self.fieldIdentifiers()))
    }
    result.append(contentsOf: self.containerSchemaMembers())
    result.append(self.member(self.matchFieldFunction()))
    for operation in [StreamApplyOperation.string, .number, .boolean, .null] {
      result.append(self.member(self.applyFunction(for: operation)))
    }
    result.append(self.member(self.fieldTableProperty()))
    result.append(self.member(self.schemaProperty()))
    return result
  }

  /// Generates the complete nested partial-storage declaration.
  public func partialDeclaration(named name: TokenSyntax? = nil) -> StructDeclSyntax {
    self.partialDeclaration(
      named: name,
      additionalViewMembers: MemberBlockItemListSyntax([]),
      additionalMembers: MemberBlockItemListSyntax([])
    )
  }

  /// Generates a complete partial declaration with concrete view and partial additions.
  public func partialDeclaration(
    named name: TokenSyntax? = nil,
    additionalViewMembers: MemberBlockItemListSyntax = MemberBlockItemListSyntax([]),
    additionalMembers: MemberBlockItemListSyntax = MemberBlockItemListSyntax([])
  ) -> StructDeclSyntax {
    if let name, name.text != self.configuration.names.partialType.text {
      var configuration = self.configuration
      configuration.names.partialType = name
      let generation = Self(
        uncheckedFields: self.fields,
        partialMembers: self.partialMembers,
        configuration: configuration
      )
      return generation.partialDeclaration(
        additionalViewMembers: additionalViewMembers,
        additionalMembers: additionalMembers
      )
    }
    let partialName = (name ?? self.configuration.names.partialType).trimmedDescription
    let view = self.viewDeclaration(additionalMembers: additionalViewMembers)
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
    members.append(contentsOf: self.schemaMembers())
    members.append(contentsOf: self.terminated(additionalMembers))
    if let lastIndex = members.indices.last {
      members[lastIndex].trailingTrivia = .newline
    }
    var declaration = self.declaration(
      """
      \(self.access)struct \(partialName): StreamParsingCore.StreamParseable,
        StreamParsingCore.StreamParseableObject, Sendable {
        \(self.access)typealias Partial = Self
      }
      """,
      as: StructDeclSyntax.self
    )
    var declarationMembers = self.terminated(
      declaration.memberBlock.members,
      nextIndentation: .spaces(2)
    )
    declarationMembers.append(contentsOf: self.indented(members))
    declaration.memberBlock.members = declarationMembers
    return declaration
  }

  /// Generates a complete partial declaration and builds additional partial members.
  public func partialDeclaration(
    named name: TokenSyntax? = nil,
    additionalViewMembers: MemberBlockItemListSyntax = MemberBlockItemListSyntax([]),
    @MemberBlockItemListBuilder additionalMembers: () throws -> MemberBlockItemListSyntax
  ) rethrows -> StructDeclSyntax {
    self.partialDeclaration(
      named: name,
      additionalViewMembers: additionalViewMembers,
      additionalMembers: try additionalMembers()
    )
  }
}

extension StreamObjectGeneration {
  fileprivate struct ApplyPlan: Hashable, Sendable {
    let name: String
    let parameters: String
    var cases = [String]()
  }

  fileprivate struct SchemaPlan: Hashable, Sendable {
    var matches = [String]()
    var fields = [String]()
    var containerSchemas = [String]()
    var apply = [StreamApplyOperation: ApplyPlan]()
  }

  fileprivate enum FieldShape {
    case scalarOrObject
    case array
    case dictionary(TypeSyntax)
  }

  fileprivate var access: String { self.configuration.accessLevel.prefix }
  fileprivate var inlinable: Bool { self.configuration.isInlinable }
  fileprivate var inline: String { self.inlinable ? "@inlinable " : "" }

  fileprivate func buildPlan() -> SchemaPlan {
    var result = SchemaPlan(apply: [
      .string: ApplyPlan(
        name: "streamApplyString",
        parameters: "_ storage: UnsafeMutableRawPointer, _ field: Int32,\n  _ bytes: Span<UInt8>"
      ),
      .number: ApplyPlan(
        name: "streamApplyNumber",
        parameters:
          "_ storage: UnsafeMutableRawPointer, _ field: Int32,\n  _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo"
      ),
      .boolean: ApplyPlan(
        name: "streamApplyBoolean",
        parameters: "_ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool"
      ),
      .null: ApplyPlan(
        name: "streamApplyNull",
        parameters: "_ storage: UnsafeMutableRawPointer, _ field: Int32"
      )
    ])
    for field in self.fields {
      let member = Self.memberName(field.name)
      let fieldID = "Self.StreamField.\(member)"
      for key in field.keys {
        result.matches.append(
          "  case \(self.wordLiteral(key))\(self.matchGuard(key)): return \(fieldID)"
        )
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
        var function = result.apply[operation]!
        if field.completedConversion != nil, operation != .null {
          let (method, args) =
            switch operation {
            case .string: ("applyString", "bytes")
            case .number: ("applyNumber", "bytes, info")
            case .boolean: ("applyBoolean", "value")
            case .null: fatalError()
            }
          function.cases.append(
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
          function.cases.append("  case \(fieldID): return \(expression)")
        }
        result.apply[operation] = function
      }
    }
    return result
  }

  fileprivate func schemaName(_ field: StreamParseableField) -> String {
    Self.memberName(
      TokenSyntax.identifier("streamContainerSchema_\(Self.bareName(field.name))")
    )
  }

  fileprivate func finishStringArgument(for fields: [StreamParseableField]) -> String {
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

  fileprivate func containerSchema(
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

  fileprivate func partialType(_ field: StreamParseableField) -> String {
    if let conversion = field.completedConversion {
      return "StreamParsingCore.ConvertedPartial<\(conversion.trimmedDescription)>"
    }
    if case .dictionary(let value) = self.fieldShape(field.type) {
      return "StreamParsingCore.StreamDictionary<\(value.trimmedDescription).Partial>"
    }
    return "\(self.unwrapped(field.type).trimmedDescription).Partial"
  }

  fileprivate func memberType(_ field: StreamParseableField) -> String {
    let base = self.partialType(field)
    return self.partialMembers.makesRequiredPropertiesOptional || self.isOptional(field.type)
      ? "\(base)?" : base
  }

  fileprivate func fieldShape(_ type: TypeSyntax) -> FieldShape {
    let type = self.unwrapped(type)
    if type.is(ArrayTypeSyntax.self) { return .array }
    if let dictionary = type.as(DictionaryTypeSyntax.self) { return .dictionary(dictionary.value) }
    if let arguments = self.genericArguments(type), arguments.count == 1,
      self.lastTypeName(type) == "Array"
    {
      return .array
    }
    if let arguments = self.genericArguments(type), arguments.count == 2,
      self.lastTypeName(type) == "Dictionary",
      case .type(let value) = arguments[arguments.index(after: arguments.startIndex)].argument
    {
      return .dictionary(value)
    }
    return .scalarOrObject
  }

  fileprivate func schemaExpression(_ type: TypeSyntax) -> String {
    let type = self.unwrapped(type)
    if let array = type.as(ArrayTypeSyntax.self) {
      return self.containerSchemaExpression("Array", element: array.element, label: "element")
    }
    if let dictionary = type.as(DictionaryTypeSyntax.self) {
      return self.containerSchemaExpression(
        "Dictionary",
        element: dictionary.value,
        label: "value"
      )
    }
    if let arguments = self.genericArguments(type), arguments.count == 1,
      self.lastTypeName(type) == "Array",
      case .type(let element) = arguments.first!.argument
    {
      return self.containerSchemaExpression("Array", element: element, label: "element")
    }
    if let arguments = self.genericArguments(type), arguments.count == 2,
      self.lastTypeName(type) == "Dictionary",
      case .type(let value) = arguments[arguments.index(after: arguments.startIndex)].argument
    {
      return self.containerSchemaExpression("Dictionary", element: value, label: "value")
    }
    return "_streamSchema(for: \(type.trimmedDescription).Partial.self)"
  }

  fileprivate func lastTypeName(_ type: TypeSyntax) -> String? {
    type.as(IdentifierTypeSyntax.self)?.name.text ?? type.as(MemberTypeSyntax.self)?.name.text
  }

  fileprivate func genericArguments(_ type: TypeSyntax) -> GenericArgumentListSyntax? {
    type.as(IdentifierTypeSyntax.self)?.genericArgumentClause?.arguments
      ?? type.as(MemberTypeSyntax.self)?.genericArgumentClause?.arguments
  }

  fileprivate func containerSchemaExpression(
    _ kind: String,
    element: TypeSyntax,
    label: String
  ) -> String {
    let storage = self.unwrapped(element).trimmedDescription
    let builder = self.isOptional(element) ? "_streamOptional\(kind)Schema" : "_stream\(kind)Schema"
    return "\(builder)(\(storage).Partial.self, \(label): \(self.schemaExpression(element)))"
  }

  fileprivate func unwrapped(_ type: TypeSyntax) -> TypeSyntax {
    var current = type
    while true {
      let next: TypeSyntax
      if let optional = current.as(OptionalTypeSyntax.self) {
        next = optional.wrappedType
      } else if let identifier = current.as(IdentifierTypeSyntax.self),
        identifier.name.text == "Optional",
        let argument = identifier.genericArgumentClause?.arguments.first,
        identifier.genericArgumentClause?.arguments.count == 1,
        case .type(let wrapped) = argument.argument
      {
        next = wrapped
      } else if let member = current.as(MemberTypeSyntax.self),
        member.name.text == "Optional",
        let argument = member.genericArgumentClause?.arguments.first,
        member.genericArgumentClause?.arguments.count == 1,
        case .type(let wrapped) = argument.argument
      {
        next = wrapped
      } else {
        return current
      }
      if next == current { return current }
      current = next
    }
  }

  fileprivate func isOptional(_ type: TypeSyntax) -> Bool { self.unwrapped(type) != type }

  fileprivate static func bareName(_ token: TokenSyntax) -> String {
    let text = token.text
    return text.count > 2 && text.hasPrefix("`") && text.hasSuffix("`")
      ? String(text.dropFirst().dropLast()) : text
  }

  fileprivate static func memberName(_ token: TokenSyntax) -> String {
    let text = token.trimmedDescription
    if text.hasPrefix("`") && text.hasSuffix("`") { return text }
    if let declaration = try? VariableDeclSyntax("var \(raw: text): Int"),
      !Syntax(declaration).hasError
    {
      return text
    }
    return "`\(text)`"
  }

  fileprivate static func isValidMemberName(_ token: TokenSyntax) -> Bool {
    guard let declaration = try? VariableDeclSyntax("var \(raw: Self.memberName(token)): Int")
    else {
      return false
    }
    return !Syntax(declaration).hasError
  }

  fileprivate func wordLiteral(_ key: String, at start: Int = 0) -> String {
    StreamUTF8Match.wordLiteral(
      StreamUTF8Match.paddedWord(in: Array(key.utf8), at: start)
    )
  }

  fileprivate func matchGuard(_ key: String) -> String {
    let utf8 = Array(key.utf8)
    var conditions = ["key.count == \(utf8.count)"]
    for offset in stride(from: 8, to: utf8.count, by: 8) {
      conditions.append("key.paddedWord(at: \(offset)) == \(self.wordLiteral(key, at: offset))")
    }
    return " where " + conditions.joined(separator: " && ")
  }

  fileprivate func members(_ source: String) -> MemberBlockItemListSyntax {
    guard !source.allSatisfy(\.isWhitespace) else {
      return MemberBlockItemListSyntax([])
    }
    var parsed = try! StructDeclSyntax(
      "struct _StreamGenerated {\n\(raw: source)\n}"
    )
    .memberBlock.members
    if let firstIndex = parsed.indices.first {
      parsed[firstIndex].leadingTrivia = Trivia(
        pieces: parsed[firstIndex].leadingTrivia.drop(while: \.isWhitespace)
      )
    }
    return self.terminated(parsed)
  }

  fileprivate func terminated(
    _ members: MemberBlockItemListSyntax,
    nextIndentation: Trivia = []
  ) -> MemberBlockItemListSyntax {
    guard !members.isEmpty else { return members }
    let lastIndex = members.index(before: members.endIndex)
    return MemberBlockItemListSyntax(
      members.indices.map { index in
        var item = members[index]
        guard index == lastIndex else { return item }
        item.trailingTrivia = .newlines(2) + nextIndentation
        return item
      }
    )
  }

  fileprivate func indented(
    _ members: MemberBlockItemListSyntax
  ) -> MemberBlockItemListSyntax {
    StreamObjectSyntaxIndenter(indentation: .spaces(2)).rewrite(members)
      .cast(MemberBlockItemListSyntax.self)
  }

  fileprivate func member(_ declaration: some DeclSyntaxProtocol) -> MemberBlockItemSyntax {
    var declaration = DeclSyntax(declaration)
    declaration.trailingTrivia = .newlines(2)
    return MemberBlockItemSyntax(decl: declaration)
  }

  fileprivate func declaration<T: DeclSyntaxProtocol>(_ source: String, as type: T.Type) -> T {
    let declaration = DeclSyntax("\(raw: source)")
    return declaration.as(T.self)!
  }
}

private final class StreamObjectSyntaxIndenter: SyntaxRewriter {
  let indentation: Trivia

  init(indentation: Trivia) {
    self.indentation = indentation
    super.init(viewMode: .sourceAccurate)
  }

  override func visit(_ token: TokenSyntax) -> TokenSyntax {
    TokenSyntax(
      token.tokenKind,
      leadingTrivia: self.indent(token.leadingTrivia),
      trailingTrivia: self.indent(token.trailingTrivia),
      presence: token.presence
    )
  }

  private func indent(_ trivia: Trivia) -> Trivia {
    Trivia(
      pieces: trivia.flatMap { piece in
        piece.isNewline ? [piece] + self.indentation.pieces : [piece]
      }
    )
  }
}
