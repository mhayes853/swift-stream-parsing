import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// The member-annotating attributes exist only so `@StreamParseable` can read them off the
/// declaration they are attached to; none of them generates anything of its own.
public protocol NoOpPeerMacro: PeerMacro {}

extension NoOpPeerMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    []
  }
}

/// Reads like a no-op, but every argument of `@StreamParseableMember` is optional so that one
/// declaration can spell any combination of them, which leaves `@StreamParseableMember` alone
/// legal to the compiler. An attribute that writes nothing is a mistake, and is diagnosed here.
public enum StreamParseableMemberMacro: PeerMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    // An explicit `nil` counts as unwritten, as it does when the arguments are read.
    let arguments = node.arguments?.as(LabeledExprListSyntax.self) ?? []
    if arguments.allSatisfy({ $0.expression.is(NilLiteralExprSyntax.self) }) {
      context.diagnose(
        Diagnostic(
          node: node,
          message: MacroExpansionErrorMessage(
            """
            @StreamParseableMember needs an argument: key:, keyNames:, initialCapacity:, \
            partialStrings: or completedConversion:.
            """
          )
        )
      )
    }
    return []
  }
}

public enum StreamParseableIgnoredMacro: NoOpPeerMacro {}
public enum StreamParseableDefaultMacro: NoOpPeerMacro {}
