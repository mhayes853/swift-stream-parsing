import CustomDump
import StreamParsingMacroSupport
import SwiftParser
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacroExpansion
import Testing

@Suite
struct `Stream UTF8 match tests` {
  private struct BuilderError: Error {}

  @Test
  func `Match Generates Exact Word And Count Checks`() {
    let match = StreamUTF8Match("abcdefghijklmnopq")
    let bytes: ExprSyntax = "bytes"

    expectNoDifference(match.leadingWord.trimmedDescription, "0x6867_6665_6463_6261")
    expectNoDifference(
      match.condition(matching: bytes).trimmedDescription,
      "(bytes).count == 17 && (bytes).paddedWord(at: 8) == 0x706F_6E6D_6C6B_6A69 && (bytes).paddedWord(at: 16) == 0x0000_0000_0000_0071 && (bytes).paddedLeadingWord() == 0x6867_6665_6463_6261"
    )
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

  @Test
  func `Matcher Rejects Byte Identical Values In Different Branches`() {
    #expect(throws: StreamUTF8MatcherError.duplicateValue(Array("name".utf8))) {
      try StreamUTF8Matcher(
        branches: [
          StreamUTF8Branch(matching: ["name"]) {
            ReturnStmtSyntax(expression: ExprSyntax("1"))
          },
          StreamUTF8Branch(matching: ["name"]) {
            ReturnStmtSyntax(expression: ExprSyntax("2"))
          }
        ]
      )
    }
  }

  @Test
  func `Matcher Treats Canonically Equivalent Encodings As Distinct`() throws {
    _ = try StreamUTF8Matcher(
      branches: [
        StreamUTF8Branch(matching: ["é"]) {
          ReturnStmtSyntax(expression: ExprSyntax("1"))
        },
        StreamUTF8Branch(matching: ["e\u{301}"]) {
          ReturnStmtSyntax(expression: ExprSyntax("2"))
        }
      ]
    )
  }

  @Test
  func `Aliases In One Branch Are Accepted`() throws {
    _ = try StreamUTF8Matcher(
      branches: [
        StreamUTF8Branch(matching: ["name", "name"]) {
          ReturnStmtSyntax(expression: ExprSyntax("1"))
        }
      ]
    )
  }

  @Test
  func `Branch Propagates Builder Errors`() {
    func body() throws -> CodeBlockItemListSyntax {
      throw BuilderError()
    }

    #expect(throws: BuilderError.self) {
      try StreamUTF8Branch(matching: ["name"]) {
        try body()
      }
    }
  }

  @Test
  func `Matcher Propagates Fallback Builder Errors`() throws {
    func fallback() throws -> CodeBlockItemListSyntax {
      throw BuilderError()
    }

    let matcher = try StreamUTF8Matcher(
      branches: [StreamUTF8Branch(matching: ["name"]) {}]
    )
    let bytes: ExprSyntax = "bytes"
    #expect(throws: BuilderError.self) {
      try matcher.statements(
        matching: bytes,
        strategy: .switchTree,
        in: BasicMacroExpansionContext()
      ) {
        try fallback()
      }
    }
  }

  @Test(arguments: [StreamUTF8Matcher.Strategy.switchTree, .ifElseTree])
  func `Empty Bodies And Fallbacks Produce Valid Syntax`(
    strategy: StreamUTF8Matcher.Strategy
  ) throws {
    let matcher = try StreamUTF8Matcher(
      branches: [StreamUTF8Branch(matching: ["", "\0", "abcdefghijk"]) {}]
    )
    let bytes: ExprSyntax = "bytes"
    let statements = matcher.statements(
      matching: bytes,
      strategy: strategy,
      in: BasicMacroExpansionContext()
    ) {}

    expectNoDifference(Syntax(statements).hasError, false)
    expectNoDifference(Parser.parse(source: statements.description).hasError, false)
    if strategy == .switchTree {
      expectNoDifference(statements.description.contains("default:\n  break"), true)
    }
  }

  @Test(arguments: [StreamUTF8Matcher.Strategy.switchTree, .ifElseTree])
  func `Matcher Evaluates Input Once And Keeps Bodies Scoped`(
    strategy: StreamUTF8Matcher.Strategy
  ) throws {
    let matcher = try StreamUTF8Matcher(
      branches: [
        StreamUTF8Branch(matching: ["customer_name", "name"]) {
          "let selected = 1"
          ReturnStmtSyntax(expression: ExprSyntax("selected"))
        },
        StreamUTF8Branch(matching: ["customer_id"]) {
          ReturnStmtSyntax(expression: ExprSyntax("2"))
        }
      ]
    )
    let context = BasicMacroExpansionContext(expansionDiscriminator: "test_")
    let input: ExprSyntax = "makeBytes()"
    let statements = matcher.statements(matching: input, strategy: strategy, in: context) {
      ReturnStmtSyntax(expression: ExprSyntax("-1"))
    }
    let source = statements.description

    expectNoDifference(source.components(separatedBy: "makeBytes()").count - 1, 1)
    expectNoDifference(source.contains("let test_15streamUTF8BytesfMu_ = makeBytes()"), true)
    expectNoDifference(source.contains("let selected = 1"), true)
    expectNoDifference(source.contains("return selected"), true)
    expectNoDifference(Syntax(statements).hasError, false)
    expectNoDifference(Parser.parse(source: statements.description).hasError, false)
  }

  @Test
  func `Switch Tree Groups Leading Word Collisions`() throws {
    let matcher = try StreamUTF8Matcher(
      branches: [
        StreamUTF8Branch(matching: ["customer_name"]) {
          ReturnStmtSyntax(expression: ExprSyntax("1"))
        },
        StreamUTF8Branch(matching: ["customer_id"]) {
          ReturnStmtSyntax(expression: ExprSyntax("2"))
        }
      ]
    )
    let context = BasicMacroExpansionContext()
    let bytes: ExprSyntax = "bytes"
    let source =
      matcher.statements(
        matching: bytes,
        strategy: StreamUTF8Matcher.Strategy.switchTree,
        in: context
      ) {
        ReturnStmtSyntax(expression: ExprSyntax("-1"))
      }
      .description

    expectNoDifference(source.components(separatedBy: "case 0x7265_6D6F_7473_7563").count - 1, 1)
    expectNoDifference(source.contains("paddedWord(at: 8)"), true)
    expectNoDifference(source.components(separatedBy: "return -1").count - 1, 2)
  }

  @Test(arguments: [StreamUTF8Matcher.Strategy.switchTree, .ifElseTree])
  func `Empty Matcher Evaluates Input Then Falls Back`(
    strategy: StreamUTF8Matcher.Strategy
  ) throws {
    let matcher = try StreamUTF8Matcher(branches: [StreamUTF8Branch]())
    let context = BasicMacroExpansionContext()
    let input: ExprSyntax = "makeBytes()"
    let source =
      matcher.statements(matching: input, strategy: strategy, in: context) {
        "fallback()"
      }
      .description

    expectNoDifference(source.components(separatedBy: "makeBytes()").count - 1, 1)
    expectNoDifference(source.components(separatedBy: "fallback()").count - 1, 1)
    expectNoDifference(
      Syntax(
        matcher.statements(
          matching: input,
          strategy: strategy,
          in: BasicMacroExpansionContext()
        ) { "fallback()" }
      )
      .hasError,
      false
    )
    expectNoDifference(Parser.parse(source: source).hasError, false)
  }
}
