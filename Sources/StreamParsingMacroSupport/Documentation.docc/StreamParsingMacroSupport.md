# StreamParsingMacroSupport

Generate stream-compatible structs and enums from another macro using SwiftSyntax.

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
let declaration = try generation.structDeclarationSyntax(in: context)
```

The generator owns storage, initialization, observation metadata, schema routing, and the
view's lifetime handling. `StreamViewMode.packageDefault` follows the `LifetimeView` package
trait. Explicit `.lifetime` and `.unsafe` modes are also available. Coordinate generated names
through `StreamGeneratedNames`; `TokenSyntax.streamPartial` and `.streamView` provide the
conventional names. Use `StreamPartialMembers.streamInitialValue` to initialize required fields
with their stream initial values instead of making them optional. A field created without `keys`
matches only its own name, without backticks.

Set `StreamGenerationConfiguration.genericParameters` when the `Partial` is declared in a generic
context: the host type's parameters and those of every generic type enclosing it. Stored statics
are not allowed there, so the schema, which every `Partial` builds together with its field table
and child schemas, is served by the per-type schema cache rather than a `static let`. It omits `Sendable`
from the `Partial`, because the members' partials are not known to be `Sendable`. It also routes
a field whose type names a parameter from that field's schema when the table is built, because
the overloads that route concrete types resolve before the parameter is known. An extension of a
generic type exposes no parameters syntactically, so a type nested in one cannot be detected.

`generation.partialFields` describes the stored properties before syntax generation. Each
`StreamPartialFieldDescriptor` supplies the emitted member name, its unescaped name, its exact
storage type, and all decoded routing keys. The storage type reflects optional-member mode,
completed-value conversions, and container lowering. It is syntax, not a resolved Swift type.
Keys preserve their supplied order; the generator does not select a preferred output key when
aliases exist.

`TypeSyntax.streamParseable`, `.streamParseableObject`, and `.streamInitializable` spell the
library protocols that generated declarations conform to, fully qualified so a host's
conformance clauses do not depend on imports or local names.

`StreamPartialCustomization` adds declaration attributes, conformances, and members to the
generated `Partial` without rewriting its syntax. The existing `additionalMembers` builder is
still supported; its members and customization members are both appended after generated members.
Avoid repeating generated conformances or member names. The result is a `StructDeclSyntax` for
consumers that need other syntax changes, though rewriting generated implementation members makes
the consumer responsible for their continued compatibility.

The regular initializer validates the plan and throws `StreamObjectGenerationError`. Macros
that have already emitted their own diagnostics can use `StreamObjectGeneration(diagnosedFields:)`
to generate recovery syntax without repeating validation. Invalid input may still produce invalid
Swift. The built-in macro uses these same public APIs.

`TypeSyntaxProtocol.streamIsOptional` and `.streamUnwrappedOptionalType` inspect explicit optional
syntax on both concrete and type-erased nodes. They preserve optional container elements and do
not resolve type aliases.

## Convert between the whole type and its partial

```swift
let conversions = try generation.conversionsSyntax(
  unparsedMembers: [StreamUnparsedMember(name: .identifier("retries"), value: IntegerLiteralExprSyntax(3))],
  partialValueInlining: .never
)
let partial = try generation.structDeclarationSyntax(in: context)
let conformance = try ExtensionDeclSyntax("extension \(type.trimmed): \(TypeSyntax.streamParseable)") {
  partial
  conversions
}
```

`conversionsSyntax` generates the members that make the whole type `StreamParseable`:
`streamPartialValue`, `init?(streamPartial:)`, `init(orInitial:)`, `streamValueOrInitial(from:)`,
and an unlabelled `init(_:)`. The unlabelled initializer is the strict, failable conversion for
`.optional` partial members and the total one for `.streamInitialValue`. A partial type name
other than `Partial` also produces `typealias Partial`. Put the members in an extension of the
whole type: initializers declared in its body suppress the memberwise initializer.

Each field's `name` must be a stored property of the whole type with the field's `type`. The
strict initializer fails when a nonoptional member is absent; `init(orInitial:)` falls back to
each member's stream initial value, recursively. A converted field has no such value, so a
nonoptional one requires `StreamParseableField.defaultValue`. Validated plans throw
`missingCompletedConversionDefault` without it; `diagnosedFields:` plans fall back to `nil`.

`unparsedMembers` lists whole-type stored properties that are absent from the partial and have
no initializer. Every conversion initializer assigns their `value`, which defaults to `nil`. Do
not list a property that declares its own initializer. A name that repeats a field or another
unparsed member throws `duplicateField`.

`streamPartialValue` is the only generated member that reads the whole type's stored properties.
It follows `configuration.inlining` unless `partialValueInlining` overrides it. The plan does not
check that those properties are readable from an inlinable context, so a host whose properties
are less visible than the type passes `.never`. The delegating members always follow the
configuration, and the initializers that assign stored properties are never inlinable.

## Generate enums

```swift
let generation = try StreamEnumGeneration(
  cases: [
    StreamParseableEnumCase(name: .identifier("idle")),
    StreamParseableEnumCase(
      name: .identifier("charge"),
      associatedValues: [
        StreamParseableField(name: .identifier("total"), type: TypeSyntax("Int")),
        StreamParseableField(name: .wildcardToken(), type: TypeSyntax("String"))
      ]
    )
  ],
  representation: .caseKeyedObject,
  defaultCase: .identifier("idle")
)
let conformance = try ExtensionDeclSyntax("extension \(type.trimmed): \(TypeSyntax.streamParseable)") {
  try generation.partialSyntax(in: context)
  generation.conversionsSyntax()
}
```

`StreamEnumRepresentation` selects the wire form:

- `.stringRawValue` parses `"live"`. Each case's `keys` are its raw value and aliases. A partial
  string resolves to the shortest case it is a prefix of, so `live` may later become
  `livestream`; an empty partial resolves to nothing unless a case's key is `""`.
- `.numericRawValue(type)` parses `5` or `2.5`. The raw type is its own partial and conversion is
  `init(rawValue:)`; keys are ignored.
- `.caseKeyedObject` parses what `Codable` produces for an enum without a raw type:
  `{"charge":{"total":21,"_1":"card"}}`. Each case's `keys` are its object keys.

An associated value is a `StreamParseableField`, so it supports key aliases, `initialCapacity`,
and `completedConversion` like a struct field. A wildcard name (`_`) marks an unlabelled value,
which is named and keyed `_<position>` counting every associated value of the case, as `Codable`
does. Each case with associated values gets a namespace, `<Case>Payload` unless
`payloadTypeName` names it, holding the payload's `Partial` and a `Value` with one stored
property per associated value. These names appear in user code (`partial.charge` is
`ChargePayload.Partial?`), so treat them as API.

`partialSyntax` returns `typealias Partial` for raw values. For `.caseKeyedObject` it returns the
partial struct and the payload namespaces. The partial's view gains `ResolvedView` and
`resolved`, which borrow whichever single case has arrived, or report `.unresolved` or
`.ambiguous`. The member hooks and `onFieldRecognized` work as for structs, and
`fieldIdentifiers` supplies each case's identity. Raw-value partials are library types, so
non-empty hooks or partial customizations throw `hooksRequireObjectRepresentation`.

`StreamEnumGeneration.partialFields` describes the top-level object partial before generation;
it is `nil` for raw-value representations and empty for a case-keyed enum without cases.
`StreamEnumPayloadInfo.partialFields` describes each payload's generated partial, with positional
names such as `_1` resolved. Both use the same descriptor type as object generation, so a macro
can build top-level and payload customizations without generating and inspecting plain partials.

`partialCustomization` applies to the top-level generated `Partial`. For a case with associated
values, `payloadCustomization` receives `StreamEnumPayloadInfo` with the case name, payload type
name, and fields (including resolved positional names). Return `.generated(partial:)` to add
attributes, conformances, or members to that payload's `Partial`. Return `.replacement` with a
complete declaration to emit a custom payload namespace. A replacement must declare the expected
payload type name and expose nested `Partial` and `Value` types with the members used by the enum's
generated schema, view, and conversions. The callback runs once for each case with a payload; it
does not run for raw-value representations or cases without associated values.

`conversionsSyntax` returns `streamPartialValue`, `init?(_:)`, and `init?(streamPartial:)`. The
strict conversion requires exactly one case to be present and its payload to be complete. With a
`defaultCase` it also returns `init(orInitial:)` and `streamValueOrInitial(from:)`, which fall
back to that case, filling a default case's payload from its stream initial values. Without one,
the host adopts `TypeSyntax.streamInitializable` and supplies `streamInitialValue()`. An enum has
no memberwise initializer, so every member can go in the same extension.

`streamPartialValue` of `.caseKeyedObject` is not inlined unless `partialValueInlining` asks for
it: an inlinable `switch self` over a public enum that isn't `@frozen` does not compile under
library evolution. Everything else follows `configuration.inlining`.

Validation throws `StreamObjectGenerationError` for a key claimed by two cases and for invalid
associated values, including a converted one without a `defaultValue`. Names that cannot
compile, such as duplicate cases or payload types, are left to the compiler. Use
`StreamEnumGeneration(diagnosedCases:)` for recovery after emitting your own diagnostics.

## Add members and behavior

```swift
let declaration = try generation.structDeclarationSyntax(
  in: context,
  additionalMembers: {
    DeclSyntax("var lastRecognizedField: StreamParsingCore.StreamFieldID? = nil")
    DeclSyntax("static var nameField: StreamParsingCore.StreamFieldID { \(generation.fieldIdentifiers[0].identifier) }")
    DeclSyntax("mutating func resetTracking() { lastRecognizedField = nil }")
  },
  additionalViewMembers: {
    DeclSyntax("var marker: Int { 42 }")
  },
  onFieldRecognized: { partial, field in
    "\(partial).lastRecognizedField = \(field)"
  }
)
```

The member builders accept arbitrary valid struct members, including methods, initializers,
subscripts, nested types, conditional compilation, and already-built member lists. Additional
stored properties must have defaults compatible with the generated initializer and satisfy the
struct's `Sendable` conformance. View additions must respect the selected lifetime mode.
Do not duplicate generated members. Defaults are also used by the cached initial-value template;
custom state should have value semantics suitable for copying that template.

`generation.configuration.names` supplies the generated type names. `generation.fieldIdentifiers`
supplies named tuples containing each field's name and identifier syntax in declaration order.
Identifier expressions have runtime type `StreamFieldID`. Consumers can compare,
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
passed to the hook should be used instead of assuming parameter or storage names.

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
