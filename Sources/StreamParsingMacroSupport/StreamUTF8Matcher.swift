import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// A body associated with one or more byte-exact UTF-8 spellings.
public struct StreamUTF8Branch: Hashable, Sendable {
  /// The strings that select this branch.
  public let values: [String]

  /// The statements emitted when a value matches.
  public let body: CodeBlockItemListSyntax

  /// Creates a branch and eagerly builds its body.
  public init(
    matching values: some Sequence<String>,
    @CodeBlockItemListBuilder body: () throws -> CodeBlockItemListSyntax
  ) rethrows {
    self.values = Array(values)
    self.body = try body()
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.values.map { Array($0.utf8) } == rhs.values.map { Array($0.utf8) }
      && lhs.body == rhs.body
  }

  public func hash(into hasher: inout Hasher) {
    self.values.forEach { hasher.combine(Array($0.utf8)) }
    hasher.combine(self.body)
  }
}

/// An error found while constructing a ``StreamUTF8Matcher``.
public enum StreamUTF8MatcherError: Error, Hashable, Sendable {
  /// Two branches contain the same exact UTF-8 byte sequence.
  case duplicateValue([UInt8])
}

/// Generates byte-exact dispatch over a collection of UTF-8 branches.
public struct StreamUTF8Matcher: Hashable, Sendable {
  /// The shape of the generated control flow.
  public enum Strategy: Hashable, Sendable {
    /// Groups candidates by their leading padded word and emits a switch.
    case switchTree

    /// Emits branches as a nested `if`/`else` tree.
    case ifElseTree
  }

  /// The branches, in matching order.
  public let branches: [StreamUTF8Branch]

  /// Creates a matcher, rejecting byte-identical values in different branches.
  ///
  /// Validation compares UTF-8 bytes directly. Canonically equivalent Swift
  /// strings remain distinct when their encoded bytes differ.
  public init(branches: some Sequence<StreamUTF8Branch>) throws {
    let branches = Array(branches)
    var seen = [[UInt8]: Int]()
    for (branchIndex, branch) in branches.enumerated() {
      for value in branch.values {
        let utf8 = Array(value.utf8)
        guard seen[utf8].map({ $0 == branchIndex }) ?? true else {
          throw StreamUTF8MatcherError.duplicateValue(utf8)
        }
        seen[utf8] = branchIndex
      }
    }
    self.branches = branches
  }

  /// Generates dispatch statements that evaluate the input expression once.
  ///
  /// Exactly one matching body is entered. If no value matches, `otherwise`
  /// is entered. Empty branches never match, and an empty matcher emits only
  /// the input binding and fallback body.
  public func statements(
    matching bytes: some ExprSyntaxProtocol,
    strategy: Strategy,
    in context: some MacroExpansionContext,
    @CodeBlockItemListBuilder otherwise: () throws -> CodeBlockItemListSyntax
  ) rethrows -> CodeBlockItemListSyntax {
    let fallback = try otherwise()
    let name = context.makeUniqueName("streamUTF8Bytes")
    let reference = DeclReferenceExprSyntax(baseName: name)
    guard self.branches.contains(where: { !$0.values.isEmpty }) else {
      return """
        let \(name) = \(bytes)
        \(fallback)
        """
    }
    let dispatch =
      switch strategy {
      case .switchTree: self.switchTree(matching: reference, otherwise: fallback)
      case .ifElseTree: self.ifElseTree(matching: reference, otherwise: fallback)
      }
    return """
      let \(name) = \(bytes)
      \(dispatch)
      """
  }

  private struct Candidate: Hashable, Sendable {
    let value: String
    let branch: Int
  }

  private func candidates() -> [Candidate] {
    self.branches.enumerated()
      .flatMap { index, branch in
        branch.values.map { Candidate(value: $0, branch: index) }
      }
  }

  private func ifElseTree(
    matching bytes: some ExprSyntaxProtocol,
    otherwise fallback: CodeBlockItemListSyntax
  ) -> CodeBlockItemListSyntax {
    let populated = self.branches.filter { !$0.values.isEmpty }
    return populated.reversed()
      .reduce(fallback) { remainder, entry in
        let condition = StreamUTF8MatchSet(entry.values).condition(matching: bytes)
        return """
          if \(condition) {
            \(entry.body)
          } else {
            \(remainder)
          }
          """
      }
  }

  private func switchTree(
    matching bytes: some ExprSyntaxProtocol,
    otherwise fallback: CodeBlockItemListSyntax
  ) -> CodeBlockItemListSyntax {
    let candidates = self.candidates()
    let groups = Dictionary(grouping: candidates.filter { !$0.value.isEmpty }) {
      StreamUTF8Match.paddedWord(in: Array($0.value.utf8), at: 0)
    }
    let switchCases = groups.keys.sorted()
      .map { word -> SwitchCaseSyntax in
        let literal = IntegerLiteralExprSyntax(
          literal: .integerLiteral(StreamUTF8Match.wordLiteral(word))
        )
        let statements = self.leadingGroupTree(
          groups[word]!,
          matching: bytes,
          otherwise: fallback
        )
        return """
          case \(literal):
            \(statements)
          """
      }
    let defaultStatements: CodeBlockItemListSyntax =
      if fallback.isEmpty {
        CodeBlockItemListSyntax { BreakStmtSyntax() }
      } else {
        fallback
      }
    let defaultCase: SwitchCaseSyntax = """
      default:
        \(defaultStatements)
      """
    let subject: ExprSyntax = "\(bytes).paddedLeadingWord()"
    let switchExpression = SwitchExprSyntax(
      switchKeyword: .keyword(.switch, trailingTrivia: .space),
      subject: subject
    ) {
      for switchCase in switchCases {
        switchCase
      }
      defaultCase
    }
    return CodeBlockItemListSyntax {
      IfExprSyntax(
        ifKeyword: .keyword(.if, trailingTrivia: .space),
        conditions: ConditionElementListSyntax {
          ConditionElementSyntax(
            condition: .expression("\(bytes).count == 0")
          )
        },
        body: CodeBlockSyntax {
          if let empty = candidates.first(where: { $0.value.isEmpty }) {
            self.branches[empty.branch].body
          } else {
            fallback
          }
        },
        elseKeyword: .keyword(.else, leadingTrivia: .space, trailingTrivia: .space),
        elseBody: .codeBlock(
          CodeBlockSyntax {
            switchExpression
          }
        )
      )
    }
  }

  private func leadingGroupTree(
    _ candidates: [Candidate],
    matching bytes: some ExprSyntaxProtocol,
    otherwise fallback: CodeBlockItemListSyntax
  ) -> CodeBlockItemListSyntax {
    let groups = Dictionary(grouping: candidates, by: \.branch)
    return groups.keys.sorted().reversed()
      .reduce(fallback) { remainder, branchIndex in
        let values = groups[branchIndex]!.map(\.value)
        let condition = StreamUTF8MatchSet(values)
          .condition(
            matching: bytes,
            afterLeadingWordMatch: true
          )
        return """
          if \(condition) {
            \(self.branches[branchIndex].body)
          } else {
            \(remainder)
          }
          """
      }
  }

}
