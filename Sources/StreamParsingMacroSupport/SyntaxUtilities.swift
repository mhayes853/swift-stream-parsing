import SwiftSyntax
import SwiftSyntaxBuilder

extension TypeSyntaxProtocol {
  /// Removes every explicit optional layer (`T?`, `Optional<T>`, or `Swift.Optional<T>`).
  /// Does not resolve type aliases or unwrap optional elements inside containers.
  public var streamUnwrappedOptionalType: TypeSyntax {
    var type = TypeSyntax(self)
    while true {
      if let optional = type.as(OptionalTypeSyntax.self) {
        type = optional.wrappedType
      } else if streamTypeName(type) == "Optional",
        let arguments = streamGenericArguments(type), arguments.count == 1,
        case .type(let wrapped) = arguments.first!.argument
      {
        type = wrapped
      } else {
        return type
      }
    }
  }

  /// Whether the type has a syntactically explicit optional layer.
  public var streamIsOptional: Bool {
    self.streamUnwrappedOptionalType != TypeSyntax(self)
  }
}

func streamTypeName(_ type: some TypeSyntaxProtocol) -> String? {
  type.as(IdentifierTypeSyntax.self)?.name.text ?? type.as(MemberTypeSyntax.self)?.name.text
}

func streamGenericArguments(_ type: some TypeSyntaxProtocol) -> GenericArgumentListSyntax? {
  type.as(IdentifierTypeSyntax.self)?.genericArgumentClause?.arguments
    ?? type.as(MemberTypeSyntax.self)?.genericArgumentClause?.arguments
}

/// Indents every non-empty line of `text` by `spaces`.
func streamIndented(_ text: String, by spaces: Int) -> String {
  let padding = String(repeating: " ", count: spaces)
  return text.split(separator: "\n", omittingEmptySubsequences: false)
    .map { $0.isEmpty ? "" : padding + $0 }
    .joined(separator: "\n")
}

/// `signature { body }`, with `body` on its own lines one level in.
func streamDeclarationSource(_ signature: String, body: String) -> String {
  "\(signature) {\n\(streamIndented(body, by: 2))\n}"
}

/// The arm label matching exactly `key` in a `switch` over `input.paddedLeadingWord()`, where
/// `byteCount` is `input`'s length.
func streamWordCaseLabel(
  _ key: String,
  input: String,
  byteCount: some ExprSyntaxProtocol
) -> String {
  let condition = streamRemainingUTF8Condition(StreamUTF8Match(key), byteCount: byteCount) {
    ExprSyntax("\(raw: input).paddedWord(at: \(raw: $0))")
  }
  return "case \(streamUTF8WordLiteral(key, at: 0)) where \(condition)"
}

private func streamPaddedWord(in utf8: [UInt8], at start: Int) -> UInt64 {
  utf8.dropFirst(start).prefix(8).enumerated()
    .reduce(into: UInt64(0)) { word, element in
      word |= UInt64(element.element) << UInt64(element.offset * 8)
    }
}

private func streamWordLiteral(_ word: UInt64) -> String {
  "0x"
    + stride(from: 48, through: 0, by: -16)
    .map { shift in
      let digits = String((word >> shift) & 0xFFFF, radix: 16, uppercase: true)
      return String(repeating: "0", count: 4 - digits.count) + digits
    }
    .joined(separator: "_")
}

func streamRemainingUTF8Condition(
  _ match: StreamUTF8Match,
  matching bytes: some ExprSyntaxProtocol
) -> ExprSyntax {
  streamRemainingUTF8Condition(match, byteCount: ExprSyntax("(\(bytes)).count")) { offset in
    ExprSyntax("(\(bytes)).paddedWord(at: \(raw: offset))")
  }
}

package func streamUTF8WordLiteral(_ value: String, at offset: Int) -> IntegerLiteralExprSyntax {
  precondition(offset >= 0)
  return IntegerLiteralExprSyntax(
    literal: .integerLiteral(streamWordLiteral(streamPaddedWord(in: Array(value.utf8), at: offset)))
  )
}

package func streamRemainingUTF8Condition<Word: ExprSyntaxProtocol>(
  _ match: StreamUTF8Match,
  byteCount: some ExprSyntaxProtocol,
  wordAtOffset: (Int) throws -> Word
) rethrows -> ExprSyntax {
  var condition: ExprSyntax = "\(streamOperand(byteCount)) == \(raw: match.value.utf8.count)"
  for offset in stride(from: 8, to: match.value.utf8.count, by: 8) {
    let loaded = try wordAtOffset(offset)
    condition = "\(condition) && \(streamOperand(loaded)) == \(streamUTF8WordLiteral(match.value, at: offset))"
  }
  return condition
}

private func streamOperand(_ expression: some ExprSyntaxProtocol) -> ExprSyntax {
  let expression = ExprSyntax(expression)
  if expression.is(DeclReferenceExprSyntax.self) || expression.is(MemberAccessExprSyntax.self)
    || expression.is(FunctionCallExprSyntax.self) || expression.is(IntegerLiteralExprSyntax.self)
    || expression.is(SubscriptCallExprSyntax.self) || expression.is(TupleExprSyntax.self)
  {
    return expression
  }
  return "(\(expression))"
}
