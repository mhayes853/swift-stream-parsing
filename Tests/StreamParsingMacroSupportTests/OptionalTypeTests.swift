import CustomDump
import StreamParsingMacroSupport
import SwiftSyntax
import SwiftSyntaxBuilder
import Testing

@Suite
struct `Optional Type Syntax tests` {
  // One layer, the one a partial member flattens; what remains is spelled so `.Partial` can
  // follow it.
  @Test(arguments: [
    ("Int?", "Int"), ("Optional<Int>", "Int"), ("Int??", "Optional<Int>"),
    ("Swift.Optional<Int?>", "Optional<Int>"), ("Optional<Optional<Int>>", "Optional<Int>"),
    ("Int???", "Optional<Int?>"),
  ])
  func `Unwraps One Explicit Optional Layer`(source: String, unwrapped: String) {
    let type = TypeSyntax(stringLiteral: source)
    expectNoDifference(type.streamIsOptional, true)
    expectNoDifference(type.streamUnwrappedOptionalType.trimmedDescription, unwrapped)
  }

  @Test
  func `Concrete Nodes Preserve Nested Container Optionality`() {
    let type = ArrayTypeSyntax(element: TypeSyntax("Int?"))
    expectNoDifference(type.streamIsOptional, false)
    expectNoDifference(type.streamUnwrappedOptionalType.trimmedDescription, "[Int?]")
  }
}
