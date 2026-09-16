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
