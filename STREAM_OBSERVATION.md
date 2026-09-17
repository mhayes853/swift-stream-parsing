# Synchronous observation

`Sequence.partialIterator(of:from:)` is a lazy, throwing, noncopyable iterator. It
accepts bytes or sequences of byte chunks; the `initialValue:from:` overload supports
an existing partial state. Unlike the eager `partials` API, it does not accumulate snapshots.

```swift
var updates = chunks.partialIterator(of: Response.self, from: .json())
while let update = try updates.next() {
  render(update.value)
  if update.isComplete { showFinished() }
}
```

Each request consumes one byte/chunk, including empty chunks, and returns an owned
snapshot. EOF validates the document and emits one extra update with `isComplete == true`,
even if the value is identical. There is no initial emission. Errors terminate the
iterator: further requests return nil and consume no input. It deliberately does not
conform to `IteratorProtocol`, whose `next()` cannot throw. Its noncopyable ownership
prevents accidentally duplicating the cursor and parser.

For synchronous rendering without whole-tree snapshots:

```swift
try chunks.withPartialViews(of: Response.self, from: .json()) { view, isComplete in
  render(view.title)
  if isComplete { showFinished() }
}
```

The callback runs after each input element and successful EOF validation. Views cannot
escape it, but selected members can be copied. Parser and callback errors propagate and
stop consumption immediately. `PartialsStream.finishWithView` provides the same snapshot-free
EOF operation to manual drivers. A throwing final callback still leaves that stream finished.
EOF completion means the JSON document was validated, not that every model field is present.

# Selective observation

Both synchronous iterators and `AsyncPartialsSequence` support a borrowed-view
projection. Select the field before a whole-root snapshot is taken:

```swift
var titles = chunks.partialIterator(of: Response.self, from: .json())
  .project { $0.title?.value }
  .removeDuplicateUpdates()
while let update = try titles.next() {
  render(update.value)
  if update.isComplete { showFinished() }
}

for try await update in asyncChunks.partials(of: Response.self, from: .json())
  .project({ $0.title?.value })
  .removeDuplicateUpdates() {
  render(update.value)
}
```

`project` takes a closure because the model's view and its members are borrowed,
noncopyable values. The closure returns an owned value, which may be a copied field
or a computed summary. It is called once per input element and once after validated
EOF. It can throw; a projection error terminates the iterator just like a parse error.
Async projections and comparison closures must be `@Sendable`. The default async
equality overload also requires a `SendableMetatype` conformance, so its equality
witness can be used across isolation boundaries.

`removeDuplicateUpdates()` compares `Equatable` outputs; the `by:` overload accepts a
custom equivalence predicate. It stores only the last emitted update, preserves the
first update (including a nil value), and always emits document completion. One
request may consume many input chunks while seeking a change, so EOF validation and
upstream errors still occur when all intermediate values compare equal. Filtering
still computes each projection; it reduces emissions, not parsing work.

Both APIs also support filtering whole snapshots without `project`. The async
`updates()` adapter exposes `PartialUpdate` without filtering; the existing async
`partials` continues to emit plain values. Async adapters share the original
single-subscriber contract, and iterator copies share position and filtering state.
Do not call `next()` concurrently on copies of an async iterator.

Value projection preserves exactly the selected type's representation. It does not
flatten optional values, but current macro-generated partials represent both an absent
member and a null member as nil. Use field observation when those distinctions matter.

# Field observation

```swift
var titles = try chunks.partialIterator(of: Response.self, from: .json())
  .observeField(\.title)
  .removeDuplicateUpdates()
while let update = try titles.next() {
  switch update.value {
  case .missing: showPlaceholder()
  case .null: clearTitle()
  case .incomplete(let text): renderDraft(text)
  case .complete(let text): renderTitle(text)
  }
  if update.isComplete { showDocumentFinished() }
}
```

`ObservedField<Value>` distinguishes four states of a selected field:

- `missing`: no value token for the field has started in this document. A key or colon
  alone does not change that state. Seeded initial values do not invent input presence.
- `null`: a complete JSON null token was accepted by the typed destination.
- `incomplete(Value?)`: a value has started. Strings and containers expose their current
  partial; an unfinished number or literal has no representable value yet and exposes nil,
  even when the destination still contains an earlier value.
- `complete(Value)`: a non-null token or container has closed. This is syntactic completion,
  not validation that all required model members exist.

`PartialUpdate.isComplete` still describes successful document EOF validation. Default duplicate
filtering compares field states as well as values, so incomplete-to-complete is emitted
when text stays identical, and document completion is emitted separately afterward.
Observation happens after each input element; intermediate events inside a chunk are
not replayed. Empty chunks still produce an update unless duplicate filtering removes it.

The async API has the same state and subscription semantics:

```swift
let titles = try asyncChunks.partials(of: Response.self, from: .json())
  .observeField(\.title)
  .removeDuplicateUpdates()
for try await update in titles {
  render(update.value)
}
```

Configure observation before consuming input. The first version supports direct stored
fields on object roots with a field table, including both generated partial-member modes.
Schema key aliases work automatically, including escaped JSON keys. Computed, nested,
ignored, or ambiguous overlapping field paths throw `FieldObservationError.unsupportedField`.
Nested values can be observed as a whole by selecting their containing field. Duplicate
keys retain the parser's existing semantics (for example, strings concatenate and containers
resume), while the state follows the latest token. Parser errors and upstream errors terminate
observation; a failed document never emits a successful document-completion update.

For repeated parsing, validate the selection once:

```swift
let title = try ObservedFieldPath<Response.Partial, StreamString>(\.title)
// Reuse `title` with `.observeField(title)` for each document.
```

Selection validates against the macro-generated `streamObservationFields` key paths and the
schema's field table, then snapshots only the selected slot. No reflection SPI is used.
Custom `StreamParseableRoot` implementations opt in by listing **all direct stored members**,
including schema-ignored members so overlapping storage can be rejected:

```swift
static var streamObservationFields: [PartialKeyPath<Self>] { [\.title, \.count] }
```

The default list is empty, which disables field selection for custom roots. Field selectors
are excluded from Embedded Swift, which does not support key paths; the enum remains available.
Async observers reuse the partial sequence's iterator box, with the field tracker as its state.
Ordinary async partials use an empty state and carry no field tracker.

Tracking is opt-in: a forwarding sink tracks one field in constant space and reads the
parser's lexical state after each chunk for unfinished numbers/literals. Ordinary partial
storage, the ordinary typed sink, and the scanner are unchanged. Existing skip-validation
semantics also remain unchanged. A custom schema that reports successful non-null completion
without producing a value throws `unavailableValue` rather than inventing one.
