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
    Self.completeCondition(matching: bytes, utf8: Array(self.value.utf8))
  }

  /// The little-endian, zero-padded first eight bytes of the match value.
  public var leadingWord: IntegerLiteralExprSyntax {
    IntegerLiteralExprSyntax(literal: .integerLiteral(Self.wordLiteral(self.paddedWord(at: 0))))
  }

  /// Generates the byte-count and trailing-word portion of the equality predicate.
  ///
  /// This predicate is complete when the caller has already established that
  /// `leadingWord` matches. The expression may occur more than once.
  public func remainingCondition(matching bytes: some ExprSyntaxProtocol) -> ExprSyntax {
    Self.remainingCondition(matching: bytes, utf8: Array(self.value.utf8))
  }

  static func completeCondition(
    matching bytes: some ExprSyntaxProtocol,
    utf8: [UInt8]
  ) -> ExprSyntax {
    guard !utf8.isEmpty else {
      return "(\(bytes)).count == 0"
    }
    let word = IntegerLiteralExprSyntax(
      literal: .integerLiteral(Self.wordLiteral(Self.paddedWord(in: utf8, at: 0)))
    )
    let leading: ExprSyntax = "(\(bytes)).paddedLeadingWord() == \(word)"
    let remaining = Self.remainingCondition(matching: bytes, utf8: utf8)
    // Count comes first so an empty span short-circuits before its nil base address
    // reaches `paddedLeadingWord()`.
    return "\(remaining) && \(leading)"
  }

  static func remainingCondition(
    matching bytes: some ExprSyntaxProtocol,
    utf8: [UInt8]
  ) -> ExprSyntax {
    var condition: ExprSyntax = "(\(bytes)).count == \(raw: utf8.count)"
    for offset in stride(from: 8, to: utf8.count, by: 8) {
      let word = IntegerLiteralExprSyntax(
        literal: .integerLiteral(Self.wordLiteral(Self.paddedWord(in: utf8, at: offset)))
      )
      condition = "\(condition) && (\(bytes)).paddedWord(at: \(raw: offset)) == \(word)"
    }
    return condition
  }

  static func paddedWord(in utf8: [UInt8], at start: Int) -> UInt64 {
    utf8.dropFirst(start).prefix(8).enumerated()
      .reduce(into: UInt64(0)) { word, element in
        word |= UInt64(element.element) << UInt64(element.offset * 8)
      }
  }

  private func paddedWord(at start: Int) -> UInt64 {
    Self.paddedWord(in: Array(self.value.utf8), at: start)
  }

  static func wordLiteral(_ word: UInt64) -> String {
    let digits = Array("0123456789ABCDEF")
    let hex = stride(from: 60, through: 0, by: -4)
      .map {
        String(digits[Int((word >> UInt64($0)) & 0xF)])
      }
    return "0x"
      + stride(from: 0, to: hex.count, by: 4)
      .map { hex[$0..<min($0 + 4, hex.count)].joined() }
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
    guard let first = self.values.first else {
      return ExprSyntax(BooleanLiteralExprSyntax(false))
    }
    return self.values.dropFirst()
      .reduce(StreamUTF8Match(first).condition(matching: bytes)) {
        partial,
        value in
        let match = StreamUTF8Match(value).condition(matching: bytes)
        return "\(partial) || (\(match))"
      }
  }
}
