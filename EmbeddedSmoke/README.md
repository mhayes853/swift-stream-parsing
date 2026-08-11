# EmbeddedSmoke

Builds and links a freestanding executable under Embedded Swift.

```sh
swiftly run +6.3.2 swift build --package-path EmbeddedSmoke \
  --swift-sdk swift-6.3.2-RELEASE_wasm-embedded
```

Existentials, dynamic casts, metatypes, key paths, untyped `throws` and unspecialized generics
all compile without complaint on Darwin. They only fail when the embedded compiler has to lower
them, or at link time. A compile-only check is not enough, so this produces an actual linked
`.wasm`.

The target does not depend on `StreamParsingCore` yet — the current core uses all of the above.
It gains the dependency once the sink based core lands, and then parses a payload through the
real parser with a hand written sink.
