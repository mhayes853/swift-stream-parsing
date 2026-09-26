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

public enum StreamParseableMemberMacro: NoOpPeerMacro {}
public enum StreamParseableIgnoredMacro: NoOpPeerMacro {}
public enum StreamParseableDefaultMacro: NoOpPeerMacro {}
