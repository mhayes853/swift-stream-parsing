# StreamParsingMacroSupport

Generate a complete stream-compatible struct from another macro using SwiftSyntax.

Add the `StreamParsingMacroSupport` product to the macro target. The source receiving the
expansion must import `StreamParsing`, which reexports `StreamParsingCore`.

## Describe the fields and generate the struct

```swift
let generation = try StreamObjectGeneration(
  fields: [
    StreamParseableField(
      name: .identifier("name"),
      type: IdentifierTypeSyntax(name: .identifier("String")),
      keys: ["name", "display_name"]
    )
  ],
  configuration: StreamGenerationConfiguration(
    viewMode: .packageDefault,
    accessLevel: .public
  )
)
let declaration = try generation.structDeclaration(in: context)
```

The generator owns storage, initialization, observation metadata, schema routing, and the
view's lifetime handling. `StreamViewMode.packageDefault` follows the `LifetimeView` package
trait. Explicit `.lifetime` and `.unsafe` modes are also available. Coordinate generated names
through `StreamGeneratedNames`; `TokenSyntax.streamPartial` and `.streamView` provide the
conventional names. Use `StreamPartialMembers.streamInitialValue` to initialize required fields
with their stream initial values instead of making them optional.

The result is a `StructDeclSyntax`, so a consumer can modify declaration attributes, generic
constraints, inheritance, or members through normal SwiftSyntax operations. Rewriting generated
implementation members makes the consumer responsible for their continued compatibility.

## Add members and behavior

```swift
let declaration = try generation.structDeclaration(
  in: context,
  additionalMembers: { references in
    DeclSyntax("var lastRecognizedField: StreamParsingCore.StreamFieldID? = nil")
    DeclSyntax("static var nameField: StreamParsingCore.StreamFieldID { \(references.fields[0].identifier) }")
    DeclSyntax("mutating func resetTracking() { lastRecognizedField = nil }")
  },
  additionalViewMembers: { _ in
    DeclSyntax("var marker: Int { 42 }")
  },
  onFieldRecognized: { event in
    "\(event.partial).lastRecognizedField = \(event.field)"
  }
)
```

The member builders accept arbitrary valid struct members, including methods, initializers,
subscripts, nested types, conditional compilation, and already-built member lists. Additional
stored properties must have defaults compatible with the generated initializer and satisfy the
struct's `Sendable` conformance. View additions must respect the selected lifetime mode.
Do not duplicate generated members. Defaults are also used by the cached initial-value template;
custom state should have value semantics suitable for copying that template.

Customization contexts supply the generated types and field references. Identifier expressions
are valid at their insertion point and have runtime type `StreamFieldID`. Consumers can compare,
store, hash, and switch on these schema-local identities. Aliases share an identifier. Identifiers
are not table positions or array indices and must not be persisted across schema revisions or
compared across unrelated schemas. The underscored numeric bridge used in expansions is
implementation support; consumers should interpolate the supplied identifier syntax.

`onFieldRecognized` runs once for each declared key on this partial, before its value is applied.
Repeated keys trigger repeated calls; aliases report the same identity; unknown keys do not
trigger the hook. Recognition does not imply that parsing or application will succeed. Table
routing and matcher routing use the same contract, including optional wrappers and nested
containers. Empty hook bodies install no runtime handler. The hook's statements run inside a
mutating helper, so returning exits that helper rather than cancelling parsing. Expressions
supplied by the event context should be used instead of assuming parameter or storage names.

## Compose complete UTF-8 predicates

For custom control flow, `StreamUTF8Match` and `StreamUTF8MatchSet` generate complete byte-exact
predicates accepting general `ExprSyntaxProtocol` nodes:

```swift
let condition = StreamUTF8MatchSet(["name", "display_name"]).condition(
  matching: DeclReferenceExprSyntax(baseName: .identifier("bytes"))
)
let clause = WhereClauseSyntax(condition: condition)
```

Inputs must provide `count`, `paddedLeadingWord()`, and `paddedWord(at:)`, such as `Span<UInt8>`.
The expression may be evaluated more than once; bind side-effecting input to a local first.
Canonical Unicode equivalents remain distinct when their UTF-8 bytes differ. Word extraction,
partial guards, dispatch strategies, and branch handlers are implementation details. Consumers
extending generated structs use field identities and the recognition hook instead.
