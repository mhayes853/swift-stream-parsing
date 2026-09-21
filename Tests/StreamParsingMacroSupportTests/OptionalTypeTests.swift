import CustomDump
import StreamParsingMacroSupport
import SwiftSyntax
import SwiftSyntaxBuilder
import Testing

@Suite
struct `Optional Type Syntax tests` {
  @Test(arguments: ["Int?", "Int??", "Optional<Int>", "Swift.Optional<Int?>"])
  func `Unwraps Every Explicit Optional Layer`(source: String) {
    let type = TypeSyntax(stringLiteral: source)
    expectNoDifference(streamIsOptional(type), true)
    expectNoDifference(streamUnwrappedOptionalType(type).trimmedDescription, "Int")
  }

  @Test
  func `Concrete Nodes Preserve Nested Container Optionality`() {
    let type = ArrayTypeSyntax(element: TypeSyntax("Int?"))
    expectNoDifference(streamIsOptional(type), false)
    expectNoDifference(streamUnwrappedOptionalType(type).trimmedDescription, "[Int?]")
  }
}
