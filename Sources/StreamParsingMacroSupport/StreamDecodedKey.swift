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

  /// A key known while the macro expands.
  init(known key: String) {
    self.storage = .known(key)
  }

  /// `name`, converted at run time by the strategy `strategy` spells.
  init(converting name: String, by strategy: some ExprSyntaxProtocol) {
    self.storage = .converted(name: name, strategy: strategy.trimmedDescription)
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
  /// Keys written out are returned as they are; a name the field converts is converted by
  /// `keyDecodingStrategy`.
  public func decodedKeys(for field: StreamParseableField) -> [StreamDecodedKey] {
    field.convertsKeys
      ? field.keys.map(self.decodedKey(converting:))
      : field.keys.map(StreamDecodedKey.init(known:))
  }

  /// The key `keyDecodingStrategy` gives `name`.
  ///
  /// For a name that cannot have a key written out, such as an enum case under `.caseKeyedObject`.
  /// For a field, use `decodedKeys(for:)`: this always converts, so it gives the wrong key for a
  /// field whose key is written out.
  public func decodedKey(converting name: String) -> StreamDecodedKey {
    switch self.keyDecoding {
    case .none: StreamDecodedKey(known: name)
    case .builtIn(let conversion): StreamDecodedKey(known: conversion.key(for: name))
    case .atSchemaBuild: StreamDecodedKey(converting: name, by: self.keyDecodingStrategy!)
    }
  }
}
