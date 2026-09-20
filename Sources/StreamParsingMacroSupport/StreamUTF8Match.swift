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
  /// The expression may occur more than once in the returned syntax. Use
  /// ``StreamUTF8Matcher`` when the expression must be evaluated exactly once.
  public func condition(matching bytes: some ExprSyntaxProtocol) -> ExprSyntax {
    guard !self.value.isEmpty else { return "(\(bytes)).count == 0" }
    let remaining = self.remainingCondition(matching: bytes)
    // Count comes first so an empty span short-circuits before its nil base address
    // reaches `paddedLeadingWord()`.
    return "\(remaining) && (\(bytes)).paddedLeadingWord() == \(self.leadingWord)"
  }

  /// The little-endian, zero-padded first eight bytes of the match value.
  public var leadingWord: IntegerLiteralExprSyntax { self.word(at: 0) }

  /// A little-endian word containing up to eight UTF-8 bytes at a nonnegative offset.
  /// Missing bytes are padded with zeros.
  public func word(at offset: Int) -> IntegerLiteralExprSyntax {
    precondition(offset >= 0)
    return IntegerLiteralExprSyntax(
      literal: .integerLiteral(
        Self.wordLiteral(Self.paddedWord(in: Array(self.value.utf8), at: offset))
      )
    )
  }

  /// Generates the byte-count and trailing-word portion of the equality predicate.
  ///
  /// This predicate is complete when the caller has already established that
  /// `leadingWord` matches. The expression may occur more than once.
  public func remainingCondition(matching bytes: some ExprSyntaxProtocol) -> ExprSyntax {
    self.remainingCondition(byteCount: ExprSyntax("(\(bytes)).count")) { offset in
      ExprSyntax("(\(bytes)).paddedWord(at: \(raw: offset))")
    }
  }

  /// Generates the remaining predicate using a custom byte count and word loader.
  ///
  /// `wordAtOffset` builds an expression for each trailing word, at offsets 8, 16,
  /// and so on. It executes during generation, not in the generated client code.
  /// The count check precedes the word loads, and `leadingWord` must already match.
  /// The result composes with `WhereClauseSyntax`, `if`, and other conditions.
  public func remainingCondition<Word: ExprSyntaxProtocol>(
    byteCount: some ExprSyntaxProtocol,
    wordAtOffset: (Int) throws -> Word
  ) rethrows -> ExprSyntax {
    var condition: ExprSyntax = "\(Self.operand(byteCount)) == \(raw: self.value.utf8.count)"
    for offset in stride(from: 8, to: self.value.utf8.count, by: 8) {
      let loaded = try wordAtOffset(offset)
      condition = "\(condition) && \(Self.operand(loaded)) == \(self.word(at: offset))"
    }
    return condition
  }

  // Preserve precedence for caller-supplied expressions without adding parentheses
  // to the simple references and calls used by the built-in generators.
  private static func operand(_ expression: some ExprSyntaxProtocol) -> ExprSyntax {
    let expression = ExprSyntax(expression)
    if expression.is(DeclReferenceExprSyntax.self) || expression.is(MemberAccessExprSyntax.self)
      || expression.is(FunctionCallExprSyntax.self) || expression.is(IntegerLiteralExprSyntax.self)
      || expression.is(SubscriptCallExprSyntax.self) || expression.is(TupleExprSyntax.self)
    {
      return expression
    }
    return "(\(expression))"
  }

  static func paddedWord(in utf8: [UInt8], at start: Int) -> UInt64 {
    utf8.dropFirst(start).prefix(8).enumerated()
      .reduce(into: UInt64(0)) { word, element in
        word |= UInt64(element.element) << UInt64(element.offset * 8)
      }
  }

  static func wordLiteral(_ word: UInt64) -> String {
    "0x"
      + stride(from: 48, through: 0, by: -16)
      .map { shift in
        let digits = String((word >> shift) & 0xFFFF, radix: 16, uppercase: true)
        return String(repeating: "0", count: 4 - digits.count) + digits
      }
      .joined(separator: "_")
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
    self.condition(matching: bytes, afterLeadingWordMatch: false)
  }

  func condition(
    matching bytes: some ExprSyntaxProtocol,
    afterLeadingWordMatch: Bool
  ) -> ExprSyntax {
    let conditions = self.values.map { value in
      let match = StreamUTF8Match(value)
      return afterLeadingWordMatch
        ? match.remainingCondition(matching: bytes) : match.condition(matching: bytes)
    }
    guard let first = conditions.first else {
      return ExprSyntax(BooleanLiteralExprSyntax(false))
    }
    return conditions.dropFirst()
      .reduce(first) { partial, condition in
        "\(partial) || (\(condition))"
      }
  }
}
