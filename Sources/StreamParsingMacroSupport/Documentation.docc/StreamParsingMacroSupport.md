# ``StreamParsingMacroSupport``

Generate stream parsing declarations from another macro's own model.

## Overview

Add the `StreamParsingMacroSupport` product to the dependencies of your `.macro` target.
The support library runs in the macro implementation; the generated client declarations
require `import StreamParsing`. The support library itself does not depend on the runtime.

Inputs accept SwiftSyntax protocols where possible, so callers can pass concrete type and
expression nodes. Outputs use concrete declaration nodes or syntax lists that compose with
SwiftSyntaxBuilder. No source declaration is required to describe a field.

```swift
import StreamParsingMacroSupport
import SwiftSyntax
import SwiftSyntaxBuilder

let field = StreamParseableField(
  name: TokenSyntax.identifier("name"),
  type: IdentifierTypeSyntax(name: TokenSyntax.identifier("String")),
  keys: ["name", "display_name"]
)
let generation = try StreamObjectGeneration(fields: [field])
let partial = generation.partialDeclaration()
```

The generated `Partial` is independently parseable. Generating this declaration alone does
not synthesize conversions or a `StreamParseable` conformance for the enclosing source type.
Those policies remain with the consuming macro in this first version.

## Compose declarations

Complete generation uses the same components exposed individually:

```swift
let partial = try StructDeclSyntax(
  "struct Partial: StreamParsingCore.StreamParseable, StreamParsingCore.StreamParseableObject, Sendable"
) {
  DeclSyntax("typealias Partial = Self")
  generation.storageMembers()
  generation.initializer()
  generation.initialValueMembers()
  generation.observationMembers()
  generation.schemaMembers()
  generation.viewDeclaration {
    DeclSyntax("var marker: Int { 42 }")
  }
  generation.streamViewFunction()
}
```

For finer schema customization, use `fieldIdentifiers()`, `containerSchemaMembers()`,
`matchFieldFunction()`, `applyFunction(for:)`, `fieldTableProperty()`, and `schemaProperty()`.
They share the generator's field ordering and storage interpretation. Keep those components
together when changing names or storage types: the field table addresses the exact stored
representation described by the generator.

Return values can be edited through ordinary SwiftSyntax APIs before insertion. Builder
closures execute during generation and their declarations become syntax nodes, not runtime
callbacks.

## Lifetime mode

`StreamViewMode.packageDefault` resolves to `.lifetime` when this package's `LifetimeView`
trait is enabled, and `.unsafe` otherwise. The lifetime mode generates noncopyable,
nonescapable views and lifetime annotations. Unsafe mode generates noncopyable unsafe pointer
views without compiler-enforced lifetime constraints.

Use the default in ordinary macro expansion so views agree with the runtime. Explicit modes
are useful for expansion tests:

```swift
let configuration = StreamGenerationConfiguration(viewMode: .lifetime)
let generation = try StreamObjectGeneration(
  fields: fields,
  configuration: configuration
)
```

Selecting a mode does not enable package traits or compiler features. A downstream package
that exposes its own `LifetimeView` trait must forward it to its `swift-stream-parsing`
dependency; its generated-code target must also enable the needed compiler features.
`SmokeTests/MacroSupport` provides an executable example of that setup.

## UTF-8 predicates and matching

`StreamUTF8Match` produces an exact byte predicate. `leadingWord` and
`remainingCondition(matching:)` expose the components used by optimized dispatch.
`StreamUTF8MatchSet` combines several spellings into one predicate; an empty set is false.
These predicates can reference the input expression repeatedly, so provide a stable expression.

For a different storage representation or a cached byte count, supply the expressions that
read the count and each trailing word. The same predicate works in a switch `where` clause
or an `if` condition:

```swift
let match = StreamUTF8Match("awaiting_moderation")
let condition = match.remainingCondition(
  byteCount: DeclReferenceExprSyntax(baseName: .identifier("streamCount"))
) { offset in
  ExprSyntax("partial.paddedWord(at: \(raw: offset))")
}
let clause = WhereClauseSyntax(
  whereKeyword: .keyword(.where, trailingTrivia: .space),
  condition: condition
)
```

The surrounding switch must already match `match.leadingWord`. The remaining predicate
checks the byte count before reading words at offsets 8, 16, and so on, distinguishing NUL
bytes from padding. The closure runs while generating syntax and accepts concrete expression
nodes. `match.word(at:)` exposes individual padded word literals for custom control flow.

For complete control flow, use `StreamUTF8Matcher`:

```swift
let matcher = try StreamUTF8Matcher(
  branches: [
    StreamUTF8Branch(matching: ["customer_name", "name"]) {
      ReturnStmtSyntax(expression: nameFieldID)
    },
    StreamUTF8Branch(matching: ["customer_id"]) {
      ReturnStmtSyntax(expression: idFieldID)
    }
  ]
)
let body = matcher.statements(
  matching: bytesExpression,
  strategy: .switchTree,
  in: context
) {
  ReturnStmtSyntax(expression: unknownFieldID)
}
```

The matcher binds its input once, using the expansion context for a unique temporary name.
Both `.switchTree` and `.ifElseTree` return `CodeBlockItemListSyntax`. A body can return,
throw, or continue into the statements following the generated matcher. A successful branch
never executes the fallback.

Matching compares UTF-8 bytes, including byte length and all words after the leading word.
Different encoded spellings remain distinct even when Swift strings compare as canonically
equivalent. Conflicting byte-identical keys in different branches are rejected at construction.
The generated expressions expect `count`, `paddedLeadingWord()`, and `paddedWord(at:)`, as
provided by `Span<UInt8>` with `StreamParsingCore` in scope.

## Inspect optional types

`TypeSyntaxProtocol.streamUnwrappedOptionalType` removes explicit optional layers written as
`T?`, `Optional<T>`, or `Swift.Optional<T>`. `streamIsOptional` checks whether any such layer
exists. These utilities accept concrete type nodes and preserve optionality inside containers;
they inspect syntax and do not resolve type aliases.
