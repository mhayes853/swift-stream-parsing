internal import StreamParsingKeyDecoding

/// How `@StreamParseable` derives the JSON key of each property that does not name its own.
///
/// ```swift
/// @StreamParseable(keyDecodingStrategy: .convertFromSnakeCase)
/// struct Tweet {
///   var createdAt: String          // "created_at"
///   var inReplyToStatusID: Int?    // "in_reply_to_status_id"
///   @StreamParseableMember(key: "full_text")
///   var text: String               // "full_text": a key the property names is never converted
/// }
/// ```
///
/// The strategy is the type's own: a member whose type is itself `@StreamParseable` follows the
/// strategy that type declares. It also applies to an enum without a raw type, to its case names
/// and associated value labels, which are the object keys `Codable` reads it from.
///
/// Where `JSONDecoder` converts each key it reads and compares the result with the declared names,
/// a stream converts each declared name into the key it expects, once -- as the macro expands for
/// a built-in strategy, when the type's schema is built for any other -- and matches keys exactly
/// while parsing. So a strategy costs nothing per key, and the conversions differ from
/// `JSONDecoder`'s at the edges:
///
/// - `userID` is read from `user_id`, where `JSONDecoder` converts `user_id` to `userId` and
///   misses.
/// - A property already named in snake case, `user_id`, is still read from `user_id`.
/// - Only the conventional spelling of a key matches: `user_ID` does not reach `userID`.
///
/// The snake, screaming snake and kebab cases split a name into words as `JSONEncoder`'s
/// `convertToSnakeCase` does: at an uppercase letter that follows anything else, and one letter
/// before the lowercase letter that ends a run of capitals (`myURLValue` is `my_url_value`).
/// Digits stay with the word they follow (`line2Text` is `line2_text`). A leading run of capitals
/// is one word (`URLValue` is `url_value`), an underscore in the name separates words, and leading
/// and trailing underscores are kept. The Pascal case uppercases the first letter and keeps the
/// rest as declared (`userID` is `UserID`).
@nonexhaustive
public enum StreamKeyDecodingStrategy: Sendable {
  /// Keys are the property and case names as declared.
  case useDefaultKeys
  /// `createdAt` is read from `created_at`.
  case convertFromSnakeCase
  /// `createdAt` is read from `CREATED_AT`.
  case convertFromScreamingSnakeCase
  /// `createdAt` is read from `created-at`.
  case convertFromKebabCase
  /// `createdAt` is read from `CreatedAt`.
  case convertFromPascalCase
  /// Returns the key a declared name is read from.
  ///
  /// The closure receives the bare name (no backticks) of each property, case and associated
  /// value label that does not name its own key, and runs when the schema is built, never while
  /// parsing. It may run more than once for the same name -- the schema is rebuilt after its cache
  /// is emptied -- so it must return the same key each time. Two names converted to the same key
  /// stop the program when the schema is built.
  ///
  /// The macro evaluates the strategy inside the generated `Partial`, where `Self` names the
  /// `Partial`, so qualify what the closure refers to. A public generic type's schema is built in
  /// its clients, so what it refers to must be `public` or `@usableFromInline`.
  case custom(@Sendable (String) -> String)

  /// The key `name` is read from under this strategy.
  ///
  /// A custom strategy can build on a built-in one with it:
  ///
  /// ```swift
  /// .custom { "x_" + StreamKeyDecodingStrategy.convertFromSnakeCase.key(for: $0) }
  /// ```
  public func key(for name: String) -> String {
    let conversion: StreamDefaultKeyConversion
    switch self {
    case .useDefaultKeys: return name
    case .convertFromSnakeCase: conversion = .snakeCase
    case .convertFromScreamingSnakeCase: conversion = .screamingSnakeCase
    case .convertFromKebabCase: conversion = .kebabCase
    case .convertFromPascalCase: conversion = .pascalCase
    case .custom(let convert): return convert(name)
    }
    return conversion.key(for: name)
  }
}
