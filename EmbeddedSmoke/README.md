# EmbeddedSmoke

Builds and links `StreamParsingCore` into a freestanding executable under Embedded Swift, then
parses a payload through the real parser and a hand written sink.

```sh
swiftly run +6.4.x-snapshot-2026-08-01 swift build --package-path EmbeddedSmoke \
  --swift-sdk swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-08-01-a_wasm-embedded

wasmer run EmbeddedSmoke/.build/out/Products/Debug-webassembly-wasm32/EmbeddedSmoke.wasm
```

Existentials, dynamic casts, metatypes, key paths, untyped `throws` and unspecialized generics
all compile without complaint on Darwin. They only fail when the embedded compiler has to lower
them, or at link time. A compile-only check is not enough, so this produces an actual linked
`.wasm`, and running it checks the parse rather than just the lowering: `precondition` traps as
`unreachable`, so a wrong answer fails the run.

Builds on 6.3.2 and on 6.4. The core enables `SuppressedAssociatedTypes` for the view layer's
`associatedtype View: ~Copyable`; consumers do not need the flag. `AsyncSequence+Partials.swift`
is gated out under `hasFeature(Embedded)`, since the 6.3 embedded SDK has no concurrency and a
target with no scheduler has no use for an async byte stream.

```sh
swiftly run +6.3.2 swift build --package-path EmbeddedSmoke \
  --swift-sdk swift-6.3.2-RELEASE_wasm-embedded
```

What it covers:

- The parser is built on a caller supplied buffer rather than the allocating initializer, which
  is how it is meant to be used where there is no heap to speak of.
- The sink folds the document into counters and checksums, so no `String`, no `Array`, nothing
  that allocates.
- Every count and checksum is compared across chunk sizes 7, 3 and 1 as well as the whole
  document, because resumability breaks the same way on a microcontroller as anywhere else.
- A malformed document has to be rejected here too, so typed `throws` is exercised rather than
  assumed.

Writing it turned up something worth knowing: keys arrive through the collapsed `key(_:)`,
because the parser always buffers them, while strings arrive through `stringBegin`, `stringChunk`
and `stringEnd`, because they are emitted as runs. A sink that counts strings only in the
collapsed form counts zero.
