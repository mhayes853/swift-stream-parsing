import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// A macro argument written in a spelling `StreamMacroArguments` cannot read.
///
/// Collected rather than emitted. A macro with more than one role reads the same arguments in
/// each, and has to diagnose from only one of them, or every message is emitted twice.
public struct StreamMacroArgumentError: Error, Sendable, CustomStringConvertible {
  /// Where the error is diagnosed: the argument's expression, or the attribute for a combination
  /// of arguments.
  public let node: Syntax
  /// The explanation, naming the argument as it is written at the use site.
  public let message: String

  /// Creates an error diagnosed at `node`.
  public init(node: some SyntaxProtocol, message: String) {
    self.node = Syntax(node)
    self.message = message
  }

  /// An error diagnostic at `node`.
  public var diagnostic: Diagnostic {
    Diagnostic(node: self.node, message: MacroExpansionErrorMessage(self.message))
  }

  public var description: String { self.message }
}

/// The stream generation options an attribute writes, read from their spelling, never evaluated.
///
/// Reading is best effort: an argument the attribute does not write stays `nil`, as does one
/// written in a spelling that cannot be read, which adds to `errors` instead. Arguments with other
/// labels are ignored, so a macro that accepts some of these options beside its own can read its
/// attribute directly, and every macro reads the same spellings and explains a wrong one the same
/// way. An explicit `nil` counts as unwritten, as the optional parameters it defaults are.
///
/// | Label | Accepted spelling |
/// | --- | --- |
/// | `partialMembers:` | `.optional`, `.streamInitialValue` |
/// | `partialStrings:` | `.streamString`, `.string` |
/// | `keyDecodingStrategy:` | any expression; see `StreamGenerationConfiguration` |
/// | `schemaCache:` | any expression; see `StreamGenerationConfiguration` |
/// | `key:` | a nonempty string literal |
/// | `keyNames:` | a nonempty array of nonempty string literals |
/// | `initialCapacity:` | an integer literal, in any radix |
/// | `completedConversion:` | `Strategy.self` |
///
/// A member spelling may name its type (`StreamPartialStrings.string`). A string literal may not
/// interpolate: `"a\(1)b"` is an error, not the key `ab`.
public struct StreamMacroArguments: Sendable {
  /// For `StreamObjectGeneration(partialMembers:)`.
  public var partialMembers: StreamPartialMembers?
  /// For `StreamParseableField.partialStrings`.
  public var partialStrings: StreamPartialStrings?
  /// For `StreamGenerationConfiguration.keyDecodingStrategy`.
  public var keyDecodingStrategy: ExprSyntax?
  /// For `StreamGenerationConfiguration.schemaCache`.
  public var schemaCache: ExprSyntax?
  /// `key:` or `keyNames:`, for `StreamParseableField.explicitKeys` or
  /// `StreamParseableEnumCase.explicitKeys`, which a key decoding strategy does not convert.
  public var explicitKeys: [String]?
  /// For `StreamParseableField.initialCapacity`.
  public var initialCapacity: Int?
  /// The strategy type, for `StreamParseableField.completedConversion`.
  public var completedConversion: TypeSyntax?
  /// The arguments written in a spelling that cannot be read, in source order.
  public var errors: [StreamMacroArgumentError]

  /// Creates a set of options directly, for a macro that spells them its own way.
  public init(
    partialMembers: StreamPartialMembers? = nil,
    partialStrings: StreamPartialStrings? = nil,
    keyDecodingStrategy: (any ExprSyntaxProtocol)? = nil,
    schemaCache: (any ExprSyntaxProtocol)? = nil,
    explicitKeys: [String]? = nil,
    initialCapacity: Int? = nil,
    completedConversion: (any TypeSyntaxProtocol)? = nil,
    errors: [StreamMacroArgumentError] = []
  ) {
    self.partialMembers = partialMembers
    self.partialStrings = partialStrings
    self.keyDecodingStrategy = keyDecodingStrategy.map { ExprSyntax($0) }
    self.schemaCache = schemaCache.map { ExprSyntax($0) }
    self.explicitKeys = explicitKeys
    self.initialCapacity = initialCapacity
    self.completedConversion = completedConversion.map { TypeSyntax($0) }
    self.errors = errors
  }

  /// Reads the options `attribute` writes. Error messages name it as written:
  /// `@StreamParseable(partialStrings:) requires .streamString or .string.`
  public init(parsing attribute: AttributeSyntax) {
    let arguments = attribute.arguments?.as(LabeledExprListSyntax.self) ?? []
    self.init(
      parsing: arguments,
      attributeName: attribute.attributeName.trimmedDescription,
      at: attribute
    )
  }

  // Error messages name each argument `@<attributeName>(<label>:)`; one about a combination of
  // arguments is diagnosed at `node`.
  private init(parsing arguments: LabeledExprListSyntax, attributeName: String, at node: some SyntaxProtocol) {
    self.init()
    func written(_ label: String) -> ExprSyntax? {
      guard let expression = arguments.first(where: { $0.label?.text == label })?.expression,
        !expression.is(NilLiteralExprSyntax.self)
      else { return nil }
      return expression
    }
    func read<Value>(
      _ label: String,
      _ parse: (ExprSyntax, String) throws(StreamMacroArgumentError) -> Value
    ) -> Value? {
      guard let expression = written(label) else { return nil }
      do {
        return try parse(expression, "@\(attributeName)(\(label):)")
      } catch {
        self.errors.append(error)
        return nil
      }
    }
    self.partialMembers = read("partialMembers", Self.partialMembers)
    self.partialStrings = read("partialStrings", Self.partialStrings)
    self.keyDecodingStrategy = written("keyDecodingStrategy")
    self.schemaCache = written("schemaCache")
    if written("key") != nil, written("keyNames") != nil {
      self.errors.append(
        StreamMacroArgumentError(
          node: node, message: "@\(attributeName) takes either key: or keyNames:, not both."
        )
      )
    } else if let key = read("key", Self.key) {
      self.explicitKeys = [key]
    } else {
      self.explicitKeys = read("keyNames", Self.keyNames)
    }
    self.initialCapacity = read("initialCapacity", Self.initialCapacity)
    self.completedConversion = read("completedConversion", Self.completedConversion)
  }
}

// MARK: - Spellings

extension StreamMacroArguments {
  private static func partialMembers(
    _ expression: ExprSyntax,
    label: String
  ) throws(StreamMacroArgumentError) -> StreamPartialMembers {
    switch Self.memberName(expression) {
    case "optional": return .optional
    case "streamInitialValue": return .streamInitialValue
    default:
      throw StreamMacroArgumentError(
        node: expression, message: "\(label) requires .optional or .streamInitialValue."
      )
    }
  }

  private static func partialStrings(
    _ expression: ExprSyntax,
    label: String
  ) throws(StreamMacroArgumentError) -> StreamPartialStrings {
    switch Self.memberName(expression) {
    case "streamString": return .streamString
    case "string": return .string
    default:
      throw StreamMacroArgumentError(
        node: expression, message: "\(label) requires .streamString or .string."
      )
    }
  }

  private static func completedConversion(
    _ expression: ExprSyntax,
    label: String
  ) throws(StreamMacroArgumentError) -> TypeSyntax {
    guard let member = expression.as(MemberAccessExprSyntax.self),
      member.declName.baseName.text == "self", let base = member.base
    else {
      throw StreamMacroArgumentError(
        node: expression, message: "\(label) requires a strategy type followed by .self."
      )
    }
    return TypeSyntax(stringLiteral: base.trimmedDescription)
  }

  // A negative number is a prefix operator applied to a literal, not a literal, so it is an
  // error, as is a literal too large for `Int`.
  private static func initialCapacity(
    _ expression: ExprSyntax,
    label: String
  ) throws(StreamMacroArgumentError) -> Int {
    guard let value = Self.integerLiteralValue(expression) else {
      throw StreamMacroArgumentError(
        node: expression, message: "\(label) requires a nonnegative integer literal."
      )
    }
    return value
  }

  private static func key(
    _ expression: ExprSyntax,
    label: String
  ) throws(StreamMacroArgumentError) -> String {
    guard let key = expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue else {
      throw StreamMacroArgumentError(node: expression, message: "\(label) requires a string literal.")
    }
    guard !key.isEmpty else {
      throw StreamMacroArgumentError(node: expression, message: "\(label) must not be empty.")
    }
    return key
  }

  private static func keyNames(
    _ expression: ExprSyntax,
    label: String
  ) throws(StreamMacroArgumentError) -> [String] {
    let notALiteral = StreamMacroArgumentError(
      node: expression, message: "\(label) requires a string array literal."
    )
    guard let array = expression.as(ArrayExprSyntax.self), !array.elements.isEmpty else {
      throw notALiteral
    }
    var keys = [String]()
    for element in array.elements {
      guard let key = element.expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
      else { throw notALiteral }
      keys.append(key)
    }
    guard !keys.contains(where: \.isEmpty) else {
      throw StreamMacroArgumentError(
        node: expression, message: "\(label) must not contain an empty name."
      )
    }
    return keys
  }

  /// The member an option's spelling names, with or without a base: `.string` and
  /// `StreamPartialStrings.string` both read as `string`.
  private static func memberName(_ expression: ExprSyntax) -> String? {
    guard let member = expression.as(MemberAccessExprSyntax.self),
      member.declName.argumentNames == nil
    else { return nil }
    return member.declName.baseName.text
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
}
