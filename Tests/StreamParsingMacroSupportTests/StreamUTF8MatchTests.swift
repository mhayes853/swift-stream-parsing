import CustomDump
@testable import StreamParsingMacroSupport
import SwiftSyntax
import SwiftSyntaxBuilder
import Testing

@Suite
struct `Stream UTF8 match tests` {
  private struct BuilderError: Error {}

  @Test
  func `Match Generates Exact Word And Count Checks`() {
    let match = StreamUTF8Match("abcdefghijklmnopq")
    let bytes: ExprSyntax = "bytes"

    expectNoDifference(streamUTF8WordLiteral(match.value, at: 0).trimmedDescription, "0x6867_6665_6463_6261")
    expectNoDifference(
      match.condition(matching: bytes).trimmedDescription,
      "(bytes).count == 17 && (bytes).paddedWord(at: 8) == 0x706F_6E6D_6C6B_6A69 && (bytes).paddedWord(at: 16) == 0x0000_0000_0000_0071 && (bytes).paddedLeadingWord() == 0x6867_6665_6463_6261"
    )
  }

  @Test
  func `Custom Count And Word Expressions Compose Into A Where Clause`() {
    let match = StreamUTF8Match("abcdefghijklmnopq")
    var offsets = [Int]()
    let condition = streamRemainingUTF8Condition(match,
      byteCount: DeclReferenceExprSyntax(baseName: .identifier("streamCount"))
    ) { offset in
      offsets.append(offset)
      return FunctionCallExprSyntax(
        callee: DeclReferenceExprSyntax(baseName: .identifier("loadWord"))
      ) {
        LabeledExprSyntax(expression: IntegerLiteralExprSyntax(offset))
      }
    }
    let clause = WhereClauseSyntax(
      whereKeyword: .keyword(.where, trailingTrivia: .space),
      condition: condition
    )
    expectNoDifference(offsets, [8, 16])
    expectNoDifference(streamUTF8WordLiteral(match.value, at: 16).trimmedDescription, "0x0000_0000_0000_0071")
    expectNoDifference(
      clause.trimmedDescription,
      "where streamCount == 17 && loadWord(8) == 0x706F_6E6D_6C6B_6A69 && loadWord(16) == 0x0000_0000_0000_0071"
    )
  }

  @Test
  func `Custom Match Expressions Preserve Operator Precedence`() {
    let condition = streamRemainingUTF8Condition(StreamUTF8Match("abcdefghi"),
        byteCount: ExprSyntax("cachedCount ?? fallbackCount")
      ) { _ in
        ExprSyntax("word & mask")
      }
    expectNoDifference(
      condition.trimmedDescription,
      "(cachedCount ?? fallbackCount) == 9 && (word & mask) == 0x0000_0000_0000_0069"
    )
  }

  @Test
  func `Custom Word Builder Propagates Errors`() {
    #expect(throws: BuilderError.self) {
      try streamRemainingUTF8Condition(StreamUTF8Match("abcdefghi"),byteCount: ExprSyntax("count")) {
          _ throws -> ExprSyntax in throw BuilderError()
        }
    }
  }

  @Test
  func `Match Distinguishes Empty And NUL Values By Count`() {
    let bytes: ExprSyntax = "bytes"

    expectNoDifference(
      StreamUTF8Match("").condition(matching: bytes).trimmedDescription,
      "(bytes).count == 0"
    )
    expectNoDifference(
      StreamUTF8Match("\0").condition(matching: bytes).trimmedDescription,
      "(bytes).count == 1 && (bytes).paddedLeadingWord() == 0x0000_0000_0000_0000"
    )
  }

  @Test
  func `Match Uses UTF8 Bytes For Unicode`() {
    let bytes: ExprSyntax = "bytes"
    let condition = StreamUTF8Match("é😀").condition(matching: bytes).trimmedDescription

    expectNoDifference(
      condition,
      "(bytes).count == 6 && (bytes).paddedLeadingWord() == 0x0000_8098_9FF0_A9C3"
    )
  }

  @Test
  func `Match Hashing Preserves Canonically Distinct Encodings`() {
    let composed = StreamUTF8Match("é")
    let decomposed = StreamUTF8Match("e\u{301}")

    expectNoDifference(composed == decomposed, false)
    expectNoDifference(Set([composed, decomposed]).count, 2)
  }

  @Test
  func `Empty Match Set Is False`() {
    let bytes: ExprSyntax = "bytes"

    expectNoDifference(
      StreamUTF8MatchSet([String]()).condition(matching: bytes).trimmedDescription,
      "false"
    )
  }

  @Test
  func `Match Set Composes Complete Predicates`() {
    let bytes: ExprSyntax = "bytes"
    let condition = StreamUTF8MatchSet(["", "\0", "abcdefghijk"])
      .condition(matching: bytes)
      .trimmedDescription

    expectNoDifference(condition.components(separatedBy: "paddedLeadingWord").count - 1, 2)
    expectNoDifference(condition.contains("(bytes).count == 0"), true)
    expectNoDifference(condition.contains("(bytes).count == 1"), true)
    expectNoDifference(condition.contains("paddedWord(at: 8)"), true)
  }

}
