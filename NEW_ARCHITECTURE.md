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
| --- | --- |
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
| --- | --- | --- | --- | --- |
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

**Superseded by "Numbers, whole" at the end of this document.** The fused design below was
measured under per digit emission; with whole-token emission the comparison inverts, and the
shipped parser is a greedy SIMD16 scan with a structured whole-token parse. The table stays
because it records what was true under the old constraint.

The boundary scan and magnitude accumulation happen in one pass. ns per number:

| variant | small | medium | large | decimals |
| --- | --- | --- | --- | --- |
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

~~**A value is reported after every digit.**~~ Reversed — see "Numbers, whole" below. The
provisional values were never prefixes of the final value the way a partial string is: `1234`
reports 1, then 12, then 123, and `-1.5e2` reports −1.5 before it reports −150, each a different
number by an order of magnitude. Emitting at part boundaries instead (integer part, then decimal
part) was considered and rejected on the same ground, because the exponent case still jumps from
1.5 to 150 at the delimiter. A number is now reported exactly once, whole, at its token's end,
`.incomplete` is gone from `NumberInfo.Flags`, and the per-digit sink call with it. That also
deleted the sink's number target machinery: with one event per token, resolving per event is
correct again, so `PartialSink.number` is a plain scalar apply like `boolean`.

### Keys: precomputed words, no Dictionary

ns per lookup:

| strategy | 4 keys | 10 keys | 24 keys |
| --- | --- | --- | --- |
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

### Schemas: a reference, not a value

`StreamSchema` began as a struct of eight closures, ~136 bytes, on the argument that non-capturing
closures are thin function pointers: no allocation, no existential, no metatype. That was true and
beside the point. It is stored by value in `StreamFrame`, in the frame stack and in `ScalarTarget`,
so `frames.last`, the write back on every key and `T.streamSchema` on every element entry each
copied all eight. A 110 byte flat struct with six members cost 275 retains.

Making it a `final class`, p50:

| | value | reference |
| --- | --- | --- |
| Array of structs, bulk | 251 µs | **79 µs** |
| Array of structs, view read per 4 KB chunk | 255 µs | **79 µs** |
| Array of structs, byte fed | 514 µs | **350 µs** |
| Flat struct | 9.4 µs | **6.3 µs** |
| Twitter 631 KB | 27 ms | **23 ms** |
| retains, 100 users | 13,000 | **2,101** |

**Malloc counts are identical everywhere**, which is what settles where the cost was: with a class
every schema construction allocates, and none appeared, so nothing is built on the hot path and the
retains were pure copying. All 21 fast interface benchmarks are unchanged within noise. Bulk gains
3.2x where byte feeding gains 1.5x, because byte feeding is dominated by per byte parser entry and
the sink is a smaller share of it.

**Going further does not pay.** Holding the schema in the frame by pointer or unowned reference
would remove the remaining ~2,100 retains, worth ~8 µs against 79 µs. It also forces the schema
tree to be built once, because container schemas are per entry temporaries: `_streamEnterArrayField`
builds a fresh array schema on every entry and the frame it returns is its only owner. A macro
codegen change and an unchecked lifetime invariant, for 10%.

What the change costs: a shared class refcount is one contended cache line, so many streams parsing
the same type concurrently now contend where copying immortal closure contexts did not. Nothing
here measures concurrency.

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
| --- | --- |
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
| --- | --- | --- |
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
| --- | --- | --- |
| Long string 8 KB | 19.1 MB/s | **5219 MB/s** |
| Array of structs 7 KB | 2.0 | **467** |
| Nested arrays 4.5 KB | 0.35 | **250** |
| Dictionary 2 KB | — | **366** |

Byte by byte lands at **124–135 MB/s** on larger payloads, against 1–11 MB/s before.

Caveats: nested arrays sits below the 300 target and the prototype's 378, the difference being
validation the prototype skipped. Small payloads are dominated by one malloc per parser in the
allocating initializer; a caller supplied buffer avoids it.

Convenience layer against the old parser, 6293 byte array of structs, p50 with the same four
metrics enabled on both sides. Recorded here because the old baselines have been deleted and
these are the last measurements taken against them:

| scenario | old | new | | old mallocs | new |
| --- | --- | --- | --- | --- | --- |
| whole payload, no observation | 3.6 ms | 161 µs | 22x | 4352 | 115 |
| byte fed, no observation | 15.0 ms | 423 µs | 36x | 18,000 | 115 |
| value after every byte | 15.0 ms | 20.0 ms | **0.8x** | 18,000 | 6398 |

The old library has no chunked benchmark, so its 3.6 ms bulk number is the floor a chunked run
would have started from. Against that floor:

| chunk | snapshots | snapshot per chunk | vs old | view read per chunk | vs old |
| --- | --- | --- | --- | --- | --- |
| 16 B | 394 | 1.4 ms | 2.5x | 204 µs | 17.5x |
| 64 B | 99 | 477 µs | 7.5x | 173 µs | 20.6x |
| 256 B | 25 | 238 µs | 15.0x | 164 µs | 21.8x |
| 1 KB | 7 | 183 µs | 19.5x | 161 µs | 21.9x |
| 4 KB | 2 | 167 µs | 21.4x | 161 µs | 22.2x |
| 1 B | 6293 | 20.0 ms | 0.2x | 439 µs | 8.1x |

**Only per byte snapshotting loses to the old parser**, and the crossover is around one snapshot
per two bytes. The view path is flat: reading a member never allocates beyond the parse's own 115,
and the only thing that moves it is feed granularity. Snapshotting after each 4 KB chunk is
faster than byte fed parsing that observes nothing at all, so the guidance is to hand over the
chunk that arrived rather than to observe less often.

Every convenience layer number above predates the schema reference change, which took the same
payload from 251 µs to 79 µs in bulk.

`twitter.json` (631 KB, from yyjson_benchmark) is the first non-synthetic payload measured. Fast
interface: 649–675 MB/s bulk, 473 at 64 B chunks, 171–177 byte by byte. The long string figure
above is a memcpy benchmark by comparison, and this is the number worth quoting.

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
  raw value's schema to a pointer to the `Tagged`, since it has one stored property. The same
  shape later solved `PersonNameComponents.phoneticRepresentation`: a frame does not have to
  point at the value it describes, only at something whose address outlives it.
- swift-collections types are **bridging destinations, not parse targets**. Container shape comes
  from syntax, so the macro reads `Deque<Int>` as an ordinary identifier and cannot route it. A
  member declared with one used to parse as empty in silence; a deprecated `_streamEnterField`
  overload on `_StreamUnroutableContainer` now makes it a warning at the expansion site.
- `OrderedDictionary` bridging both ways, which insertion order makes lossless, plus
  `TreeDictionary` for contents only.

### Phase 6 — Conveniences and removal (done)

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

- Embedded compile job (done). The wasm job installs the SDK, builds `EmbeddedSmoke` and runs it
  under wasmtime, since a wrong answer has to fail rather than merely link. None of the embedded
  blockers fail visibly on Darwin.
- Benchmark regression job against a checked in baseline. A `pre-arc` baseline exists locally and
  is 11 MB, which is more than belongs in the repo: the metric set or sample count wants trimming
  first.
- Re-measure byte by byte on a quiet machine; it varied ±40% across runs in development.
- Revisit nested arrays, currently below the 300 target.
- The full benchmark suite died once with SIGSEGV partway through and has not reproduced in six
  runs since, with no crash report on disk. Raw pointers into array buffers make that worth
  pinning rather than forgetting. Note that there are no longer any raw pointers into array
  buffers, so if it reproduces the cause is elsewhere.

### Phase 8 — StreamArray (done)

- `StreamArray`, with the measurements above as the argument for its shape.
- `Array`'s `StreamParseableRoot` conformance and `_streamAppendElement` removed, so no path writes
  into an `Array` buffer through a raw pointer. `Array.Partial` is `StreamArray<Element.Partial>`,
  which is the source breaking part: a root array is written `StreamArray<Int>()` now.
- `streamSnapshot()` removed from the protocol, along with the macro's member wise implementation
  and the recursive rebuild. A plain value copy is the snapshot.
- **Removing it is what found the remaining aliasing.** Every one of the 292 tests passed except
  seven, and all seven were `StreamDictionary` states showing a value that had not arrived yet,
  because the dictionary still wrote into a shared buffer through a raw pointer. That is the same
  bug `partials()` had, isolated to the one container that had not been converted.
- `StreamDictionary` therefore has a `pendingKey`/`pendingValue` pair on the same rule: the open
  entry is written inline and committed when the next one opens. A repeated key resumes from the
  value already stored and commits back to its original slot, so `{"a":1,"b":2,"a":3}` keeps its
  order. Its storage is still flat, which is a performance question rather than a correctness one.
- `Codable` and `CustomReflectable` on `StreamArray`, both guarded out of the embedded build.
  Without the mirror every custom dump and recorded snapshot shows the blocks and the pending slot.

---

## Known gaps

- `Float` scaled parsing rounds twice, once into `Double` and once into `Self`. It needs its own
  bound before that path can be called exact.
- ~~Lone high surrogates are rejected, but the check happens at run and string end rather than
  immediately.~~ Fixed with the adversarial round's surrogate bugs: every event that can follow a
  high surrogate now checks for one, so a pair is severed exactly where it breaks.
- A container materializes its slot on entry, so a dictionary key is visible with its initial
  value before the value arrives. Load bearing rather than merely tolerated since the shape check:
  a container discarded for arriving at a destination that cannot hold it leaves the slot behind,
  so `{"a":[2,3]}` into a `StreamDictionary<Int>` reads `["a": 0]`.
- A container at a destination that cannot hold it is discarded silently, where a scalar at a
  destination that cannot hold it throws `.typeMismatch`. An object field cannot distinguish a key
  it does not have from a field that cannot hold a container, which is what keeps the container
  direction quiet everywhere rather than in one shape only.
- `null` is accepted where the destination is optional and rejected where it is not, so it clears
  any member of a macro generated `Partial` but is a mismatch in a `StreamArray<Int>`. It follows
  from `applyNull` rather than from a decision about JSON null.
- ~~A provisional number is a different number, not an approaching one.~~ Resolved by removing
  provisional reporting entirely: a number is emitted once, whole, at its token's end, and
  `.incomplete` no longer exists. See "Numbers, whole".
- Error reasons are coarser: `missingColon`, `trailingComma`, `missingComma` and
  `missingClosingBrace` all collapse into `unexpectedToken`, and errors carry a byte offset rather
  than a line and column. The offset is absolute and chunking-independent now — see "Numbers,
  whole" for the accounting fix that made it so.
- Keeping every state costs about twice the parse on an array of structs, down from 269x, because
  a snapshot still copies the open element at each depth. Reading transiently through `withView`
  is still cheaper.
- `StreamDictionary` storage is flat by measurement rather than by omission: blocking it cost 2x on
  the discarding path, because a dictionary reads its storage back on every lookup. So a kept state
  still shares three buffers that copy in full per divergence point, and retention is still
  quadratic in key count — 3.5x the discarding parse at 512 keys against 2.5x at 32. The rehash is
  gone, the constant is 8–19% better, and the shape is unchanged.
- Depth is capped at 64 by the container bitmask; deeper nesting is rejected rather than spilled.
- The optional payload assumption is an implementation detail, mitigated by tests rather than
  eliminated. `Tagged` adds a second case of it, a single stored property at offset zero, kept in
  the same file behind a size assertion.
- `PersonNameComponents` string writes are a get, modify and set through the bridge rather than an
  append, so a long name streamed byte by byte is quadratic. That is the whole of what the type's
  lack of stored properties costs now: `phoneticRepresentation` is entered rather than skipped,
  by pointing the frame at the parent and reaching the field through the bridge on every write.
- swift-collections containers cannot be parsed into directly, only converted to. The macro reads
  container shape from syntax and cannot see through a generic identifier. Declaring a member with
  one does not compile — the generated `Partial` asks for `Deque<Int>.Partial`, which does not
  exist — so it is caught at build time rather than parsing as empty. The message names the
  missing `Partial` rather than the real problem, which is the part worth improving.
- Nested arrays throughput is below target, and per digit number reporting moved it further from
  it: 17 µs to 21 µs on the bulk benchmark. That payload is an integer matrix, so it pays the new
  sink call more often than anything else measured.
- A shared schema refcount is one contended cache line, so concurrent parses of the same type
  contend where the value typed schema did not. No benchmark covers concurrency.
- ~~The Twitter benchmark model declares `screenName` and `followersCount`, which never match
  `screen_name` and `followers_count`, so those members are always nil and the benchmark measures
  more of the discard path than it appears to. Both benchmark files also use `try?`, so a payload
  that aborted early would score as fast.~~ Both settled by measurement and by fix: a matched keys
  model measures identically — the distortion was in what the number meant, not what it was — and
  the runners now trap on a parse failure. See the adversarial round below.

---

## Freezing the completed prefix

Built in phase 8. Snapshot cost was quadratic where parse cost is linear. Per byte snapshotting against the discarding
floor:

| payload | discarding | snapshot per byte | retains |
| --- | --- | --- | --- |
| 10 users, ~600 B | 53 µs | 433 µs | 8.8K |
| 100 users, 6.3 KB | 516 µs | 24 ms | 658K |
| 400 users, 25 KB | 2.2 ms | 379 ms | 11M |

Mallocs stay at roughly one per snapshot at every size, so the cost is refcount traffic over copied
elements rather than allocation. An 8 KB document snapshotted per byte costs 569 µs and 88 retains,
which is what makes this arrays and dictionaries observed per byte, not snapshots in general.

Everything left of the parse cursor is immutable — `users[k]` never changes once closed — so a
snapshot only needs its own copy of the open element. `Array` cannot express that: any divergence
from a shared buffer copies all of it, which is why `streamSnapshot()` is a full recursive rebuild.

### The open element goes outside the storage

Where the open element lives decides the shape of the whole thing. Put it *outside* the sealed
storage, in a `pending` slot held inline in the container, and three things fall out together:

- **A plain value copy is already a correct snapshot.** Sealed storage is immutable, `pending` is
  copied inline, and nested containers recurse through ordinary value semantics. The recursive
  rebuild in `streamSnapshot()` stops being necessary.
- **The raw pointer bypass that caused the `partials()` bug disappears.** The parser's frame points
  at the `pending` slot, and writes through it are ordinary mutations that respect the slot
  contents' own copy on write. Nothing writes into element storage another value can see.
- **Committing an element is the only operation that touches shared storage**, and it happens once
  per element rather than once per byte.

Chunking then bounds what that commit costs. With a plain `Array` behind `pending`, the first append
after a snapshot copies all n elements, so per byte snapshotting costs O(n) per element — better
than today and still quadratic. With fixed size blocks only the filling block is ever copied, so the
same append costs at most B and the quadratic term becomes n·B.

**No new sink event is needed.** A container commits its pending element when the next one opens,
and readers see `pending` as the last element until then — which is what keeps an incomplete element
visible while it streams. `endArray` needs nothing; the element simply stays pending until
conversion. This matters because the sink has no notion of closing an element today: frames are
popped without telling the container.

### What the commit costs

Moving the open element out of the buffer means every element is copied out of `pending` when the
next one opens, where today it is filled in place and never copied. That is the price of the whole
design and it lands on the discarding path, so it was measured before anything was built. An
isolated append loop, p50 wall clock, against the append helper as it exists today. `narrow` is
`Int?`/`String?`/`String?`, matching `BenchmarkUser.Partial`; the payload's names are 15 bytes or
fewer and so are inline small strings, leaving one heap string per element. `wide` is four heap
strings plus two numbers.

| | array in place | pending, copied out | **pending, swapped out** |
| --- | --- | --- | --- |
| narrow, 100 | 8.0 µs | 10 µs | **7.6 µs** |
| narrow, 400 | 29 µs | 38 µs | **29 µs** |
| wide, 100 | 9 µs | 13 µs | **10 µs** |
| wide, 400 | 35 µs | 49 µs | **39 µs** |

**How the element leaves the slot matters more than that it leaves at all.** Reading it out and
letting the reassignment destroy the original is two element sized copies; swapping a nil in is one,
and the optimizer takes it as a move. `consume self.pending` is not the way to say that:

```
error: 'consume' can only be used to partially consume storage of a noncopyable type
```

With the swap the tax is nothing on a user shaped element and 11% on a fat one, *within the append
loop*. That loop is around 10% of the bulk parse — 8.0 µs against the 78 µs the array of structs
bulk benchmark measures — so end to end it is 0–1%. The cost tracks element size rather than
refcounted field count, because there is no per element retain traffic: the move leaves nothing to
retain.

Two things went the other way from the estimate. **Blocks allocate less than `Array`, not more**:
9 mallocs against 7 at wide 100, because `reserveCapacity(B)` per block beats geometric growth once
there are a few blocks. And the per element retain tax estimated at ~5% is not there at all.

### What the snapshot saves

400 elements at 63 snapshots each, which is the user payload's byte count per element, so 25,200
snapshots:

| | array rebuild | pending copy | |
| --- | --- | --- | --- |
| dropped immediately | 84 ms, 25K mallocs, 5.08M retains | **86 µs**, 19 mallocs, 1.6K retains | 977x |
| 16 deep window | 85 ms | **1.91 ms**, 426 mallocs, 83K retains | 44x |

The dropped row is the methodology the existing benchmarks use, so it is what the 379 ms above is
comparable to. The window row keeps history, which is the case the tables have never measured: it
forces the tail to be shared at every append, so every commit pays its O(B) copy and every
snapshot's retains are real. At 1.91 ms against a real byte fed 400 user parse of 1.49 ms, keeping
16 states roughly doubles the parse. Today it is 379 ms against 2.2 ms.

Correctness was checked alongside, with `blockCapacity` at 4 so that seals happen while snapshots
share the spine: the `pending` slot keeps one address across every element and every seal, the live
value reads back correctly, and snapshots taken *mid string* hold their own value while the parser
keeps appending to the open element. No uniqueness handling is written anywhere — `ContiguousArray`
does it.

### Measured end to end

Built, and measured against the same benchmarks on the same machine in the same session rather
than against the tables above, which predate several other changes. p50 wall clock:

| | before | after | |
| --- | --- | --- | --- |
| Array of structs, bulk, discarding | 78 µs, 115 mallocs, 2201 retains | 81 µs, 112, 2103 | −4% |
| 100 users, byte fed, discarding | 360 µs, 115, 2101 | 351 µs, 112, 2003 | — |
| 400 users, byte fed, discarding | 1486 µs, 417, 9001 | 1465 µs, 423, 8612 | — |
| 100 users, snapshot per byte | 25 ms, 6398, 647K | **735 µs**, 112, 21K | 34x |
| 400 users, snapshot per byte | 394 ms, 26K, 11M | **3.06 ms**, 423, 87K | 129x |
| 8 KB document, snapshot per byte | 570 µs, 13, 17 | 560 µs, 13, 15 | — |

**Snapshotting no longer allocates.** Mallocs on the per byte path drop from 6,398 to 112, which is
the parse's own count: a snapshot used to cost an allocation and now costs a few retains. The
document row is the control — it has no containers, so nothing should move, and nothing does.

The discarding path is flat everywhere except the bulk benchmark, which is 4% slower. That is the
commit copy, and it shows up there rather than in the byte fed rows because bulk parsing is the
case where the append loop is the largest share of the work. It is the price the tables above
predicted, landing where they predicted it.

Snapshot per byte of 400 users is now 2.1x the discarding parse of the same payload, against 269x
before, so keeping every state is finally the same order of magnitude as the parse rather than
three orders above it.

### Where the allocations went

Those benchmarks drop each state before the next byte, so nothing is shared when a write happens
and copy on write never fires. The allocations did not disappear, they became **conditional on the
application keeping something**, which is worth measuring separately because the benchmarks never
have. 100 users, states held in a rolling window or all at once:

| retention | old mallocs | new mallocs | old p50 | new p50 |
| --- | --- | --- | --- | --- |
| dropped immediately | 6398 | **112** | 25 ms | **0.74 ms** |
| window of 4 | 6589 | **399** | 24 ms | **0.85 ms** |
| window of 16 | 6589 | **399** | 24 ms | **0.85 ms** |
| window of 64 | 6589 | **399** | 24 ms | **0.85 ms** |
| every state | 6589 | **399** | 25 ms | **0.76 ms** |

**Both sides are flat in retention depth, and that is the point.** The old rebuild allocated per
snapshot whether or not the snapshot was kept, so dropping one cost the same as keeping it. The new
one allocates per *divergence point*: the first commit after a snapshot copies the filling block,
and every later snapshot then shares the new block, so holding 6,293 states costs exactly what
holding 4 costs. 287 mallocs over the parse floor across 100 elements is about three per element —
one tail block copy per commit while shared, one spine copy per 32 commits, and the open element's
own buffers.

**Except for the element's own storage, which is unchanged.** An 8 KB document held at every byte:

| | old | new |
| --- | --- | --- |
| mallocs | 7994 | 7994 |
| retains | 16K | 16K |
| p50 | 2.95 ms | 3.20 ms |

One allocation per append, because a retained state shares the `String` buffer and the parser's
next append copies it. Nothing in the container design touches that, and nothing was expected to:
the old `streamSnapshot()` shared string buffers too, since `String`'s was the identity. This is
the remaining quadratic, it lives in the element rather than the container, and the chunk size knob
is the lever for it.

So the guidance splits by value shape rather than by observation frequency. A consumer that renders
each state and drops it now pays nothing at all. One that keeps history of a container shaped value
pays a bounded per element cost that does not grow with how much history it keeps. One that keeps
history of a value with a long streaming string field still pays per byte of that string.

### The spine does not need to be unsafe

An append only spine behind an unsafe pointer with a per value count would make a snapshot O(1)
rather than O(1) amortised. It is not worth it, for two reasons.

**A snapshot's spine cost is already O(1).** Copying `[ContiguousArray<Element>]` retains one buffer
object, not one per block. The 16 deep window run shows 83K retains over 25,200 snapshots, 3.3 each:
the blocks buffer, the tail buffer, and the open element's string. Nothing element wise.

The quadratic term that remains is spine *appends while shared* — once per B elements, copying n/B
references, so (n/B)² over the parse. Against the per snapshot floor of 3·n·bytesPerElement, the
ratio is n / (3·B²·bytesPerElement), so at B=32 and 63 bytes per element the spine only overtakes
the cost that cannot be removed at **n ≈ 200,000 elements**. At 400 it is 144 retains against 75,000.

**And "prior blocks are read only" does not make it safe.** The blocks are; the spine storage is
not. Appending reallocates the buffer, so a snapshot read on another thread races the parser on the
buffer pointer itself rather than on any block. A spin lock closes that by putting an acquire on
every read of every sealed element, which is the path this feature exists to make cheap, and it
turns `@unchecked Sendable` from "what `Array` does" into a claim that has to be argued.

If n ever reaches that range the answer is a **spine of spines** — the same chunking one level up,
which keeps ordinary copy on write and costs a second shift and mask on indexing. Noted rather than
built, because nothing streams 200,000 elements today.

### Sketch

```swift
public struct StreamArray<Element> {
  // Sealed on commit and never written again, so copies share them and a snapshot retains one
  // buffer object rather than one per block. Every sealed block is exactly `blockCapacity` long,
  // which keeps indexing a shift and a mask rather than a search over prefix sums.
  //
  // No wrapper class: a ContiguousArray is already a single refcounted pointer, so the spine copies
  // for the same cost, and copy on write for the filling block comes for free instead of being
  // written by hand.
  @usableFromInline var blocks: [ContiguousArray<Element>]
  @usableFromInline var tail: ContiguousArray<Element>
  // The element being parsed. Held here rather than in `tail` so the parser's frame points at a
  // slot no other value can see, and so its address survives every append.
  @usableFromInline var pending: Element?

  // A power of two, so `blocks.count << shift` is the sealed count and no separate field is needed.
  @usableFromInline static var blockCapacity: Int { 32 }
}

extension StreamArray: RandomAccessCollection, MutableCollection {
  public typealias Index = Int
  public var startIndex: Int { 0 }
  // (blocks.count << shift) + tail.count + (pending == nil ? 0 : 1)
  public var endIndex: Int { ... }
  // Sealed, then tail, then pending. The setter writes through `blocks[i][j]`, which copies the one
  // block it touches when a snapshot shares it.
  public subscript(position: Int) -> Element { get { ... } set { ... } }
}

extension StreamArray: ExpressibleByArrayLiteral {}
extension StreamArray: Equatable where Element: Equatable {}
extension StreamArray: Hashable where Element: Hashable {}
extension StreamArray: @unchecked Sendable where Element: Sendable {}

extension Array {
  public init(_ elements: StreamArray<Element>)
}

extension StreamArray {
  // The parser's door. Commits the previous pending element into `tail` by swapping it out, then
  // returns the address of the new pending slot for a frame to hold.
  @usableFromInline
  mutating func _openElement(_ initial: Element) -> UnsafeMutableRawPointer
}
```

### What this does to the three hazards

1. **A user mutates one snapshot and another sees it.** Gone. Every write to sealed storage goes
   through the checked subscript, which copies the one block it touches. There is no unchecked door
   into shared storage at all: the only unchecked write is into `pending`, which is inline and
   private to each value.
2. **The parser writes below the frozen line.** Gone once `StreamDictionary.storedValues` is one of
   these. `updateValue` writing an existing key's slot for `{"a":{…},"b":1,"a":{…}}` goes through
   the same checked subscript, so it copies a frozen block rather than mutating it.
3. **An element's own storage.** Unchanged. A snapshot shares an element's `String` by refcount, so
   the parser's next append to it copies. True today as well, and the benchmarks do not measure it:
   `blackHole(stream.current)` drops each snapshot before the next append, so keeping history costs
   more than the tables show.

That is the argument for chunking over the alternative of an append only buffer with a per value
visible count, which the spine measurement above settles: the count version buys nothing a snapshot
can feel, and costs synchronisation to be safe.

A persistent bitmapped trie also gives O(1) snapshots safely, but pays path copying and allocation on
every append, penalising the discarding case to speed up the rare one. Ruled out on the same grounds
as routing element writes through the `Array` API.

### The open path is inline all the way down

With the open element outside the storage at every level, the whole path from root to parse cursor is
inline storage: the root allocation holds the partial, a container member holds a `pending` slot, the
element in it holds the next container, and so on. No heap buffer appears anywhere along it.

Frame validity used to rest on an argument about mutation order — only the innermost open container
is written, and a buffer can only move on the next append. It rests on layout now: an inner append
cannot invalidate an outer frame, because the outer container's open element was never in a buffer
to begin with. That is the version worth defending, because it survives someone editing the sink.

What it needs in return is an invariant the sink does not currently state: **no write may straddle a
commit.** A stale element pointer used to reach a stale-but-owned slot; it now reaches a *different*
element. It holds today — numbers are single-event so no number target survives a token,
`scalarTarget` clears at `stringEnd`, and frames pop before the next container opens — but nothing
enforces it. Per digit number reporting was exactly the sort of thing that would have broken it,
and its removal (see "Numbers, whole") is what retired the risk.

### Costs and open questions

- `Partial` array members become `StreamArray<Element>` rather than `[Element]`. Macro generated, but
  visible to anyone reading a partial, and the 82 recorded per byte state sequences are written
  against array literals — `Equatable` plus `ExpressibleByArrayLiteral` should keep them compiling.
  This is the API cost of the whole plan. It also reaches `Array.Partial`, a public typealias, so it
  is not confined to generated members.
- `Array`'s `StreamParseableRoot` conformance and `_streamAppendElement` go, since leaving them would
  leave a live path that writes into an `Array` buffer through a raw pointer, which is the hazard
  this replaces.
- `streamSnapshot()` comes out of the protocol entirely: a plain value copy is a correct snapshot
  once every container is one of these, so the requirement, the macro's member wise implementation
  and the recursive rebuild all go together.
- The container grows by one inline element, since `pending` is stored rather than referenced.
  Bounded by the depth cap of 64.
- `RangeReplaceableCollection` is a question rather than a given. A general `replaceSubrange` on a
  blocked structure can rebuild from a flat array, leaving only `append` specialised, but it may be
  better not to conform than to conform slowly.
- `Sendable` needs `@unchecked` with the copy on write argument written out, as `Array` itself
  relies on.
- B is a tuning knob and nothing here measures it — 32 was assumed throughout. The spine result
  removes the pressure toward large B, leaving only the O(B) commit after a snapshot, which argues
  for smaller. Worth a sweep once the real type exists.
- Whether a block should ever be sealed early — on snapshot rather than when full — which would make
  a commit O(1) after a snapshot instead of O(B), at the price of variable length blocks and a
  binary search over prefix sums for every subscript. Against: reads are what this is for.
- `Mirror` renders the blocks, tail and pending slot into every custom dump and recorded snapshot,
  so the type needs `CustomReflectable` to read as a collection — guarded, since `Mirror` is outside
  the embedded subset. Done.
- `StreamDictionary` needs the same treatment. It has the pending slot, so it is correct; its
  storage is still flat. That is the next section.

A chunk size knob remains the cheapest lever and needs none of this: cost is exactly linear in
snapshot count, so 64 B chunks turn 20 ms into 477 µs. "Snapshot on element boundaries" is the
version worth offering, since it coalesces naturally and gives states that mean something.

---

## Next: StreamDictionary

Phase 8 gave `StreamDictionary` an open entry slot, because removing `streamSnapshot()` made its
absence a correctness bug rather than a performance one. What it did not do is change the storage
behind that slot:

```swift
public struct StreamDictionary<Value> {
  var storedKeys: [String]      // flat
  var storedValues: [Value]     // flat
  var pendingKey: String?       // done in phase 8
  var pendingValue: Value?      // done in phase 8
  var pendingSlot: Int          // done in phase 8
  var index: [String: Int]?     // flat, and the interesting one
}
```

So a kept state shares three buffers, and the next committed entry copies all of them in full. The
array measurements say what that costs: the same shape of problem, one order of magnitude smaller
because a dictionary entry commits once per key rather than once per element.

### The two easy fields

`storedKeys` and `storedValues` become `StreamArray<String>` and `StreamArray<Value>`, and
everything the array work established carries over unchanged: an append while shared copies one
block instead of the whole buffer, a snapshot's copy retains one buffer object per field, and the
cost is per divergence point rather than per retained state. Committing a repeated key writes
`storedValues[slot] = value` through the checked subscript, which copies the one block it lands in.

Their own `pending` slots go unused, since the dictionary keeps its open entry in its own inline
pair — it has to, because `StreamArray.pending` can only express a *new* element and a repeated key
has to resume in the slot it already occupies. Two unused `Element?` slots is the price and it is
the right one; collapsing the two levels of pending would mean teaching `StreamArray` about a case
only the dictionary has.

**The alternative of one `StreamArray<Entry>` is rejected on scan locality.** Interleaving keys and
values halves the block bookkeeping, but the linear key scan is the thing this type is fastest at —
1.3 ns against 9–10 ns for `Dictionary` — and striding it over `Value` sized elements is how that
gets lost. Keys stay in their own contiguous run.

### The index: measured, and `Dictionary` loses outright

`index` is a `[String: Int]` built once the entry count passes eight. Appending a key to a shared
one copies *and rehashes* the whole table, so under retention it is O(n) per key and O(n²) per
parse — which is the cost phase 8 removed from arrays, reintroduced by one field.

The question was framed as a crossover: how many keys before an index beats a scan. The measurement
answered a different question, because **a byte keyed index over flat `Int32` arrays beats
`[String: Int]` at every size and on every axis**, which makes the crossover a detail. ns per
lookup, p50, absent keys generated in the same shape and length as present ones so a miss is not
rejected for free by a length check:

| strategy | hit 8 | hit 32 | hit 128 | hit 512 | miss 512 | build 512 |
| --- | --- | --- | --- | --- | --- | --- |
| materialising scan (today's) | 26.0 | 59.9 | 179.7 | 664 | 1328 | 670 |
| span scan | 15.6 | 27.3 | 85.9 | 320 | 621 | 322 |
| leading word scan | 10.5 | 11.7 | 34.5 | 111 | 199 | 121 |
| whole key hash scan | 15.6 | 16.9 | 47.9 | 143 | 254 | 125 |
| `[String: Int]` | 41.6 | 33.8 | 34.8 | 35.2 | 46.9 | 119 |
| **flat chained index prototype** | **15.6** | **13.0** | **12.4** | **14.2** | **10.1** | **39.1** |

Those keys differ from the first byte, which is what an object's field names look like. Repeating it
with keys that all share their first eight bytes — `key_number_N`, which is what the counts payload
actually produces — kills the leading word and leaves everything else standing:

| strategy | hit 8 | hit 32 | hit 128 | hit 512 |
| --- | --- | --- | --- | --- |
| span scan | 20.8 | 43.0 | 132.8 | 549 |
| leading word scan | 26.0 | 46.9 | 148.4 | 639 |
| whole key hash scan | 15.6 | 18.2 | 47.9 | 143 |
| `[String: Int]` | 41.6 | 37.8 | 37.5 | 37.1 |
| **flat chained index prototype** | **15.6** | **15.6** | **17.3** | **17.3** |

**A leading word is the wrong prefilter for dynamic keys.** It is the right one for the schema
layer, where the keys are a struct's field names and differ early; a dictionary's keys are data and
routinely share a prefix. A whole key hash costs one walk over the span and cannot be fooled.

The chained rows above are the flat-array prototype, not the shipped dictionary. The benchmark now
also registers `StreamDictionary` itself under `StreamDictionary (String lookup)`, so changes to
the real open-addressed table cannot silently be measured only against a copy. That isolated row
uses the public `String` subscript and therefore includes String materialization; the parser's
borrowed-span path remains represented by the end-to-end `Dictionary` benchmarks below.

The crossover the plan asked for does exist, for the options that keep no index at all: a scan
matches `[String: Int]` at ~32 keys with prefixed keys and ~128 with diverse ones. Against the parse
it is smaller than it looks, because the discarding parse costs ~1.1 µs per key — dropping the index
entirely would cost ~9% at 128 keys and ~43% at 512.

Parse level, `BenchmarkCounts` byte fed, which is the retention half:

| keys | discarding | window 16 | snapshot per byte |
| --- | --- | --- | --- |
| 8 | 9.3 µs, 13 mallocs | 19.0 µs, 21 | 17.0 µs, 21 |
| 32 | 35.0 µs, 19 | 82.0 µs, 92 | 73.0 µs, 92 |
| 128 | 141 µs, 25 | 391 µs, 380 | 356 µs, 380 |
| 512 | 601 µs, 31 | 2.37 ms, 1532 | 2.30 ms, 1532 |

**Three mallocs per key under retention**, one per flat buffer per divergence point, exactly the
shape the array work removed. The time ratio climbs with n — 2.0x at 8 keys, 3.9x at 512 — which is
the quadratic term. The discarding row is flat per key, so today's index is doing its job on the hot
path and the cost is entirely in what a kept state shares.

So the four options the plan listed are settled without needing to choose between them. Boxing the
index in a class and copying it on write are both moot, because the structure that replaces
`Dictionary` is two `Int32` arrays rather than a hash table. Per block indexes are unnecessary,
because only one of those arrays is randomly written. And dropping the index is not free enough to
prefer.

### The index: one table, one entry buffer

A lookup hashes the span once, probes a flat slot table, and compares a stored `UInt64` before it
touches any bytes. The key and its hash live in one buffer, and the table is open addressed, both
for the same reason: **what a retained state pays tracks the number of buffers it shares, not their
size.** That was not the starting design, and the measurement that changed it is below.

What makes it fit this type rather than merely being faster:

- **One randomly written field.** `table` is `Int32` slots, so a commit while shared copies four
  bytes per slot with no hashing and no refcount traffic — against `[String: Int]`, which rehashes
  every key and retains every `String`.
- **The stored hash doubles as the rebuild source.** Growth rebuilds the table from the entries'
  hashes in one pass and never looks at a key again.
- **Insertion order survives.** The table maps a key to a slot; `entries` is still the order the
  keys arrived in. Making the dictionary unordered was on the table as the price of fixing this,
  and it turns out not to be one.
- **No `Dictionary` in the core.** FNV-1a over a span is a loop and a multiply, which is inside the
  embedded subset with nothing to verify.
- **`Sendable` stays checked.** Every field is a value type, so nothing is asserted.

**A fixed hash is a hash flooding surface, and the bound is the reason it is acceptable.**
`Dictionary` seeds `Hasher` per process precisely so that crafted keys cannot force every entry into
one bucket; FNV-1a with a fixed basis can be collided deliberately by anyone who can choose the keys
in a payload, which for a streaming parser is any untrusted input. What stops that from mattering is
that a fully collided chain **degrades to the whole key hash scan row above**, since the chain walk
compares a `UInt64` per step and only falls through to bytes on a match: 143 ns at 512 keys rather
than something unbounded. The attack buys a factor of ten on a path that is 1% of the parse.

#### Shape

```swift
@usableFromInline
struct StreamDictionaryEntry: Hashable, Sendable {
  @usableFromInline var hash: UInt64
  @usableFromInline var key: String
}

public struct StreamDictionary<Value> {
  // The key and the hash that guards it, in one buffer so a probe reads one cache line and a
  // retained state copies one thing.
  @usableFromInline var entries: ContiguousArray<StreamDictionaryEntry>
  @usableFromInline var storedValues: [Value]

  // Open addressed slot table, -1 where empty, held at half load since linear probing degrades
  // sharply past that. Nil below the threshold, where a scan over `entries` measures the same and
  // costs no table at all.
  @usableFromInline var table: ContiguousArray<Int32>?

  // The open entry. `pendingSlot` is -1 when none is open, an existing slot when the key repeats,
  // and `storedValues.count` when it is new. `pendingKey` and `pendingHash` are needed only in
  // that last case, which is what keeps a repeated key from materialising a `String` at all.
  @usableFromInline var pendingKey: String?
  @usableFromInline var pendingValue: Value?
  @usableFromInline var pendingHash: UInt64
  @usableFromInline var pendingSlot: Int32

  @usableFromInline static var indexThreshold: Int { 8 }
}

extension StreamDictionary {
  // One walk over the span, no `String`. The fixed basis is what makes this available to embedded;
  // see the flooding note above for why that is affordable.
  @usableFromInline static func hash(_ key: UnsafeBufferPointer<UInt8>) -> UInt64

  // Compares the stored hash, then the bytes. `table == nil` scans `entries` directly, which is the
  // same comparison without the probe.
  @usableFromInline func slot(forKey key: UnsafeBufferPointer<UInt8>, hash: UInt64) -> Int32?

  @usableFromInline mutating func append(_ value: Value, forKey key: String, hash: UInt64)
  // Takes the first free probe for a key already known to be absent, which is what lets it stop at
  // the first empty rather than comparing anything.
  @usableFromInline mutating func claim(slot: Int32, hash: UInt64)
  // Rebuilt from the entries' stored hashes, so growth hashes nothing and never looks at a key.
  @usableFromInline mutating func rebuildTable()
}

extension StreamDictionary {
  /// Commits the open entry and opens one for `key`, returning the address of its slot.
  ///
  /// Hashes the span, resolves the slot, and materialises a `String` only when the key is new.
  @inlinable
  public mutating func _openValue(
    forKey key: Span<UInt8>,
    initial: @autoclosure () -> Value
  ) -> UnsafeMutableRawPointer
}
```

#### Built, and both structural guesses were wrong

The plan said to block `storedKeys` and `storedValues` the way `StreamArray` blocks an array's
elements, and to chain the index through a `heads`/`next` pair. Both were built and measured, and
both lost. p50 wall clock on the byte fed `BenchmarkCounts` sweep, mallocs at 128 keys retained:

| configuration | buffers | disc. 128 | disc. 512 | window 16 @128 | mallocs |
| --- | --- | --- | --- | --- | --- |
| `[String: Int]`, flat (before) | 3 | 141 µs | 601 µs | 391 µs | 380 |
| chained index, every field blocked | 5 | 287 | 1190 | 713 | 654 |
| chained index, every field flat | 5 | 135 | 558 | 427 | 637 |
| **one table, merged entry, flat** | **3** | **132** | **549** | **359** | **380** |

**Blocking the storage cost 2x on the discarding path**, which is the row that matters most because
it is the path that always runs. The reason is a difference between the two containers that the plan
read straight past: an array is written and never read back while parsing, so a block indexed
subscript costs nothing on the hot path — but a dictionary *reads its own storage on every lookup*,
so every key comparison pays the sealed count, the shift, the mask and a block retain. Blocking is
right for a container the parser only appends to, and wrong for one it searches.

**And a retained state's cost tracks buffer count, not buffer size.** Going from three flat buffers
to five — keys, values, hashes, next, heads — took retention mallocs from 380 to 637 even with every
field flat, because copy on write fires once per buffer per divergence point regardless of how many
bytes each holds. That is what rules out parallel arrays here and what makes the hash travel inside
the entry and the chain collapse into one open addressed table. Three buffers in, three buffers out,
and the malloc counts come back **identical to the old implementation at every size** — 13/19/25/31
discarding, 21/92/380/1532 retained — which is the check that the structure really is the same shape
and only the contents changed.

Against the old implementation, the shipped version is 6–9% faster discarding at 128 and 512 keys,
parity at 8 and 32, 7% faster on the long key payload (264 → 246 µs), and 8–19% faster under
retention (391 → 359 µs at 128, 2.37 → 1.91 ms at 512). Every array, document and Twitter benchmark
is unchanged.

The end to end win is far smaller than the 3x the lookup microbenchmark shows, and that is expected
rather than disappointing: the discarding parse costs ~1.1 µs per key, so a lookup that goes from 37
ns to 13 is worth a few percent of it. **The reasons to have done it are the ones that are not
speed** — `Dictionary` is out of the core, a repeated key no longer materialises a `String`, and
`Sendable` stays checked.

**The retention quadratic is reduced, not removed.** Three flat buffers still copy in full per
divergence point, so 512 keys retained is still 3.5x its discarding parse against 2.5x at 32 keys.
Blocking was the plan's answer and it costs more on the hot path than it saves on the cold one. The
way out, if it ever matters, is that **the table is derivable state that only the live parse needs**
— a snapshot could scan. Holding it in the sink's frame rather than in the value would remove it
from every copy, at the cost of giving frames owned storage and a lifetime, which they do not have
today.

### On the hot path, not just under retention

`_openValue` decodes the key span into a `String` only for a new key. Past fifteen bytes the old
implementation paid an allocation per occurrence on the discarding path, where nothing is retained
at all. The open-addressed index removes it rather than needing separate work: the probe compares
hashes and then bytes, so a repeated key never becomes a `String`. The older chained row is retained
below only as a structural comparison. Measured on 36 byte keys at 128 entries, per lookup:

| | ns | mallocs |
| --- | --- | --- |
| `[String: Int]` | 125.0 | one per lookup |
| materialising scan | 414.1 | one per lookup |
| **flat chained index prototype** | **40.4** | **none** |

### Plumbing the array pass established

- `RandomAccessCollection` rather than `Collection`. Indexing is O(1) once the storage is blocked,
  and the conformance is free.
- `CustomReflectable`, for the same reason `StreamArray` needed it, and with evidence: the phase 8
  test failures printed `StreamDictionary(storedKeys: […], storedValues: […], index: nil)`, and it
  would now print the three pending fields as well. It should read as a dictionary.
- `Codable`, guarded, so a partial with a dictionary member encodes the way `StreamArray` does.
- `keys` and `values` allocate an array each since phase 8 changed them from stored property
  returns to `map`. They should be lazy projections, not copies.
- `Sendable` stays checked as long as the index does not become a class — one more entry on that
  side of the ledger.

### Behaviour pinned first (done)

`ContainerReentryTests` and `SnapshotStabilityTests`, 28 cases, written before touching the
storage so the conversion has something to diverge from. Two of the three things they were meant
to record turned out differently than expected, and one of them is a bug.

**Re-entry is one rule for containers and two for scalars.** A repeated key whose value is a
container *resumes* the container the first occurrence built, in all four places it can happen: an
array field, an object field, a dictionary field, and a dictionary value. A repeated dictionary key
keeps its original slot, so `{"a":[1],"b":[9],"a":[2]}` gives `["a": [1, 2], "b": [9]]` with the
order intact. `StreamSchema.enterField` claimed to reset the container; it never has, and the
comment is corrected.

Scalars do not agree with each other. A repeated **number replaces**, because applying a number
assigns. A repeated **string concatenates**, because applying a string appends and a second
occurrence is indistinguishable from a second chunk of the first — so `{"name":"first",
"name":"second"}` reads back as `"firstsecond"`. Nothing chose that; it falls out of
`streamApply`. It is recorded rather than endorsed.

**A container arriving at a scalar dictionary value leaks its elements into the value.** Everywhere
else this is discarded: a scalar root substitutes the discarding schema, and a scalar object field
yields no frame so the subtree is skipped. `PartialSink.valueTarget` hands back the frame `enterKey`
produced without checking that its shape can hold a container, so the array is entered carrying the
*scalar's* schema and every element is written straight into it, last one winning:

```swift
try parse(#"{"a":[2,3]}"#, as: StreamDictionary<Int>.self)   // ["a": 3], should be ["a": 0]
```

Not a re-entry problem — it happens on the first occurrence — and not new, but the dictionary is
the only destination that does it. The other two only discard by accident of returning nil; neither
checks anything. The fix is a shape check in the `.dictionary` case of `valueTarget`, and it belongs
with this work rather than before it, since that function is what the rework touches. Pinned to the
current answer in the meantime, marked as recording a bug.

#### Fixed, and it was never dictionary specific (done)

The suspicion recorded in step 6 below was right and understated. Probing every destination a
container can reach found **six leaking sites, not one**, and the dictionary was merely the one
that had been noticed:

| destination | input | was | is |
| --- | --- | --- | --- |
| `StreamArray<Int>` element | `[[2,3]]` | `[3]` | `[0]` |
| `StreamArray<Int>` element | `[{"a":1}]` | `[1]` | `[0]` |
| `StreamArray<StreamArray<Int>>` | `[{"a":1}]` | `[[1]]` | `[[]]` |
| `[Int]` object field | `{"values":{"a":1}}` | `[1]` | `[]` |
| `StreamArray<Int>` root | `{"a":1}` | `[1]` | `[]` |
| `StreamDictionary<Int>` value | `{"a":[2,3]}` | `3` | `0` |

**The mechanism is broader than a missing check on a dictionary value.** A scalar frame ignores
keys and applies every token to itself, so *any* container reaching one has its contents written
straight in. An array frame is the same one level up: an object reaching it has its values appended
as elements, because `key` sets a `pendingField` the array schema never reads and the values then
resolve through `appendElement`. So mismatched container *kinds* leak as well as containers at
scalars, which the plan did not anticipate at all.

The root cause is one line: `enterContainer(shape:)` took the container kind and never looked at
it. The fix is `Shape.canHold(container:)` — an object reaches an object or a dictionary, an array
reaches an array, a scalar reaches nothing — tested once in `enterContainer`, covering the root
case and `valueTarget`'s three cases together. Malloc and retain counts are unchanged at every
benchmark, which is the check that a per container branch costs nothing measurable.

**A discarded container still leaves the slot its target resolution materialised.** Resolving the
target is what appends the element or creates the key, and it happens before the shape is known, so
`{"a":[2,3]}` gives `["a": 0]` rather than `[:]`. That is the same behaviour the entry gap below
describes, and the fix now depends on it rather than merely tolerating it.

**The opposite pairing already worked, and is now covered.** When the container shape is right and
the *contents* are wrong — `["a","b"]` into a `StreamArray<Int>`, `{"a":"x"}` into a
`StreamDictionary<Int>` — the destination matched and then refused the token, so it throws
`.typeMismatch` at every depth. That was true before the shape check and was only tested through
object fields; elements and dictionary values resolve through different branches of
`resolveScalarTarget` and now have their own cases. A rejected element leaves its slot at the
initial value and parsing stops there, so `[1,"a",3]` throws holding `[1, 0]` — the same rule as a
discarded container, for the same reason.

**`null` is accepted exactly where the destination is optional**, which was never written down.
It is not special cased anywhere; it goes through `applyNull` like every other token, so it lands
on whether the destination can represent absence. Every member of a macro generated `Partial` is
optional, so `{"count":null}` clears the field; a `StreamArray<Int>` element is an `Int` with
nowhere to put it, so `[1,null]` is a mismatch. `StreamArray<Int?>` accepts it. The split follows
the types rather than the container kind, which is why it is worth stating rather than fixing.

**Discarded, not rejected**, which leaves a real asymmetry: a *scalar* arriving at a container
destination throws `.typeMismatch`, while a *container* arriving at a scalar destination is silent.
Neither answer was chosen — the first falls out of `applyNumber` returning false, the second out of
the object path resolving to no frame. Making both throw is possible everywhere except an object
field, where `enterField` returns nil for a key the destination lacks and for a scalar field alike,
so the two cannot be told apart. Rather than make objects the one shape that stays quiet, everything
stays quiet. Recorded as an open question, not as a decision worth defending.

**Snapshot stability composes at every shape tested, unchanged.** Every state of a byte fed parse
compared against a rendering of itself taken when it was handed out — arrays, nested arrays, arrays
across a block seal, dictionaries, dictionaries of arrays, dictionaries of dictionaries, arrays of
dictionaries, a dictionary of arrays of arrays, macro generated partials with both container kinds,
and states taken before a repeated key writes into a slot they hold. This is the test the original
differential could not be: it compares sequences rather than final values, which is precisely why
the `partials()` bug survived it.

### Duplicate keys: resume

Decided: a repeated key keeps resuming the value already stored under it, which is what the reentry
tests pin and what the shipped implementation does. `storedValues[slot] = value` is the one write
that lands below the frozen line, and it is safe because the parser only ever writes `pendingValue`,
which is inline. The alternatives were weighed and are recorded here because the argument for them
survives the decision:

- **Reject.** Storage becomes strictly append only, and no frame ever points into it. It does not
  remove the lookup, since detecting a duplicate *is* the lookup. RFC 8259 permits repeated names
  and every other parser accepts them, so this is the one place the library would refuse a document
  that `JSONSerialization` takes.
- **Shadow.** Append the repeat and let it hide the earlier slot. Append only without rejecting
  anything, and **lookup is free**: a chain is newest first, so the first match is already the live
  one. The cost is iteration — `count`, `keys`, `values` and the positional subscript have to skip
  shadowed slots, which without metadata is O(n) per entry. One `duplicateCount` field fixes it:
  zero in the common case, so iteration stays a straight walk and only pays when a duplicate
  actually arrived. A per slot `shadowed` bit would be the obvious alternative and is the wrong one,
  since setting it writes into a sealed slot, which is the thing being removed.

Shadowing is a **semantic change, not a storage one**, which is what settled it: `{"a":[1],"a":[2]}`
would become `[2]` rather than the pinned `[1, 2]`, because the second occurrence starts a fresh
container instead of resuming. That is last one wins, which is what most parsers do, and it
incidentally fixes the string concatenation the reentry tests recorded as unendorsed —
`{"name":"first","name":"second"}` would read `"second"` rather than `"firstsecond"`. Rewriting
behaviour that 28 cases were just written to pin is not something to do as a side effect of a
storage change, so it stays available and unspent.

### Order

1. ~~Pin the behaviour, so the conversion has something to diverge from.~~ Done.
2. ~~Measure what the index buys, then resolve it.~~ Done: the flat chained prototype above, which
   also answered the key materialisation question; the shipped implementation is the one-table
   open-addressed index described below.
3. ~~`storedKeys` and `storedValues` to `StreamArray`.~~ Built, measured, reverted: blocking costs
   2x on the discarding path, for the reason recorded above. The storage stays flat.
4. ~~The index, and `_openValue` rewritten around a span lookup.~~ Done, with the sweep re-run.
5. ~~Resolve duplicate keys.~~ Resume.
6. ~~The `valueTarget` shape check, which may not be dictionary specific.~~ Done, and it was not:
   six sites leaked rather than one, including mismatched container kinds, which the plan did not
   anticipate. One check on `Shape.canHold(container:)` in `enterContainer` covers all of them. See
   the section above.
7. ~~Plumbing, and a `StreamDictionary` line in `EmbeddedSmoke`.~~ The type/init smoke links; a
   deeper embedded `_openValue` smoke is blocked by the embedded Swift runtime's missing Unicode
   normalization symbols when a new key would be materialized.

---

## Adversarial round: string shapes, whitespace, and two blind spots

The long string benchmark is a memcpy by comparison — one SIMD run the length of the body — so
the string shapes that defeat the run scanner were measured, each sized to the same ~8 KB. p50,
MB/s:

| payload | bulk | 64 B chunks | byte by byte |
| --- | --- | --- | --- |
| Long string (control) | 9655 | — | — |
| Escaped string, every third byte `\n` or `\t` | 369 | 321 | 161 |
| Unicode escaped, everything `\uXXXX`, half surrogate pairs | 390 | 337 | 200 |
| Non-ASCII, mixed 2/3/4 byte sequences | 1347 | 1003 | 168 |
| Pretty printed users | 652 | 554 | 160 |
| Array of structs, compact (control) | 459 | — | 147 |

- **Escape density is a 26x cliff, and still clears the target.** Roughly 8 ns per escape across
  the state transitions, the scratch emission and the extra sink call. For escape heavy input the
  number worth quoting is ~370 MB/s.
- **The full UTF-8 validator costs 7x against the ASCII prefilter and is not a bottleneck.**
  1.35 GB/s bulk. Byte fed non-ASCII lands with every other byte fed payload, so the pending
  sequence path is a correctness problem (below), not a performance one.
- **Whitespace is settled: the scanner stays scalar.** The same content pretty printed costs
  17 µs against 14 µs compact — indentation is skipped at ~1.5 GB/s by the plain loop, so a SIMD
  whitespace scanner would buy ~2 µs on an 11 KB payload. Measured so it stops being a question.
- **The Twitter model mismatch never moved the number.** A matched keys model (`screen_name`,
  `followers_count`) measures identically — 22 ms, 566 mallocs, 29 MB/s byte fed, both ways —
  because the two writes it adds are an inline small string and an `Int`. The mismatch distorted
  what the benchmark meant, not what it measured. Both models stay registered so that stays true,
  and the runners now trap on a parse failure instead of `try?` scoring an aborted parse as fast.

### Bugs found by the same pass

The conformance corpus had two blind spots: its invalid UTF-8 cases were the only ones never
parsed byte by byte, and no case put an escape inside an object key. Both hid real bugs, pinned
in `AdversarialConformanceTests` and fixed in the section after this one:

- **A key whose first character is an escape is rejected.** `{"\n":1}` and `{"\u0041":1}` fail
  with `unexpectedToken`, parsed whole or split at any position. `consumeStringRun` drops the
  key/string distinction on entering the escape state, and `emitScratch` recovers it from
  `bufferCount > 0` — which is false exactly when the escape is the key's first character, so the
  decoded byte is emitted as string content and the rest of the key parses as a string value. The
  `state == .inKey` test there is dead code: the state is `.escape` or `.unicode` at every call.
- **Invalid UTF-8 is accepted whenever the sequence straddles a chunk boundary, which includes
  all byte fed input.** `completePendingUTF8` reassembles a held sequence and emits it without
  validating, and consumes continuation bytes blindly — overlongs, encoded surrogates and out of
  range leads all pass when split after the lead byte, and `"\xC3` followed by `"` swallows the
  closing quote as a continuation byte, turning a document rejected whole into one accepted
  split.
- **Almost pairs of surrogate escapes are accepted.** A second `\uD800` silently overwrites a
  pending high surrogate, and a simple escape between a high and a low does not sever the pair —
  `"\uD800\n\uDC00"` parses, with the `\n` emitted before the combined scalar, reordering the
  content.
- **Error offsets are chunk relative.** `error(_:)` reports `consumedByteCount`, which only
  advances at the end of `parse`, so every error names the offset of the chunk it was thrown in
  — byte 0, for a whole document parse. `checkSink` gets it right by adding the loop index;
  `finish` then adds `consumedByteCount` to itself. Diagnostics only, and wrong everywhere.
- A number longer than the buffer parses in bulk, where it stays contiguous in the input, and
  throws `bufferExhausted` byte fed, where it must be accumulated: the same document accepted or
  rejected by feed granularity. Keys at least fail both ways.

### Fixed, and what the fixes cost

The three acceptance bugs are fixed, the suite that pinned them is green alongside the other 337,
the corpus's invalid UTF-8 cases now split like everything else, and `EmbeddedSmoke` builds and
passes under wasmer with the fixed core.

- The key/string distinction is a stored `isKeyToken`, set at each opening quote, replacing the
  `bufferCount > 0` inference that failed for a key opening with an escape. `stateAfterEscape`
  and `emitScratch` read it, and the dead `state == .inKey` test is gone.
- `completePendingUTF8` admits only continuation bytes — a structural byte now ends the sequence
  instead of being swallowed — and validation splits across the boundary: the hold rejects
  invalid leads before holding anything, completion checks the second byte constraints. Routing
  the assembled sequence through the contiguous validator instead cost 32% of byte fed non-ASCII
  throughput, almost all of it the ASCII prescan, so the split is measured rather than stylistic.
- A pending high surrogate is checked at every event that can follow it — a simple escape, a
  second high surrogate, a non surrogate scalar, a content run, the closing quote — so a severed
  pair is rejected at the escape that severs it rather than accepted, reordered, or caught late.

Costs are measured against pristine controls stashed and run in the same session, because the
first session's numbers had drifted: the same pristine parser that measured 188 MB/s on byte fed
Twitter measures 141 in this one. p50 MB/s:

| | pristine control | fixed |
| --- | --- | --- |
| Twitter, byte by byte | 141 | 142 |
| Twitter, bulk | 730 | 730 |
| Non-ASCII string, byte by byte | 158 | 142 |
| Escaped string, bulk | 357 | 334 |
| Unicode escaped string, bulk | 378 | 377 |

Two costs are real: ~10% on byte fed non-ASCII, which is validation existing where there was
none, and ~7% on escape dense strings, one load and branch per escape for the severed pair
check. Twitter, which is both at once, pays nothing measurable.

Still open from the list above at the time: the chunk relative error offsets, since fixed (see
"Numbers, whole"), and the long number feed asymmetry, which remains — a number longer than the
buffer parses in bulk and throws `bufferExhausted` byte fed.

### The gap between the convenience layer and the sink

Twitter, p50, the same payload on every row:

| | bulk | byte by byte |
| --- | --- | --- |
| fast interface, counting sink | 719 MB/s | 188 MB/s |
| convenience layer, discarding | 296 MB/s, 293 mallocs | 29 MB/s |
| gap | 2.4x | 6.5x |

The gap tripling as chunks shrink is the diagnostic: per token costs amortize with chunk size and
per byte costs do not. The known per byte cost is `String.streamAppend`, which is
`self += String(decoding:)` — a whole `String` materialized per chunk, re-validating UTF-8 the
parser already validated, which bulk pays once per run and byte fed pays once per content byte.
The counting sink row is the floor.

### Plumbing is not the gap

The first theory tried was sink plumbing: the whole frame copy and write back in `key(_:)`
replaced with an in-place `pendingField` write, cached scalar targets holding the one apply
closure a token repeats instead of a schema reference so that copying a target touches no
refcount, and `stringBegin`'s temporary allocation for its empty probe span removed. Built,
measured, and reverted. p50, retains:

| Stream, discarding | baseline | all trims | minus thin targets |
| --- | --- | --- | --- |
| Array of structs, bulk | 75 µs, 2103 | 75 µs, 2204 | 81 µs*, 2303 |
| Array of structs, byte fed | 325 µs, 2003 | 324 µs, 2104 | 338 µs*, 2203 |
| Flat struct | 5.2 µs, 45 | 5.2 µs, 48 | 5.3 µs, 47 |
| Long string, byte fed | 500 µs, 15 | 506 µs, 15 | 509 µs, 17 |

*Noisy run — p100 spiked to milliseconds — but the retain counts are exact.

**Wall clock never moved beyond noise, and every trim added retains.** Reading a closure out of
the schema class copies its context, which is a retain the cached reference never paid. The frame
copy and write back per key compiles to nothing. A control run on the pristine file afterward
reproduced the baseline to the retain, so the counts are deterministic and the differences were
real: ARC already elides every copy the trims were aimed at, and the sink's plumbing is optimal
in exactly the ways it looks wasteful.

What the Long string row proves is where the gap actually lives. An 8 KB string fed byte by byte
costs 500 µs with fifteen retains and thirteen mallocs — ~61 ns per content byte of pure
`String.streamAppend`, with nothing else on the path. Scalar conversion is the gap; the plumbing
around it is free.

### The append itself, isolated

`String.streamAppend` re-validates UTF-8 the parser already validated, so skipping that walk via
`String(unsafeUninitializedCapacity:)` was the surviving cheap theory. Measured against today's
`+= String(decoding:)` and against accumulating raw bytes and materializing once, which is the
floor any accumulation redesign would buy. p50, `StringAppendBenchmarks`:

| 8 KB ASCII accumulated | `+= String(decoding:)` | unsafe init | byte buffer |
| --- | --- | --- | --- |
| by 1 B | 194 µs | 242 µs | **35 µs** |
| by 64 B | 13 µs | 14 µs | **1.9 µs** |
| by 4096 B | 792 ns | 792 ns | 792 ns |
| fresh 14 B token, one append | 83 ns, 0 mallocs | 83 ns | — |
| fresh 23 B token, one append | 167 ns, 1 malloc | 208 ns | — |

**Validation is not the cost either.** The unvalidated construction is identical at every size
that matters and *worse* at one byte, because its setup overhead exceeds the ASCII validation it
skips — `String(decoding:)`'s ASCII path is already a memcpy. What costs is the fixed ~20 ns of
per call append machinery, which vanishes into the copy at 4 KB and dominates at 1 B.

So the split is clean:

- **At 4 KB chunks there is nothing left to win inside `streamAppend`.** All three strategies
  measure identically. The convenience layer at realistic chunk sizes is bounded by per token
  costs — one intermediate `String` and one heap allocation per 15+ byte field — which the fresh
  token rows put at 83–167 ns, and which no change short of not producing a `String` removes.
- **At small feeds only two things win, and both change where bytes accumulate**: batching in the
  sink and flushing per token or per read turns the 1 B column into the 64 B column, ~15x on the
  append path; a byte buffer accumulation type is worth another 7x past that and is the only lever
  that also touches bulk. That is the `StreamString` discussion, parked as an API question — the
  measurements here are what it would buy.

---

## Numbers, whole: greedy scan, structured parse

Per digit reporting is gone. A number is emitted exactly once, complete, at its token's end.
Part-boundary emission — the integer part at the first `.` or `e`, then the final value — was
the intermediate design, and it died on the exponent case: `1.5e2` still jumps from 1.5 to 150
at the delimiter, so the provisional value is still a different number, just less often. Whole
emission also removes the per digit sink call, the sink's number target machinery, and the last
provisional writer the "no write may straddle a commit" invariant had to worry about.

What whole emission buys structurally: the scan no longer needs to accumulate anything, so
finding the token and parsing it separate cleanly, and the parse can look at the whole token at
once. Strategies measured on 512-token corpora, ns per number, p50:

| strategy | small 1–4d | medium 5–10d | large 17–19d | decimals | exponents |
| --- | --- | --- | --- | --- | --- |
| fused scalar (the old shape) | 19.5 | 41.0 | 91.8 | 31.2 | 27.3 |
| two-pass scalar | 15.1 | 27.3 | 56.6 | 18.1 | 23.4 |
| two-pass SWAR8 | 15.7 | 25.4 | 33.2 | 18.9 | 23.4 |
| greedy scalar | 13.4 | 25.4 | 54.7 | 17.7 | 19.5 |
| greedy SIMD16 | **12.6** | 23.4 | 50.8 | **16.9** | **19.5** |
| **greedy SIMD16+SWAR8** | 13.4 | **16.9** | **23.4** | 19.5 | 21.5 |

**The fused per byte loop loses to everything once it no longer has to emit.** The original
measurement that installed it compared fused accumulation against a consumer re-scan under per
digit emission; with one emission per token the comparison inverts at every corpus size. The
shipped combination is the greedy SIMD16 class scan with 8-digit blocks in the digit runs: the
block costs 1–3 ns on short tokens against plain SIMD16 and pays 2.2x on 17–19 digit ids, which
is what a document id is. `NumberParseBenchmarks.swift` keeps all six variants registered and
cross-checks them against each other before timing anything.

### Digit block width

The block above began as a 64-bit SWAR conversion. `DigitAccumulateBenchmarks.swift` isolates
just the digit-run-to-integer step and walks the width, because a block tier only fires on runs
at least as long as itself. ns per digit run, p50, relative to SWAR8:

| strategy | 4d | 1–4d | 8d | 5–8d | 9–15d | 16d | 17–19d |
| --- | --- | --- | --- | --- | --- | --- | --- |
| scalar | 0.88x | 0.88x | 1.36x | 0.96x | 1.68x | 2.04x | 2.49x |
| SWAR4 | **0.71x** | 0.98x | 1.00x | **0.85x** | 1.01x | 1.15x | 1.26x |
| SIMD4 | 0.76x | 0.98x | 1.14x | 0.90x | 1.10x | 1.27x | 1.23x |
| SWAR8 | 1.00x | 1.00x | 1.00x | 1.00x | 1.00x | 1.00x | 1.00x |
| **SIMD8** | 1.00x | 1.00x | **0.93x** | 0.97x | 1.03x | **0.88x** | **0.87x** |
| SIMD16 | 1.01x | 0.98x | 1.50x | 1.11x | 1.72x | 0.82x | 0.79x |
| SWAR8+SWAR4 | 0.78x | 1.02x | 1.00x | 0.84x | 0.99x | 0.95x | 1.02x |
| SIMD16+SIMD8+SIMD4 | 0.90x | 1.12x | 1.00x | 0.95x | 1.10x | 0.92x | 0.96x |

**SIMD8 is the same 8-digit block through NEON lanes instead of GPR multiplies, and it wins
7–13% wherever the block fires with no penalty where it does not**, so it replaced the SWAR
form in `streamParseEightDigits`. Two results are worth keeping. Widening a whole vector up
front calls an out-of-line `SIMD16<UInt16>(truncatingIfNeeded:)`, and `all(mask)` lowers to an
out-of-line `SIMD.max()`; either one forces a stack frame onto the accumulate loop and costs
more than the block saves. Two-digit values still fit a byte, so the first reduction stage
stays in `SIMD8<UInt8>` and the all-lanes test is spelled as a 64-bit compare over a 0/1 lane
vector. The first draft measured *slower than scalar on runs the block never touched* before
that was fixed.

Wider is not better below 16 digits, and narrower does not reach: in `twitter.json` only 12.9%
of digit runs are exactly four long, since 1–3 digit runs outnumber four-digit ones four to
one, so a 4-wide tier idles on most of the short runs it was meant to serve. At four digits the
answer is also not SIMD but a narrower SWAR — Swift's `SIMD4<UInt8>` is a 32-bit vector the
compiler promotes to 16-bit lanes inside a stack frame. Ladders all land within 0.95–1.08x:
each extra tier costs a bounds check and a failed validation on the runs it cannot serve.

Keep the size of this in view. Digit accumulation is **~2.2% of a `twitter.json` parse**
(7823 digit runs at ~5.3 ns against 1949 µs), so the whole spread from scalar to the best block
is under 0.4% end to end, and SIMD8 over SWAR8 is ~0.03% — below run-to-run variance, and
confirmed as such: p0 held at 1878 µs across the swap. It was taken because it is free and
strictly better, not because it is visible.

The shape, in `consumeNumber`:

- **The boundary scan is greedy over the byte class** — digits, `.`, `e`, `E`, `+`, `-` —
  which makes it stateless: no booleans survive a chunk boundary, `resetNumber` is
  `bufferCount = 0`, and eleven parser fields are gone. Placement is not the scan's business.
- **The parse is one structured walk at the token's end**: sign, integer digits, fraction,
  exponent. The grammar is the segment order, so validation falls out of the walk — a byte the
  grammar has no place for fails the final position check instead of a tracked flag. Digit runs
  go through `streamAccumulateDigits`, wrapping-congruent with the scalar loop so overflowed
  magnitudes agree between paths.
- **A token that reaches the chunk's end is buffered whole** and parsed when its delimiter
  arrives, which replaced the old spanning path's byte-at-a-time copy with one append per chunk.
  Byte fed input pays a class test and a one-byte append per byte where it used to run the full
  state machine and a sink call per digit.

**The structured walk found an acceptance bug the per byte rules had:** `1e--2` and `1e+-2`
parsed, because each sign only checked that no exponent digit had arrived yet, and a second sign
still satisfied that. The walk has one place for a sign, so doubled signs are rejected by shape.
Pinned in `Rejects doubled exponent signs`.

Semantics that moved, all deliberate:

- A malformed token with trailing class bytes — `1.2.3`, `1-2`, `1e2e3` — is now one token
  rejected as `.invalidNumber` at its end, where the old rules emitted a valid prefix and then
  threw `.unexpectedToken` at the byte that broke them. The sink no longer sees a number the
  document does not contain on the way to an error.
- An open number contributes nothing to any emitted state: `[1,2` byte fed reads `[1]` until the
  token ends, where it used to read `[1, 2]` with 2 still growing. The 82 recorded per byte
  sequences were regenerated through the existing `STREAM_PARSING_RECORD` harness and re-audited:
  every array is still bytes + 1 long, and values land at their delimiters.
- Unchecked parsing (`validatesNumberGrammar: false`) takes the same walk without the guards and
  ignores trailing class bytes, degrading harmlessly as before.

### Error offsets: absolute, and independent of chunking

Fixed alongside, since `emitNumber` needed a position to report anyway. `error()` now takes the
chunk-local detection offset and adds `consumedByteCount`, so every error names the absolute
position of the byte it was detected at:

- Errors detected at a token's completion — a key validated whole, a number parsed whole — name
  the token's final byte, which is the same byte at every split.
- Invalid UTF-8 names the sequence's lead byte in both the contiguous validator and the
  reassembly path: a sequence held across a boundary reports `consumedByteCount` *minus* the
  bytes already held, so bulk and byte fed agree.
- `finish` reports end of input, and its `checkSink` call no longer adds `consumedByteCount` to
  a count that already contains it, which was the double-counting path.
- Sink-rejection offsets remain granularity-dependent by design: a sink records a failure and
  the parser reads it once per state machine step, so where it surfaces tracks the step.

`ErrorOffsetTests` pins both halves: the same `JSONParsingError` — reason and offset — at every
split position for a dozen malformed documents, and the exact detection byte for each error kind
in bulk, which previously reported 0 for all of them. The chunk boundary failure harness now
compares whole errors rather than reasons alone.

### Measured end to end

Same machine, same session, against a pristine control run. p50:

| benchmark | control | whole emission | |
| --- | --- | --- | --- |
| Fast Nested arrays, bulk | 21 µs, 188 MB/s | **17 µs, 231 MB/s** | +23% |
| Fast Nested arrays, byte fed | 44 µs, 90 MB/s | **39 µs, 101 MB/s** | +12% |
| Fast Dictionary, bulk | 5043 ns, 391 MB/s | **4667 ns, 424 MB/s** | +8% |
| Fast Dictionary, byte fed | 18 µs, 106 MB/s | **16 µs, 123 MB/s** | +16% |
| Fast Twitter, bulk | 901 µs, 701 MB/s | **862 µs, 732 MB/s** | +4% |
| Fast Twitter, byte fed | 4.58 ms, 137 MB/s | **4.24 ms, 149 MB/s** | +9% |
| Fast Array of structs, bulk | 14 µs, 442 MB/s | 14 µs, 460 MB/s | +4% |
| Fast Long string, bulk (control payload) | 917 ns | 917 ns | — |
| Stream Array of structs, bulk | 75 µs | **69 µs** | +8% |
| Stream Array of structs, byte fed | 325 µs | 331 µs | noise |
| Stream Twitter, bulk | 2.18 ms | **1.99 ms** | +9% |
| Stream Twitter, byte fed | 22 ms | 22 ms | — |

The cost lands where per digit reporting's cost did — number dense payloads — with the sign
flipped, and nested arrays finally clears the 17 µs the per digit table used as its "at token
end" column. The string payload is the control and does not move. The offset accounting costs
nothing measurable anywhere, which is what "arithmetic on the error path only" predicts.

What whole emission costs: byte fed consumers see nothing while a number token is open. A
consumer rendering a stream of large integers digit by digit lost that ability, and part
boundary emission is the design to revisit if one ever exists.
