import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct StreamParsingMacrosPlugin: CompilerPlugin {
  let providingMacros: [any Macro.Type] = [
    StreamParseableMacro.self,
    StreamParseableMemberMacro.self,
    StreamParseableIgnoredMacro.self,
    StreamParseableDefaultMacro.self
  ]
}
