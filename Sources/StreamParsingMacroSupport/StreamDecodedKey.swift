internal import StreamParsingKeyDecoding
import SwiftSyntax

/// A key that selects a field or case, as the generated `Partial` matches it.
///
/// Emit `expression` wherever the key is needed. Read `knownKey` only where the key itself must be
/// known while the macro expands, such as to diagnose two fields claiming one key: under a custom
/// `keyDecodingStrategy`, a converted name's key exists only at run time.
public struct StreamDecodedKey: Hashable, Sendable {
  private enum Storage: Hashable, Sendable {
    case known(String)
    /// A name that a strategy, spelled `strategy`, converts at run time.
    case converted(name: String, strategy: String)
  }

  private let storage: Storage

  /// A key known while the macro expands, such as one written out.
  public init(knownKey key: String) {
    self.storage = .known(key)
  }

  /// The key a `StreamKeyDecodingStrategy` expression gives `name`, as
  /// `StreamGenerationConfiguration.keyDecodingStrategy` reads it.
  ///
  /// For a name that cannot have a key written out, such as an enum case under `.caseKeyedObject`;
  /// for a field, use `StreamGenerationConfiguration.decodedKeys(for:)`, which keeps the keys it
  /// writes out. Without a strategy the name is the key. A built-in strategy spelled as a member
  /// (`.convertFromSnakeCase`, optionally qualified with `StreamKeyDecodingStrategy`) converts it
  /// now, and any other expression at run time.
  public init(converting name: String, by strategy: ExprSyntax?) {
    guard let strategy else {
      self.storage = .known(name)
      return
    }
    let conversion: StreamDefaultKeyConversion
    switch Self.memberName(strategy) {
    case "useDefaultKeys":
      self.storage = .known(name)
      return
    case "convertFromSnakeCase": conversion = .snakeCase
    case "convertFromScreamingSnakeCase": conversion = .screamingSnakeCase
    case "convertFromKebabCase": conversion = .kebabCase
    case "convertFromPascalCase": conversion = .pascalCase
    default:
      self.storage = .converted(name: name, strategy: strategy.trimmedDescription)
      return
    }
    self.storage = .known(conversion.key(for: name))
  }

  /// The member a strategy's spelling names, if it is one of `StreamKeyDecodingStrategy`'s,
  /// without arguments: `.x`, `StreamKeyDecodingStrategy.x`, or
  /// `StreamParsing.StreamKeyDecodingStrategy.x`.
  private static func memberName(_ strategy: ExprSyntax) -> String? {
    guard let member = strategy.as(MemberAccessExprSyntax.self),
      member.declName.argumentNames == nil,
      member.base.map({
        ["StreamKeyDecodingStrategy", "StreamParsing.StreamKeyDecodingStrategy"]
          .contains($0.trimmedDescription)
      }) ?? true
    else { return nil }
    return member.declName.baseName.text
  }

  /// The key, if it is known while the macro expands.
  ///
  /// Always known for a key written out, and for a converted name without a strategy or under a
  /// built-in one. `nil` only for a name a custom strategy converts, whose key exists only at run
  /// time.
  public var knownKey: String? {
    guard case .known(let key) = self.storage else { return nil }
    return key
  }

  /// The name a custom strategy converts at run time, when `knownKey` is `nil`.
  var convertedName: String? {
    guard case .converted(let name, _) = self.storage else { return nil }
    return name
  }

  /// An expression evaluating to the key.
  ///
  /// `knownKey` as a string literal, or
  /// `(<strategy> as StreamParsing.StreamKeyDecodingStrategy).key(for: "<name>")`. It refers to no
  /// generated declaration, so it is valid wherever the strategy expression is: in the type, its
  /// `Partial`, a payload `Partial`, a generic context, or beside a hand-written `Partial`. A custom
  /// strategy is evaluated each time the expression is.
  public var expression: ExprSyntax {
    switch self.storage {
    case .known(let key):
      ExprSyntax(StringLiteralExprSyntax(content: key))
    case .converted(let name, let strategy):
      """
      (\(raw: strategy) as StreamParsing.StreamKeyDecodingStrategy)\
      .key(for: \(StringLiteralExprSyntax(content: name)))
      """
    }
  }
}

extension StreamGenerationConfiguration {
  /// The keys that select `field`, in their supplied order. Emit the first.
  ///
  /// `explicitKeys` are returned as they are. Without them, the field's name, without backticks,
  /// is converted by `keyDecodingStrategy`. A wildcard name has no keys of its own: the enum
  /// generation keys an unlabelled associated value by its position.
  public func decodedKeys(for field: StreamParseableField) -> [StreamDecodedKey] {
    if let explicitKeys = field.explicitKeys {
      return explicitKeys.map(StreamDecodedKey.init(knownKey:))
    }
    guard field.name.tokenKind != .wildcard else { return [] }
    return [
      StreamDecodedKey(
        converting: StreamObjectGeneration.bareName(field.name), by: self.keyDecodingStrategy
      )
    ]
  }
}
