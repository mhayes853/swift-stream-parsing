import SwiftSyntax
import SwiftSyntaxBuilder

/// A byte-exact match against the UTF-8 encoding of a string.
///
/// The generated predicates expect an expression whose value provides `count`,
/// `paddedLeadingWord()`, and `paddedWord(at:)`, such as `Span<UInt8>`.
public struct StreamUTF8Match: Hashable, Sendable {
  /// The string whose UTF-8 encoding is matched.
  public let value: String

  /// Creates a byte-exact UTF-8 match.
  public init(_ value: String) {
    self.value = value
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.value.utf8.elementsEqual(rhs.value.utf8)
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(Array(self.value.utf8))
  }

  /// Generates a complete byte-exact equality predicate.
  ///
  /// The expression may occur more than once in the returned syntax. Bind
  /// side-effecting input to a local first when it must be evaluated exactly once.
  public func condition(matching bytes: some ExprSyntaxProtocol) -> ExprSyntax {
    guard !self.value.isEmpty else { return "(\(bytes)).count == 0" }
    let remaining = streamRemainingUTF8Condition(self, matching: bytes)
    // Count comes first so an empty span short-circuits before its nil base address
    // reaches `paddedLeadingWord()`.
    return "\(remaining) && (\(bytes)).paddedLeadingWord() == \(streamUTF8WordLiteral(self.value, at: 0))"
  }


}

/// A byte-exact predicate that accepts any of several UTF-8 strings.
public struct StreamUTF8MatchSet: Hashable, Sendable {
  /// The accepted strings, in their original order.
  public let values: [String]

  /// Creates a set of accepted UTF-8 strings.
  public init(_ values: some Sequence<String>) {
    self.values = Array(values)
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.values.map { Array($0.utf8) } == rhs.values.map { Array($0.utf8) }
  }

  public func hash(into hasher: inout Hasher) {
    self.values.forEach { hasher.combine(Array($0.utf8)) }
  }

  /// Generates a predicate that is true when any value matches.
  ///
  /// An empty set produces `false`. The input expression may occur more than once.
  public func condition(matching bytes: some ExprSyntaxProtocol) -> ExprSyntax {
    streamUTF8Condition(self.values, matching: bytes)
  }
}
