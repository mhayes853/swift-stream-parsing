# New Architecture

Rewrite of the parsing core around a push based sink interface, replacing the key path handler
registration system. Targets ~300 MB/s through the fast interface for chunked input and 30–60
MB/s byte by byte, with the whole core usable from Embedded Swift.

Every number here was measured on arm64 (M1 Pro). Where a decision went against intuition, the
measurement that settled it is recorded, because several of them are counterintuitive enough to
be re-litigated otherwise.

---

## Why

The library started at **2.5–3.5 MB/s**. Profiling found the cost was not where it looked:

| assumption | reality |
|---|---|
| Key paths are the bottleneck | At ~800 cycles/byte, dispatch is single digit percent. |
| Branch misprediction matters | A naive byte-at-a-time switch already runs at 1520 MB/s, 5× the target. |
| Per-byte function calls are expensive | 0.28 ns/byte. The mode switch is another 0.35. |
| Copying a `Partial` per byte is expensive | CoW makes it O(top-level refcounted fields); ~1% difference. |

What actually cost:

- **One malloc per byte of string content.** `ParserByteChunkState` callers copied the buffer out
  of the stored optional, appended, and assigned back, putting it at refcount two at the moment
  of the append, so every scalar copied the whole accumulated value.
- **Unspecialized generic `Sequence` iteration.** `parse(bytes:)` is generic and not inlinable,
  so cross module callers allocated ~2 mallocs per byte just to iterate.
- **Read-modify-write of whole subtrees.** `\.currentElement` is a computed key path, so writing
  one byte of a nested field copied the array element out and back in.

---

## Design decisions

### Fast interface: a token granular sink

`StreamParseSink` receives events carrying borrowed `Span<UInt8>`. Format agnostic rather than
JSON specific, so other parsers can drive the same sinks.

- **Methods do not throw.** A check after every call sits on the hottest path; a sink records a
  failure and the parser reads it once per chunk. Measured 2–5%.
- **Apply closures return a bool instead.** A schema's apply members report whether they consumed
  the token, which is what distinguishes a key the destination does not have (ignored, as it
  always has been) from a field that cannot hold this kind of value (a type mismatch, which the
  registration based parser threw for). A return value is not a throw check: across the six bulk
  benchmarks it measured within run to run noise, 14 µs/5503/458/792/18 µs/541 ns before against
  14 µs/5335/417/750/17 µs/500 after.
- **Collapsed and incremental forms.** `key(_:)` and `string(_:)` default to the incremental
  methods. Overriding them avoids two of every three sink calls, which dominates token dense
  payloads.
- **No `Unicode.Scalar`, no `String`.** Escapes are decoded to UTF-8 inside the parser and
  delivered as byte spans, keeping the Unicode data tables out of an embedded binary.

### Runs, not bytes

The parser finds the next byte needing attention and hands everything before it over in one
piece. Scan strategy, MB/s over an 8 KB corpus:

| run length | 4 | 16 | 64 | 4096 |
|---|---|---|---|---|
| scalar | 1401 | 1480 | 1528 | 1548 |
| SWAR | 940 | 2373 | 5730 | 9817 |
| **SIMD16** | **2476** | **7469** | **12770** | **21411** |
| SIMD32 | 1680 | 2987 | 9201 | 18480 |

SIMD16 wins at every run length. SWAR is worse than scalar below ~12 bytes and never beats
SIMD16, so it is unused. SIMD32 loses on arm64 because NEON registers are 128 bits and it lowers
to two operations plus a recombine.

**simdjson style structural bitmaps are counterproductive here**: byte + table 3788 MB/s, SWAR
bitmap 1611, SIMD16 bitmap 2824. Structurals are 20–25% of token dense JSON, so the bitmap is
dense and iterating set bits costs more than testing bytes.

### Numbers: fused scan, two words

The boundary scan and magnitude accumulation happen in one pass. ns per number:

| variant | small | medium | large | decimals |
|---|---|---|---|---|
| span only, consumer re-scans | 4.68 | 9.43 | 16.73 | 6.87 |
| fused, checked overflow | 5.27 | 13.50 | 23.20 | 8.27 |
| **fused, wrapping + digit count** | **2.96** | **7.47** | **11.91** | **5.52** |
| fused, wrapping, packed word | 3.64 | 7.27 | 11.81 | 5.60 |

The win is not fusion, it is **dropping per-digit overflow checks**. With
`multipliedReportingOverflow`, fused accumulation *loses* to re-scanning. Packing into one word
does not pay; magnitude plus a separate flags word is fastest. End to end this was +17% on a
number dense payload.

`NumberInfo` carries magnitude, decimal exponent, digit count and flags, so floats are built by
accumulation rather than a string round trip.

### Keys: precomputed words, no Dictionary

ns per lookup:

| strategy | 4 keys | 10 keys | 24 keys |
|---|---|---|---|
| static `[UInt64: Int32]` | 9.12 | 9.83 | 10.26 |
| switch on padded word | 2.32 | — | — |
| **hash + table** | **1.28** | **1.32** | **1.32** |

`Dictionary` is 7–8× slower and flat in key count, because `Hasher` runs at every lookup. On a
token dense payload that is ~30% of the parse. It is also a non-starter for embedded.

**Zero padding discriminates keys shorter than the word only.** A key of exactly eight bytes has
no padding and shares its word with any longer key having the same prefix, so the length check
applies from eight bytes, not beyond it. This was a real bug found by a boundary test.

### Storage: frames pointing into the value

Frames hold pointers into the value being built, so partials update per byte at every depth.
Sound because only the innermost open container is ever mutated: a buffer can only move on the
next append, which cannot happen while the current element is open.

**`Dictionary` breaks that**, since insertion can relocate every value. `StreamDictionary` keeps
values in an append-only array, inheriting the array invariant, and preserves insertion order so
conversion to an ordered container is lossless. Lookups scan linearly and build an index only
past a threshold.

**A frame needs a stored property.** Taking the address of a computed one yields a temporary that
dies when the inout scope ends, so the frame dangles. This rules out nesting into bridged
Foundation structs: `PersonNameComponents` is eight bytes on Darwin, a single handle, and every
property on it is computed. Scalars still work, because their inout scope is one call and the
write back lands; only a frame, which outlives the call, does not.

### Views: paying for what you read

A value handed out while parsing continues shares the buffers being written into, so keeping one
means copying it. `current` does that, which is right for keeping a state and wrong for reading a
field as it arrives: on a 7 KB array of structs, reading one member per byte through `current`
costs 24 ms against 449 µs for parsing the same payload and observing nothing.

`withView` hands over a projection instead. It is `~Copyable` and arrives borrowed, which is what
stops it outliving the parser's storage: `copy` is rejected for a noncopyable type, `consume` is
rejected on a borrow, and an implicit conversion out is rejected as consuming. Nothing needs
`~Escapable`, which matters because that requires an experimental feature flag *at every use
site*, and the macro emits into the user's module. `SuppressedAssociatedTypes` is enabled on the
library targets alone, because suppressing the requirement is the declaration's business and
satisfying it is not.

Accessors copy per member rather than per value, and a nested object yields another view, so
reading one leaf never materializes the levels above it:

| reading one member per byte, 7 KB array of structs | p50 |
|---|---|
| observe nothing | 449 µs |
| **through a view** | **459 µs** |
| through `current` | 24 ms |

**The macro still cannot tell a scalar from a nested object**, and no longer needs to. Every
member goes through `_streamMemberView`, whose result type follows the member's own `View`, and
`View` defaults to `Self`. A scalar's view is the scalar, so reading it copies it; a nested
object's view is a projection, so reading it defers again. The overload problem that shaped the
rest of the generated code does not arise here, because the answer comes from an associated type
rather than an overload.

### Optional payload access

Entering a nested field needs a pointer to a stored property. `MemoryLayout.offset(of:)` requires
a key path, and Embedded Swift rejects those outright:

```
error: cannot use key path in embedded Swift [#EmbeddedRestrictions]
```

So the frame entry helpers reinterpret a pointer to an `Optional` as a pointer to its payload,
relying on single payload enums storing the payload at offset zero. That is an implementation
detail rather than a guarantee. It is confined to `StreamFrameEntry.swift`, and the nested object
and array tests exercise it end to end, so a toolchain change fails there rather than corrupting
values silently.

### Macro generated code

The macro sees only syntax. It can tell an array from a dictionary from a plain identifier, but
not whether an identifier is a nested object or a type accepting string content. Overload pairs
resolve that: constrained does the work, unconstrained degrades harmlessly.

**Overloads resolve where a generic is written, not where it is specialized.** A helper generic
over an unconstrained element cannot pick the right overload on its behalf, and
`@_disfavoredOverload` does not change this — the constrained overload is *inapplicable*, not
merely disfavored. Element and value schemas are therefore built by `_streamSchema(for:)` at
call sites where the macro has written a concrete type.

Emitting every field into every apply switch is **free**: at 30 and 100 fields the generated code
is byte identical to hand written code emitting only matching fields, because LLVM builds a
compressed jump table and merges the dead cases. It is not free in *compile time*: 3N cases cost
32.5 ms/struct against 16.3 ms for N. So known type names go to one switch and unknown ones to
all of them.

### Buffering

Chunk size sweep, MB/s:

| chunk | document | token dense |
|---|---|---|
| 1 B | 102 | 123 |
| 16 B | 1780 | 503 |
| 64 B | 3860 | 579 |
| 256 B | 5503 | 647 |
| 8 KB | 5695 | 685 |

The curve is call amortization, not vector width. Buffering to 16 bytes for SIMD gets 31% of
peak; 256 bytes gets 97%. But 256 bytes is ~1.3 s of latency at LLM streaming rates, so buffering
is **not** offered as a throughput feature. A dedicated `parse(byte:)` entry point is worth ~2×
over a one byte span through the general path.

---

## Results so far

Fast interface, bulk, against the old parser on identical payloads:

| payload | old | new |
|---|---|---|
| Long string 8 KB | 19.1 MB/s | **5219 MB/s** |
| Array of structs 7 KB | 2.0 | **467** |
| Nested arrays 4.5 KB | 0.35 | **250** |
| Dictionary 2 KB | — | **366** |

Byte by byte lands at **124–135 MB/s** on larger payloads, against 1–11 MB/s before.

Caveats: nested arrays sits below the 300 target and the prototype's 378, the difference being
validation the prototype skipped. Small payloads are dominated by one malloc per parser in the
allocating initializer; a caller supplied buffer avoids it.

---

## Phase status

### Phase 0 — De-risk (done)

- Two module harness proving cross module specialization. Client sink within ±4% of same module.
  Removing `@inlinable` costs ~8%, not the 2–3× feared, because default cross module optimization
  already specializes the generic parse loop.
- `Span` verified at the 10.15 deployment floor. Only `Array.span` needs macOS 26; the parser
  builds its own spans.
- Key paths confirmed rejected by Embedded Swift.

### Phase 0b — Embedded smoke (done)

- `EmbeddedSmoke/` builds and **links** a freestanding wasm executable, since the failures that
  matter are link time and do not appear on Darwin.
- `swiftly run +6.3.2 swift build --package-path EmbeddedSmoke --swift-sdk swift-6.3.2-RELEASE_wasm-embedded`
- Does not depend on the core yet; gains that once the old parser is removed.

### Phase 1 — Safe wins and test infrastructure (done)

- In-place string accumulation. Quadratic term removed: 4 KB 1159→602 µs, 8 KB 2558→1149,
  16 KB 5919→2286, with scaling ratios going from 2.2/2.3 to 1.91/1.99.
- `withContiguousStorageIfAvailable` fast path. 8 KB document: 16,000 mallocs → 53.
- Benchmark package tracked in the repo, with handler registration measured separately.
- Chunk boundary harness: every payload split at every interior position plus byte by byte, with
  failures given the same treatment as successes.
- Pinned an existing conformance gap: unknown escapes such as `\q` are accepted. The sink based
  parser closed it, and the test now asserts rejection.

### Phase 2 — Core primitives (done)

- `StreamParseSink`, `NumberInfo`, `StreamSinkFailure`.
- SIMD16 scanners with the measurement rationale in source.
- `StreamStringConvertible` / `StreamNumberConvertible` / `StreamBooleanConvertible` /
  `StreamNullable` / `StreamInitializable`, plus conversion initializers on `FixedWidthInteger`
  and `BinaryFloatingPoint`.
- Bridging shims in `StreamParsing`, not the core.

### Phase 3 — The parser (done)

- `JSONParser`: `~Copyable`, `Span` and `UnsafeBufferPointer` entries plus `parse(byte:)`, typed
  throws, owned or caller supplied buffer, container kinds in a `UInt64` bitmask.
- Keys always buffered, giving cross chunk contiguity and 16 bytes of zeroed padding in one step.
- Strings emitted as runs from the input, with a trailing partial UTF-8 sequence held back so
  every span ends on a sequence boundary.
- Escapes decoded into a reserved buffer tail, allocation free and inside the embedded subset.
- Adversarial conformance corpus (~100 cases) written inline, each parsed whole and byte by byte.

Bugs the tests found: `[1,]` and `{"a":1,}` accepted; number grammar declared but never
implemented; overlong UTF-8 and encoded surrogates accepted; lone low surrogate accepted; `--1`
parsed as `-1`.

### Phase 4 — Macro and PartialSink (done)

- `StreamSchema` of non-capturing closures; `StreamFrame`; `PartialSink` walking a frame stack,
  with a discarding schema for subtrees under unknown keys.
- `StreamDictionary`, ordered and append-only, with dictionary routing through `enterKey`.
- Frame entry helpers, underscored, with the optional layout assumption confined to one file.
- Schema builders in `StreamParsing`.
- Macro emits `streamMatchField` with precomputed key words, four apply switches,
  `streamEnterField` and `streamSchema`, additively alongside the old registration so both
  parsers drive the same `Partial`.
- Expansions recorded through `xcodebuild` (the `swift test` CLI does not write them), then all
  38 key cases verified independently against the words their keys imply.
- Generated code carries one comment, the field name on each key case.
- Hand written conformances in `PartialSinkTests` converted to the macro.
- **Differential against the old parser**: same input, both parsers, same `Partial`. It found an
  empty string producing nil and container elements getting an inert scalar schema, and pinned
  two places where the parsers differ and the new one is right.

`MockParser` still drives the old registration path. Porting it moved to Phase 6, since its only
consumers are the stream types that phase rewrites.

### Phase 5 — Support types (done)

- `StandardLibrary`, `Foundation`, `CoreGraphics`, `SwiftCollections` and `Tagged` ported, with
  the new conformances sitting next to the registration based ones they replace so Phase 6 is a
  single subtraction.
- **`Decimal` is exact.** It is built from the accumulated magnitude and decimal exponent, which
  is what `Decimal` already stores, so `1.005` round trips instead of arriving as the nearest
  `Double`. Out of range exponents and magnitudes wider than the accumulator fall back to
  `Decimal(string:)`.
- **`Data` is no longer quadratic** — it appends the bytes it is handed rather than rebuilding a
  `String` from the whole accumulated value on every write.
- **128 bit integers re-scan.** The accumulator carries magnitude in a `UInt64`, so anything
  wider arrives flagged as overflowed with nothing usable in it. `Int128` and `UInt128` walk the
  token instead, which is what the registration based parser did; taking the shared conversion
  unchanged would have silently narrowed them to 64 bits.
- The shared integer conversion bounded the negative case with `UInt64(Self.max.magnitude)`,
  which traps for types wider than 64 bits. It is expressed in `Self.Magnitude` now.
- `Tagged` forwards every conversion protocol to its raw value, and a tagged object applies the
  raw value's schema to a pointer to the `Tagged`, since it has one stored property.
- swift-collections types are **bridging destinations, not parse targets**. Container shape comes
  from syntax, so the macro reads `Deque<Int>` as an ordinary identifier and cannot route it. A
  member declared with one used to parse as empty in silence; a deprecated `_streamEnterField`
  overload on `_StreamUnroutableContainer` now makes it a warning at the expansion site.
- `OrderedDictionary` bridging both ways, which insertion order makes lossless, plus
  `TreeDictionary` for contents only.

### Phase 6 — Conveniences and removal (done, except EmbeddedSmoke)

- `PartialsStream` is `~Copyable` and owns the value in its own allocation, because the sink holds
  pointers into it that have to survive the stream being moved. `AsyncPartialsSequence` keeps it
  in a box, since `AsyncIteratorProtocol` requires a copyable conforming type.
- `.json()` now describes a parser rather than being one: `JSONParser` owns a buffer and is
  `~Copyable`, so `JSONStreamFormat` carries the settings and each stream builds its own.
- Removed: `YAMLStreamParser.swift` and `JSONStreamParser.swift`, JSON5 syntax options, key
  decoding strategies, line and column positions, `PathTrie`, `HandlerRegistration`,
  `ErasedPaths`, `NumberAccumulator`, `ParserByteChunkState`, `DigitParsing`, `StreamParser`,
  `StreamParserHandlers` and its 20 `register*Handler` requirements, `StreamParseableValue`,
  `StreamParseableArrayObject`, `StreamParseableDictionaryObject`, `MockParser`. 68,000 lines
  deleted against 1,200 added.
- YAML support goes with it. The sink is format agnostic, so a YAML parser can be rebuilt against
  it later; until then the library is JSON only.
- **`partials()` handed out values that changed after the fact.** The sink writes container
  elements through a raw pointer, which never triggers copy on write, so every state it emitted
  shared the buffer being written into. A captured `[String]` read `[""]` and then `["a"]` two
  bytes later. This is the bug the plan's differential was meant to catch and did not, because it
  compared final values rather than sequences.
- `streamSnapshot()` fixes it by rebuilding containers, and the rebuild has to recurse: a one
  level copy fixes `[String]` and `[[Int]]` but not `[[String]]`, whose inner element is also
  written through a raw pointer. `next()` no longer returns a value, because returning one is the
  same thing as asking to keep one, and that is what costs a snapshot.
- The 169 registration based JSON tests were ported. 82 per-byte state sequences survive, 13
  covering deleted features were dropped, and 55 were regenerated against two deliberate timing
  changes, then audited: every array is still `bytes + 1` long, and a sample across numbers,
  literals, arrays, dictionaries and nested structs was checked against the grammar by hand.
- `withView` and the generated per-member projections, with the benchmark above as the argument
  for them.
- `EmbeddedSmoke` links the real core now: it parses a payload through `JSONParser` and a hand
  written sink, on a caller supplied buffer with no `String` or `Array` anywhere, checks counts
  and checksums across chunk sizes 7, 3 and 1, and requires a malformed document to be rejected.
  Running it is part of the check rather than just linking it, since `precondition` traps as
  `unreachable` and a wrong answer fails the run. It caught two things: the payload has four
  strings rather than the five the test first claimed, and a sink that counts strings only in the
  collapsed `string(_:)` counts zero, because the parser buffers keys but emits strings as runs.

**The view layer needs `SuppressedAssociatedTypes`, and only the library needs it.** 6.3.2
rejects `associatedtype View: ~Copyable` outright, on Darwin as well as under the embedded
compiler, which went unnoticed because Xcode-beta ships 6.4. Enabling the experimental feature on
the two library targets is enough: a module that provides a noncopyable `View` for the associated
type compiles without it, which was checked with a consumer standing in for macro generated code
in a module that does not enable it. So the floor stays where it was rather than moving to 6.4.

### Phase 7 — CI and hardening

- Embedded compile job. None of the embedded blockers fail visibly on Darwin.
- Benchmark regression job against a checked in baseline.
- Re-measure byte by byte on a quiet machine; it varied ±40% across runs in development.
- Revisit nested arrays, currently below the 300 target.

---

## Known gaps

- `Float` scaled parsing rounds twice, once into `Double` and once into `Self`. It needs its own
  bound before that path can be called exact.
- Lone high surrogates are rejected, but the check happens at run and string end rather than
  immediately.
- Two token timing changes, both inherent to the design rather than incidental. A number
  materializes when its token ends rather than per digit, because the fused scan has nothing to
  emit until then, and a bare number at the root therefore only lands at `finish()`. A container
  materializes its slot on entry, so a dictionary key is visible with its initial value before the
  value arrives.
- Error reasons are coarser: `missingColon`, `trailingComma`, `missingComma` and
  `missingClosingBrace` all collapse into `unexpectedToken`, and errors carry a byte offset rather
  than a line and column.
- `partials()` is O(n x value size), because each state it keeps has to be materialized before the
  next write overwrites it. Reading transiently through `withView` is free; keeping history is
  not, and measures 52x the parse on an array of structs.
- Depth is capped at 64 by the container bitmask; deeper nesting is rejected rather than spilled.
- The optional payload assumption is an implementation detail, mitigated by tests rather than
  eliminated. `Tagged` adds a second case of it, a single stored property at offset zero, kept in
  the same file behind a size assertion.
- `PersonNameComponents.phoneticRepresentation` is matched but not entered, because the type has
  no stored property for a frame to point at. A nested object there is skipped; a null still
  clears it. Its string writes are a get, modify and set through the bridge rather than an
  append, so a long name streamed byte by byte is quadratic.
- swift-collections containers cannot be parsed into directly, only converted to. The macro reads
  container shape from syntax and cannot see through a generic identifier.
- Nested arrays throughput is below target.
