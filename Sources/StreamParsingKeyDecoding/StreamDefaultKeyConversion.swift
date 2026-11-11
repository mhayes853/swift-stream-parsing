/// A built-in `StreamKeyDecodingStrategy`'s conversion from a declared Swift name to the JSON key
/// it is read from; see that type for the rules.
///
/// `@StreamParseable` applies it as it expands and `StreamKeyDecodingStrategy.key(for:)` when a
/// schema is built, and the two must agree on every key, so both link this one implementation.
public enum StreamDefaultKeyConversion: Hashable, Sendable {
  /// `createdAt` is read from `created_at`.
  case snakeCase
  /// `createdAt` is read from `CREATED_AT`.
  case screamingSnakeCase
  /// `createdAt` is read from `created-at`.
  case kebabCase
  /// `createdAt` is read from `CreatedAt`.
  case pascalCase

  /// The key `name` is read from.
  public func key(for name: String) -> String {
    switch self {
    case .snakeCase: Self.joinedWords(of: name, separator: "_", uppercased: false)
    case .screamingSnakeCase: Self.joinedWords(of: name, separator: "_", uppercased: true)
    case .kebabCase: Self.joinedWords(of: name, separator: "-", uppercased: false)
    case .pascalCase: Self.capitalized(name)
    }
  }

  private static func capitalized(_ name: String) -> String {
    guard let first = name.firstIndex(where: { $0 != "_" }) else { return name }
    return String(name[..<first]) + name[first].uppercased() + name[name.index(after: first)...]
  }

  private static func joinedWords(
    of name: String,
    separator: Character,
    uppercased: Bool
  ) -> String {
    let characters = Array(name)
    // Leading and trailing underscores are kept as declared, and are not separators.
    guard let start = characters.firstIndex(where: { $0 != "_" }),
      let last = characters.lastIndex(where: { $0 != "_" })
    else { return name }
    var key = String(characters[..<start])
    for index in start...last {
      let character = characters[index]
      // Each underscore in the name is a separator, so `a__b` keeps both.
      if character == "_" {
        key.append(separator)
        continue
      }
      // `aB` starts a word at `B`; `ABc` starts one at `B`, closing the acronym before it.
      if index > start, character.isUppercase {
        let previous = characters[index - 1]
        if previous != "_",
          !previous.isUppercase || (index < last && characters[index + 1].isLowercase)
        {
          key.append(separator)
        }
      }
      key += uppercased ? character.uppercased() : character.lowercased()
    }
    return key + String(characters[(last + 1)...])
  }
}
