# Progression

The record of every experiment run on the parser and its typed layer, landed and rejected, in
the order they were run. It begins with the rewrite of the parsing core around a push based sink
interface, which replaced the key path handler registration system (targets at the time: ~300
MB/s through the fast interface for chunked input, 30–60 MB/s byte by byte, and the whole core
usable from Embedded Swift), and continues through every change measured since.

Numbers were measured on arm64 (M1 Pro) unless a section says otherwise; the API-layer
evaluations at the end were run on x86_64 Linux. Where a decision went against intuition, the
measurement that settled it is recorded, because several of them are counterintuitive enough to
be re-litigated otherwise. A verdict goes in the section title (`Landed: …` / `Rejected: …`).

Each entry is kept brief: what changed, the verdict, the headline numbers and the tables that
measured it. The longer write-ups each entry was condensed from are in this file's git history
(as `NEW_ARCHITECTURE.md` before 2026-11-09).

Every section opens with the day it was recorded. Those dates come from git: each is the first
revision of this log (or, for the evaluations at the end, of the file they were first written in)
that contained the section. A section that was moved here from elsewhere, such as the design notes
relocated from source comments, is dated by the move, so its experiment may be older.

---

## Why

*Recorded 2026-08-11.*

The library started at **2.5–3.5 MB/s**, and profiling found the cost was not where it looked:

| assumption | reality |
| --- | --- |
| Key paths are the bottleneck | At ~800 cycles/byte, dispatch is single digit percent. |
| Branch misprediction matters | A naive byte-at-a-time switch already runs at 1520 MB/s, 5× the target. |
| Per-byte function calls are expensive | 0.28 ns/byte. The mode switch is another 0.35. |
| Copying a `Partial` per byte is expensive | CoW makes it O(top-level refcounted fields); ~1% difference. |

What actually cost: one malloc per byte of string content (the buffer was at refcount two at the
moment of the append), unspecialized generic `Sequence` iteration in `parse(bytes:)` (~2 mallocs
per byte cross module), and read-modify-write of whole subtrees through the computed
`\.currentElement` key path.

---

## Design decisions

*Recorded 2026-08-11.*

### Fast interface: a token granular sink

*Recorded 2026-08-11.*

`StreamParseSink` receives events carrying borrowed `Span<UInt8>` and is format agnostic. Sink
methods do not throw (a sink records a failure and the parser reads it once per chunk; measured
2–5%); schema apply closures return a bool to separate an unknown key from a type mismatch, which
measured within noise. Each token has one form (`stringBegin`/`stringChunk`/`stringEnd`, keys
always whole), and escapes are decoded to UTF-8 in the parser so no `Unicode.Scalar` or `String`
reaches the sink.

### Runs, not bytes

*Recorded 2026-08-11.*

The parser finds the next byte needing attention and hands everything before it over in one
piece. Scan strategy, MB/s over an 8 KB corpus:

| run length | 4 | 16 | 64 | 4096 |
| --- | --- | --- | --- | --- |
| scalar | 1401 | 1480 | 1528 | 1548 |
| SWAR | 940 | 2373 | 5730 | 9817 |
| **SIMD16** | **2476** | **7469** | **12770** | **21411** |
| SIMD32 | 1680 | 2987 | 9201 | 18480 |

SIMD16 wins at every run length; SWAR is unused, and SIMD32 lowers to two operations plus a
recombine on 128-bit NEON. simdjson style structural bitmaps measured slower (byte + table 3788
MB/s, SWAR bitmap 1611, SIMD16 bitmap 2824) because structurals are 20–25% of token dense JSON.

### Whitespace: one compare in front of the run scan

*Recorded 2026-08-16.*

Whitespace outside strings varies by document:

| document | whitespace | runs | 1 byte | ≥ 16 bytes |
| --- | ---: | ---: | ---: | ---: |
| canada | 0% | 0 | – | – |
| llm_message | 17% | 0 | – | – |
| github_events | 19% | 2526 | 45% | 0% |
| gsoc-2018 | 19% | 41713 | 45% | 0% |
| twitter | 26% | 28826 | 46% | 2% |
| citm_catalog | 71% | 76337 | 34% | 59% |

The shipped form is one inline `<= 0x20` compare, with the SIMD16 scan out of line. The variants
below (p50 MB/s against the control) show the inlined body costing escape-heavy rows 18–35% on code
that never runs there:

| variant | citm | twitter | twitterescaped | unicode escapes |
| --- | ---: | ---: | ---: | ---: |
| vector body inlined | +22% | +7% | −18% | −35% |
| one byte run peeled inline | +20% | +8% | −18% | −34% |
| **shipped: one compare, then out of line** | **+21%** | **+7%** | **−1%** | **−2%** |

The one-byte peel was dropped for re-triggering that cliff. A width test keeps byte-fed input off
the vector body (it cost byte-fed `twitter` 20%), and a scalar loop behind the same early-out lost
2–5% everywhere.

### The parse loop is a dispatcher, and a structural byte costs a call

*Recorded 2026-08-17.*

`parse` is a thin dispatcher that calls out to a function per token class, so each structural
byte cost a call, return and re-entry. `consumeStructuralRun` keeps looping while the state stays
structural, with the structural `State` cases ordered first. The `@inline` attributes are load
bearing: unforced, the optimizer inlined the run loop into `parse` and still called
`consumeStructural` per byte (function sizes in bytes):

| | HEAD | unforced | forced |
| --- | ---: | ---: | ---: |
| `parse` | 1284 | 1424 | **1252** |
| `consumeStructural` | 1044 | 1064 | **0** |
| `consumeStructuralRun` | – | 0 | **1240** |

Measured against controls on either side:

| document | before | after | Δ |
| --- | ---: | ---: | ---: |
| citm_catalog | 1211 | 1425 | +16 to +20% |
| canada | 679 | 776 | +14 to +15% |
| twitter | 808 | 911 | +10 to +16% |
| github_events | 962 | 1073 | +11 to +13% |
| gsoc-2018 | 2134 | 2187 | +2 to +4% |
| twitterescaped | 473 | 501 | +3 to +10% |
| llm_message | 1640 | 1646 | ±1% |

Corpus aggregate 1071 → 1181 MB/s (+10.2%). Byte-fed pretty printed users and unicode escaped
string lose 7–8%, but real-corpus byte-fed rows gain, so it was kept.

### The run loop subsumes the transition it would have been fused with

*Recorded 2026-08-17.*

Fusing the colon after a key into `consumeStringRun` was built and moved the aggregate from 1187
to 1188 MB/s: the run loop already coalesces `:` with the value's opening quote, so the fusion
added a compare and removed no call. Byte-fed rows lost 3–6%. The rule recorded: a fusion only pays
if it consumes everything structural before the next non-structural token.

### Fusing the comma, which does pass that test

*Recorded 2026-08-17.*

`fuseAfterValue` consumes `,`, the following whitespace and the next value's first byte at the
two sites a value closes (`consumeStringRun`, `consumeNumber`). Covering objects only cost
`canada` 3.8%; covering objects and arrays was kept:

| document | control | objects only | objects + arrays |
| --- | ---: | ---: | ---: |
| canada | 780 | 750 (−3.8%) | **843 (+8.1%)** |
| citm_catalog | 1421 | 1497 (+5.3%) | 1483 (+4.4%) |
| gsoc-2018 | 2273 | 2425 (+6.6%) | 2335 (+2.7%) |
| github_events | 1081 | 1198 (+10.1%) | 1115 (+3.1%) |
| twitter | 908 | 963 (+6.8%) | 952 (+4.8%) |
| twitterescaped | 500 | 518 (+3.6%) | 513 (+2.6%) |
| llm_message | 1647 | 1744 (+6.2%) | 1635 (−0.7%) |
| **aggregate** | **1190** | **1214 (+2.0%)** | **1246 (+4.7%)** |

`parse` stays 1252 bytes; the growth lands in the already out-of-line `consumeStringRun` and
`consumeNumber`. Byte-fed rows pay 2–6%; 16 KB streaming tracks bulk.

### Escapes decoded in the string run

*Recorded 2026-08-17.*

When a whole escape is in the chunk, `consumeStringRun` decodes it and keeps scanning;
`streamHexQuad` decodes the four hex digits as one `SIMD4<UInt8>`.

| document | before | after | Δ |
| --- | ---: | ---: | ---: |
| twitterescaped | 513 | 724 | **+41.1%** |
| twitterescaped, unchecked | 547 | 805 | **+47.2%** |
| unicode escapes (synthetic) | 410 | 1019 | **+148.5%** |
| gsoc-2018 | 2413 | 2521 | +4.5% |
| llm_message | 1712 | 1735 | +1.3% |
| citm_catalog / twitter / canada / github_events | — | — | ±0.4% |

Corpus aggregate 1259 → 1324 MB/s (+5.1%). Only simple escapes are inline: with the `\u` decode
also inline, `Fast Escaped string` lost 18.5%, and moving `fusedUnicodeEscapeEnd` out of line made
that +2.6%. Escapes with diagnostics (bad hex, lone surrogate, past the chunk) fall back to the per
byte states, keeping error offsets and resumption identical; `JSONChunkBoundaryTests` pins them at
every split.

### Discovering whitespace instead of scanning for it

*Recorded 2026-08-16.*

Handling whitespace in each state's unrecognised-byte arm, so minified input pays no compare, was
built and measured 10–18% slower nearly everywhere:

| document | lookahead scan | discovered in dispatch |
| --- | ---: | ---: |
| citm_catalog | 1214 | 1015 (−17%) |
| twitter | 818 | 681 (−17%) |
| twitterescaped | 476 | 395 (−17%) |
| github_events | 962 | 848 (−12%) |
| gsoc-2018 | 2120 | 1898 (−10%) |
| canada | 676 | 660 (−2%) |
| llm_message | 1594 | 1633 (+2%) |
| unicode escapes | 393 | 269 (−32%) |

It replaced one compare in the loop with five (one per state) plus an enum return, and even
`canada`, with zero whitespace, lost 2%; the loop is register bound, not work bound. Kept from the
attempt: `JSONConformanceTests` pins whitespace in every legal position, rejection of non-whitespace
control bytes, and rejection of a whitespace-only document.

### Literals are already fast enough to be unmeasurable

*Recorded 2026-08-16.*

Replacing `consumeLiteral`'s byte loop with a masked word compare was built and reverted: literals
are at most 3.4% of any real document, and on the 62% literal `Fast Literals` payload it is a wash
bulk and −6% byte fed.

| variant | bulk | byte by byte |
| --- | ---: | ---: |
| **shipped: byte loop over the nested array** | **345** | **147** |
| masked word compare | 346 | 138 |

### Numbers: fused scan, two words

*Recorded 2026-08-11.*

Superseded by "Numbers, whole": the shipped parser is a greedy SIMD16 scan with a whole-token
parse. Under per digit emission, fusing scan and accumulation measured as below (ns per number):

| variant | small | medium | large | decimals |
| --- | --- | --- | --- | --- |
| span only, consumer re-scans | 4.68 | 9.43 | 16.73 | 6.87 |
| fused, checked overflow | 5.27 | 13.50 | 23.20 | 8.27 |
| **fused, wrapping + digit count** | **2.96** | **7.47** | **11.91** | **5.52** |
| fused, wrapping, packed word | 3.64 | 7.27 | 11.81 | 5.60 |

The win came from dropping per-digit overflow checks, not from fusion (+17% end to end on a number
dense payload). `NumberInfo` carries magnitude, decimal exponent, digit count and flags. Per digit
reporting was later reversed: a number is now reported once, whole, `.incomplete` is gone, and
`PartialSink.number` is a plain scalar apply.

### Keys: precomputed words, no Dictionary

*Recorded 2026-08-11.*

ns per lookup:

| strategy | 4 keys | 10 keys | 24 keys |
| --- | --- | --- | --- |
| static `[UInt64: Int32]` | 9.12 | 9.83 | 10.26 |
| switch on padded word | 2.32 | — | — |
| **hash + table** | **1.28** | **1.32** | **1.32** |

`Dictionary` is 7–8× slower (~30% of a token dense parse) and unsuitable for embedded. The leading
word is only a dispatch key: each case also checks decoded length and remaining padded words, which
fixed two aliasing bugs found by boundary tests.

### Storage: frames pointing into the value

*Recorded 2026-08-11.*

Frames hold pointers into the value being built; only the innermost open container is mutated, so
buffers cannot move under an open frame. `StreamDictionary` keeps values in an append-only,
insertion-ordered array for the same reason. A frame needs a stored property, which rules out
nesting into bridged Foundation structs such as `PersonNameComponents`.

### Schemas: a reference, not a value

*Recorded 2026-08-14.*

`StreamSchema` went from a ~136 byte struct of eight closures, copied on every frame access, to a
`final class`. p50:

| | value | reference |
| --- | --- | --- |
| Array of structs, bulk | 251 µs | **79 µs** |
| Array of structs, view read per 4 KB chunk | 255 µs | **79 µs** |
| Array of structs, byte fed | 514 µs | **350 µs** |
| Flat struct | 9.4 µs | **6.3 µs** |
| Twitter 631 KB | 27 ms | **23 ms** |
| retains, 100 users | 13,000 | **2,101** |

Malloc counts are identical, so the cost was retain traffic from copying. Holding the schema by
pointer would save the remaining ~2,100 retains (~10%) at the cost of macro changes and an
unchecked lifetime invariant, so it was not done. A shared refcount may contend under concurrent
parses; unmeasured.

### Views: paying for what you read

*Recorded 2026-08-12.*

`withView` hands over a borrowed `~Copyable` projection instead of copying via `current`; it does
not need `~Escapable`, and `SuppressedAssociatedTypes` is enabled on library targets only. Each
member goes through `_streamMemberView`, whose `View` defaults to `Self`.

| reading one member per byte, 7 KB array of structs | p50 |
| --- | --- |
| observe nothing | 449 µs |
| **through a view** | **459 µs** |
| through `current` | 24 ms |

### Optional payload access

*Recorded 2026-08-11.*

Embedded Swift rejects key paths, so frame entry helpers reinterpret a pointer to an `Optional` as
a pointer to its payload at offset zero. That is an implementation detail, confined to
`StreamFrameEntry.swift` and covered by the nested object and array tests.

### Macro generated code

*Recorded 2026-08-11.*

The macro sees only syntax, so constrained/unconstrained overload pairs route fields; element
schemas are built by `_streamSchema(for:)` where a concrete type is written, since overloads
resolve where a generic is written. Emitting every field into every apply switch is free at runtime
but doubles compile time (32.5 vs 16.3 ms/struct), so known type names go to one switch.

### Buffering

*Recorded 2026-08-11.*

Chunk size sweep, MB/s:

| chunk | document | token dense |
| --- | --- | --- |
| 1 B | 102 | 123 |
| 16 B | 1780 | 503 |
| 64 B | 3860 | 579 |
| 256 B | 5503 | 647 |
| 8 KB | 5695 | 685 |

The curve is call amortization. 256 B buffering reaches 97% of peak but is ~1.3 s of latency at
LLM rates, so buffering is not offered. A dedicated `parse(byte:)` is ~2× a one byte span.

---

## Results so far

*Recorded 2026-08-11.*

Fast interface, bulk, against the old parser on identical payloads:

| payload | old | new |
| --- | --- | --- |
| Long string 8 KB | 19.1 MB/s | **5219 MB/s** |
| Array of structs 7 KB | 2.0 | **467** |
| Nested arrays 4.5 KB | 0.35 | **250** |
| Dictionary 2 KB | — | **366** |

Byte by byte reaches 124–135 MB/s against 1–11 MB/s before. The convenience layer against the old
parser (the last measurements taken against it), and chunked snapshotting against its 3.6 ms bulk
floor:

| scenario | old | new | | old mallocs | new |
| --- | --- | --- | --- | --- | --- |
| whole payload, no observation | 3.6 ms | 161 µs | 22x | 4352 | 115 |
| byte fed, no observation | 15.0 ms | 423 µs | 36x | 18,000 | 115 |
| value after every byte | 15.0 ms | 20.0 ms | **0.8x** | 18,000 | 6398 |

| chunk | snapshots | snapshot per chunk | vs old | view read per chunk | vs old |
| --- | --- | --- | --- | --- | --- |
| 16 B | 394 | 1.4 ms | 2.5x | 204 µs | 17.5x |
| 64 B | 99 | 477 µs | 7.5x | 173 µs | 20.6x |
| 256 B | 25 | 238 µs | 15.0x | 164 µs | 21.8x |
| 1 KB | 7 | 183 µs | 19.5x | 161 µs | 21.9x |
| 4 KB | 2 | 167 µs | 21.4x | 161 µs | 22.2x |
| 1 B | 6293 | 20.0 ms | 0.2x | 439 µs | 8.1x |

Only per byte snapshotting loses to the old parser; the view path stays flat. These predate the
schema reference change (251 → 79 µs bulk). `twitter.json` fast interface: 649–675 MB/s bulk, 473
at 64 B chunks, 171–177 byte by byte.

---

## Phase status

*Recorded 2026-08-11.*

### Phase 0 — De-risk (done)

*Recorded 2026-08-11.*

Cross module specialization proven (client sink within ±4%; removing `@inlinable` costs ~8%),
`Span` verified at the 10.15 floor, and key paths confirmed rejected by Embedded Swift.

### Phase 0b — Embedded smoke (done)

*Recorded 2026-08-11.*

`SmokeTests/` builds and links the `EmbeddedSmoke` freestanding wasm executable, since embedded
failures are link time and invisible on Darwin.

### Phase 1 — Safe wins and test infrastructure (done)

*Recorded 2026-08-11.*

In-place string accumulation removed a quadratic term (8 KB 2558 → 1149 µs), the
`withContiguousStorageIfAvailable` fast path cut an 8 KB document from 16,000 mallocs to 53, and a
chunk boundary harness and in-repo benchmark package were added.

### Phase 2 — Core primitives (done)

*Recorded 2026-08-11.*

Added `StreamParseSink`, `NumberInfo`, `StreamSinkFailure`, the SIMD16 scanners, and the
`Stream*Convertible` conversion protocols, with bridging shims in `StreamParsing`.

### Phase 3 — The parser (done)

*Recorded 2026-08-11.*

`JSONParser` landed: `~Copyable`, typed throws, buffered keys with zeroed padding, strings emitted
as runs ending on UTF-8 boundaries, and escapes decoded into a reserved buffer tail. The ~100 case
adversarial corpus found trailing commas, unimplemented number grammar, overlong UTF-8, lone
surrogates and `--1` being accepted.

### Phase 4 — Macro and PartialSink (done)

*Recorded 2026-08-12.*

`StreamSchema`, `StreamFrame`, `PartialSink` with a discarding schema, `StreamDictionary`, frame
entry helpers, and macro emission of `streamMatchField` and the apply switches alongside the old
registration. A differential against the old parser found an empty string producing nil and inert
element schemas. `MockParser` porting moved to Phase 6.

### Phase 5 — Support types (done)

*Recorded 2026-08-12.*

Standard library, Foundation, CoreGraphics, swift-collections and `Tagged` conformances ported.
`Decimal` is built exactly from magnitude and exponent, `Data` is no longer quadratic, 128-bit
integers re-scan the token, and swift-collections types are bridging destinations only, with a
deprecation warning when a member declares one.

### Phase 6 — Conveniences and removal (done)

*Recorded 2026-08-14.*

`PartialsStream` and `AsyncPartialsSequence` landed, and the old parsers, YAML, JSON5 options and
the registration machinery were removed (68,000 lines deleted, 1,200 added). A `partials()` bug
where emitted states shared buffers written through raw pointers was fixed by a recursive
`streamSnapshot()`. Tests were ported, `withView` added, and `EmbeddedSmoke` now runs the real core.
The view layer needs `SuppressedAssociatedTypes` on the library targets only, keeping the 6.3.2
floor.

### Phase 7 — CI and hardening

*Recorded 2026-08-11.*

The embedded wasm job builds and runs `EmbeddedSmoke` (done). Open: a benchmark regression job
(the local baseline is 11 MB), re-measuring byte by byte on a quiet machine, nested arrays below
target, and one unreproduced SIGSEGV in the full suite.

### Phase 8 — StreamArray (done)

*Recorded 2026-08-14.*

`StreamArray` replaced `Array` as `Array.Partial` (source breaking), and `streamSnapshot()` was
removed since a plain copy is now the snapshot. Removing it exposed seven failures from
`StreamDictionary` writing through a shared buffer, fixed with a `pendingKey`/`pendingValue` open
entry that a repeated key resumes in its original slot. `Codable` and `CustomReflectable` added.

---

## Known gaps

*Recorded 2026-08-11.*

Open at the time: `Float` scaled parsing rounds twice; a container's initial slot is visible
before its value and survives a caught `.typeMismatch`; `null` follows `applyNull` (accepted only
where optional); error reasons are coarse and carry a byte offset rather than line and column;
`StreamDictionary` retention stays quadratic in key count because blocking cost 2x discarding;
depth is capped at 64; the optional payload and `Tagged` layout assumptions are test-mitigated;
`PersonNameComponents` streams quadratically; swift-collections containers cannot be parse targets;
nested arrays are below target; and concurrent schema refcount contention is unmeasured. Resolved
since: high surrogate checks, mismatched containers throwing, provisional numbers, and the Twitter
benchmark model.

---

## Freezing the completed prefix

*Recorded 2026-08-14.*

Per byte snapshot cost was quadratic in array length against the discarding floor:

| payload | discarding | snapshot per byte | retains |
| --- | --- | --- | --- |
| 10 users, ~600 B | 53 µs | 433 µs | 8.8K |
| 100 users, 6.3 KB | 516 µs | 24 ms | 658K |
| 400 users, 25 KB | 2.2 ms | 379 ms | 11M |

The cost is refcount traffic over copied elements, not allocation. Everything left of the cursor
is immutable, so a snapshot only needs its own copy of the open element, which `Array` cannot
express.

### The open element goes outside the storage

*Recorded 2026-08-14.*

The open element lives in an inline `pending` slot outside sealed storage, so a plain value copy
is a correct snapshot, the raw pointer bypass behind the `partials()` bug disappears, and commit
(once per element) is the only operation touching shared storage. Fixed size blocks bound that
commit to copying one block. No new sink event is needed: a container commits when the next element
opens.

### What the commit costs

*Recorded 2026-08-14.*

Every element is now copied out of `pending` when the next opens. Isolated append loop, p50:

| | array in place | pending, copied out | **pending, swapped out** |
| --- | --- | --- | --- |
| narrow, 100 | 8.0 µs | 10 µs | **7.6 µs** |
| narrow, 400 | 29 µs | 38 µs | **29 µs** |
| wide, 100 | 9 µs | 13 µs | **10 µs** |
| wide, 400 | 35 µs | 49 µs | **39 µs** |

Swapping a nil into the slot is one copy and taken as a move (`consume self.pending` does not
compile here); with it the tax is 0–11% within the append loop, 0–1% end to end. Blocks allocated
less than `Array`, and the estimated per element retain tax did not appear.

### What the snapshot saves

*Recorded 2026-08-14.*

400 elements, 25,200 snapshots:

| | array rebuild | pending copy | |
| --- | --- | --- | --- |
| dropped immediately | 84 ms, 25K mallocs, 5.08M retains | **86 µs**, 19 mallocs, 1.6K retains | 977x |
| 16 deep window | 85 ms | **1.91 ms**, 426 mallocs, 83K retains | 44x |

Keeping a 16-deep window roughly doubles the parse (1.91 ms against 1.49 ms), against 379 ms vs
2.2 ms before. Correctness was checked with `blockCapacity` 4, including snapshots taken mid string.

### Measured end to end

*Recorded 2026-08-14.*

Built and measured in one session, p50:

| | before | after | |
| --- | --- | --- | --- |
| Array of structs, bulk, discarding | 78 µs, 115 mallocs, 2201 retains | 81 µs, 112, 2103 | −4% |
| 100 users, byte fed, discarding | 360 µs, 115, 2101 | 351 µs, 112, 2003 | — |
| 400 users, byte fed, discarding | 1486 µs, 417, 9001 | 1465 µs, 423, 8612 | — |
| 100 users, snapshot per byte | 25 ms, 6398, 647K | **735 µs**, 112, 21K | 34x |
| 400 users, snapshot per byte | 394 ms, 26K, 11M | **3.06 ms**, 423, 87K | 129x |
| 8 KB document, snapshot per byte | 570 µs, 13, 17 | 560 µs, 13, 15 | — |

Snapshotting no longer allocates (6,398 → 112 mallocs, the parse's own count). The discarding bulk
row is 4% slower, the predicted commit copy. Snapshot per byte of 400 users is 2.1x the discarding
parse, against 269x before.

### Where the allocations went

*Recorded 2026-08-14.*

Allocations became conditional on the application keeping states. 100 users at varying retention:

| retention | old mallocs | new mallocs | old p50 | new p50 |
| --- | --- | --- | --- | --- |
| dropped immediately | 6398 | **112** | 25 ms | **0.74 ms** |
| window of 4 | 6589 | **399** | 24 ms | **0.85 ms** |
| window of 16 | 6589 | **399** | 24 ms | **0.85 ms** |
| window of 64 | 6589 | **399** | 24 ms | **0.85 ms** |
| every state | 6589 | **399** | 25 ms | **0.76 ms** |

Cost is per divergence point, so holding every state costs what holding 4 does (about three
mallocs per element). An element's own `String` storage is unchanged, still one allocation per
append when retained:

| | old | new |
| --- | --- | --- |
| mallocs | 7994 | 7994 |
| retains | 16K | 16K |
| p50 | 2.95 ms | 3.20 ms |

### The spine does not need to be unsafe

*Recorded 2026-08-14.*

An unsafe append-only spine was not built: a snapshot already retains one spine buffer (3.3
retains per snapshot in the 16-deep run), the spine's quadratic term only overtakes the
irreducible cost near n ≈ 200,000 elements, and an unsafe spine would race readers on reallocation.
A spine of spines is the noted answer if that size is ever reached.

### Sketch

*Recorded 2026-08-14.*

`StreamArray<Element>` holds sealed `blocks: [ContiguousArray<Element>]`, a filling `tail`, and an
inline `pending: Element?`, with a power-of-two `blockCapacity` of 32; it conforms to
`RandomAccessCollection`/`MutableCollection`, and `_openElement` commits the previous pending
element and returns the new slot's address.

### What this does to the three hazards

*Recorded 2026-08-14.*

Snapshots mutating each other and the parser writing below the frozen line are both gone, since
every write to sealed storage goes through the checked subscript. An element's own `String` storage
is unchanged. An append-only buffer with a visible count and a persistent bitmapped trie were both
ruled out (synchronisation, and per-append path copying respectively).

### The open path is inline all the way down

*Recorded 2026-08-14.*

The whole root-to-cursor path is now inline storage, so frame validity rests on layout rather
than mutation order. It requires the unenforced invariant that no write straddles a commit, which
removing per digit number reporting made safe.

### Costs and open questions

*Recorded 2026-08-14.*

API cost: array members of `Partial` and `Array.Partial` become `StreamArray<Element>`;
`Array`'s `StreamPartial` conformance and `streamSnapshot()` go. Open: `RangeReplaceableCollection`,
`@unchecked Sendable`, a sweep of block size B (32 assumed), early sealing, and the same treatment
for `StreamDictionary`. `CustomReflectable` is done. Chunk size remains the cheapest lever (64 B
chunks: 20 ms → 477 µs).

---

## Next: StreamDictionary

*Recorded 2026-08-14.*

Phase 8 gave `StreamDictionary` an open entry slot but left `storedKeys`, `storedValues` and its
`[String: Int]` index flat, so a kept state shares three buffers that the next committed entry
copies in full.

### The two easy fields

*Recorded 2026-08-14.*

Plan: make `storedKeys` and `storedValues` `StreamArray`s, leaving their own `pending` slots
unused since a repeated key must resume in place. A single `StreamArray<Entry>` was ruled out to
keep the key scan contiguous.

### The index: measured, and `Dictionary` loses outright

*Recorded 2026-08-14.*

The `[String: Int]` index copies and rehashes under retention. A byte keyed flat index beats it at
every size and on every axis. ns per lookup, diverse keys:

| strategy | hit 8 | hit 32 | hit 128 | hit 512 | miss 512 | build 512 |
| --- | --- | --- | --- | --- | --- | --- |
| materialising scan (today's) | 26.0 | 59.9 | 179.7 | 664 | 1328 | 670 |
| span scan | 15.6 | 27.3 | 85.9 | 320 | 621 | 322 |
| leading word scan | 10.5 | 11.7 | 34.5 | 111 | 199 | 121 |
| whole key hash scan | 15.6 | 16.9 | 47.9 | 143 | 254 | 125 |
| `[String: Int]` | 41.6 | 33.8 | 34.8 | 35.2 | 46.9 | 119 |
| **flat chained index prototype** | **15.6** | **13.0** | **12.4** | **14.2** | **10.1** | **39.1** |

Keys sharing their first eight bytes defeat the leading word prefilter but not a whole key hash:

| strategy | hit 8 | hit 32 | hit 128 | hit 512 |
| --- | --- | --- | --- | --- |
| span scan | 20.8 | 43.0 | 132.8 | 549 |
| leading word scan | 26.0 | 46.9 | 148.4 | 639 |
| whole key hash scan | 15.6 | 18.2 | 47.9 | 143 |
| `[String: Int]` | 41.6 | 37.8 | 37.5 | 37.1 |
| **flat chained index prototype** | **15.6** | **15.6** | **17.3** | **17.3** |

A scan matches `[String: Int]` at ~32–128 keys, but dropping the index would cost ~9% at 128 keys
and ~43% at 512. `StreamDictionary (String lookup)` now benchmarks the shipped table directly.
Parse level retention, `BenchmarkCounts` byte fed:

| keys | discarding | window 16 | snapshot per byte |
| --- | --- | --- | --- |
| 8 | 9.3 µs, 13 mallocs | 19.0 µs, 21 | 17.0 µs, 21 |
| 32 | 35.0 µs, 19 | 82.0 µs, 92 | 73.0 µs, 92 |
| 128 | 141 µs, 25 | 391 µs, 380 | 356 µs, 380 |
| 512 | 601 µs, 31 | 2.37 ms, 1532 | 2.30 ms, 1532 |

Three mallocs per key under retention, and a time ratio rising from 2.0x to 3.9x, is the quadratic
term; the discarding path is flat.

### The index: one table, one entry buffer

*Recorded 2026-08-14.*

A lookup hashes the span once (FNV-1a), probes an open-addressed `Int32` slot table and compares a
stored `UInt64` hash before bytes; key and hash share one entry buffer, because retention cost
tracks buffer count. Insertion order, embedded support and checked `Sendable` are preserved. A
fixed hash permits flooding, but a fully collided chain degrades to the whole key hash scan
(143 ns at 512 keys).

#### Shape

*Recorded 2026-08-14.*

`StreamDictionary` holds `entries: ContiguousArray<StreamDictionaryEntry>` (hash + key),
`storedValues`, an optional half-load `table`, the pending key/value/hash/slot, and an
`indexThreshold` of 8; `_openValue(forKey:initial:)` materialises a `String` only for a new key.

#### Built, and both structural guesses were wrong

*Recorded 2026-08-14.*

Blocking the storage and chaining the index were both built and lost:

| configuration | buffers | disc. 128 | disc. 512 | window 16 @128 | mallocs |
| --- | --- | --- | --- | --- | --- |
| `[String: Int]`, flat (before) | 3 | 141 µs | 601 µs | 391 µs | 380 |
| chained index, every field blocked | 5 | 287 | 1190 | 713 | 654 |
| chained index, every field flat | 5 | 135 | 558 | 427 | 637 |
| **one table, merged entry, flat** | **3** | **132** | **549** | **359** | **380** |

Blocking cost 2x on the discarding path because a dictionary reads its storage on every lookup,
and five buffers raised retention mallocs regardless of size. The shipped one-table form matches
the old malloc counts exactly and is 6–9% faster discarding at 128/512 keys and 8–19% faster under
retention. The retention quadratic is reduced, not removed; moving the table into the sink's frame
is the noted way out.

### On the hot path, not just under retention

*Recorded 2026-08-14.*

The probe compares hashes then bytes, so a repeated key never becomes a `String`, removing the old
per-occurrence allocation for keys past fifteen bytes. 36 byte keys at 128 entries:

| | ns | mallocs |
| --- | --- | --- |
| `[String: Int]` | 125.0 | one per lookup |
| materialising scan | 414.1 | one per lookup |
| **flat chained index prototype** | **40.4** | **none** |

### Plumbing the array pass established

*Recorded 2026-08-14.*

Planned for `StreamDictionary`: `RandomAccessCollection`, `CustomReflectable`, guarded `Codable`,
lazy `keys`/`values` projections instead of copies, and checked `Sendable`.

### Behaviour pinned first (done)

*Recorded 2026-08-14.*

`ContainerReentryTests` and `SnapshotStabilityTests` (28 cases) pinned behaviour before the storage
change. A repeated container key resumes the existing container; a repeated number replaces and a
repeated string concatenates (recorded, not endorsed). A container arriving at a scalar dictionary
value leaked its elements into it, pinned as a bug.

#### Fixed, and it was never dictionary specific (done)

*Recorded 2026-08-15.*

Six leaking sites were found, not one:

| destination | input | was | is |
| --- | --- | --- | --- |
| `StreamArray<Int>` element | `[[2,3]]` | `[3]` | `[0]` |
| `StreamArray<Int>` element | `[{"a":1}]` | `[1]` | `[0]` |
| `StreamArray<StreamArray<Int>>` | `[{"a":1}]` | `[[1]]` | `[[]]` |
| `[Int]` object field | `{"values":{"a":1}}` | `[1]` | `[]` |
| `StreamArray<Int>` root | `{"a":1}` | `[1]` | `[]` |
| `StreamDictionary<Int>` value | `{"a":[2,3]}` | `3` | `0` |

The root cause was `enterContainer(shape:)` ignoring the container kind; `Shape.canHold(container:)`
checked there fixes all six at no measurable cost. A discarded container still leaves its
materialised slot. Wrong contents in a right shape throw `.typeMismatch`, `null` is accepted where
the destination is optional, and a container at a scalar destination stays silent (an open
question). Snapshot stability holds at every shape tested.

### Duplicate keys: resume

*Recorded 2026-08-14.*

Decided: a repeated key resumes the stored value. Rejecting duplicates would refuse documents RFC
8259 permits; shadowing (last one wins) would make lookup free but is a semantic change to behaviour
the 28 cases pin, so it was left unspent.

### Order

*Recorded 2026-08-14.*

All seven steps are resolved: behaviour pinned, flat open-addressed index landed, blocking the
storage reverted (2x discarding), duplicate keys resume, the shape check fixed six sites, and
plumbing done, with a deeper embedded `_openValue` smoke blocked by missing Unicode normalization
symbols.

---

## Adversarial round: string shapes, whitespace, and two blind spots

*Recorded 2026-08-15.*

String shapes that defeat the run scanner, each ~8 KB, p50 MB/s:

| payload | bulk | 64 B chunks | byte by byte |
| --- | --- | --- | --- |
| Long string (control) | 9655 | — | — |
| Escaped string, every third byte `\n` or `\t` | 369 | 321 | 161 |
| Unicode escaped, everything `\uXXXX`, half surrogate pairs | 390 | 337 | 200 |
| Non-ASCII, mixed 2/3/4 byte sequences | 1347 | 1003 | 168 |
| Pretty printed users | 652 | 554 | 160 |
| Array of structs, compact (control) | 459 | — | 147 |

Escape density is a 26x cliff (~370 MB/s); full UTF-8 validation costs 7x against the ASCII
prefilter but is not a bottleneck; whitespace stays scalar (pretty printed 17 µs vs 14 µs compact).
A matched keys Twitter model measures identically, and the runners now trap on parse failure.

### Bugs found by the same pass

*Recorded 2026-08-15.*

Byte-fed invalid UTF-8 and escaped keys were untested, and both hid bugs, pinned in
`AdversarialConformanceTests`: keys starting with an escape were rejected; invalid UTF-8 straddling
a chunk boundary was accepted; almost-pairs of surrogate escapes were accepted; error offsets were
chunk relative; and a number longer than the buffer parsed in bulk but threw byte fed.

### Fixed, and what the fixes cost

*Recorded 2026-08-15.*

The three acceptance bugs are fixed: a stored `isKeyToken`, split validation in
`completePendingUTF8`, and a pending high surrogate check at every following event. Against
same-session pristine controls, p50 MB/s:

| | pristine control | fixed |
| --- | --- | --- |
| Twitter, byte by byte | 141 | 142 |
| Twitter, bulk | 730 | 730 |
| Non-ASCII string, byte by byte | 158 | 142 |
| Escaped string, bulk | 357 | 334 |
| Unicode escaped string, bulk | 378 | 377 |

Costs are ~10% on byte-fed non-ASCII and ~7% on escape dense strings; Twitter is unmoved. The long
number feed asymmetry remains open.

### The gap between the convenience layer and the sink

*Recorded 2026-08-15.*

Twitter, p50:

| | bulk | byte by byte |
| --- | --- | --- |
| fast interface, counting sink | 719 MB/s | 188 MB/s |
| convenience layer, discarding | 296 MB/s, 293 mallocs | 29 MB/s |
| gap | 2.4x | 6.5x |

The gap growing as chunks shrink points at per byte costs, chiefly `String.streamAppend` building
a `String` per chunk.

### Plumbing is not the gap

*Recorded 2026-08-15.*

Sink plumbing trims (in-place `pendingField`, thin cached targets, no probe allocation) were
built, measured and reverted. p50, retains:

| Stream, discarding | baseline | all trims | minus thin targets |
| --- | --- | --- | --- |
| Array of structs, bulk | 75 µs, 2103 | 75 µs, 2204 | 81 µs*, 2303 |
| Array of structs, byte fed | 325 µs, 2003 | 324 µs, 2104 | 338 µs*, 2203 |
| Flat struct | 5.2 µs, 45 | 5.2 µs, 48 | 5.3 µs, 47 |
| Long string, byte fed | 500 µs, 15 | 506 µs, 15 | 509 µs, 17 |

*Noisy run — p100 spiked to milliseconds — but the retain counts are exact.

Wall clock never moved and every trim added retains; ARC already elides those copies. The long
string row (~61 ns per byte of `String.streamAppend`) locates the gap in scalar conversion.

### The append itself, isolated

*Recorded 2026-08-15.*

Skipping UTF-8 re-validation was measured against `+= String(decoding:)` and a byte buffer floor,
p50:

| 8 KB ASCII accumulated | `+= String(decoding:)` | unsafe init | byte buffer |
| --- | --- | --- | --- |
| by 1 B | 194 µs | 242 µs | **35 µs** |
| by 64 B | 13 µs | 14 µs | **1.9 µs** |
| by 4096 B | 792 ns | 792 ns | 792 ns |
| fresh 14 B token, one append | 83 ns, 0 mallocs | 83 ns | — |
| fresh 23 B token, one append | 167 ns, 1 malloc | 208 ns | — |

Validation is not the cost; the fixed ~20 ns per call append machinery is. At 4 KB chunks nothing
remains to win; at small feeds only changing where bytes accumulate helps (sink batching ~15x, a
byte buffer type ~7x more), which led to `StreamString`.

---

## Numbers, whole: greedy scan, structured parse

*Recorded 2026-08-15.*

Per digit reporting is gone: a number is emitted once, complete, at its token's end. Part-boundary
emission was the intermediate design and died on exponents (`1.5e2` still jumps from 1.5 to 150).
With nothing to accumulate, finding the token and parsing it separate. Strategies measured on
512-token corpora, ns per number, p50:

| strategy | small 1–4d | medium 5–10d | large 17–19d | decimals | exponents |
| --- | --- | --- | --- | --- | --- |
| fused scalar (the old shape) | 19.5 | 41.0 | 91.8 | 31.2 | 27.3 |
| two-pass scalar | 15.1 | 27.3 | 56.6 | 18.1 | 23.4 |
| two-pass SWAR8 | 15.7 | 25.4 | 33.2 | 18.9 | 23.4 |
| greedy scalar | 13.4 | 25.4 | 54.7 | 17.7 | 19.5 |
| greedy SIMD16 | **12.6** | 23.4 | 50.8 | **16.9** | **19.5** |
| **greedy SIMD16+SWAR8** | 13.4 | **16.9** | **23.4** | 19.5 | 21.5 |

The fused per byte loop loses to everything once it no longer emits. The shipped combination is
the greedy SIMD16 class scan with 8-digit blocks in the digit runs, which pays 2.2x on 17–19 digit
ids. `NumberParseBenchmarks.swift`, which held the six variants as private re-implementations, has
since been deleted because it drifted from production; the number path is now measured by the
`Numbers` rows in `ParserShapeBenchmarks.swift`.

### Digit block width

*Recorded 2026-08-16.*

The digit-run-to-integer step measured across block widths, ns per digit run, p50, relative to
SWAR8:

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

SIMD8 wins 7–13% wherever the block fires with no penalty elsewhere, so it replaced SWAR8 in
`streamParseEightDigits` (it needed the first reduction kept in `SIMD8<UInt8>` and the all-lanes
test as a 64-bit compare to avoid out-of-line calls). Narrower tiers and ladders do not pay. Digit
accumulation is ~2.2% of a `twitter.json` parse, so the change is below run-to-run variance. The
benchmark cannot be re-run because the scanners are `package`.

`consumeNumber` now does a greedy, stateless boundary scan over the number byte class, then one
structured walk (sign, integer, fraction, exponent) at the token end; a token reaching the chunk
end is buffered whole. The walk rejects `1e--2` and `1e+-2`, which the per byte rules accepted.
Malformed tokens like `1.2.3` are now one `.invalidNumber` at the token end, and an open number
contributes nothing to emitted state until it ends.

### Error offsets: absolute, and independent of chunking

*Recorded 2026-08-15.*

`error()` now adds `consumedByteCount` to the chunk-local offset, so every error names the absolute
byte it was detected at, identical at every split (invalid UTF-8 names the lead byte; `finish` no
longer double-counts). Sink-rejection offsets stay granularity-dependent by design.
`ErrorOffsetTests` pins both the split-independence and the exact detection byte per error kind.

### Measured end to end

*Recorded 2026-08-15.*

Whole emission against a pristine control, same session, p50:

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

Number-dense payloads gain; the string control does not move, and the offset accounting costs
nothing measurable. The cost: byte fed consumers see nothing while a number token is open.

---

## The benchmark suite: production only, and the shapes nobody measured

*Recorded 2026-08-16.*

The suite had 305 benchmarks, 182 of them sweeping seven key table strategies whose decision had
shipped. The rule now is that a benchmark measures shipped code; a strategy comparison earns a table
here and is then deleted (`StringAppendBenchmarks` is the exception, for an unapplied decision).
Prototype key tables, forked number strategies, the materialising dictionary sink and three
duplicate Stream rows were removed, plus one wrong "miss" row that was actually measuring an insert.

### What had no coverage at all

*Recorded 2026-08-16.*

Axes of shipped surface the suite never exercised:

| axis | why it was a hole |
| --- | --- |
| `bufferCapacity` | defaults to 4096, never swept; the supplied-buffer initializer appeared once, hardcoded |
| depth | capped at 64 by the container bitmask; nothing else in the suite nested past three |
| chunk boundaries | every chunked row fed powers of two, which land inside a token only by accident |
| schema width | key matching scans member words; no model declared more than six members |

### Buffer capacity, depth, schema width

*Recorded 2026-08-16.*

Buffer capacity is flat from 64 B to 64 KB (16–17 µs); it only decides whether a document parses.
Depth costs ~27 ns per object level, under half that per array level. Hitting the first or last of
48 members measures the same (83 µs): key matching is not linear in member count, because the
generated matcher switches on the leading word.

### Real datasets

*Recorded 2026-08-16.*

The rest of `yyjson_benchmark`'s corpus (`canada`, `citm_catalog`, `gsoc-2018`, `twitterescaped`,
`github_events`) and a generated escape-dense `llm_message.json` were added to `Resources/`. Bulk
MB/s p50 ranged from GSoC 1888 down to Canada 671 and Twitter escaped 438, the two floors being
per-byte work the SIMD scanner cannot skip. Rows at 1400 B, 16 KB and 64 KB chunks were added; the
convenience layer is flat across them. NDJSON is absent because the parser rejects trailing content.

### Tests, where speed is not the question

*Recorded 2026-08-16.*

Concurrency and malformed input became tests (`ConcurrentParsingTests`, `DepthLimitTests`,
`BufferCapacityTests`) rather than benchmarks. `BufferCapacityTests` pins that capacity bounds only
keys and numbers, not strings, which drain as chunks. The suite went from 305 to 201 benchmarks.

---

## Review round: state that outlived its token, an offset a fusion moved, and a schema per `[`

*Recorded 2026-08-17.*

A correctness read through `Fast/` with the cost of each fix measured. Four findings, all confirmed
against the built library and all fixed here.

### A sink rejection reported the wrong byte, and got one more token after it

*Recorded 2026-08-17.*

`fuseAfterValue` moved the cursor past the comma before `parse` read the sink failure, so the
reported offset named the next token and a failed sink got one more call:

| document | sink rejects | reported | should be |
|:---------|:-------------|---------:|----------:|
| `[1,2]`  | `number`     |        3 |         2 |
| `["a","b"]` | `stringEnd` |       6 |         4 |

The fusion now bails when the sink has already failed, so the offset no longer depends on whether
the following bytes were fusable; both cases are pinned at every split. Cost, against a rerun of
the same build:

| payload | before | after | run to run spread |
| :-------- | -------: | ------: | ------------------: |
| Canada | 848 MB/s | 842 | 0.2% |
| Nested arrays | 353 | 349 | 0.0% |
| Array of structs | 553 | 545 | 0.4% |
| GSoC 2018 | 2523 | 2493 | 1.0% |
| CITM catalog | 1476 | 1478 | — |

Under 1% and mostly inside the spread.

### A `StreamSchema` per `[`, and the benchmark that could not see it

*Recorded 2026-08-17.*

The macro built each container field's schema as an argument expression, so every `[` reaching the
field allocated two schema instances (~18 ns). No benchmark saw it because every model declared its
containers on the root; the new `Fields per element` row is that shape. The macro now hoists each
container field's schema to a `private static let` and passes it to `_streamEnterContainerField`:

| | before | after | |
| :--- | ---: | ---: | ---: |
| Fields per element — malloc | 2,017 | 816 | **-59.5%** |
| Fields per element — wall p50 | 631 µs | 509 µs | **-19.3%** |
| Fields per element — throughput | 33 MB/s | 41 MB/s | **+24%** |
| Schema 48 members — malloc | 17 | 16 | -1 (the one root array) |
| Twitter matched keys — malloc | 293 | 292 | -1 (ditto) |

`Optional.streamSchema` allocated a wrapped schema per token and now captures it once. Still open:
computed `streamSchema` on scalar roots, `StreamArray` and `StreamDictionary` builds per access,
since generic static stored properties are not allowed and a lock is worse.

### `paddedWord` had the padding and did not take it

*Recorded 2026-08-17.*

`paddedWord` was a byte loop; it is now one 8-byte load plus a 4/2/1 tail ladder, bounded by the
span because it is public. 6.35 → 0.98 ns per key (−84.6%). Document level, raw sink:

| payload | before | after |
| :-------- | -------: | ------: |
| CITM catalog | 1476 MB/s | 1498 |
| Twitter | 945 | 957 |
| GSoC 2018 | 2493 | 2511 |
| Array of structs | 545 | 551 |

+0.7% to +3.3%; the `Schema 48 members` rows are too short to resolve it.

### A note on reading these numbers

*Recorded 2026-08-17.*

`Real GSoC 2018` showed −3.8% in a combined run but was equal or faster when run alone against a
pristine control. As the largest payload it is the most sensitive to batch position, so a filtered
run is not comparable to a batch.

### Also found, not fixed

*Recorded 2026-08-17.*

Open items: `PartialSink.keyChunk` mishandled multi-chunk keys (later resolved by removing the key
trio); `JSONParser.init(buffer:)` has no minimum size check; `resolveScalarTarget` does not clear
`pendingDictionaryFrame`; a raw control byte in a string reports `.unterminatedString`; `finish()`
emits a buffered number before checking depth.

---

## StreamString: bytes accumulate, `String` is a read

*Recorded 2026-08-18.*

`String.Partial` is now `StreamString`: string fields accumulate raw UTF-8 in sealed 512-byte blocks
plus a tail (the `StreamArray` layout) and decode on read, instead of building a `String` per
escape-delimited chunk. Equality and hashing are byte-wise; the existing tests passed with no edits.
Measured on the `Layer` batch, p50:

| Layer, partial sink | before | after | mallocs |
| --- | --- | --- | --- |
| LLM message bulk | 382 MB/s, 2798 µs | **600 MB/s, 1782 µs** | 9088 → 6019 |
| LLM message 16KB chunks | 382 MB/s | **599 MB/s** | 9144 → 6022 |
| LLM message byte by byte | 30 MB/s, 35 ms | **62 MB/s, 17 ms** | 3735 → 6283 |
| Twitter bulk | 515 MB/s | 512 MB/s | 288 → 327 |
| CITM catalog bulk | 408 MB/s | 399 MB/s | 1932 → 2201 |

LLM message got +57% bulk and 2.05x byte fed. Isolated append, 8 KB accumulated then materialized:

| | by 1 B | by 64 B | by 4096 B | fresh 14 B | fresh 23 B |
| --- | --- | --- | --- | --- | --- |
| `String.streamAppend` | 199 µs | 13 µs | 833 ns | 83 ns, 0 mallocs | 208 ns |
| `StreamString` | **42 µs** | **4.6 µs** | 2.8 µs | 208 ns, 1 malloc | 208 ns |

Accepted costs: Twitter and CITM are flat but gained mallocs, because every non-empty `StreamString`
allocates a tail where short `String`s were inline; an inline small form is the follow-up.

### The `StringProtocol` question, and the bridge instead

*Recorded 2026-08-18.*

`StreamString` does not conform to `StringProtocol` (its index and element constraints would force
materialization). Instead it ships byte-wise `hasPrefix`/`hasSuffix`/`contains` and
`Substring.init(_:)` as an explicit bridge; equality goes through `streamBytesEqual`. Comparison
rows (`StringCompareBenchmarks`), p50 on equal operands:

| | `streamBytesEqual` | `elementsEqual` control | `String == String` |
| --- | --- | --- | --- |
| compare 23 B | 42 ns | 83 ns | — |
| compare 8 KB | **250 ns** | 10 µs | 625 ns, 1 malloc |
| compare 8 KB vs `String` | 333 ns | 10 µs | — |
| contains, match at end of 8 KB | 7.7 µs | 7.7 µs | — |
| hasSuffix 6 B of 8 KB | 83 ns | 83 ns | — |

Ordering uses `streamCompareBytes`, which compares the first unequal lane directly:

| ordering | equality probe + byte walk | `streamCompareBytes` |
| --- | --- | --- |
| 23 B, difference at end | 83 ns | 83 ns |
| 8 KB, equal | 333 ns | 292 ns |
| 8 KB, difference at byte 511 | 250 ns | **83 ns** |
| 8 KB, difference at value end | 500 ns | **292 ns** |

### The API round: scalars, forward characters, and one index currency

*Recorded 2026-08-18.*

Collection conformances live on views: `unicodeScalars` (bidirectional, `Int` byte-offset indices
shared with `utf8`) and `characters` (a forward `Sequence` delegating grapheme breaks to `String`).
Also added: `append`, `+=`/`+`, `TextOutputStream`, `TextOutputStreamable`, string interpolation,
byte-wise `Comparable`, and `range(of:from:)` returning `Range<Int>`. `count`, case mapping and
locale APIs were declined because members never materialize.

## Routing: frames borrow their schema, and two rewrites that measurement rejected

*Recorded 2026-08-18.*

With the counting sink as control, `partial sink, no values` rows were added for the widest gaps
(a `BenchmarkDiscardedScalar` control for dictionaries) to split routing from value writing. Bulk,
p50:

| Payload | counting | no values | matched | routing | values | routing share |
|---|---:|---:|---:|---:|---:|---:|
| Dictionary | 540 | 102 | 103 | 7.95 ns/B | −0.10 ns/B | **100%** |
| CITM catalog | 1451 | 437 | 405 | 1.60 ns/B | 0.18 ns/B | 90% |
| Twitter | 935 | 551 | 525 | 0.75 ns/B | 0.09 ns/B | 89% |
| Array of structs | 547 | 205 | 111 | 3.05 ns/B | 4.13 ns/B | 42% |
| LLM message | 1768 | 1505 | 608 | 0.10 ns/B | 0.98 ns/B | 9% |

Routing dominates everywhere except LLM message; on `Dictionary` it is all of the gap (`enterKey`
and opening the entry). Building the rows added a `precondition` on `sink.streamFailure` and found
that `_streamSchema(for:)` picks a schema by overload, not conformance.

### Durability before borrowing

*Recorded 2026-08-18.*

Borrowing schemas needs every schema to outlive the parse, which was false for hand-written
conformances with a computed `streamSchema`. `StreamParseableObject` now refines
`StreamContainerPartial`, and the parent hoists a child's schema into its own `private static let`,
closing the ownership graph.

### The witness rewrite, measured and rejected

*Recorded 2026-08-18.*

Replacing stored schema closures with a witness metatype measured 4.8 ns against 17.0 ns per call in
isolation, but made the parser slower: generic builders lost specialization (Dictionary 103 → 36
MB/s, CITM 405 → 269) and witnesses added retains. In `PartialSink` the closure load was already a
borrow, so the micro-benchmark's premise did not hold at the real call site.

### What did work: `BorrowedFrame`

*Recorded 2026-08-18.*

`PartialSink` lowers each `StreamFrame` to a trivial `BorrowedFrame` with an `unowned(unsafe)` schema,
so the frame stack stops retaining:

| Payload | before | after | retains |
|---|---:|---:|---|
| Dictionary — partial sink | 103 | **119** (+15.5%) | 313 → 311 |
| CITM catalog — partial sink | 405 | **429** (+5.9%) | 150,000 → **129,000** |
| Twitter — partial sink | 525 | 534 | 16,000 → **13,000** |
| LLM message — partial sink | 608 | 603 | 13,000 → 12,000 |
| Array of structs — partial sink | 111 | 111 | 1,913 → 1,811 |

Only `Dictionary` and `CITM catalog` clear the noise on wall clock; retain counts drop everywhere.
`ScalarTarget.schema` stayed strong because borrowing it cost LLM message 604 → 485 MB/s.

### The tripwire

*Recorded 2026-08-18.*

> **Superseded.** A `StreamFrame` no longer carries a schema: it names one of the entering schema's
> `children` by position, and the entering schema owns them, so the mistake this tripwire caught can
> no longer be written. `StreamSchemaBorrowAudit` and `SchemaBorrowAuditTests` are deleted. See "Frames
> name their schema by position".

`StreamSchemaBorrowAudit` held each borrowed schema weakly in debug builds and reported deallocation;
`SchemaBorrowAuditTests` proved it fired. Still open at the time: `Dictionary` at 119 against a 515
MB/s counting sink, and a byte-fed floor of 9–12 ns/B from one `stringChunk` per byte.

---

## The optional seam: one level of optionality, a field that is not zero, and a key that is whole

*Recorded 2026-08-19.*

An audit found three defects of one shape: an optional is stripped where the schema is built and
kept where the storage is declared. None had coverage; all were fixed.

### A scalar arriving at an object was absorbed by its first field

*Recorded 2026-08-19.*

Field `0` meant both "first member" and "this value itself", so `["abc"]` into
`StreamArray<Person.Partial>` silently wrote the first member. `StreamSchema.wholeValueField` (`-1`)
is now the sentinel, which also fixes `Optional`'s `applyNull` wiping a whole element. Measured
free, p50:

| Row (`Layer … bulk - partial sink`) | before | after |
| --- | ---: | ---: |
| Array of structs | 111 | 112 |
| Dictionary | 129 | 128 |
| Flat struct | 79 | 79 |
| Twitter | 553 | 556 |
| CITM catalog | 425 | 426 |

### A `Partial` stored two levels of optionality and understood one

*Recorded 2026-08-19.*

An optional property became an `Int??` member while its schema described `Int`, so scalars were
rejected and containers dropped their contents; only `null` worked. `partialTypeName` now describes
the wrapped type and `memberTypeName` adds one `?`. Macro codegen only.

### An optional dictionary member did not compile

*Recorded 2026-08-19.*

`streamPartialValue` called `mapValues` on an optional `[String: Int]?`; it maps through it now.


### A key has no chunked form

*Recorded 2026-08-19.*

`keyBegin`/`keyChunk`/`keyEnd` were removed from `StreamParseSink`, leaving `key(_:)`: a key is
always delivered whole and contiguous, which the matcher path requires. The change moved
`Layer LLM message bulk - counting sink` by ~−5–6% and the partial row by ~+3.6%, attributed to code
layout rather than cost; `Flat struct` rows are too noisy to read.

### Optional elements: open the slot, copy the closures

*Recorded 2026-08-19.*

`[String?]`, `[String: String?]` and `[Person?]` segfaulted because storage and schema disagreed.
Using `Optional`'s wrapper cost 2.4x (73.5 vs 32.1 ns/element). Instead the optional builders open
the slot as `.some(...)` and `_streamOptionalElementSchema` copies the wrapped closures verbatim,
adding only `applyNull`: 32.9 ns/element, no change on the layer rows. `[{}]` into `[Person?]` now
reads as one empty `Person`. `{"scores":null}` on a container field also works now.

### `streamElementSchema`: the type answers, not the spelling

*Recorded 2026-08-19.*

(Since renamed along with the schema cache's `StreamSchema.Usage`: `streamElementSchema` and
`streamElementInitialValue()` are `streamArrayElementSchema` and `streamInitialArrayElement()`,
dictionaries read the new `streamDictionaryValueSchema`/`streamInitialDictionaryValue()` pair, which
defaults to them, and `streamContainerSchema`/`_streamContainerPrepare` are
`streamObjectMemberSchema`/`_streamObjectMemberPrepare`. The names below are as they were.)

The macro only recognised sugared spellings, so `Array<Int?>`, aliases and roots stayed at 77 ns
against 32. Two defaulted `StreamPartial` requirements, `streamElementSchema` and
`streamElementInitialValue()`, overridden only by `Optional`, let the type decide. 20,000 element
array, ns/element:

| | before | after |
| --- | ---: | ---: |
| `var xs: [Int]` | 31.9 | 32.4 |
| `var xs: [Int?]` | 32.4 | 31.9 |
| `var xs: Array<Int?>` | **77.0** | **32.6** |
| root `StreamArray<Int>` | 31.6 | 31.5 |
| root `StreamArray<Int?>` | **73.5** | **32.8** |

No cost elsewhere.

### An entry exists from the moment its key does

*Recorded 2026-08-19.*

A dictionary entry for an optional value now reads `Optional(0)` between its key and value, matching
the non-optional rule that an entry exists from the moment its key does. Publishing entries only once
their value arrives was not taken.

---

## Structural dispatch: the state machine was living in memory

*Recorded 2026-08-20.*

`consumeStructuralRun` was 28% of `canada` and 32% of `citm_catalog`, for runs of two to four bytes.
The run loop stored and reloaded `state`, `depth` and `containers` through `self` on every byte.

### Register-resident state

*Recorded 2026-08-20.*

`consumeStructuralRun` now keeps `state`, `depth` and `containers` in locals written back by `defer`,
with `topIsObject` computed lazily in the arms (eagerly it measured 2–9% slower). Interleaved, p50:

| benchmark | control | register state | |
| --- | ---: | ---: | ---: |
| Fast Nested arrays, bulk | 11.7 µs | 10.2 µs | **-13.3%** |
| Real Canada, bulk | 2701 µs | 2576 µs | **-4.6%** |
| Real GSoC 2018, bulk | 1061 µs | 1028 µs | -3.1% |
| Real LLM message, bulk | 563 µs | 549 µs | -2.5% |
| Real CITM catalog, bulk | 1067 µs | 1042 µs | -2.3% |
| Real GitHub events, bulk | 48.7 µs | 47.7 µs | -2.0% |
| Fast Pretty printed users, byte by byte | 61.1 µs | 59.8 µs | -2.1% |
| Real Twitter, bulk | 596 µs | 590 µs | -0.9% |

### Classifying the window ahead of time, measured and rejected

*Recorded 2026-08-20.*

Classifying a sixteen byte window once and visiting content bytes by bitmask, and separately peeling
two bytes scalar, were measured against register state:

| benchmark | register state | window classified | peel 2 bytes scalar |
| --- | ---: | ---: | ---: |
| Real CITM catalog, bulk | 1061 µs | 1138 µs (+7.3%) | 1083 µs (-0.0%) |
| Real Canada, bulk | 2628 µs | 2795 µs (+6.4%) | 2672 µs (-0.4%) |
| Real Twitter, bulk | 602 µs | 619 µs (+2.9%) | 598 µs (-1.0%) |
| Real GitHub events, bulk | 49.1 µs | 48.6 µs (-0.9%) | 47.7 µs (-1.3%) |
| Real GSoC 2018 / LLM message, bulk | — | ±0.5% | ±1.5% |
| Fast Pretty printed users, byte by byte | 60.4 µs | 63.8 µs (+5.6%) | 58.8 µs (-3.7%) |

rejected: structural runs are two to four bytes, so the classify chain sits on the critical path at
every entry; the scalar peel is noise. Neither is in the tree.

### Fusing the colon after a key: measured across seven variants, and rejected

*Recorded 2026-08-20.*

Fusing `":` and the value's first byte into the key's closing quote gave bulk gains (`Fast
Dictionary` −16 to −20%, GitHub −7 to −12%), but every one of seven variants had a disqualifying
cost:

| variant | shape | disqualifying cost |
| --- | --- | --- |
| recurse | run tail-calls itself for the fused token | the self-call is a real `bl`, not TCO'd — unbounded stack, one frame per token in a chunk; ~34K frames / 5 MB on a single-chunk GSoC, survives the 8 MB main thread and overflows a worker |
| loop, `let isKey` local | switch on the fusion, flip a local, `continue` | local spilled into the content loop; byte fed `Long string` +32%, `LLM message` +31% |
| loop, `isKeyToken` field | as above, flag read from the field | no escaped-string cliff, but the loop back-edge keeps the content loop's live ranges up: byte fed `Long string` +15%, `LLM message` +15%, `Pretty printed` +8% |
| return to dispatcher (three forms: enum, `let isKey`, field flag) | fuse, return the cursor, let `parse` re-enter — the exact shape of the accepted comma fusion | `Fast Escaped string` bulk **+62%**, in every form |
| out of line fusion helpers | the two fusions `@inline(never)` | escaped cliff gone, but the per-boundary call outweighs the structural-run it skips: `Twitter` +6%, `CITM`/`Canada`/`GSoC`/`GitHub` +3-4% |

`consumeStringRun` is at its register ceiling, so a second inlined fusion costs `Fast Escaped string`
62% even when it never runs. Rejected.

---

## Keys in place: the padding nobody read, and the function that could not hold the branch

*Recorded 2026-08-20.*

A key paid a copy into the parser buffer, a validate call and a sixteen byte zero store, to support
chunk-cut keys and the `keyPaddingByteCount` guarantee. No reader ever used the padding, so the
guarantee is retired: a key span is a borrow readable within its count.

### Where the in-place read lives is the whole result

*Recorded 2026-08-20.*

Emitting in-place keys from `consumeStringRun` cost −9 to −12%. Instead `consumeStructuralRun` reads
a key whose closing quote is in the chunk and continues through the colon to the value; cut or
escaped keys go through the new `consumeKeyRun`, and `consumeStringRun` is values only. Interleaved,
three rounds, p50:

| benchmark | before | keys in place | |
| --- | ---: | ---: | ---: |
| Real Twitter escaped, bulk | 683 µs | 539 µs | **−21.1%** |
| Real CITM catalog, bulk | 1053 µs | 902 µs | **−14.3%** |
| Real GitHub events, bulk | 48.0 µs | 42.0 µs | **−12.5%** |
| Real Twitter, bulk | 603 µs | 530 µs | **−12.1%** |
| Real GSoC 2018, bulk | 1027 µs | 933 µs | **−9.1%** |
| Fast Dictionary, bulk | 3.1 µs | 2.4 µs | −24.0% |
| Real Canada / Fast Nested arrays / Escaped / Unicode escaped / Non-ASCII, bulk | — | — | 0 to +0.2% at p0 |
| Fast Long string, byte by byte | 45.9 µs | 46.0 µs | +0.1% |
| Real LLM message, byte by byte | 6238 µs | 6394 µs | +2.5% |
| Real Twitter escaped, byte by byte | 3269 µs | 3365 µs | +2.9% |
| Fast Pretty printed users, byte by byte | 59.1 µs | 60.7 µs | +2.8% |
| Fast Escaped string, byte by byte | 35.7 µs | 37.3 µs | +4.7% |

Byte fed escape rows pay 2–5%. A key in one chunk is no longer bounded by buffer capacity, and
`StreamParsingLayout` is gone.

### Three cheap fixes from the disassembly, one kept

*Recorded 2026-08-20.*

Kept: `NumberInfo.Flags` statics as `@inlinable public static var` instead of addressor calls
(`canada` −8.1%). rejected: replacing the number scanner's `umov` ladder with a `uminv` reduction
(`citm_catalog` +10.5%, as short numbers pay the reduction's dependent latency). rejected: splitting
`validateUTF8IfNeeded` into an inline guard (noise, and more stack traffic in `consumeStringRun`).

---

## UTF-8 validation in vectors: the three table lookups, and the one instruction Swift cannot say

*Recorded 2026-08-20.*

The scalar validator ran at ~1.35 GB/s and walked long `llm_message` runs end to end for a single
non-ASCII byte, which was most of its strict-versus-unchecked gap.

### The algorithm

*Recorded 2026-08-20.*

Keiser and Lemire's lookup validator: three sixteen-entry nibble tables ANDed per lane, plus a
continuation mask and an end check, sixteen bytes a block. `tbl` is reached through a header-only C
target, `StreamParsingShims` (`vqtbl1q_u8`); the previous-byte views are overlapping unaligned loads,
with a zero-padded scratch for short runs and tails.

### Where the kernel lives, and the two shapes that lost

*Recorded 2026-08-20.*

Shifting views in with `ext` from Swift ran 2.6x slower (half-vectorized lanes), so the arm64 block
kernel is one C function, `stream_parsing_utf8_block_errors`; the Swift path is the portable
reference. In C, overlapping loads still beat `ext` (−10.5% on `Fast Non-ASCII string`).
`UTF8ValidationTests` checks both against the stdlib decoder; the scalar walk only runs to locate an
error.

### Measured

*Recorded 2026-08-20.*

Interleaved, three rounds, p50:

| benchmark | before | vector validator | |
| --- | ---: | ---: | ---: |
| Real LLM message, bulk | 569 µs (1880 MB/s) | 308 µs (3480 MB/s) | **−46.0%** |
| Real Twitter, bulk | 518 µs (1219 MB/s) | 454 µs (1390 MB/s) | **−12.3%** |
| Real Twitter, 16 KB chunks | 518 µs | 460 µs | −11.3% |
| Fast Non-ASCII string, bulk | 6.3 µs (1.3 GB/s) | 1.4 µs (5.8 GB/s) | **−77.6%** |
| Fast Non-ASCII string, 64 B chunks | 8.3 µs | 4.0 µs | −51.5% |
| Fast Non-ASCII string, byte by byte | 45.9 µs | 43.3 µs | −5.6% |
| CITM / GSoC / Twitter escaped / Escaped / Unicode escaped, bulk | — | — | −1 to +0.3% |
| Real LLM message, byte by byte | 6525 µs | 6619 µs | +1.4% |

ASCII documents do not move; `llm_message` strict is within ~10% of unchecked.

## Unchecked mode: three flags, and only one of them was ever paying

*Recorded 2026-08-21.*

Each `JSONParserConfiguration` flag was measured alone against strict, `Payload MB/s`:

| payload | strict | noUTF8 | noNumbers | noLiterals | unchecked |
| --- | ---: | ---: | ---: | ---: | ---: |
| LLM message | 3520 | **+44.0%** | +0.2% | +0.0% | **+44.1%** |
| Twitter | 1433 | +3.5% | +0.6% | +0.6% | +4.4% |
| CITM catalog | 1971 | +1.0% | +0.7% | +0.3% | +1.2% |
| GSoC 2018 | 3681 | +0.0% | +0.1% | +0.2% | −0.2% |
| GitHub events | 1608 | −0.9% | −0.2% | −0.3% | +0.0% |
| Canada | 962 | −1.4% | −1.4% | −1.5% | +0.3% |
| Twitter escaped | 1086 | **−7.3%** | −0.1% | +0.0% | **−5.6%** |

Only `validatesUTF8` paid, and turning validation off made `twitterescaped` slower (the unchecked
scanner was `@inline(never)`). So all three flags, `JSONParserConfiguration` and
`streamStringRunEnd` were deleted; a lone high surrogate is now always an error.

### Measured

*Recorded 2026-08-21.*

| granularity | representative rows | delta |
| --- | --- | --- |
| bulk | LLM 3570→3750, GSoC 3756→3844, Non-ASCII 6885→7711 | −2.2% … **+12.0%** |
| 16 KB | LLM 3552→3744, GSoC 3718→3806, Twitter 1433→1452 | **+1.3% … +5.4%** |
| 64 B | Long string 6433→6657, Non-ASCII 2117→2140 | −3.5% … +3.5% |
| 13 B | Escaped 526→567, non-ASCII 453→466 | −1.9% … **+7.8%** |
| 7 B | Escaped 421→447, structs 375→388 | −0.7% … **+6.2%** |
| 3 B | Unicode escaped 312→330, structs 259→267 | **−6.1%** … +5.8% |
| 1 B | Escaped 209→166, Unicode escaped 282→175, LLM 165→140 | **−13% … −38%** |

`llm_message` gains 6%. The 1 B regression is the `parse` inlining cliff: removing the field flipped
an optimiser decision so `parse` calls out to the token consumers once per byte; forcing them inline
was worse and reverted. `Fast Unicode escaped string` is negative at every granularity, unexplained.

---

## The dead-code pass: what nothing was calling

*Recorded 2026-08-21.*

Every declaration in `Sources` with no caller was deleted (309 lines): `Internal/UTF8State.swift`,
`Internal/String+Capitalized.swift`, the rejected lane-shift shims and their tests, twenty-one ASCII
constants and five `UInt8` predicates, and four unused public members.

### Two protocol requirements

*Recorded 2026-08-21.*

`StreamStringConvertible.streamReserve(utf8ByteCount:)` was never called through the protocol and was
removed. `StreamParseSink.string(_:)` was removed too: whole-string emission was never built, and it
comes back with a benchmark if it is.

---

## Cheap first tiers: one of three landed, and the census said which

*Recorded 2026-08-22.*

`streamStringRun`, `streamNumberRunEnd` and `streamWhitespaceEnd` receive the chunk end, so the only
hybrid shape is a cheap general-register first pass in front of the vector body. A census of spans
as the scanner sees them sized each tier:

| document | kind | spans | <8 | <40 | >=40 |
|---|---|---:|---:|---:|---:|
| twitter | string | 19,327 | 28% | 92% | 8% |
| twitterescaped | string | 51,145 | 74% | 98% | 2% |
| citm | string | 26,606 | 47% | 100% | 0% |
| gsoc | string | 49,141 | 37% | 71% | 29% |
| llm_message | string | 17,503 | 29% | 68% | 32% |
| canada | number | 111,126 | **0%** | 100% | 0% |
| mesh | number | 73,013 | 58% | 100% | 0% |
| citm | number | 14,392 | 6% | 100% | 0% |
| twitter | number | 4,900 | 90% | 100% | 0% |
| citm | ws | 76,337 | 34% | 100% | 0% |
| twitter | ws | 28,826 | 57% | 100% | 0% |
| gsoc | ws | 41,713 | 52% | 100% | 0% |
| mesh / canada | ws | 73,042 | 100% | 100% | 0% |

Each tier was built by patching a pristine copy so the control is byte-identical to HEAD.

### Landed: two bytes of bitmap test in front of the whitespace vector body

*Recorded 2026-08-22.*

A two-byte straight-line bitmap test in the out-of-line `streamWhitespaceRunEnd`, p50 against a
byte-identical control:

| document | payload | HEAD | now | |
|---|---:|---:|---:|---:|
| gsoc-2018 bulk | 3250K | 3,711 | **4,207** | +13.4% |
| github_events bulk | 64K | 1,609 | **1,790** | +11.2% |
| twitter bulk | 617K | 1,396 | **1,497** | +7.2% |
| twitter 16KB chunks | 617K | 1,393 | **1,497** | +7.5% |
| citm_catalog bulk | 1687K | 1,952 | **2,087** | +6.9% |
| citm_catalog 16KB chunks | 1687K | 1,945 | **2,077** | +6.8% |
| mesh bulk | 707K | 700 | **742** | +6.0% |
| mesh 16KB chunks | 707K | 700 | **737** | +5.3% |
| twitterescaped bulk | 549K | 1,090 | 1,086 | -0.4% |
| llm_message bulk | 1045K | 3,615 | 3,617 | +0.1% |
| canada bulk | 2198K | 946 | 945 | -0.1% |

No row regresses more than 1%. It resolves only one-byte runs, so the gain tracks their share:

| document | ws runs | len 1 | len 2 | >= 3 | median | gain |
|---|---:|---:|---:|---:|---:|---:|
| mesh | 73,024 | 100% | 0% | 0% | 1 | +6.0% |
| twitter | 28,826 | 46% | 0% | 54% | 7 | +7.2% |
| github_events | 2,526 | 45% | 0% | 55% | 5 | +11.2% |
| gsoc-2018 | 41,713 | 45% | 0% | 55% | 5 | +13.4% |
| citm_catalog | 76,337 | 34% | 0% | 66% | 21 | +6.9% |

Runs of two do not occur and wider peels lost on `citm_catalog`, so the bound is two. Two tests were
added, since the vector body previously had no direct coverage.

### Rejected: a SWAR first word in front of the string scanner

*Recorded 2026-08-22.*

Median −0.4%: `Fast Escaped string` +38.5%, but `Fast Long string - 64B chunks` −35.5%. It helps
runs of eight bytes or fewer and makes nine-to-sixteen byte runs pay a word and a block.

### Rejected: a bitmap peel in front of the number scanner

*Recorded 2026-08-22.*

Median −1.0%: `canada` −11.7%, `mesh` −10.3%. A peel bounded at four never sees the terminator of
`mesh`'s median four-byte number. A `vshrn_n_u16` movemask leaf shim is the better lever.


## Porting `streamStringRun` to C: the kernel got better and the parse got slower

*Recorded 2026-08-22.*

The string scanner was rewritten as a C kernel in `StreamParsingShims`, measured, rejected and
reverted (2026-08-22). Nothing from it is in the tree.

### Why it looked promising

*Recorded 2026-08-22.*

A `static inline` C function is bodiless in SIL, and `vshrn_n_u16` (the arm64 movemask) is reachable
only from C. The movemask kernel shortened the hit path's dependency chain. Standalone C harness,
8 KB of fixed-length ASCII runs, MB/s:

| run length | SIMD16 movemask | SIMD16 `uminv` | SIMD16 2x | SWAR |
|-----------:|----------------:|---------------:|----------:|-----:|
| 1          | 272             | 273            | 251       | 366  |
| 2          | 408             | 409            | 376       | 548  |
| 4          | 663             | 682            | 623       | 904  |
| 8          | 1192            | 1203           | 1128      | 1431 |
| 16         | 2120            | 1954           | 1993      | 2454 |
| 24         | 3178            | 2886           | 2855      | 3230 |
| 32         | 3799            | 3903           | 3519      | 4064 |
| 64         | 6368            | 6291           | 5847      | 5387 |
| 256        | 14701           | 14300          | 14841     | 8066 |
| 4096       | 23133           | 23133          | 23481     | 9198 |

Movemask beats `uminv` by 8–10% at 16–32 byte runs.

### What it cost, and the experiment that found out why

*Recorded 2026-08-22.*

Real documents were flat, but chunked and byte-fed string rows regressed (`Fast Non-ASCII string -
64B chunks` −37.8%); median −0.5%. Not the forced inlining into `consumeStructuralRun`: re-declining
it fixed the size, not the regressions. A C transliteration of the Swift algorithm regressed the
same, so the cost is the Swift/C boundary; no return representation was free.

### What this says about porting kernels to C generally

*Recorded 2026-08-22.*

A C kernel cannot take part in Swift's per-call-site inlining decisions. Use C for capability Swift
lacks, not for better codegen of something Swift can already express.

### The two questions this was built to answer

*Recorded 2026-08-22.*

The 2x string unroll compiles cleanly in C and still loses (median −1.5%), so the approach, not the
Swift traps, was the problem. SIMD does not always beat SWAR in C: the crossover is ~40 bytes, from
SIMD's per-call entry cost (SWAR +39.3% on `Fast Escaped string`, −51.8% on `Fast Long string`,
median −2.3%), so SWAR is not a replacement.
## The short integer kernel: eight bytes, backwards

*Recorded 2026-08-21.*

`emitNumber`'s digit loop is eleven instructions per digit, so a flat-cost kernel crosses over at
two digits. Digits are the wrong axis, though: segments (dot, exponent) dominate digits roughly
three to one, as the synthetic rows show.

| row | shape | ns/number |
| --- | --- | --- |
| `Numbers small integers` | 2.9 digits, no dot, no exponent | 9.0 |
| `Numbers large integers` | 19 digits, no dot, no exponent | 11.5 |
| `Numbers floats` | 3-6 digits, **dot + exponent** | 14.5 |

### The kernel

*Recorded 2026-08-21.*

`streamShortInteger` parses an unsigned integer of one to eight digits with no loop and no
data-dependent branch, by reading the eight bytes *ending* at the token and right-aligning them so
no scaling step is needed. Eighteen hot-path instructions against the rejected branchless tail's
thirty-five; `Numbers small integers` gains 7.4%. The mask must precede the `0x30` bias, or a
preceding byte below `'0'` borrows into the leading digit; `ShortIntegerKernelTests` pins it.

### SWAR against SIMD, and where each one belongs

*Recorded 2026-08-21.*

SWAR, a hybrid and a pure SIMD form were measured over three interleaved rounds (`Payload MB/s`
p0); SWAR won. The pure SIMD form scalarised a runtime-mask `replacing(with:where:)`, and the clean
hybrid still lost on GPR/NEON crossings. Rule: SIMD wins where data is already in vectors and stays
there; SWAR wins where the answer is needed in a GPR and the token is short.

| row | eligible | control | **SWAR** | hybrid | pure SIMD |
| --- | --- | --- | --- | --- | --- |
| `Numbers small integers - bulk` | 100% | 444 | **477 (+7.4%)** | 461 (+3.8%) | 359 (-19.1%) |
| `Real Mesh - bulk` | 57.7% | 682 | **712 (+4.4%)** | 699 (+2.5%) | 644 (-5.4%) |
| `Real Twitter - bulk discarding` | -- | 631 | **647 (+2.5%)** | 636 (+0.8%) | 645 (+2.1%) |
| `Real Canada - bulk` (control) | 0.1% | 951 | 950 | 950 | 950 |
| `Numbers floats - bulk` | 0% | 721 | 699 (-3.1%) | 696 (-3.5%) | 681 (-5.5%) |

| form | GPR/NEON crossings in `emitNumber` | crossings in the kernel | instructions |
| --- | --- | --- | --- |
| **SWAR** | 5 | **0** | **255** |
| hybrid | 9 | 4 | 269 |
| pure SIMD | 23 | 14 | 306 |

### What it costs where it does not apply

*Recorded 2026-08-21.*

`Numbers floats` loses 3.1% (short decimal tokens enter the kernel and fail on the `.`) and
`Numbers large integers` loses 2.9% from code layout. No real payload regresses; the exponent shape
appears in 0 of 468,000 real corpus numbers. Hoisting the shape test into
`streamNumberRunEndShimmed` was rejected on cost before being built: the masked horizontal OR adds
~12 instructions to the scanner's critical path.

### Coverage, and what is left

*Recorded 2026-08-21.*

Every real-corpus token falls into one of four shapes; the kernel takes shape A. D is half the
corpus by token count only because canada is 55% of all numbers.

| shape | corpus | who it serves | status |
| --- | --- | --- | --- |
| A, unsigned integer <= 8 digits | 20.4% | llm 100%, github 91%, twitter 78%, mesh 51% | **built** |
| B, unsigned integer 9-16 digits | 8.7% | **citm 93.7%**, twitter 12.6% | open, cheap (one more `ldr`) |
| C, signed or decimal <= 16 digits | 21.1% | **mesh 44.4%**, canada 9.4% | open, needs `tbl` |
| D, decimal 17-19 digits | 49.8% | **canada 90.6%** | open, needs `tbl2` |
| exponent, or > 19 digits | **0.0%** | nothing real | general walk |

### B, the nine to sixteen digit integer: built, measured, REJECTED

*Recorded 2026-08-22.*

`streamMediumInteger` (two words, `high * 100_000_000 + low`) was correct and rejected: CITM +1.4%,
but Mesh discarding -2.8% and `Numbers floats` -3.9%, because long decimal tokens now paid two
loads and masks before declining. The selection metric was wrong: benefit scales with eligible
tokens per byte, not eligibility. `streamEightDigitWord` and `streamWordHasNonDigit` were kept, and
a `package` kernel must enforce its own range. The first control silently parsed every >8-digit
number as 0 via Swift's smart shift; run the test suite against the control too.

| row | B eligible | A only | A+B | |
| --- | --- | --- | --- | --- |
| `Real CITM catalog - bulk` | **93.7%** | 1970 | 1997 | **+1.4%** |
| `Real Twitter escaped - bulk discarding` | -- | 452 | 459 | +1.5% |
| `Real Twitter - bulk discarding` | -- | 635 | 642 | +1.1% |
| `Real Mesh - bulk` | 4.9% | 700 | 700 | 0.0% |
| `Real LLM message - bulk discarding` | -- | 721 | 712 | -1.2% |
| `Real GSoC 2018 - bulk discarding` | -- | 611 | 601 | -1.6% |
| `Real Mesh - bulk discarding` | -- | 145 | 141 | **-2.8%** |
| `Numbers floats - bulk` | 0% | 688 | 661 | **-3.9%** |

| | numbers/KB | B eligible | B eligible per KB |
| --- | --- | --- | --- |
| citm | 8.3 | 93.7% | **7.8** |
| mesh | 100.9 | 4.9% | 4.9 |
| twitter | 3.3 | 12.6% | 0.4 |

### C, the decimal kernel: built, measured, REJECTED -- and the size ceiling this exposes

*Recorded 2026-08-22.*

A decimal kernel that splits at the dot (`integer * 10^fractionDigits + fraction`, no shuffle) was
correct across 900,000 randomised cases and rejected: Mesh -14.2%, CITM -2.4%, the two payloads it
was for. `Numbers large integers` loses 5.1% without entering it, which identifies code size as the
cause: `emitNumber` grows from 255 to 570 instructions.

| row | shape | A | A+C | C only |
| --- | --- | --- | --- | --- |
| **`Real Mesh - bulk`** | 51% A / 44% C | 725 | **622 (-14.2%)** | **570 (-21.4%)** |
| `Numbers floats` | **0% eligible** | 714 | 488 (-31.7%) | 497 (-30.4%) |
| `Numbers small integers` | 100% A | 487 | 468 (-3.9%) | 348 (-28.5%) |
| `Real CITM catalog - bulk` | **94% C** | 2014 | 1966 (-2.4%) | 1983 (-1.5%) |
| `Numbers large integers` | 0% eligible | 1736 | 1647 (-5.1%) | 1647 (-5.1%) |
| `Real GSoC 2018 - bulk` | 0, control | 3867 | 3859 (-0.2%) | 3853 (-0.4%) |

### The variable that predicted all three kernels

*Recorded 2026-08-22.*

Neither coverage nor coverage times density predicted the outcomes; size added to `emitNumber` did.
That sets a ceiling of roughly one kernel (A); further number work has to come out of the existing
path, such as outlining the `.invalidNumber` construction and demoting the exponent walk.

| kernel | size added to `emitNumber` | eligible/KB on its best payload | outcome |
| --- | --- | --- | --- |
| **A**, unsigned integer <= 8 digits | +40 | 51 (mesh) | **+7.4%, +4.4%, landed** |
| B, unsigned integer 9-16 digits | +65 | 7.8 (citm) | -3.9% worst, rejected |
| C, decimal <= 16 digits | +315 | 42.6 (mesh) | **-14.2%, rejected** |

### `NumberInfo.digitCount`: measured and retained

*Recorded 2026-08-23.*

Deleting `digitCount` measured as noise: the optimizer already drops unread fields in specialized
sinks, and the 16-byte stride does not change. Since `NumberInfo` is public and external sinks may
read it, the field stays.

| row | with `digitCount` | without | change |
| --- | ---: | ---: | ---: |
| `Numbers floats - bulk` | 698 | 699 | +0.1% |
| `Numbers large integers - bulk` | 1702 | 1699 | -0.2% |
| `Numbers small integers - bulk` | 477 | 479, then 477 | 0 to +0.4% |
| `Real Canada - bulk discarding` | 437 | 429, then 432 | -1.1 to -1.8% |
| `Real Mesh - bulk discarding` | 361 | 364, then 363 | +0.6 to +0.8% |

### A backward read is invisible to assertions about values

*Recorded 2026-08-22.*

Kernel C shipped an out-of-bounds backward read that no test caught: unit tests padded the prefix,
and parser tests read into mapped memory. `NumberBufferBoundsTests` (numbers at offsets 0-24, bare
documents, byte-fed vs bulk) is kept; it only fails under `swift test --sanitize=address`, which CI
does not currently run.

---

## Native fixed-width arrays: `InlineArray`

*Recorded 2026-08-23.*

`InlineArray<count, Element>` now streams when `Element` does, gated to Apple OS 26. Slots start at
`Element.streamInitialValue()`, the frame's `pendingField` is the cursor, and `appendElement` gained
an `Int32` index rather than a second witness. The table measures 512 width-four arrays
(`Payload MB/s` p0, allocations per parse): +12% to +56%, with mallocs cut to ~30.

| element shape | dynamic | inline | change | malloc dynamic -> inline |
| --- | ---: | ---: | ---: | ---: |
| strings | 35 | 40 | +14% | 544 -> 32 |
| booleans | 36 | 52 | +44% | 544 -> 32 |
| numbers | 48 | 69 | +44% | 544 -> 32 |
| objects | 61 | 95 | +56% | 542 -> 30 |
| mixed object, bulk | 83 | 95 | +14% | 2,075 -> 27 |
| mixed object, 64-byte chunks | 74 | 83 | +12% | 2,075 -> 27 |

The real-world sweep shows no directional regression from the ordinary-array route check.

| structured bulk row | before | after |
| --- | ---: | ---: |
| Canada, SIMD coordinates | 434 | 437 |
| Mesh, SIMD influences | 364 | 361 |
| Canada, nested dynamic control | 134 | 137 |
| Mesh, nested dynamic control | 257 | 263 |
| CITM catalog | 448 | 444 |
| GSoC 2018 | 603 | 602 |
| GitHub events | 415 | 412 |
| LLM message | 709 | 715 |
| Twitter | 637 | 640 |
| Twitter escaped | 447 | 454 |

## Fixed-capacity strings: `StreamInlineString`

*Recorded 2026-08-25.*

> **Removed.** `StreamInlineString` is gone; its advantage came mostly from costs `StreamString`
> later shed. See "`StreamString` holds one reference". This section is history.

`StreamInlineString<capacity>` was an `Int32` count plus `InlineArray<capacity, UInt8>`: no
allocator, append is a compare and a memcpy, copy is O(capacity). It was an additive sibling
available only where `InlineArray` is, for fields the schema bounds.

### Overflow is a parse failure, and the appliers stopped returning `Bool`

*Recorded 2026-08-25.*

Overflow rejects rather than truncates: `streamAppend` and `applyString` now return
`StreamApplyResult` (`applied`, `unsupported`, `capacityExceeded`), measured free. Fixed arrays
with too many elements now report `capacityExceeded`.

### The chunk check that cost 8.7%, and the fold that did not

*Recorded 2026-08-25.*

Branching on the applier's result per `stringChunk` cost 8.7% on Twitter discarding (the branch
broke a tail call; outlining it was worse). Folding the result with `max`, `applied` lowest, and
reading it once at `stringEnd` cost +1.1%; the fold is sticky so a later fitting chunk cannot mask
a refusal. A byte-fed improvement on the discarding rows reproduced (+41% escaped Twitter) but is
not explained.

| row | HEAD | branch per chunk | `max` fold |
| --- | ---: | ---: | ---: |
| Real Twitter - bulk discarding | 2268 µs | 2465 (+8.7%) | 2294 (+1.1%) |
| Real LLM message - bulk discarding | 1758 µs | 1786 | 1751 |
| Real Twitter escaped - byte by byte | 10.0 ms | 7.3 ms | 7.15 ms |

| row | HEAD | now |
| --- | ---: | ---: |
| Real Twitter escaped - byte by byte discarding | 46 | 65 (+41%) |
| Real LLM message - byte by byte discarding | 22 | 25 (+13.6%) |
| Real LLM message string capacity hint - byte by byte discarding | 23 | 25 (+9%) |
| Real Twitter escaped - byte by byte | 72 | 72 |
| Real LLM message - byte by byte | 63 | 63 |

### The full real-world sweep, and why most of it says nothing

*Recorded 2026-08-25.*

A single pass over 62 `Real .*` rows swung -10% to +92%; re-measuring the largest movers with three
settled runs collapsed nearly all of it. Sweep to find candidates, then settle them with repeated
runs.

| row (Payload MB/s) | HEAD | now | change |
| --- | ---: | ---: | ---: |
| Real Twitter - bulk discarding | 349 | 349 | none |
| Real Mesh - bulk discarding | 185 | 184 | -0.3% |
| Real Twitter escaped - bulk discarding | 248 | 244 | -1.4% |
| Real LLM message string capacity hint - bulk discarding | 544 | 533 | -2.0% |

### The route the sink cannot name

*Recorded 2026-08-25.*

One leaf route, `valueInlineString`, plus the capacity carried in the schema's `fixedElementCount`
lets `PartialSink` append to any `StreamInlineString<N>` through a raw pointer, recognized at
`stringBegin` for fields, array elements and dictionary values. `_streamStringSchema` reads the
capacity from a static requirement on `StreamStringConvertible`, so the OS-26 gate stays in the
type's own file; the layout is checked against `MemoryLayout` at schema build. Optionals stay on
the generic path.

### Measured: it wins in a field and loses in a container, and the reason is the route

*Recorded 2026-08-25.*

On 2,048 records of three short string fields, the inline string wins as a bounded field (-9.6%
bulk, -37% snapshot per byte, -62% retains) and loses badly as a container element. The loss is the
missing closed container route (`arrayStreamString` has one), plus a per-element capacity cost;
until container routes exist the type is for bounded fields, or containers where allocation count
matters more than throughput.


| row | `StreamString` | `StreamInlineString` | change |
| --- | ---: | ---: | ---: |
| Fields, bulk | 2322 µs | 2099 µs | **-9.6%** |
| Fields, byte by byte | 4020 µs | 3582 µs | **-11%** |
| Fields, snapshot per byte | 19 ms | 12 ms | **-37%** |
| Fields, retains (snapshot per byte) | 671 K | 256 K | **-62%** |

| row | `StreamString` | inline 32 | inline 64 | inline 128 | inline 512 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Array short, bulk | 371 µs | 870 | 985 | 1201 | 2324 |
| Array short, byte by byte | 766 µs | 1257 | | | |
| Array short, snapshot per byte | 3381 µs | 3074 | 3228 | 3564 | 4899 |
| Dictionary short, bulk | 416 µs | 1350 | | | |
| Array medium, bulk mallocs | 2127 | 80 | | | |

### What the fold costs the string path, and the `|=` variant that did not help

*Recorded 2026-08-25.*

On synthetic string rows the `max` fold costs up to 10.8% (escaped bulk), tracking chunks per byte;
long single-chunk strings are flat. A `|=` over disjoint bits instead of `max` measured the same
and was reverted: the cost is the per-chunk load-store on the sink's storage, not the `cmov`.
Letting unbounded destinations skip the fold via the schema is untried and would need macro work
for object schemas.

| row | HEAD | `max` fold |
| --- | ---: | ---: |
| Fast Escaped string - bulk | 286 | 255 (-10.8%) |
| Fast Escaped string - 64B chunks | 264 | 241 (-8.7%) |
| Fast Long string - byte by byte | 75 | 70 (-6.7%) |
| Fast Escaped string - byte by byte | 116 | 110 (-5.2%) |
| Fast Long string - 64B chunks | 3196 | 3039 (~-5%) |
| Fast Long string - bulk | 8001 | 7946 | 
| Leaf Array String, Leaf Dictionary String, Non-ASCII bulk, Layer partial sink | | flat |

### The container gap is the route, not the storage

*Recorded 2026-08-25.*

Removing `StreamString`'s closed container route puts it where the inline string already is: parity
in an array, ~10% behind in a dictionary (zero-init). The container loss is entirely the missing
route; the capacity sweep is a separate effect. A route through the schema's `appendElement`
witness looked worth building.

| row | `StreamString` with route | `StreamString` without route | inline 32 (never had one) |
| --- | ---: | ---: | ---: |
| Array short, bulk | 371 µs | 887, 886, 887 | 881, 883, 913 |
| Dictionary short, bulk | 416 µs | 1238, 1240, 1380 | 1364, 1354, 1470 |

### The container route cannot be reached through indirection: built, measured, REJECTED

*Recorded 2026-08-25.*

Two witness-based dictionary routes were built and rejected: within noise of the generic path.
Sending concrete `StreamString` through the same witness costs 418 -> 1100 µs, so the concrete
route's advantage is that `_openValue` inlines into the sink, which no witness can recover. The
remaining options are a raw stride-parameterized container open or using the type only for bounded
fields. The route and `openValueStorage` were reverted; `inlineCapacity` was kept.

| dictionary, 2,048 short values | wall clock |
| --- | ---: |
| `StreamString`, concrete route (`openKnownDictionaryValue`) | 418 µs |
| `StreamString`, through a raw-returning witness | 1100, 1099, 1248 |
| `StreamInlineString<32>`, generic path | 1350, 1354, 1470 |
| `StreamInlineString<32>`, through `enterKey`, frame discarded | 1398, 1507, 1614 |
| `StreamInlineString<32>`, through a raw-returning witness | 1347, 1443, 1507 |

## The power-of-ten table: what a Swift array global actually cost

*Recorded 2026-08-27.*

`digitPow10Value`'s two `[Double]` globals cost a `__DATA` load behind an array header, emitted
once-init functions (paid in debug and Embedded), a sign branch with two bounds checks, and an
out-of-line call returning `Optional<Double>`. `Pow10_Double.c` replaced them with one `.rodata`
run of 633 `double`s reached through an `always_inline` accessor, checked bit-for-bit by
`Pow10TableTests`; the lookup becomes two instructions.

### Measured: a small win exactly where the census says it should be

*Recorded 2026-08-27.*

The exact path runs only when the significand fits 2^53 and the exponent is non-zero; the census
shows how often that is. Twelve interleaved rounds measured ~0.7% p0 wins on the rows that use it
and 0.00% on rows that cannot; mainly a correctness-and-size cleanup (664 lines to 32).

| payload | exponent == 0 (no lookup) | pow10 exact path | Eisel-Lemire / fallback |
| --- | ---: | ---: | ---: |
| `mesh.json` | 55.6% | **44.4%** | 0.0% |
| `canada.json` | 0.0% | **8.8%** | 91.2% |
| `citm_catalog.json` | 100.0% | 0.0% | 0.0% |

| row | p0 | p50 |
| --- | ---: | ---: |
| `Numbers floats - discarding` (nearly every token) | **-0.77%** | -1.80% |
| `Real Mesh - bulk discarding` (44%) | **-0.72%** | -0.80% |
| `Real Canada - bulk discarding` (8.8%) | +0.32% | -0.14% |
| `Real Canada - 16KB chunks discarding` | +0.39% | +1.93% |
| `Numbers large integers - discarding` (never reaches it) | 0.00% | -0.87% |
| `Numbers floats - bulk` (fast sink, no conversion) | 0.00% | -0.15% |

### Follow-up: only 0 ... 22 are exact scales

*Recorded 2026-08-27.*

Rounded powers from `10^23` up can double-round (`1639941743779501e23` landed one ULP low), so the
exact-path table is now `10^0 ... 10^22` (184 bytes); larger exponents go to Eisel-Lemire or the
standard parser. x86-64: Canada discarding 1.4-1.8% faster p0, Mesh flat, the synthetic exact-float
row 1.3% slower (unexplained).

### Follow-up: the Eisel-Lemire table covers all of `Double`

*Recorded 2026-08-27.*

Eisel-Lemire's table now has all 651 rows, `10^-342 ... 10^308` (10,416 bytes), generated by
`Scripts/generate_pow10_128.py`. Wide-exponent `[Double]` conversion is 17.5x faster and its
allocations fall from 6,102 to 232; a normal-exponent guard on the subnormal rounding recovered
about half of Canada's initial 2% regression, and the out-of-line form was worse.

| row | 45 rows | 651 rows | change |
| --- | ---: | ---: | ---: |
| wide exponents, `[Double]` | 7,414,643 ns | **422,997 ns** | **17.5x faster** |
| wide exponents, raw sink | 198,746 ns | **197,695 ns** | -0.5% |
| ordinary floats, `[Double]` | 120,338 ns | **119,705 ns** | -0.5% |
| Canada, `[Double]` | 225 MB/s | 222 MB/s | -1.3% |
| Mesh, `[Double]` | 3,906,340 ns | 3,910,223 ns | +0.1% |

## Where `canada.json`'s number budget actually goes

*Recorded 2026-08-27.*

A standalone probe of the transcribed kernels, adding one stage at a time, split canada's 33.6 ns
per number (x86-64). There is no dominant stage; the largest is token decomposition (fraction and
exponent), not the scan or the conversion.

| stage | ns/number | delta | share of 33.6 |
| --- | --- | --- | --- |
| number-run scan, SIMD16 | 8 | 8 | 24% |
| \+ integer digit accumulation | 12 | 4 | 12% |
| \+ sign, dot, fraction, exponent | 23 | **11** | **33%** |
| \+ Eisel-Lemire | 30 | 7 | 21% |
| full parse (parser state machine, sink, containers) | 33.6 | 3.6 | 11% |

### Three hypotheses, all measured, all rejected

*Recorded 2026-08-27.*

Eisel-Lemire is 7 ns (21%), not dominant; the earlier 18 ns figure used the wrong baseline.
Returning a bare `Double` with an `inout Bool` was slower than `Double?`. A SWAR conversion of the
scalar digit tail measured 29 ns against 23, because counting the tail walks the digits twice.

### Two facts that bound what is worth trying

*Recorded 2026-08-27.*

91.2% of canada's numbers exceed 2^53 and reach Eisel-Lemire, a property of full-precision GeoJSON.
The second 64x64 multiply fires on 0.76% of tokens and Eisel-Lemire declines on 0.145%; neither is
worth optimizing.

### The pow10 table is not a cache problem

*Recorded 2026-08-27.*

canada's exponents span -15 to 0, so the working set is 16 rows in four L1-resident cache lines.

## Cache line behaviour in the x86 scanners: measured, and it is not the constraint

*Recorded 2026-08-27.*

Three alignment and load-port theories were measured against. Four overlapping unaligned loads in
the AVX2 UTF-8 kernel beat the simdjson `permute2x128`/`alignr` shape by 17-19%; aligning the string
scan to 32 bytes is 4-56% worse because short runs end in the prologue; and canada's number scan is
not bandwidth-bound (2577 MB/s standalone vs 594 full parse). The scan was never a large share of
the work.

| document | four overlapping loads | one load + `permute2x128`/`alignr` |
| --- | --- | --- |
| `llm_message` | **13926** | 11497 (-17%) |
| `twitter` | **14350** | 11692 (-19%) |
| `canada` | **15101** | 12479 (-17%) |

| document | unaligned `loadu` | align-to-32 first |
| --- | --- | --- |
| `llm_message` | **2397** | 1962 (-18%) |
| `twitter` | **1899** | 830 (**-56%**) |
| `canada` | **2577** | 2480 (-4%) |

## Inter-block ILP in the AVX2 scanners

*Recorded 2026-08-28.*

The AVX2 UTF-8 validator's main loop now validates two 32-byte blocks and pays one `vptest` per 64
bytes; the gain is mainly the removed reduction and loop control (+0.4 to +1.1%, function 635 to
871 bytes). A late two-block string-scan unroll was measured and rejected: +14.1% on the long
synthetic row but GSoC -2.0% and LLM -0.8%, so the one-block loop (228 bytes) remains.

| row | 32 byte loop | 64 byte loop | change |
| --- | ---: | ---: | ---: |
| Fast Non-ASCII string, bulk | 5243 MB/s | **5299 MB/s** | **+1.1%** |
| Fast Non-ASCII string, 64 B chunks | **850 MB/s** | 848 MB/s | -0.2% |
| Real LLM message, bulk | 2241 MB/s | **2251 MB/s** | **+0.4%** |
| Real LLM message, 16 KB chunks | 2211 MB/s | **2223 MB/s** | **+0.5%** |
| Real Twitter, bulk | 734 MB/s | **735 MB/s** | +0.1% |
| Real Twitter, 16 KB chunks | 724 MB/s | **727 MB/s** | +0.4% |

| row | one block | late two-block | change |
| --- | ---: | ---: | ---: |
| Fast Non-ASCII string, bulk | 7415 MB/s | **8463 MB/s** | **+14.1%** |
| Fast Non-ASCII string, 64 B chunks | **893 MB/s** | 878 MB/s | **-1.7%** |
| Real GSoC 2018, bulk | **2091 MB/s** | 2049 MB/s | **-2.0%** |
| Real GitHub events, bulk | 880 MB/s | **895 MB/s** | +1.7% |
| Real LLM message, bulk | **2255 MB/s** | 2237 MB/s | **-0.8%** |
| Real Twitter, bulk | 736 MB/s | **746 MB/s** | +1.4% |

## Inter-block ILP on arm64: reduction removal pays, latency removal does not

*Recorded 2026-08-28.*

The arm64 counterpart of the AVX2 work is not symmetric: of four candidates built and measured, two
landed and two were rejected. Removing a per-block cross-lane reduction (`uminv`/`umaxv` plus
`fmov`) is the lever; manual interleaving is not, and neither is latency that sits beside a loop
rather than inside it.

### Landed: defer the UTF-8 validator's per-block reduction

*Recorded 2026-08-28.*

`streamValidateUTF8Shimmed` now ORs each block's error vector into an accumulator and reduces once
per run (one `fmov` in the whole function), since the validator answers only valid or invalid.
Non-ASCII bulk +5.7%, LLM +3.0%, no regressions. A 2x unroll on top was measured and rejected: the
target rows were identical while canada, gsoc and citm lost 2-3% to code growth.

| row | before | after | change |
| --- | ---: | ---: | ---: |
| Fast Non-ASCII string, bulk | 7013 MB/s | **7415 MB/s** | **+5.7%** |
| Real LLM message, bulk | 3571 MB/s | **3677 MB/s** | **+3.0%** |
| Fast Non-ASCII string, 64 B chunks | 2071 MB/s | **2117 MB/s** | **+2.2%** |

### Landed: the arm64 movemask, and the lane the mask already held

*Recorded 2026-08-28.*

`streamNumberRunEndShimmed`'s per-lane `umov`/`cbz` ladder (about sixty inlined instructions) was
replaced by `stream_parsing_movemask_u8`, a C leaf wrapping `vshrn_n_u16`, with the bound check
fused into the lane computation. Mesh +5.6%, Canada +3.1%, no real payload regressing; the one loser
is `Payloads.matrix` (-7.9%, one-to-three digit integers), where the ladder's parallel `umov`s exit
sooner and no movemask formulation can win. The earlier `uminv` rejection was dependent latency to
the lane, not vector work. A plain movemask and a loop-test-only movemask were both rejected; the
gain is deleting the exit.

| row | ladder | movemask | change |
| --- | ---: | ---: | ---: |
| Numbers floats, bulk | 666 MB/s | **783 MB/s** | **+17.6%** |
| Real Mesh, bulk | 714 MB/s | **754 MB/s** | **+5.6%** |
| Numbers wide exponent floats, bulk | 1629 MB/s | **1708 MB/s** | **+4.8%** |
| Numbers large integers, bulk | 1622 MB/s | **1684 MB/s** | **+3.8%** |
| Real Canada, bulk | 907 MB/s | **936 MB/s** | **+3.1%** |
| Real GitHub events, bulk | 1737 MB/s | **1757 MB/s** | +1.2% |
| Real LLM message, bulk | 3545 MB/s | **3580 MB/s** | +1.0% |
| Real CITM catalog, bulk | 2010 MB/s | **2028 MB/s** | +0.8% |
| Real GSoC 2018, bulk | **4061 MB/s** | 4054 MB/s | -0.2% |
| Real Twitter, bulk | **1454 MB/s** | 1450 MB/s | -0.2% |
| `Payloads.matrix` (both spellings) | **453 MB/s** | 418 MB/s | **-7.9%** |

### Rejected: the whitespace run end, in two forms

*Recorded 2026-08-28.*

Reading `streamWhitespaceRunEnd`'s mask as two `UInt64`s and taking the lane from `rbit`/`clz`
measured mixed twice (CITM/Twitter up, GSoC/Pretty down), and the exit-only variant was worse,
falsifying the hypothesis behind it. Not kept.

| variant | CITM bulk | Twitter bulk | GSoC | Pretty printed |
| --- | ---: | ---: | ---: | ---: |
| body and exit | **+1.2%** | **+1.7%** | -1.3% | -0.5% |
| exit only, body byte-identical | +0.6% | +0.4% | -0.9% | -0.5% |

### Rejected: the string run hit path, where the chain was real and the cost was not

*Recorded 2026-08-28.*

`consumeStringRun`'s hit path had a nine-deep chain and a stack spill once per span. Both a
lane-only movemask and a full word-domain rewrite (spill gone, frame `0xb0` to `0x90`) measured
nothing: medians +0.14% and +0.07%, CITM -0.9%. Removing a serial chain pays where the chain is the
loop, not where it sits beside it; prefer per-iteration targets. It also shows the C port's -37.8%
on `Fast Non-ASCII string, 64 B chunks` was the boundary, not the algorithm.

### Two methodology notes

*Recorded 2026-08-28.*

Discard any row whose `Payload MB/s` and wall-clock metrics disagree by more than about 1.5 points.
The machine drifts at the 1% level across sweeps; eight-round two-way sweeps are steadier, and
1%-magnitude rows in a single sweep should not be given signs.

---

## The byte the whitespace scan already loaded

*Recorded 2026-08-28.*

`streamWhitespaceEndByte` returns `(end, byte)` so `consumeStructuralRun` dispatches from a
register instead of reloading the byte `streamWhitespaceEnd` just compared. The register allocator
also stopped spilling `depth` on the back edge (stack accesses 89 -> 83); the two effects cannot be
separated. Two eight-round sweeps: every row +0.2 to +3.4%, byte-fed flat, no regressions.

| document | before | after | sweep 1 | sweep 2 |
| --- | ---: | ---: | ---: | ---: |
| CITM catalog, bulk | 1305 MB/s | 1344 MB/s | +2.68% | +2.99% |
| GSoC 2018, bulk | 2525 | 2611 | +2.69% | +3.41% |
| GitHub events, bulk | 1075 | 1106 | +2.60% | +2.88% |
| Canada, bulk | 550 | 561 | +2.00% | +2.00% |
| **Twitter, bulk** | **912** | **929** | **+1.86%** | **+1.86%** |
| Twitter, 16 KB chunks | 903 | 917 | +1.66% | +1.55% |
| Twitter escaped, bulk | 598 | 607 | +1.51% | +1.51% |
| LLM message, bulk | 2429 | 2457 | +0.82% | +1.15% |
| Mesh, bulk | 435 | 437 | +0.46% | +0.23% |
| LLM message / Twitter escaped, byte by byte | — | — | flat | flat |

### The same defect at the fusion site: built, measured, REJECTED

*Recorded 2026-08-28.*

The same substitution in `fuseAfterValue` removed the duplicate load as intended and was rejected:
Twitter -6.67%, CITM -6.40%, byte-fed -6 to -8%, with only number- and long-string-heavy documents
gaining. It extends the byte's live range backward across the whitespace branch in
`consumeStringRun` and `consumeNumber`, which are at their register ceiling. Only the structural
run change is in the tree.

| document | structural run only | + fusion site |
| --- | ---: | ---: |
| Twitter, bulk | 930 MB/s | 868 (**-6.67%**) |
| CITM catalog, bulk | 1343 | 1257 (-6.40%) |
| GitHub events, bulk | 1109 | 1058 (-4.60%) |
| Twitter, 16 KB chunks | 918 | 874 (-4.79%) |
| GSoC 2018, bulk | 2601 | 2547 (-2.08%) |
| Twitter escaped, bulk | 607 | 598 (-1.48%) |
| LLM message, bulk | 2455 | 2571 (+4.73%) |
| Mesh, bulk | 437 | 454 (+3.89%) |
| Canada, bulk | 561 | 569 (+1.43%) |
| LLM message, byte by byte | 81 | 76 (**-6.17%**) |
| Twitter escaped, byte by byte | 91 | 84 (**-7.69%**) |

---

## Two dispatchers, one transformation, opposite signs

*Recorded 2026-08-29.*

Feeding the switch from a register and replacing the jump table with a ladder was applied to both
`parse` (per token) and `consumeStructural` (per structural byte), with opposite results. What is
being dispatched on decides it, not the transformation.

### Landed: the structural step's state ladder

*Recorded 2026-08-29.*

`consumeStructural`'s `switch state` became a ladder over `rawValue`, reaching each arm in one to
three compares; `consumeStructuralRun` went 2128 -> 1961 bytes and from two indirect branches to
one. Every row positive (Canada +5.7%, Twitter +2.5%), byte-fed flat.

| document | before | after | sweep 1 | sweep 2 |
| --- | ---: | ---: | ---: | ---: |
| Canada, bulk | 561 MB/s | 593 MB/s | +5.70% | +5.70% |
| CITM catalog, bulk | 1342 | 1411 | +5.14% | +4.99% |
| GitHub events, bulk | 1108 | 1163 | +4.96% | +4.96% |
| Mesh, bulk | 436 | 456 | +4.59% | +4.59% |
| Twitter, 16 KB chunks | 918 | 958 | +4.36% | +4.13% |
| GSoC 2018, bulk | 2603 | 2693 | +3.46% | +3.23% |
| **Twitter, bulk** | **928** | **951** | **+2.48%** | **+2.48%** |
| LLM message, bulk | 2455 | 2505 | +2.04% | +2.04% |
| Twitter escaped, bulk | 607 | 615 | +1.32% | +1.65% |
| byte-fed canaries | — | — | flat | flat |

### Rejected: the same ladder in `parse`

*Recorded 2026-08-29.*

Four variants were tried in `parse`. Returning `(Int, State)` to feed the switch from a register
gained 1-3% on string documents but lost canada -4.81%, Mesh -8.49% and byte-fed 5-14%. Replacing
the table with a ladder lost about 5 points even at the smallest `parse` size, so branch structure,
not size, controls it: per-token state is predictable as a sequence (indirect predictor) but not as
binary tests (ladder). The structural-run attribution between branch removal and shrink remains
unsplit.

| variant | `parse` | dispatch | Twitter bulk | Twitter escaped, byte fed |
| --- | ---: | --- | ---: | ---: |
| HEAD | 967 | table, state from memory | — | — |
| register-feed | 1036 | table, state from register | **+1.29%** | -14.3% |
| register-feed, narrowed | 1053 | table, state from register | +1.18% | -11.8% |
| **+ ladder** | **1032** | **ladder**, state from register | **-4.31%** | -15.2% |
| + ladder, narrowed | 1064 | **ladder**, state from register | **-5.28%** | -20.9% |

### Rejected: the structural step's byte ladder

*Recorded 2026-08-29.*

Hoisting quote and digit ahead of `.value`'s byte switch made LLVM re-form the table for the
remaining arms (1961 -> 1979 bytes) and lost 1.5-3.9% across documents. Only the state ladder is in
the tree.

---

## The structural run is limited by its size, not by its iteration count

*Recorded 2026-08-29.*

`"key": "value"` costs three structural-run iterations, two of which only move one byte. Four
variants that removed them were built, and all four lost; how they lost settles the open size
versus branch question from the previous section.

| iteration | byte | state on entry | ladder rungs walked |
| --- | --- | --- | ---: |
| 1 | `"` | `.key` / `.firstKey` | 3 |
| 2 | `:` | `.afterKey` | 4 |
| 3 | `"` | `.value` | 1 |

### Reordering the ladder to match what the run actually sees

*Recorded 2026-08-29.*

Moving `.afterKey` up the ladder cut a member's compares from eight to six and lost 3-10% on
everything: `.afterValue`, demoted, is taken on every `}` and `]`, so canada lost 5.90%, and the
pure reorder grew the function 1961 -> 1997 bytes.

| benchmark | control | reordered | |
| --- | ---: | ---: | ---: |
| Fast Dictionary, bulk | 545 MB/s | 492 | **-9.72 / -10.26%** |
| Real Twitter, 16 KB | 957 | 899 | -6.06 / -6.12% |
| Real Canada, bulk | 593 | 558 | -5.90 / -5.90% |
| Real GitHub events, bulk | 1167 | 1102 | -5.57 / -5.59% |
| Real Twitter, bulk | 952 | 908 | **-4.62 / -4.68%** |
| Real GSoC 2018, bulk | 2691 | 2567 | -4.61 / -4.44% |
| Real Mesh, bulk | 457 | 436 | -4.60 / -4.18% |
| Real CITM catalog, bulk | 1408 | 1344 | -4.55 / -4.28% |
| Real Twitter escaped, bulk | 615 | 596 | -3.09 / -3.18% |

### Peeling the colon, two ways

*Recorded 2026-08-29.*

The key arm checks the byte after the closing quote and sets `.value` directly, either through the
whitespace scanner (+207 bytes, worse on every row) or a bare compare (+49 bytes, Twitter +1.58%
but canada and Mesh -3.7%). Documents that never execute the new code pay for it in proportion to
its size.

| benchmark | control | scanner (+207) | compare (+49) |
| --- | ---: | ---: | ---: |
| Real Twitter, bulk | 950 MB/s | 928 (-2.32 / -2.32%) | 965 (**+1.58 / +1.53%**) |
| Real Twitter, 16 KB | 957 | 916 (-4.28 / -4.19%) | 962 (+0.52 / +0.63%) |
| Fast Pretty printed, byte fed | 90 | 89 (-1.11 / -1.11%) | 92 (+2.22 / +1.67%) |
| Fast Long string, byte fed | 77 | 79 (+2.60 / +0.00%) | 79 (+2.60 / +1.30%) |
| Real CITM catalog, bulk | 1407 | 1308 (-7.04 / -6.85%) | 1397 (-0.71 / -0.43%) |
| Real GSoC 2018, bulk | 2687 | 2559 (-4.76 / -4.66%) | 2657 (-1.12 / -1.42%) |
| Real GitHub events, bulk | 1168 | 1101 (-5.74 / -5.66%) | 1149 (-1.63 / -1.54%) |
| Fast Dictionary, bulk | 538 | 503 (-6.51 / -6.45%) | 532 (-1.12 / -2.25%) |
| Real Mesh, bulk | 456 | 428 (-6.14 / -6.15%) | 439 (-3.73 / -3.74%) |
| Real Canada, bulk | 593 | 539 (-9.11 / -9.36%) | 571 (**-3.71 / -3.71%**) |

### The variant that removes more work and is slower

*Recorded 2026-08-29.*

Extending the peel through the value's opening quote makes `"key": "value"` one iteration instead
of three (+214 bytes), and it is 4.7 points slower than the colon-only peel on Twitter and ten on
CITM. Iteration count is not what this loop is paying.

| benchmark | control | peel colon (+49) | peel colon and quote (+214) |
| --- | ---: | ---: | ---: |
| Real Twitter, bulk | 951 MB/s | 966 (**+1.58 / +1.58%**) | 921 (**-3.15 / -3.11%**) |
| Real Twitter, 16 KB | 956 | 961 (+0.52 / +0.37%) | 908 (-5.02 / -5.29%) |
| Real CITM catalog, bulk | 1408 | 1397 (-0.78 / -0.43%) | 1264 (-10.23 / -9.91%) |
| Real Mesh, bulk | 457 | 438 (-4.16 / -3.74%) | 413 (-9.63 / -9.45%) |
| Fast Dictionary, bulk | 533 | 525 (-1.50 / -1.61%) | 493 (-7.50 / -7.28%) |
| Real GitHub events, bulk | 1169 | 1148 (-1.80 / -1.55%) | 1101 (-5.82 / -5.81%) |
| Real Canada, bulk | 593 | 571 (-3.71 / -3.55%) | 558 (-5.90 / -5.74%) |
| Real GSoC 2018, bulk | 2685 | 2651 (-1.27 / -1.23%) | 2561 (-4.62 / -4.78%) |
| Fast Pretty printed, byte fed | 90 | 92 (+2.22 / +2.22%) | 88 (-2.22 / -2.22%) |

### What the four say together

*Recorded 2026-08-29.*

Loss tracks growth of `consumeStructuralRun`, not work removed, which settles the earlier split
toward size. Standing constraint: anything added to the run is paid by every document (49 bytes
cost canada 3.7%), so the remaining `"key": value` cost has to come from the key path costing less.
Handing back the colon from `streamStringRun`'s register stays unbuilt, since no peel proved itself.

| variant | Δ size | work removed | Twitter, bulk |
| --- | ---: | --- | ---: |
| state ladder (landed) | **-167** | one indirect branch per byte | **+2.48%** |
| bare-compare colon peel | +49 | one iteration in three | +1.58% |
| ladder reorder | +36 | two ladder compares per member | -4.68% |
| scanner colon peel | +207 | one iteration in three | -2.32% |
| colon and quote peel | +214 | two iterations in three | -3.15% |

### The tests stayed

*Recorded 2026-08-29.*

`KeyColonFusionTests` and the key-rejection offset cases in `ErrorOffsetTests` outlive the variants:
they assert the full tree at every chunk boundary and byte by byte across colon spacing, value
shapes, escaped and long keys and malformed spellings, and that a rejected key reports its own
offset.

## String values and literals finish inside the structural run

*Recorded 2026-08-29.*

The saving came from the value path rather than the key path: the structural run already contains
the string scanner, so a token whose closing quote is in the chunk can be finished there without a
state change or a return to `parse`.

### What a member actually cost

*Recorded 2026-08-29.*

Profiling Twitter bulk showed every value ending the run, re-dispatching through `parse` and paying
`consumeStringRun`'s frame and prologues, and literals never fusing the comma; roughly a quarter of
all instructions were those transitions, not token work.

### The change

*Recorded 2026-08-29.*

`consumeStructural` tests for `"` once ahead of the state ladder and finishes any unescaped key or
value closed in the chunk with `streamStringRun`; `t` / `f` / `n` whole in the chunk are one 32-bit
compare. Cut or escaped tokens leave as before and byte-fed input never takes the new branches.
Twitter +11.8% p0, Literals +45.4%, GSoC -2.5%.

| benchmark | before | after | Δp0 | Δp50 |
| --- | ---: | ---: | ---: | ---: |
| Real Twitter, bulk | 1496 / 1458 | 1673 / 1619 | **+11.8%** | **+11.0%** |
| Real Twitter escaped, bulk | 1057 / 1037 | 1232 / 1205 | +16.6% | +16.2% |
| Real GitHub events, bulk | 1764 / 1746 | 1865 / 1826 | +5.7% | +4.6% |
| Real Canada, bulk | 966 / 944 | 990 / 960 | +2.5% | +1.7% |
| Real LLM message, bulk | 3780 / 3673 | 3860 / 3765 | +2.1% | +2.5% |
| Fast Literals, bulk | 643 / 629 | 935 / 911 | +45.4% | +44.8% |
| Real Mesh, bulk | 803 / 784 | 808 / 781 | +0.6% | -0.4% |
| Real CITM catalog, bulk | 2084 / 2037 | 2074 / 2013 | -0.5% | -1.2% |
| Fast Pretty printed users, bulk | 1147 / 1126 | 1126 / 1112 | -1.8% | -1.2% |
| Real GSoC 2018, bulk | 4160 / 4075 | 4058 / 3965 | **-2.5%** | -2.7% |
| every byte-fed row | | | ±1.4% | |

### The GSoC loss, and the fix that was measured and not kept

*Recorded 2026-08-29.*

GSoC's escaped values are scanned twice (in the run up to the backslash, then again by
`consumeStringRun`). A handoff at the backslash returned GSoC to flat but grew the run and cost
Twitter 2% and Pretty printed users 3-7%, so it was not kept; it is the first thing to revisit if the
run gets cheaper to grow.

### The cliff, named

*Recorded 2026-08-29.*

An `@inline(__always)` twin of `streamWhitespaceRunEnd` in the run measured -23..-28% on every text
payload: the SIL inliner stopped inlining `consumeStructural` and emitted a `bl` per structural byte.
Before trusting a structural-run number, check the specialised run's `bl` targets with `objdump`;
the six inline `throw` expansions are the budget to reclaim first.

---

## Stage-1 extraction: the census and the budget

*Recorded 2026-08-24.*

Pre-work for a two-pass design (classify a whole chunk, then walk positions instead of scanning
bytes): a corpus census and the cost of the extraction pass alone, measured in the benchmark-only
`Benchmarks/StageOneLab` C target with `Stage1 *` rows. The earlier bitmap microbench did not test
bits-to-indices and rules out neither direction.

### The census

*Recorded 2026-08-24.*

Index entries per 64-byte block over each corpus. Number-dense corpora would carry an index more
than half the document's size; string-heavy ones have 70-94% of blocks with nothing to stop at, so
the string mask alone is most of the information.

| corpus | str% | ws% | num% | entries | idx as %doc (u32) | entries/block p50 | blocks with 0 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| canada | 0 | 0 | 90 | 334,385 | 59% | 10 | 0% |
| mesh | 0 | 10 | 79 | 153,285 | 85% | 8 | 0% |
| citm_catalog | 13 | 71 | 7 | 162,594 | 38% | 6 | 0% |
| twitter | 59 | 26 | 2 | 73,362 | 47% | 8 | 13% |
| twitterescaped | 83 | 0 | 2 | 73,362 | 52% | 8 | 31% |
| github_events | 71 | 18 | 1 | 6,547 | 40% | 6 | 16% |
| gsoc-2018 | 89 | 8 | 0 | 109,969 | 13% | 0 | 70% |
| llm_message | 99 | 0 | 0 | 11,850 | 4% | 0 | 94% |

### The kernel and its verification

*Recorded 2026-08-24.*

`StageOneLab.c` restates simdjson's stage 1 for streaming (escape finder with carry, PMULL quote
parity, `tbl` classifier, NEON movemask, bits-to-indices) with state carried across windows and no
padding. A Swift scalar reference checks it over all corpora, boundary-crossing backslash runs and
500 seeded buffers before any row runs; the tables classify NUL as whitespace.

### The budget: what stage 1 costs against the parser it would tax

*Recorded 2026-08-24.*

Each pass's cost as a share of the current parser's time (p50 MB/s). A full index is ruled out on
string-heavy corpora (64% tax on gsoc); on canada and mesh it costs 18-22%, leaving stage 2 ~80% of
the budget for batched number parsing. The string mask (3-9% on slow corpora) stays alive as a
substrate if it buys back its tax.

| corpus | parser | string mask | full masks | index | tax: mask | full | index |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| canada | 869 | ~23,000 | 8,567 | 4,021 | 3.8% | 10.1% | 21.6% |
| mesh | 709 | ~23,000 | 8,559 | 4,009 | 3.1% | 8.3% | 17.7% |
| citm_catalog | 1,988 | ~23,000 | 8,735 | 5,643 | 8.6% | 22.8% | 35.2% |
| twitter | 1,451 | ~23,000 | 8,567 | 5,031 | 6.3% | 16.9% | 28.8% |
| twitterescaped | 1,055 | ~23,000 | 8,783 | 4,819 | 4.6% | 12.0% | 21.9% |
| github_events | 1,725 | ~23,000 | 8,783 | 5,503 | 7.5% | 19.6% | 31.3% |
| gsoc-2018 | 3,863 | ~23,000 | 8,743 | 6,071 | 16.8% | 44.2% | 63.6% |
| llm_message | 3,453 | ~23,000 | 8,567 | 7,399 | 15.0% | 40.3% | 46.7% |

### The window sweep, and what the L1 hypothesis actually earned

*Recorded 2026-08-24.*

With a synthetic stage 2, 32 KB windows win on all four corpora; whole-document costs 4-6% and 512B
costs 5-24% to per-window overhead. All corpora fit in the 12 MB L2, so this measured L1 vs L2, not
DRAM; no cliff on larger documents is claimed.

| corpus | 512B | 4KB | 32KB | 256KB | whole |
| --- | ---: | ---: | ---: | ---: | ---: |
| canada | 3,379 | 3,549 | **3,637** | 3,499 | 3,441 |
| citm_catalog | 4,599 | 4,883 | **5,115** | 4,971 | 4,911 |
| gsoc-2018 | 5,391 | 5,751 | **5,855** | 5,691 | 5,603 |
| twitter | 3,557 | 4,395 | **4,651** | 4,471 | 4,431 |

### What this stage of the experiment decides

*Recorded 2026-08-24.*

Ruled out: full-index two-pass as the general architecture, and 512B windows. Ruled in for a
vertical slice: tier 2 plus batched number parsing on number-dense corpora at 32 KB windows.
Undecided: whether tier 1's string mask pays as a substrate. Any of it sits behind a chunk-size gate
at `parse`; byte-fed is untouched.

## The windowed walk: first pass

*Recorded 2026-08-24.*

Stage 1 moved into `StreamParsingShims` as `stream_parsing_index_window` (u32 positions plus
`needs_scan` and `non_ascii` block bitmaps), with a consuming walk in `Fast/JSONParserWindow.swift`
behind a chunk-size gate in `parse`, off by default (`windowThreshold: .max`). The gate measured
clean (canada +0.1%, mesh +0.3%, byte-fed 0 to +3.6%) only once the loop stayed in `parse` and
`parse(byte:)` drove `dispatchOnce` itself; the dispatcher's functions are unchanged.

### The seam, and the bug it had first

*Recorded 2026-08-24.*

The walk hands a cut string, a number or literal reaching the chunk end, or an escaped key back to
the dispatcher for one step. Re-indexing from the handed-back position hung on a cut string; the fix
forces one `dispatchOnce` and resumes in the existing index past the dispatcher's cursor.

### Correctness

*Recorded 2026-08-24.*

`WindowedParserTests` compares every sink event from the dispatcher and the windowed path at the
same chunking across 58 documents; `StageOneIndexTests` pins the kernel against a scalar reference,
with NUL now rejected as a scalar. Full suite green.

### The measurement

*Recorded 2026-08-24.*

Windowed vs dispatcher, three interleaved rounds: only GitHub events gains (+4.8%); the rest lose
4-39%. The walk is 25-37% faster on structure-heavy corpora but loses it all to the index tax, and on
number-dense corpora it is not faster at all, which inverts the budget section's choice of canada
and mesh.

| corpus | dispatcher | windowed | delta | index share of dispatcher time | walk alone / dispatcher |
| --- | ---: | ---: | ---: | ---: | ---: |
| GitHub events | 1,784 | 1,869 | **+4.8%** | 32% | 0.63 |
| CITM catalog | 2,063 | 1,915 | -7.2% | 37% | 0.71 |
| Twitter | 1,485 | 1,422 | -4.2% | 30% | 0.75 |
| Mesh | 743 | 662 | -10.9% | 19% | 0.94 |
| Canada | 949 | 794 | -16.3% | 24% | 0.96 |
| Twitter escaped | 1,078 | 876 | -18.7% | 22% | 1.01 |
| GSoC 2018 | 4,227 | 2,801 | -33.7% | 70% | 0.81 |
| LLM message | 3,631 | 2,209 | -39.2% | 42% | 1.22 |

### What this decides, and what it leaves open

*Recorded 2026-08-24.*

The plain walk fails the parity floor on canada/mesh and lands gated off. The lever is the index:
extraction is roughly half of stage 1, and CITM needs the index at about 7 GB/s (from 5.6) to break
even. The windowed rows stay in the suite.

## Index cost: three moves, and what each one bought

*Recorded 2026-08-24.*

The three index-cost moves named above were built in sequence, each measured against the previous
build with the differential suite as the gate; the final table is a three-round interleaved A/B
against HEAD.

### The extraction loop was not unrolled

*Recorded 2026-08-24.*

The bits-to-indices `for (i < 8)` had compiled to a branching loop; spelled out as eight slots it is
six instructions per index with no branch. The non-ASCII flag became a `vmaxvq` reduce.

### Move 2, first form: the gap check — REJECTED as built

*Recorded 2026-08-24.*

Not indexing numbers and literals, with the walk skipping whitespace before every entry, gained
canada +10% but was rejected: CITM -13% and mesh -8%, because pretty-printed input ran a vector
whitespace scan per entry.

### Move 2, second form: index a scalar only when whitespace precedes it

*Recorded 2026-08-24.*

Indexing `scalar & (whitespace << 1)` makes the walk's gap check one load and compare: canada
+14.0%, GitHub +11.2%, mesh -6.9% (unexplained, open). A quote at bit 0 bug in the "all inside a
string" test was caught by the byte-soup reference.

| corpus | windowed before | after | delta |
| --- | ---: | ---: | ---: |
| canada | 794 | 905 | **+14.0%** |
| github_events | 1,869 | 2,079 | **+11.2%** |
| twitterescaped | 876 | 967 | +10.4% |
| twitter | 1,422 | 1,491 | +4.9% |
| gsoc-2018 | 2,801 | 2,925 | +4.4% |
| llm_message | 2,209 | 2,277 | +3.1% |
| citm_catalog | 1,915 | 1,962 | +2.5% |
| mesh | 662 | 616 | −6.9% |

### Move 1: the two-speed block

*Recorded 2026-08-24.*

Blocks that are string interior edge to edge take their flags from `vminvq`/`vmaxvq` and skip
classification and extraction: gsoc-2018 windowed +14.3%, llm_message +18.9%, others within ±1.4%.

### Move 3: routing sparse windows to the dispatcher

*Recorded 2026-08-24.*

A window after one averaging under 3 entries per block goes through `dispatchOnce` steps, with every
eighth window indexed regardless. gsoc-2018 and llm_message land at −5% against the dispatcher, from
−34/−39%.

### Where it stands, against HEAD (three rounds, interleaved)

*Recorded 2026-08-24.*

Windowed now wins on GitHub (+20.8%), breaks even on Twitter and loses 4-6% elsewhere, matching the
census; mesh bulk (-16.1%) is the open question, since 16 KB chunks run it at -3.0%. Gate off, the
dispatcher rows are within ±1% of HEAD, and 16 KB vs 32 KB windows measured within ±1%.

| corpus | dispatcher bulk | windowed bulk | delta | 16 KB chunks windowed vs dispatcher |
| --- | ---: | ---: | ---: | ---: |
| github_events | 1,780 | 2,151 | **+20.8%** | +19.7% |
| twitter | 1,504 | 1,514 | +0.7% | +1.6% |
| canada | 934 | 893 | −4.4% | −4.5% |
| gsoc-2018 | 4,219 | 3,973 | −5.8% | −4.2% |
| llm_message | 3,613 | 3,431 | −5.0% | −5.0% |
| citm_catalog | 2,081 | 1,965 | −5.6% | −6.4% |
| twitterescaped | 1,086 | 989 | −8.9% | −9.4% |
| mesh | 738 | 619 | −16.1% | **−3.0%** |
## Shape loops: the walk stops being a state machine

*Recorded 2026-08-24.*

Two speculative loops in `Fast/JSONParserShapes.swift` replace the walk's per-token
`(state, byte)` state machine for runs whose shape the index shows in advance. Each element is
pattern-checked from the index before any sink call, and the first off-pattern element returns
to the walk, which owns every grammar error. The differential suite gained 35 documents with no
change to the reference.

### Numeric array subtrees

*Recorded 2026-08-24.*

Per element: one byte test on the first byte, one on the separator, and `emitNumber` on the
known extent with no scan; a rejected extent falls back to the walk with nothing emitted. Canada
windowed 893 → 1,118 (+25%), Mesh 619 → 643 (+4%). Mesh was low because the loop was only
entered at `[`; also entering from the walk's comma arm inside an array took Mesh to 949 and
Canada to 1,180.

### Object members with scalar values

*Recorded 2026-08-24.*

Per member: quote, quote and colon loaded at known offsets, the key emitted in place, then a
scalar value and the separator; containers, escapes and malformed input fall back to the walk.
GitHub +21%, Twitter +25%, CITM +13%, Twitter escaped +11% against step 1. Step 1's ~3.5% cost
on object corpora (a call and two loads at every `[`) is buried, but would show on small
non-numeric arrays.

### Where it stands, against HEAD (three rounds, interleaved)

*Recorded 2026-08-24.*

| corpus | dispatcher bulk | windowed bulk | delta | 16 KB chunks windowed vs dispatcher |
| --- | ---: | ---: | ---: | ---: |
| github_events | 1,800 | 2,493 | **+38.5%** | +38.3% |
| mesh | 739 | 954 | **+29.1%** | +4.1% |
| canada | 942 | 1,198 | **+27.2%** | +26.8% |
| twitter | 1,504 | 1,826 | **+21.4%** | +20.7% |
| twitterescaped | 1,092 | 1,055 | −3.4% | −3.7% |
| citm_catalog | 2,093 | 2,003 | −4.3% | −3.4% |
| gsoc-2018 | 4,231 | 4,013 | −5.2% | −4.3% |
| llm_message | 3,643 | 3,435 | −5.7% | −5.1% |

With the gate off, dispatcher rows stay within ±0.6% of HEAD. The number-dense corpora gain
27–29% and the string-heavy ones lose 3–6%; CITM sits on the line. Mesh through 16 KB chunks
gains only +4% because a cut number hands the array to the dispatcher until the next window.
Open: interleaved digit accumulation, the Mesh chunk seam, and CITM.

## The number kernel lab: interleaving, single-pass validation, and where the cycles are

*Recorded 2026-08-24.*

`NumberKernelBenchmarks.swift` tests two kernels over the real number extents of four corpora:
interleaving consecutive numbers, and a single vector classification that merges validation
with parsing. Every number fits a "simple decimal" shape, but lengths differ (Canada p50 18,
Twitter 3). The table is MB/s of number bytes.

| corpus | current port | single pass (32 B classify) | paired | hybrid (≤8 port, ≤16 one vector, else 32 B) |
| --- | ---: | ---: | ---: | ---: |
| Canada (p50 18) | 1,559 | **1,887 (+21%)** | 1,962 (+26%) | **1,927 (+24%)** |
| Mesh (p50 4) | 1,226 | 1,109 (−9%) | 1,090 | 1,236 (+1%) |
| CITM (p50 9) | 1,855 | 1,290 (−30%) | 1,263 | 1,349 (−27%) |
| Twitter (p50 3) | 957 | 651 (−32%) | 707 | 853 (−11%) |

Interleaving gains only +4% on Canada: the out-of-order core already overlaps consecutive
numbers. The single-pass kernel wins 21–24% on long numbers and loses 27–32% on short ones,
because its ~10-cycle serial classification latency only amortizes past 16 digits. It is worth
taking only above 16 bytes and at least 32 bytes from the chunk end (~+10% on Canada's row).
Not built yet at this point.

### The third number path, landed

*Recorded 2026-08-24.*

`stream_parsing_decimal32` (static inline in StreamParsingShims.h) now handles extents longer
than sixteen bytes that lie at least 32 bytes inside the chunk; everything else takes
`emitNumber`. The differential suite gained long-decimal documents.

| corpus | windowed before | after | delta |
| --- | ---: | ---: | ---: |
| Canada | 1,198 | **1,362** | **+13.7%** |
| Mesh | 954 | 927 | −2.8% |
| Twitter | 1,826 | 1,847 | +1.2% |
| CITM | 2,003 | 2,000 | −0.1% |

Canada windowed is now +45% over the dispatcher. Mesh loses 2.8% because its 13–16 byte floats
mostly pay the length compare and gain nothing.

## Number batching in the sink protocol: step 1

*Recorded 2026-08-24.*

The Canada typed row ran at 117 MB/s against 942 raw, with about five retains and six releases
per number. The layer's cost is per event, so a 64-number batch event amortizes it.

### The shape

*Recorded 2026-08-24.*

Added `StreamNumberBatch` and a `numbers(_:)` requirement whose default unrolls into
`number(_:info:)`, plus a static `streamAcceptsNumberBatches` gate (default false). Without the
gate, batching cost raw Canada 7% and Mesh 18%; with it, the gated-off path matches the shipping
one (all rows within ±2.6%). A non-generic `parseNumber` would not inline even under
`@inline(__always)`.

### Where batches come from

*Recorded 2026-08-24.*

Only the numeric shape loop batches: it fills a 64-slot scratch and flushes at 64, before a
nested `[`, before `]` and before any fallback, so event order matches the document.
`WindowedParserTests` checks batch sizes, flattened streams and rejection offsets against the
dispatcher.

### The gate, removed

*Recorded 2026-08-24.*

`streamAcceptsNumberBatches` was dropped after one round: every sink gets `numbers` and the
numeric loop always batches. The raw benchmark sink now folds every `NumberInfo` field, because
reading only the magnitude had flattered unbatched rows by ~3%. The table is the ratio of
windowed to dispatcher.

| corpus | before | after |
| --- | ---: | ---: |
| Canada | 1.446 | 1.339 |
| Mesh | 1.244 | 1.390 |
| Twitter | 1.225 | 1.225 |
| CITM | 0.956 | 0.933 |

Mesh gains ~12% net, with `parseNumber` inlined via `@_transparent`. Canada loses ~5% on the raw
row from the fixed cost of the deferred round trip; that cost is accepted. CITM's −2.3% is
unattributed.

## Real-world throughput: the arc so far

*Recorded 2026-08-24.*

Three interleaved rounds against HEAD, p50 MB/s, raw sink. "first pass" is the delta from the
first windowed walk.

| corpus | KB | HEAD bulk | windowed bulk | delta | first pass | 16 KB chunks windowed |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| github_events | 64 | 1,836 | 2,489 | **+35.6%** | +4.8% | +37.0% |
| mesh | 707 | 747 | 1,015 | **+35.9%** | −10.9% | +1.6% |
| canada | 2,198 | 954 | 1,243 | **+30.3%** | −16.3% | +30.7% |
| twitter | 617 | 1,514 | 1,859 | **+22.8%** | −4.2% | +21.9% |
| twitterescaped | 549 | 1,095 | 1,047 | −4.4% | −18.7% | −4.8% |
| gsoc-2018 | 3,250 | 4,259 | 4,039 | −5.2% | −33.7% | −4.9% |
| llm_message | 1,045 | 3,647 | 3,403 | −6.7% | −39.2% | −6.8% |
| citm_catalog | 1,687 | 2,101 | 1,940 | −7.7% | −7.2% | −7.2% |

Number-heavy deltas are understated by ~2–3% because the benchmark sink now folds every
`NumberInfo` field. Layer rows are unchanged (±2%), since `PartialSink` does not take batches
yet. Mesh through 16 KB chunks still loses most of its gain at the chunk seam.

## Number batching, step 2: the layer takes the batch

*Recorded 2026-08-24.*

> **Removed.** `PartialSink` stopped calling `appendNumbers` when its batch decoder went in "The
> fusion series" (stage 4); `[Double]` and `[Int]` now take the `.arrayDouble` / `.arrayInt` leaf
> routes. The closure outlived its caller as dead code until `StreamSchema.appendNumbers`, the
> `_streamArrayNumberAppender` requirement and its two implementations were deleted. This section is
> history.

`StreamSchema.appendNumbers` and `PartialSink.numbers` let an array frame take a number batch in
one call, leaving the last number as the open element. `JSONStreamFormat` gained
`windowThreshold`. The appender's conversion first went through unspecialised generic code
(Mesh at half speed); making the two initialisers `@inlinable` fixed it. Typed layer, bulk:

| corpus | gate off | windowed | delta | retains per parse |
| --- | ---: | ---: | ---: | ---: |
| Mesh | 144 | **322** | **+124%** | 170 K → 33 K |
| Canada | 112 | 132 | +18% | 560 K → 449 K |
| Twitter | 636 | 750 | +18% | 13 K |
| GitHub events | 409 | 441 | +8% | 3.9 M |
| CITM catalog | 437 | 427 | −2% | 127 K |

Mesh more than doubles. Canada gains less because its inner arrays have two numbers each, so
the per-array frame push and pop dominates. GitHub's 3.9 M retains per parse are untouched.

### Unrolling the appender: measured, and left alone

*Recorded 2026-08-25.*

Unroll factors for the appender's commit loop, typed layer, windowed:

| unroll | Mesh | Canada |
| --- | ---: | ---: |
| 1 | **323** | **133** |
| 2 | 316 | 132 |
| 4 | 312 | 131 |
| 8 | 311 | 131 |

Each step up is slightly slower: consecutive conversions are independent and the core overlaps
them already. The plain loop stays.

## Event batching, step 1: the tax, measured

*Recorded 2026-08-25.*

Added `StreamEventRecord` (32 bytes), `StreamEventBatch` and `events(_:)` with a default that
unrolls. The walk records structurals, keys, clean strings, literals and numbers, and flushes at
256 records, at the window's end and before any direct emit. The differential suite gained an
`events`-overriding sink.

| row | before | after | delta |
| --- | ---: | ---: | ---: |
| GitHub events, raw windowed | 2,489 | 1,966 | **−21.0%** |
| Twitter, raw windowed | 1,859 | 1,547 | −16.8% |
| CITM, raw windowed | 1,940 | 1,626 | −16.2% |
| Twitter escaped, raw windowed | 1,047 | 968 | −7.5% |
| Canada / Mesh / GSoC / LLM, raw windowed | | | −0.6 / −1.4 / −3.5 / +0.9% |
| Twitter, layer windowed (default unroll) | 750 | 703 | −6.3% |
| GitHub, layer windowed (default unroll) | 441 | 419 | −5.0% |
| CITM, layer windowed (default unroll) | 427 | 400 | −6.3% |
| Canada / Mesh, layer windowed | 132 / 322 | 132 / 324 | 0 / +0.6% |

The tax is ~2 cycles per event (the record's store and reload). It reads as 21% on GitHub
because the counting sink's per-event work is an add, and as 5–6% on the layer. Whether
sink-side lookahead pays for it is left to step 2.

## Event batching, step 2: the sink takes the run

*Recorded 2026-08-25.*

`PartialSink.events` routes each key-plus-scalar pair under a key-matching object frame in
place, with one `matchField` and one apply. This drops the frame resolution, the strong
`ScalarTarget` schema copy and the string's three closure calls. Typed layer, bulk:

| corpus | gate off | events, default unroll | events, runs | vs gate off |
| --- | ---: | ---: | ---: | ---: |
| Twitter | 624 | 703 | **828** | **+32.7%** |
| GitHub events | 408 | 419 | **465** | **+14.0%** |
| CITM catalog | 436 | 400 | 433 | −0.7% |
| GSoC 2018 | 572 | 557 | 562 | −1.7% |
| Canada | 112 | 132 | 132 | +17.9% |
| Mesh | 142 | 324 | 323 | +127.5% |

Run routing adds 11–18% over the unrolled events on object corpora, and every layer row is at
or above the gate-off control. GitHub's retains did not move, so they are not the member
routing. The raw rows keep step 1's tax.

### Recovering the raw rows: what came back and what is inherent

*Recorded 2026-08-25.*

A whole-`string` record kind cut record traffic ~40% (GitHub raw windowed +11.5%, Twitter
+4.8%). Rewriting the consumer loop added +0.6% on CITM. Raw windowed rows remain 7–16% behind
pre-events on the object corpora. The residual is the record's store, load and dispatch
(~2 cycles per event), which only skipping the round trip removes.

### Separate methods instead of one event stream: measured

*Recorded 2026-08-25.*

Per-kind batches were tried instead: `numbers`, a new `members(_:)` with one 32-byte record per
member, and direct emission for everything else.

| raw windowed | pre-events | events (`.string` record) | member batches |
| --- | ---: | ---: | ---: |
| GitHub events | 2,489 | 2,193 (−12%) | 2,229 (−10%) |
| Twitter | 1,859 | 1,623 (−13%) | 1,617 (−13%) |
| CITM catalog | 1,940 | 1,639 (−16%) | 1,705 (−12%) |
| Twitter escaped | 1,047 | 973 (−7%) | 919 (−12%) |

Layer rows were the same. The API shape is not the cost; the round trip is, and the per-kind
form buys nothing.

### The leaner record: measured, and kept

*Recorded 2026-08-25.*

The single `events(_:)` came back with a 16-byte record. `end` is derived, and a number's
`NumberInfo` moves to a parallel side array read through `StreamEventBatch.info(of:)`.

| raw windowed | pre-events | 32-byte record | 16-byte record |
| --- | ---: | ---: | ---: |
| GitHub events | 2,489 | 2,193 | 2,177 (−0.7% / −12.5%) |
| Twitter | 1,859 | 1,623 | 1,636 (+0.8% / −12.0%) |
| CITM catalog | 1,940 | 1,639 | 1,655 (+1.0% / −14.7%) |
| Twitter escaped | 1,047 | 973 | 986 (+1.3% / −5.8%) |
| Canada | 1,243 | 1,227 | 1,239 (+1.0% / −0.3%) |

Raw rows move about 1% (noise) and layer rows +1.5–2.7%: the cost is the flush call, the
per-event `kind` branch and lost specialisation, not the record size. The 16-byte layout is kept
because it costs nothing. The remaining 12–15% raw tax on string-heavy corpora is the price of
the single requirement.

## One requirement: the legacy sink methods removed

*Recorded 2026-08-25.*

`events(_:)` (plus `streamFailure`) becomes the sole `StreamParseSink` requirement, replacing
eleven per-event methods and `numbers`; every parser path now records instead of calling.

### What changed

*Recorded 2026-08-25.*

The recorder moves onto the parser (JSONParserEvents.swift) and flushes at the end of every
`parse`/`finish`, before a rethrown error, when full, and after any record pointing into the
parser's buffer. The record grows to 20 bytes with a `source` (input, parser buffer, or inline
bytes) and an explicit `end`. `stringBegin` is recorded lazily, so a clean string is one record.
`numbers` is folded into `events`, `StreamNumberBatch` is gone, and rejection offsets are the
record's `end`. Test sinks conform through an `EventSink` adapter.

### What it cost, and what it took to get there

*Recorded 2026-08-25.*

The first build lost 10–28% on raw rows. Three defects were fixed: `emitNumber` falling out of
line, a `memmove` per `\u` escape, and non-`@inlinable` `StreamEventBatch` accessors. The counting
sink against the pre-events dispatcher:

| bulk, gate off | before | after | | 16KB chunks | before | after |
| --- | ---: | ---: | --- | --- | ---: | ---: |
| CITM catalog | 2,077 | 1,784 (−14%) | | CITM catalog | 2,067 | 1,770 (−14%) |
| Canada | 928 | 863 (−7%) | | Canada | 928 | 869 (−6%) |
| GSoC 2018 | 4,223 | 3,569 (−16%) | | GSoC 2018 | 4,203 | 3,509 (−17%) |
| GitHub events | 1,802 | 1,652 (−8%) | | GitHub events | 1,802 | 1,673 (−7%) |
| LLM message | 3,599 | 3,243 (−10%) | | LLM message | 3,555 | 3,225 (−9%) |
| Mesh | 730 | 704 (−4%) | | Mesh | 731 | 700 (−4%) |
| Twitter | 1,507 | 1,433 (−5%) | | Twitter | 1,504 | 1,427 (−5%) |
| Twitter escaped | 1,068 | 981 (−8%) | | Twitter escaped | 1,073 | 978 (−9%) |

Windowed against the 16-byte build: CITM +1% to Canada −14%. Canada's loss in the numeric arm's
schedule is unexplained; three fixes measured nothing.

### What it bought: the layer, without the gate

*Recorded 2026-08-25.*

Every `PartialSink` row with the window gate off (the default, byte-fed and small-chunk paths)
now gets batched routing:

| bulk discarding, gate off | before | after |
| --- | ---: | ---: |
| Mesh | 144 | 300 (+108%) |
| Twitter | 631 | 821 (+30%) |
| Twitter escaped | 455 | 533 (+17%) |
| Canada | 114 | 131 (+15%) |
| GitHub events | 411 | 449 (+9%) |
| CITM catalog | 438 | 476 (+9%) |
| GSoC 2018 | 587 | 623 (+6%) |
| LLM message | 706 | 694 (−2%) |

16 KB-chunk layer rows match. Windowed layer rows are flat to slightly up, since they already
had batches.

### The byte fed price

*Recorded 2026-08-25.*

Byte-fed rows lost much more than predicted: LLM message −41% raw / −33% typed, Twitter escaped
−26% / −25%. Each byte inside a string is delivered as a one-record batch per parse call (~80
instructions against ~5 for a direct call). The per-call flush is the contract; only the
constant can move.

## Outlined throws, and the whitespace inline they were blocking

*Recorded 2026-08-29.*

Typed throws are moved behind a static `@inline(never)` `JSONParser.fail(_:byteOffset:)`
returning `Never`, which takes `consumeStructuralRun` from 859 to 667 instructions. A method form
grew the run by copying `self` at every site. On its own the change is neutral. It let the
whitespace body inline into the run, using `@_transparent` on the step and scanners; `any(hit)`
had to be respelled through the `vmaxvq` shim.

| bulk, p50 MB/s | before | after | |
| --- | ---: | ---: | ---: |
| Twitter | 1435 | 1502 | **+4.7%** |
| GitHub events | 1645 | 1689 | +2.7% |
| GSoC 2018 | 3409 | 3493 | +2.5% |
| LLM message | 3279 | 3361 | +2.5% |
| Twitter escaped, byte by byte | 109 | 111 | +1.8% |
| Canada | 890 | 871 | **−2.1%** |
| Mesh | 733 | 728 | −0.7% |
| CITM / Twitter escaped / layer rows | | | −0.5…+1.1% |

Canada pays the extra register pressure (four splats) and gets nothing from the scan.

### The hit test as a table

*Recorded 2026-08-29.*

The four whitespace compares are replaced by a 16-entry `tbl` lookup on the low nibble (`and`,
`tbl`, `cmeq`), with 0x00 filler since 0xFF matched itself. `movi` sites drop 67 → 45 and most of
Canada's loss comes back.

| row | before | OR form | table form | table vs before |
| --- | ---: | ---: | ---: | ---: |
| Twitter, bulk | 1429 | 1493 | 1508 | **+5.5%** |
| GitHub events, bulk | 1631 | 1680 | 1733 | **+6.3%** |
| GSoC 2018, bulk | 3397 | 3499 | 3521 | +3.7% |
| LLM message, bulk | 3277 | 3361 | 3355 | +2.4% |
| CITM catalog, bulk | 1692 | 1689 | 1731 | +2.3% |
| Canada, bulk | 888 | 865 | 880 | −0.9% |
| Mesh, bulk | 732 | 727 | 728 | −0.5% |
| Fast Literals, bulk | 829 | 833 | 883 | +6.5% |
| Twitter escaped, byte by byte | 109 | 111 | 112 | +2.8% |
| Twitter / GSoC / LLM, raw windowed | 1542 / 3345 / 3143 | | 1562 / 3447 / 3205 | +1.3 / +3.0 / +2.0% |
| GitHub / CITM / Canada / Mesh, raw windowed | 2163 / 1669 / 1070 / 943 | | 2169 / 1677 / 1068 / 939 | +0.3 / +0.5 / −0.2 / −0.4% |
| Twitter / CITM / Canada, layer bulk | 820 / 364 / 354 | | 835 / 370 / 357 | +1.8 / +1.6 / +0.8% |
| layer windowed rows | | | | −1.3 … +1.4% |

The gain is on the bulk dispatcher. The windowed path barely moves because stage 1 already
skips its whitespace.

### The record repack, re-measured

*Recorded 2026-08-29.*

`t3code/tier1-record-repack` (5242a10: 16-byte record, hoisted cursor) was measured on the
merge. Twitter and byte-fed rows gained (Twitter escaped byte by byte +6…8%), while Canada
windowed lost 4–8% and CITM/GSoC layer 1–2%. Not landed.

## The sink in isolation: recorded batches, replayed

*Recorded 2026-08-29.*

The new `Sink` rows (`PartialSinkReplayBenchmarks.swift`) record every `StreamEventBatch` from
one bulk parse and replay them into a sink with no parser in the loop. This separates the
sink's cost from the parser's. Batch boundaries are the parser's own, parser-buffer bytes are
copied out, and an `@_spi(Benchmarks)` initialiser was added. Four rows per recording: null
sink, counting sink, `PartialSink`, and `PartialSink` fed everything as one batch.

### The recording is exact, and the harness costs nothing

*Recorded 2026-08-29.*

Retain and malloc counts match the typed `Real` rows on every corpus except GSoC, which differs
because of the wrapper. The null floor is ~2 ns per batch, so the sink rows read as absolute
numbers.

### Composition, and the fact it establishes

*Recorded 2026-08-29.*

"Predicted" is `1 / (1/typed − 1/raw)`, the sink-only throughput that would add up to the typed
row.

| corpus | raw bulk | typed bulk | predicted sink | replayed | one batch | counting replayed | events | ns / event |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Twitter | 1,519 | 848 | 1,920 | **1,623** | 1,645 | 11,000 | 32 K | 12.0 |
| Twitter escaped | 1,055 | 521 | 1,029 | **939** | 937 | 6,899 | 65 K | 9.2 |
| Canada | 898 | 353 | 582 | **539** | 541 | 6,883 | 221 K | 18.9 |
| CITM catalog | 1,740 | 362 | 457 | **440** | 437 | 10,000 | 82 K | 47.6 |
| GSoC 2018 | 3,515 | 600 | 723 | **826** | 818 | 29,000 | 69 K | 58.8 |
| GitHub events | 1,727 | 442 | 594 | **590** | 588 | 13,000 | 3 K | 40.0 |
| LLM message | 3,367 | 678 | 849 | **835** | 836 | 35,000 | 29 K | 43.5 |
| Mesh | 737 | 438 | 1,080 | **944** | 967 | 8,583 | 80 K | 9.6 |

The parser and sink are additive: replayed lands within 4–15% of predicted, with no overlap. On
Twitter neither half fits the 350 µs budget for 1,800 MB/s. Batch seams cost the sink nothing
(one batch within ±2%). `PartialSink` costs 9–59 ns per event against 1–2 for counting, highest
on strings and dynamic keys.

### One route per row

*Recorded 2026-08-29.*

Synthetic shapes, each exercising one sink route, recorded and replayed the same way:

| shape | route | events | MB/s | ns / event | mallocs | retains | releases |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| int fields | `matchField` + `applyNumber` into a field | 142 K | 303 | 21.3 | 261 | 144 K | 145 K |
| int fields, no key matches | `matchField` miss, value ignored | 143 K | 530 | 12.0 | 261 | 80 K | 81 K |
| string fields | `matchField` + `applyString` into `String` | 85 K | 141 | 76.9 | 167 | 290 K | 370 K |
| double array | `appendNumbers`, long runs | 40 K | 1,851 | 9.4 | 1,263 | 2 K | 4 K |
| double pairs | `[[Double]]`: a frame per pair, runs of two | 77 K | 104 | 90.9 | 21,000 | 161 K | 222 K |
| container churn | `enterField`, push, pop, three deep | 119 K | 151 | 20.0 | 386 | 120 K | 121 K |
| dictionary | `enterKey` into `[String: Int]` | 39 K | 180 | 47.6 | 43 | 60 K | 60 K |

Routes that allocate nothing still pay a retain/release per event, from calling closures stored
on the schema. A matched int member costs 21 ns and an ignored one 12. A short `String` field
costs 77 ns, the most expensive route. `[Double]` costs 9.4 ns, and a dictionary member 48.

### What this changes about the next step

*Recorded 2026-08-29.*

A fused typed path is now judged route by route against this table: an int member has to beat
21 ns, a string member 77, a double 9.4. Closure dispatch is the largest cost, then strings.

## The field table: the sink's object routes as data

*Recorded 2026-08-30.*

The `matchField`/`applyNumber` closure pair is replaced by a table (`StreamFieldTable.swift`).
Each key gets one entry with its first word and length, the member's kind and byte offset in the
`Partial`, and a field identifier for kinds the table cannot write itself.

### What the macro emits, and what resolves it

*Recorded 2026-08-30.*

The macro emits one `StreamField` per key. An overload set (`_streamFieldRoute`) resolves the
kind the same way `streamApply` would apply the member. Offsets come from pointer arithmetic
over a prototype (`_streamFieldOffset`), because key paths do not compile under Embedded Swift.
`custom` and `container` entries still go through the generated switches, and hand-written
schemas keep `matchField`.

### What the sink does with it

*Recorded 2026-08-30.*

Under a `.table` frame the key is matched by a linear scan of first word and length. The scalar
is written by kind: a typed store at `storage + offset`, an in-place `StreamString` append, or
the erased inline-string append.

### The retain that was not the closure's

*Recorded 2026-08-30.*

The first build kept every retain. The cost was loading the `unowned(unsafe)` schema (and the
table's class reference) into strong parameters, not the closure context. The table path now
reads raw views through the frame and passes member addresses, so int-field retains fall 144 K →
16 K.

### Measured

*Recorded 2026-08-30.*

Three interleaved rounds against 5648255, best p0 and median p50.

| row | base p0 / p50 | table p0 / p50 | Δ p50 | retains |
| --- | ---: | ---: | ---: | ---: |
| Sink synthetic int fields | 314 / 303 | 870 / 843 | **+178%** | 144 K → 16 K |
| Sink synthetic int fields, no key matches | 551 / 535 | 951 / 926 | +73% | 80 K → 16 K |
| Sink synthetic string fields | 150 / 145 | 230 / 221 | +52% | 290 K → 170 K |
| Sink synthetic container churn | 157 / 153 | 221 / 214 | +40% | 120 K → 72 K |
| Sink Twitter | 1,697 / 1,649 | 2,295 / 2,223 | +35% | 11 K → 4 K |
| Sink GitHub events | 605 / 588 | 801 / 781 | +33% | 4 K → 2 K |
| Sink Twitter escaped | 963 / 933 | 1,220 / 1,186 | +27% | 12 K → 5 K |
| Sink GSoC 2018 | 859 / 830 | 1,043 / 1,005 | +21% | 49 K → 16 K |
| Sink CITM catalog | 460 / 445 | 538 / 517 | +16% | 124 K → 85 K |
| Sink LLM message | 854 / 830 | 947 / 915 | +10% | 12 K → 10 K |
| Sink Canada / Mesh / double array / double pairs / dictionary | — | — | +0.2 / 0.0 / +0.2 / +1.9 / −1.6% | unchanged |
| Real GitHub events - bulk discarding | 451 / 438 | 549 / 530 | **+21%** | |
| Real Twitter - bulk discarding | 862 / 839 | 999 / 976 | +16% | |
| Real GSoC 2018 - bulk discarding | 623 / 596 | 716 / 686 | +15% | |
| Real Twitter escaped - bulk discarding | 539 / 525 | 612 / 596 | +14% | |
| Real CITM catalog - bulk discarding | 377 / 363 | 428 / 411 | +13% | |
| Real LLM message - bulk discarding | 687 / 664 | 744 / 723 | +9% | |
| Real Canada / Mesh - bulk discarding | 365 / 352, 447 / 434 | 367 / 356, 448 / 431 | +1.1 / −0.7% | |
| every `Real <x> - bulk` (raw) | | | −0.8 … +1.9% | |

An int member is now 7.6 ns (was 21.3) and a missed key 7.0 (was 12.0). Raw rows are flat.
Canada, Mesh and the dictionary row do not take an object route and do not move.

### What is left on the closures

*Recorded 2026-08-30.*

Still left: container entry (`enterField`, `appendElement`, `enterKey`), array elements and
dictionary values on the old path, `StreamString`'s own append cost (strings now 47 ns), and the
linear key scan.

## Container entry as data: the frame is the entry

*Recorded 2026-08-30.*

Entering a container went through closures that built a strong-referenced `StreamFrame`,
costing two retain/release pairs per container open. This section removes them.

### What changed in the contract

*Recorded 2026-08-30.*

A `container` table entry carries its child schema and an optional `prepare`, called only to
materialise an optional or reserve capacity. The generated `streamEnterField` switch is gone.
`appendElement`/`enterKey` return the slot, with the element schema as data on the parent.
`InlineArray` elements are addressed by stride with no call. `streamContainerFrame` became
`_streamContainerPrepare`.

### Bits, not references

*Recorded 2026-08-30.*

`if let` on an `unowned(unsafe)` optional formed a strong temporary, so the first build kept
every retain. Child schemas are now stored as object addresses (`schemaBits` and friends) and
bit-cast into the frame's unowned field, which leaves `valueTarget`'s table branch with no ARC.

### Measured (3 rounds interleaved, p50, vs 113ae98)

*Recorded 2026-08-30.*

| Row | Before | After | Δ |
|---|---|---|---|
| Sink synthetic container churn | 216 MB/s (14.5 ns/ev) | 285 (11.0) | +32% |
| Sink synthetic dictionary | 181 (41.7 ns) | 212 (35.6) | +17% |
| Sink synthetic int fields | 851 (7.8 ns) | 949 (7.0) | +12%, retains 16K → 8K |
| Sink synthetic int fields, no key matches | 933 | 1064 | +14% |
| Sink CITM catalog | 528 | 573 | +8.5%, retains 85K → 63K |
| Sink Twitter / Twitter escaped / GitHub | 2233 / 1192 / 781 | 2303 / 1228 / 803 | +3% each |
| Sink GSoC / LLM / Mesh / Canada | | | +1.5 / +1.6 / +0.3 / +0.4% |
| Real CITM catalog - bulk discarding | 420 | 446 | +6.2% |
| Real GitHub events - bulk discarding | 536 | 549 | +2.4% |
| Real Twitter escaped - bulk discarding | 599 | 610 | +1.8% |
| Fixed array booleans / numbers / objects / composite - inline | 60 / 63 / 143 / 120 | 70 / 73 / 164 / 137 | +17 / +16 / +15 / +14% |
| Fixed array * - dynamic | | | +3..+8% |
| Real * - bulk (raw parser) | | | −1.1..+2.3%, code untouched |

Int fields gain 12% because each row is an array element open. Canada, Mesh and double pairs do
not move: their cost is the element open itself and the number run.

## Known scalar kinds: elements, values, lanes and slots as typed stores

*Recorded 2026-08-30.*

Scalars arriving at a container (array element, dictionary value, SIMD lane, `InlineArray`
slot) went through a strong `ScalarTarget` and the child's `applyNumber` closure, two retain
pairs per value. They now take typed stores.

### The contract

*Recorded 2026-08-30.*

Scalar schemas declare `scalarKind`/`scalarOptional`. Container schemas cache `elementKind`,
and SIMD schemas name their lane kind. The frame carries `routeBits` in one word; scalar entry
points test one mask and branch to an outlined typed path (`knownScalarSlot()` plus
`storeNumber`/`storeBoolean`/`storeNull`).

### Three things the measurements caught

*Recorded 2026-08-30.*

1. A byte test ahead of the `StreamString` chunk append cost LLM 3% and GSoC 2.4%; moving it
   after the append fixed both.
2. Copying three bytes at push instead of one word drifted every corpus 1–3%. The packed word
   also needed a bit-cast decode, because `init(rawValue:)` doubled `number`'s size.
3. `ScalarTarget` nested in the generic `PartialSink<Root>` lowered to a value-witness destroy
   (Leaf Array String −22%); moving it to file scope fixed it.

### Measured (3 rounds interleaved, p50, vs 9d706cd)

*Recorded 2026-08-30.*

| Row | Before | After | Δ |
|---|---|---|---|
| Sink synthetic dictionary (`[String: Int]`) | 209 MB/s (36 ns/ev) | 256 (29) | +22.5%, retains 40K → 20K |
| Leaf Dictionary Optional Int / Array Optional Int | 40 / 21 | 44 / 23 | +10% / +9.5% |
| Leaf Dictionary Double | 57 | 59 | +3.5% |
| Inline string Array 32/64/128 short, 128 medium | 34 / 33 / 28 / 217 | 40 / 40 / 33 / 253 | +17..+21%, retains 8K → 2K |
| Inline string Dictionary 32 short | 47 | 53 | +13% |
| Fixed array booleans / numbers / strings - inline | 70 / 72 / 40 | 87 / 82 / 48 | +24% / +14% / +20% |
| Fixed array composite / composite 64B - inline | 136 / 106 | 155 / 118 | +14% / +11% |
| Sink CITM catalog | 564 | 579 | +2.7% |
| Leaf Nested SIMD2 Double | 210 | 214 | +1.9% (lanes through the kind path) |
| Leaf Array/Dictionary String, Bool, Double, Int | | | −0.3..+0.5% |
| Sink Twitter escaped | 1203 | 1179 | −2.0% (typed row −0.3%) |
| Real * (raw and typed) | | | within ±1.6% |

Left on closures: `custom` scalars, hand-written `enterField`, the `appendElement`/`enterKey`
calls and the number-run appender. Canada and Mesh's remaining cost is the element open in
`StreamArray<StreamArray<Double>>`, which is a container design question.

## The block key match: measured, and not kept

*Recorded 2026-08-30.*

Tried an arm64 NEON block key match that compares eight packed entries at once, in place of the
linear scan. Four variants, three interleaved rounds each against 9d706cd:

| Variant | 48-member last / undeclared | int fields | no key matches | Twitter sink / escaped | churn |
|---|---|---|---|---|---|
| block on every table | +7% / +8% | +2.4% | **+30%** | +1.9% / −3% | −4.3% |
| scan for ≤2 entries, block above | +7% / +8% | 0% | +15% | −0.2% / −2.9% | −1.4% |
| scan for ≤8 (over the packed arrays) | +7% / +7% | −4.7% | +5.6% | +1.7% / −1.1% | −1.1% |
| scan for ≤8 (over the entries), block outlined, views last in the class | +7% / +6% | −5.7% | −4.0% | −1.9% / −2.6% | −2.1% |

Not kept. The block is a ~20-cycle dependent chain, while a well-predicted scan retires an entry
every couple of cycles, so the block only wins past eight entries. A `count <= 8` branch also
made LLVM unroll the scan eight times. A −4 to −6% residual stayed unexplained, and real models
declare eight members or fewer. A perfect hash would be the form for wide objects; the code was
not committed.

## The fused slice: the seam priced before the protocol is touched

*Recorded 2026-08-30.*

Measures what the record/replay seam costs, route by route, with no protocol change: a private
loop calls the sink's internals directly at the lex points.

### What the slice is

*Recorded 2026-08-30.*

`FusedParseExperiment.swift` (`parseFusedDocument`, `@_spi(Benchmarks)`) runs the real kernels
and calls the sink's routing where the recorded loop writes a record. Two routes are fused:
table-object members and `[Double]` runs. Everything else delegates to single-token internals.
It handles one chunk only, with no escapes, and `FusedParseTests` checks it differentially.

### Two codegen findings before any honest number existed

*Recorded 2026-08-30.*

1. Generic over `Root`, the loop materialised `PartialSink<Root>` metadata at thirteen sites.
   Making it concrete over a phantom `FusedSliceRoot` gained ~+30%, so fusion needs the generic
   parameter out of the hot loop, not per-model specialisation.
2. `StreamArray.commit` would not inline into the larger loop (+6% measured where the real figure
   was +22%), so it got a forced-inline clone, `fusedCommitDouble`.

### Measured (3 rounds interleaved vs 31aaa61, best-of-3 p0 wall clock)

*Recorded 2026-08-30.*

"Increment" is the row minus the raw counting row, per value written.

| payload | raw counting | recorded parse | fused parse | sink increment | E2E |
|---|---:|---:|---:|---|---:|
| double array | 548.3 us | 889.7 us | 731.4 us | 8.54 -> **4.58 ns/number** | **+21.6%** |
| int fields | 1583.2 us | 2240.4 us | 1578.2 us | 10.27 -> **-0.08 ns/member** | **+42.0%** |
| int fields, no key matches | 1583.2 us | 2131.2 us | 1449.5 us | 8.56 -> **-2.09 ns/member** | **+47.0%** |

Corpus and replay rows against HEAD are flat. A table member's sink cost is all seam (fused
increment ≈ 0). A double's residual is the conversion, with the seam 46% of the number route. A
missed key is cheaper than counting.

### What this licenses

*Recorded 2026-08-30.*

Fusing removes half to all of the sink's per-value cost on the dominant routes. It is the first
credible route under the ceiling. Strings, escapes, chunk cuts and the byte-fed path are not
priced yet. The proposed design is one protocol with per-token primitives, with batching as an
optional transport.

## The fusion series: per-token emission lands, the recorder is deleted

*Recorded 2026-08-30.*

Five commits replace batched transport with a per-token protocol. Batching becomes an opt-in
adapter, and `commit()` is the only lifetime hook beyond the tokens.

### The stages, each gated by a clean interleaved A/B

*Recorded 2026-08-30.*

Stage 0: `PartialSink` drops its phantom `Root` (flat, `Sink Twitter escaped` +14.6%). Stage 1:
the eleven per-token methods become `StreamParseSink`, plus a whole-string form and a no-op
`commit()` (flat). Stage 2: batching moves into a `StreamEventBatchingSink` adapter. Stage 3: the
parser's choke points call the sink's per-token methods directly, and `StreamArray.commit` is
forced inline. Stage 4: `events()`, the batch decoder, the event scratch and the replay
benchmarks are deleted.

### What stage 3 measured (vs stage 2, 3 clean interleaved rounds, best-of-3 p0)

*Recorded 2026-08-30.*

| row | Δp0 | note |
|---|---:|---|
| Real Canada - bulk discarding | **+42.8%** | retains 115K → 3K: the per-number schema retain is gone |
| Real Twitter - bulk discarding | **+20.0%** | 1027 → 1232 MB/s |
| Real CITM catalog - bulk discarding | **+20.0%** | retains 63K → 42K |
| Real Twitter escaped - bulk discarding | +12.7% | |
| Real LLM message / GSoC / GitHub | +7.0 / +6.4 / +5.3% | string-heavy: `String` construction still dominates |
| Real Mesh - bulk discarding | +0.7% | retains 10K → 2K |

Raw rows gain too (Twitter +19.6%, CITM +22.1%). Byte-fed rows gained the most (+8% to +99%,
`Fast Long string - byte by byte` 228 → 453 MB/s) with no regressions. The assembly shows
per-sink specialisations, no witness or metadata calls, and smaller hot functions.

### What composition means now

*Recorded 2026-08-30.*

The additive parser-plus-sink ledger no longer applies, because there is no seam left. Known
residuals: the `[Double]` run is ~10% behind the old bulk appender (`Fused synthetic double
array` 791 → 712 MB/s, the one regression), strings still pay `String` construction, and
ignored-subtree emission is deferred to stage 5.

## Stage 5: container dispositions — skipped subtrees run at structural speed

*Recorded 2026-08-31.*

`beginObject()`/`beginArray()` now return a `StreamContainerDisposition` (`.stream`/`.skip`,
`@nonexhaustive`). A subtree the sink does not need is scanned to its close instead of parsed.
The sketched `.wholeValue` case is deferred.

### The contract, and why it is advisory

*Recorded 2026-08-31.*

`.skip` is advisory: replay and the batching adapter may ignore it and deliver everything. The
close is always delivered, so a skipping sink stays balanced. The requirement is deliberately
not defaulted, so a conformer's `Void` implementation cannot shadow it silently.

### What a skipped interior still validates

*Recorded 2026-08-31.*

The skip scanner (JSONParserSkip.swift) still tracks brackets and the 64-deep cap, rejects
control bytes, validates UTF-8, and reduces numbers to their byte class. Three parser states
carry a skip across chunks. Fixed bug: a cut number can resume at `.`, `+` or `E`. `PartialSink`
answers `.skip` only for a container under an unmatched key.

### Measured (3 clean interleaved rounds vs 3d13c11, best-of-3 p0 / median p50)

*Recorded 2026-08-31.*

| row | Δp0 | Δp50 | note |
|---|---:|---:|---|
| Real Twitter - bulk discarding | **+21.9%** | +21.2% | 1233 → 1503 MB/s; retains 4K → 1K |
| Real Twitter escaped - bulk discarding | **+18.0%** | +18.9% | |
| Real GitHub events - bulk discarding | **+13.1%** | +13.5% | |
| CITM / LLM / GSoC / Canada / Mesh typed | −0.4..+0.8% | | few or no undeclared subtrees |
| raw rows, whole corpus | −2.0..+3.1% | | non-skipping sinks: pure layout drift |

Byte-fed and chunked rows are flat to positive. On the new nested-miss synthetic the skip is
+41% and the typed path reaches 80% of the structural-scan floor. Non-skipping sinks'
`consumeStructuralRun` is byte-identical. Typed Twitter is at 1503 MB/s against the ~1,800
ceiling.

## StreamString adaptive block growth — the allocator leaves the string-heavy typed path

*Recorded 2026-08-31.*

A census showed byte storage was ~47% of typed GSoC and ~63% of LLM message (one allocation per
512 sealed bytes), not `String` construction. Sealed `StreamString` blocks now double from 512
to the 8 KiB cap, with closed-form positions (`sealedPosition(of:)`). The first overflow append
sizes the start like a `streamReserve` hint. The tail shift is cached in `storageBits`, which
fixed a byte-fed −6..−17%, and `promoteSizedInlineStorage` is outlined to avoid the inlining
cliff.

### Measured (3 clean interleaved rounds vs 7505e6a, best-of-3 p0 / median p50)

*Recorded 2026-08-31.*

| row | Δp0 | Δp50 | note |
|---|---:|---:|---|
| Real LLM message - bulk discarding | **+22.9%** | +26.9% | 833 → 1024 MB/s; mallocs 4744 → 2913 |
| Real GSoC 2018 - bulk discarding | **+6.9%** | +6.9% | 13,000 → 11,000 mallocs; escape-fragmented, so the ramp, not the sizing, does the work |
| Stream Long string - discarding (byte-fed) | **+6.6%** | +6.8% | |
| Twitter / Twitter escaped / CITM / Canada / Mesh / GitHub / Qwen typed | −0.9..+0.9% | | |
| raw rows, byte-fed set | flat | | worst p0 −2.2% (nested-miss drift, raw row drifts the same) |

`consumeStringRun` is byte-identical and no specialisation was lost. Hinted LLM still leads
(1255 vs 1024). Remaining: per-fragment append overhead and CITM's dictionary machinery.

## The small-payload fixed cost — three ARC leaks leave the typed layer

*Recorded 2026-08-31.*

The Qwen rows ran at 9–17% of raw. A clean profile blamed whole-tree copy/destroy, a
value-witness destroy per string and a retain pair per scalar, and one commit fixed all three. A
consuming `PartialsStream.finishValue()` moves the tree out. `ScalarTarget` stores `schemaBits`
and uses `_withUnsafeGuaranteedRef` (the `unowned(unsafe)` and computed-property forms both
failed). `StreamArray.drainPending` moves the payload bitwise instead of copying it.

### Measured (3 clean interleaved rounds vs 84b1c5a, best-of-3 p0 / median p50)

*Recorded 2026-08-31.*

| row | Δp0 | Δp50 | note |
|---|---:|---:|---|
| Real Qwen 3 search tool call - bulk discarding | **+43.9%** | +39.5% | 132 → 190 MB/s |
| Real Qwen 3 structured response - bulk discarding | **+37.1%** | +35.6% | retains 1K → ~0 |
| Real Qwen 3 workspace edit tool call - bulk discarding | **+33.3%** | +33.2% | |
| Real CITM catalog - bulk discarding | **+14.9%** | +11.9% | retains 42K → 21K |
| Real GitHub events - bulk discarding | **+10.3%** | +8.4% | |
| Real LLM message - bulk discarding | **+9.8%** | +7.4% | retains 6K → 2K |
| Real Twitter - bulk discarding | **+5.6%** | +3.5% | retains → ~0 |
| GSoC / Twitter escaped discarding | +3.3% / +3.7% | | |
| Canada / Mesh discarding | +0.6 / −1.0% | −2.5 / −1.5% | number-heavy; the two rows the changes barely touch |
| raw rows (all) | flat | | ±0.2%, drift ±1.9% |
| Fused nested miss - fused parse | +12.4% | +11.8% | retains 12K → 6K |
| Stream Array of structs (byte-fed, typed) | +24..+46% | | view read per 16B +45.7% |
| Scaling 10/400 users - discarding | +25.8 / +27.7% | | |
| Fast * - byte by byte (raw) | −2..−7% | | every executed body instruction-identical to base (verified per symbol); code-placement drift on the alignment-sensitive rows |

Clean harness: structured 34.5 → 27.8 µs per parse, workspace edit 51.0 → 42.2. Remaining
overhead in profile order: memmove, the key scan, the destroy of the returned tree, array-growth
malloc, and the `appendElement` closure pair.

## Stream reuse — `reset(to:)` and `finishValue(resettingTo:)`

*Recorded 2026-08-31.*

> **Renamed.** `finishValue(resettingTo:)` is now `finishAndReset(to:)`, and the consuming
> `finishValue()` is `finishPartial()`. `finish()` consumes the stream too, and returns the model:
> the moved partial through `init?(streamPartial:)`, throwing `StreamParsingError.incompleteValue`
> when that fails. No public finish leaves a finished stream behind, so `parserFinished` is internal.

Added `reset()` on the parser and sink and `PartialsStream.reset(to:)`, which keep allocations
and allow recovery after a thrown parse, plus the looping `finishValue(resettingTo:)`. It is not a
throughput lever: the reused Qwen rows were flat, with identical mallocs, because per-token sink
work dominates.

## The last closure pairs — guaranteed-ref scopes on the frame routes

*Recorded 2026-08-31.*

`BorrowedFrame.withSchema` wraps closure calls through a frame's schema in
`_withUnsafeGuaranteedRef`. This removes the context retain pair per `appendElement`,
`enterKey`, `enterField` and `matchField` call. Also tried and REJECTED: a one-entry key-match
predictor, which hit but still cost ~1% on Twitter, CITM, LLM and GSoC because the predicted scan
over ≤8 entries is already free. Nothing goes in front of that scan.

### Measured (3 clean interleaved rounds vs be975c0, best-of-3 p0 / median p50)

*Recorded 2026-08-31.*

| row | Δp0 | Δp50 | note |
|---|---:|---:|---|
| Real CITM catalog - bulk discarding | **+5.5%** | +5.3% | retains 21K → 11K; the per-key `enterKey` pair |
| Fused synthetic int fields / nested miss (fused + recorded) | +5.5..+9.0% | | replay retains 8K/6K → 0 |
| Real Qwen 3 workspace edit / structured - bulk discarding | +2.5% / +2.0% | | retains 122→26 / 96→60 per parse |
| Stream Array of structs (byte-fed, typed) | +6..+11% | | |
| Scaling 10/400 users - discarding | +1.9 / +2.5% | | |
| GitHub / Twitter escaped discarding | +1.1 / +1.0% | | LLM retains 1687→1051, Canada 1993→1512 |
| Twitter / LLM / GSoC / Canada / Mesh discarding | ±0.3% | | |
| raw rows | flat | | Qwen search raw p0/p50 flipped −9.9/+8.9 — the documented bimodal row |
| Fast * byte-fed (raw) | ±2% mixed | | no uniform pattern |

## Performance ceiling analysis: current M1 Pro

*Recorded 2026-09-01.*

A planning model of throughput ceilings on this host, keeping the raw event boundary separate
from the typed materialization boundary.

### Scope and host normalization

*Recorded 2026-09-01.*

The host is an M1 Pro (6P+2E, 32 GiB, 128 KiB L1D, 12 MiB L2 per cluster). Cycle figures assume a
nominal 3.2 GHz. DRAM bandwidth is not the limit; cache residency, branches, indirect calls and
writes are.

### What the two boundaries include

*Recorded 2026-09-01.*

The raw benchmark is the parser plus an event-producing sink through `StreamEventBatch`. The
typed benchmark (`streamBulkDiscarding`) adds `PartialSink` routing and materialization without
snapshots. The event batch is mandatory on both paths.

### Current representative throughput

*Recorded 2026-09-01.*

Approximate p50 bulk results (2026-08-29), with `cycles/byte = 3200 / MB/s`.

| Boundary and shape | Throughput | Approx. cycles/byte |
| --- | ---: | ---: |
| Raw, Twitter, 631 KiB | 1,515 MB/s | 2.11 |
| Typed, Twitter, 631 KiB | 847 MB/s | 3.78 |
| Raw, Twitter escaped, 562 KiB | 1,050 MB/s | 3.05 |
| Typed, Twitter escaped, 562 KiB | 515 MB/s | 6.21 |
| Raw, Canada, 2.25 MiB | 866 MB/s | 3.70 |
| Typed, Canada, 2.25 MiB | 351 MB/s | 9.12 |
| Raw, byte-by-byte Twitter | 111 MB/s | 28.8 |
| Typed, byte-by-byte Twitter | 89 MB/s | 36.0 |

Chunking is close to flat; byte-by-byte is a latency mode, not a bulk target. The long-ASCII
scanner reaches ~13,000 MB/s, so the SIMD scan is not the dominant cost.

### SIMD bandwidth and parser state

*Recorded 2026-09-01.*

SIMD16 is the useful NEON width; SIMD32 is slower. Ideal load bounds (51–102 GB/s) are not parser
ceilings, because string, UTF-8, escape, depth, number and event state must carry across
vectors. The structural-bitmap path lost to the direct run on token-dense JSON.

### Comparator context

*Recorded 2026-09-01.*

For order of magnitude only: yyjson (DOM, A14) runs ~2.4–3.5 GB/s on Twitter, simdjson ~2.2 and
sajson ~1.7, roughly 0.85–1.8 cycles/byte under different API contracts. simdjson's paper reports
Stage 1 at 0.5–1 cycles/byte.

Sources: [yyjson performance table](https://github.com/ibireme/yyjson#performance), [yyjson benchmark corpus and methodology](https://github.com/ibireme/yyjson_benchmark), [simdjson paper](https://arxiv.org/abs/1902.08318), [simdjson performance notes](https://github.com/simdjson/simdjson/blob/master/doc/performance.md), [sajson design notes](https://github.com/chadaustin/sajson), and [Apple's M1 Pro specification](https://support.apple.com/en-us/111902).

### Theoretical planning ceilings

*Recorded 2026-09-01.*

| Boundary | Current representative range | Plausible planning ceiling | Ceiling at 3.2 GHz |
| --- | ---: | ---: | ---: |
| Raw parser → `StreamParseSink` | 866–1,515 MB/s, 2.11–3.70 c/B | 3,000–4,000 MB/s | 1.07–0.80 c/B |
| Typed parser → `PartialSink` materialization | 351–847 MB/s, 3.78–9.12 c/B | 1,500–2,000 MB/s | 2.13–1.60 c/B |

Planning targets are ~3,500 MB/s raw and ~1,800 MB/s typed. The raw target assumes near
one-pass scanning with cheap record writes; the typed target assumes schema-specialised direct
routes.

### Data shape is a first-order term

*Recorded 2026-09-01.*

| Shape | Effect on the ceiling |
| --- | --- |
| Long ASCII strings | SIMD scanning dominates; the current scanner reaches about 13 GB/s, so this shape is not representative of mixed-parser throughput. |
| Token-dense objects/arrays and small integers | Structural dispatch, event records, key routing, and branch density dominate. A structural bitmap is not automatically beneficial. |
| Canada's float-heavy geometry | Number conversion and typed writes expose the semantic floor: roughly 866 MB/s raw and 351 MB/s typed today. |
| Escaped Twitter and long escaped text | Escape decoding, Unicode validation, and emitted-byte handling lower both boundaries; typed storage adds another copy/assembly cost. |
| CITM's high whitespace fraction and deep/repeated keys | Whitespace scanning is cheap when the fast path applies, but depth, key matching, and repeated routing still exercise the control plane. |
| Small chunks or one-byte feeds | Per-call state preservation and sink checks dominate. This is a latency contract, not a realistic bulk ceiling. |

Typed throughput cannot be derived from raw by a fixed multiplier, because materialization
writes and allocates per shape.

### Biggest architectural limiter

*Recorded 2026-09-01.*

The largest gap is that every token is interpreted twice: the parser encodes a
`StreamEventRecord` and `PartialSink.events` decodes and routes it. The proposed next step is an
optional schema-specialised fused typed path that bypasses `StreamEventBatch` for known schemas,
without generating one parser per model. It should be measured against the same payloads,
including assembly and i-cache behavior.

### Interpretation and measurement caveats

*Recorded 2026-09-01.*

Cycle figures are normalized estimates, not counter measurements. Comparators run on other CPUs
and APIs. Typed rows omit per-chunk snapshots.

## The fused slice, retired — and where the object-heavy gap actually is

*Recorded 2026-09-01.*

`FusedParseExperiment.swift`, its tests and its benchmark rows are deleted. Its findings had
shipped in the fusion series, and it cost 615 lines of cloned code in the shipping module. Its
control shapes survive as `TypedShapeBenchmarks.swift`. Final reading:

| payload | raw counting | typed (production) | slice | slice lead |
|---|---:|---:|---:|---:|
| double array, 40 K | 514 us | 924 us | 761 us | +21.4% |
| int fields, 64 K members | 1166 us | 1849 us | 1471 us | +25.7% |
| int fields, no key matches | 1166 us | 2013 us | 1352 us | +48.9% |
| nested miss subtrees | 858 us | **991 us** | 1237 us | −19.9% |

The slice still leads on the three routing shapes and trails on skipped subtrees, because it
ignores dispositions.

### The key match is not the object-heavy bottleneck

*Recorded 2026-09-01.*

Three measurements say a better matcher will not help. The 48-member indexed table is flat
across first member, last member and miss (26–27 us). Dictionary lookups are ~21–23 ns, about
0.7% of GSoC. The NEON block match and the predictor both lost already. A macro-emitted LUT
would only remove one-time setup. The one untested option is a SwissTable-style byte-tag vector,
which would have to replace the scan, never precede it.

### Where it is instead: what happens after the key resolves

*Recorded 2026-09-01.*

Corpus raw against typed, p0 MB/s, same run:

| payload | raw | typed | typed/raw | typed mallocs |
|---|---:|---:|---:|---:|
| Qwen 3 search tool call | 1355 | 225 | 0.17 | 7 |
| GSoC 2018 (`StreamDictionary`) | 4184 | 895 | 0.21 | 11 K |
| LLM message | 3860 | 1152 | 0.30 | 2,913 |
| Twitter full (26-field model) | 1841 | 576 | 0.31 | 1,078 |
| CITM catalog | 2176 | 944 | 0.43 | 2,280 |
| Canada | 1050 | 543 | 0.52 | 2,658 |
| Mesh | 820 | 478 | 0.58 | 2,230 |
| Twitter escaped | 1324 | 918 | 0.69 | 109 |
| **Twitter (3-field model)** | 1841 | **1566** | **0.85** | 114 |

The same Twitter payload runs at 0.85 of raw with a 3-field model and 0.31 with a 26-field one:
what gets stored matters, not what gets matched. Capacity hints price the allocation half (LLM
+27%, GSoC +16%), so unhinted allocation is the larger lever. The Qwen rows are fixed-cost bound
and read separately.
## The allocation the census found: `StreamString`'s bookkeeping, not its blocks

*Recorded 2026-09-01.*

The capacity-hint variants of the object-heavy typed models bought +16% (GSoC) and +27% (LLM
message) by halving the malloc count. The hypothesis was the block schedule's doubling ramp; a
census showed it was wrong.

### The census

*Recorded 2026-09-01.*

`StringSizeCensus.swift` (`STREAM_PARSING_STRING_CENSUS=1`) replays the block schedule over the
string lengths a real parse produced.

| payload | values | inline | promoted | block buffers, fragment-fed → hinted | blocks-array allocs, today → reserved |
|---|---:|---:|---:|---|---|
| GSoC 2018 | 10,112 | 5,605 | 4,507 | 6,779 → 6,197 | 2,272 → 1,690 |
| LLM message | 1,276 | 730 | 546 | 1,494 → 1,092 | 948 → 546 |
| Twitter full | 811 | 540 | 271 | 271 → 271 | 0 → 0 |

`StreamString` is 82–84% of the typed layer's allocations on GSoC and LLM; Twitter is the control
and confirms the 512-byte start. Perfect size knowledge saves only 582 (GSoC) and 402 (LLM) block
buffers. The larger costs were bookkeeping: the `blocks` array doubling (25% of GSoC's
`StreamString` mallocs, 39% of LLM's), and a fragment-fed value re-reserving only the fragment in
hand after every sealed block.

### The change

*Recorded 2026-09-01.*

Both fixes are local to `appendBlocked`: reserve the whole block once a block has sealed (read from
`storageBits`, no dependent load), and reserve `blocks` to four at the first seal, keyed on
`capacity == 0` so a hinted reserve is not reallocated.

### Measured (3 clean interleaved rounds, best-of-3 p0 / median p50)

*Recorded 2026-09-01.*

| row | Δp0 | Δp50 | mallocs |
|---|---:|---:|---|
| Real LLM message - bulk discarding | **+11.2%** | +11.4% | 2,913 → 2,069 (−29%) |
| Real GSoC 2018 - bulk discarding | **+5.5%** | +5.6% | 11,000 → 9,518 (−13%) |
| Real LLM message string capacity hint | +1.2% | +2.7% | 1,415 → 1,313 (−7%) |
| CITM / Mesh / Canada / Twitter / GitHub / Twitter full | −0.4..+0.9% | | unchanged |
| Real GSoC string capacity hint | −0.1% | +0.7% | 7,511 → 7,387 (−2%) |
| Real Qwen 3 search - bulk discarding | −1.7% | −1.6% | 7 → 7 — the documented bimodal row |

Byte-fed and streaming rows are flat (within ±1%). `PartialSink.stringChunk` is byte-identical;
the change sits entirely in the out-of-line `appendBlocked`, which runs once per sealed block.

### What this leaves

*Recorded 2026-09-01.*

Hinted rows still lead (GSoC 1,045 vs 946, LLM 1,489 vs 1,290), but size knowledge is now worth
about half what it was. The larger remaining term is the per-fragment append itself.

## The open element moves into the storage

*Recorded 2026-09-08.*

> **Correction.** The frozen-tail chain under *Snapshots after the move* (`previous`/`previousTotal`
> links, compaction, the `spare` block) is not what shipped: the open element lives inline in
> `StreamArray.pending`, so a plain value copy is the snapshot. See "Correction: the frozen-tail
> chain is not what shipped" under "Design notes relocated from source comments".

A profile of the Twitter full typed parse showed where the typed rows' missing two-thirds went:

| where | share of wall |
|---|---:|
| `memmove` and struct copy/destroy witnesses | ~39% |
| parser (structural run, numbers, strings, UTF-8) | ~32% |
| every `PartialSink` method together | ~8% |
| malloc/free | ~3.5% |
| long-key tail compare | ~2.6% |

The `memmove`s came from `_streamArraySchema`'s element open moving an 11,904-byte
`BenchmarkTweetFull.Partial` about six times per tweet. The sink's 8% was too small a ceiling for a
generated per-type sink, so this change went after the moves instead.

### The protocol

*Recorded 2026-09-08.*

The element is copy-initialised in place from a template at the end of the tail block, and the sink
writes through that slot's address. The tail became a `StreamBlock` (`ManagedBuffer`, one
allocation per block, non-generic header), the template became a leaked per-schema pointer rather
than a closure, and uniqueness is settled once per container (`prepareWrites`,
`PartialSink.reseat()`) rather than per element, which had cost the double array 29%. The
dictionary's values took the same shape.

### Snapshots after the move

*Recorded 2026-09-08.*

Copying the tail on write cost `Retention 100 users` 90%, and freezing it into the spine made
`Retention Mesh - window 16` quadratic. The form described here froze a shared tail in place,
chained it behind a fresh tail, compacted the chain, and reused a `spare` block. Feeding chunks to
the three-field Twitter model with the latest state held:

| chunk | before | after |
|---|---:|---:|
| 64 B | 319 MB/s | 268 MB/s |
| 16 B | 132 MB/s | 98 MB/s |
| 4 B | 41 MB/s | 28 MB/s |

A retained snapshot inside an open element costs a fixed ~40 ns per cycle; non-retained snapshots
and view reads gained.

### Measured (3 interleaved rounds against 7229235, best-of-3 p0 / median p50)

*Recorded 2026-09-08.*

Typed corpus rows (raw controls within ±2%):

| row | base p0 | cand p0 | Δp0 | Δp50 | mallocs |
|---|---:|---:|---:|---:|---|
| Real Twitter full - bulk discarding | 576 | 791 | **+37.3%** | +37.1% | 1,078 → 1,266 |
| Real GitHub events - bulk discarding | 844 | 1052 | **+24.6%** | +25.3% | 63 → 80 |
| Real GSoC 2018 - bulk discarding | 943 | 1099 | **+16.5%** | +17.1% | 9,519 → 9,676 |
| Real Qwen 3 structured response - bulk discarding | 400 | 437 | +9.3% | +10.4% | 81 → 81 |
| Real Mesh - bulk discarding | 481 | 525 | +9.1% | +9.0% | 2,231 → 2,233 |
| Typed shape synthetic double array - typed parse | 752 | 817 | +8.6% | +7.9% | 1,264 → 1,264 |
| Real Qwen 3 workspace edit tool call - bulk discarding | 528 | 557 | +5.5% | +6.5% | 105 → 107 |
| Real Canada - bulk discarding | 543 | 565 | +4.1% | +3.8% | 2,659 → 2,671 |
| Real LLM message - bulk discarding | 1286 | 1306 | +1.6% | +1.5% | 2,069 → 2,069 |
| Real Twitter - bulk discarding | 1584 | 1592 | +0.5% | +0.2% | 114 → 114 |
| Real CITM catalog - bulk discarding | 943 | 927 | -1.7% | -0.8% | 2,281 → 2,403 |

The gain tracks the partial's size: the full Twitter element shrank from 11,904 to 6,608 bytes and
gained a third, while the 289-byte model is flat. CITM's cost is dictionary machinery.

Streaming and snapshots:

| row | Δp0 | Δp50 |
|---|---:|---:|
| Stream Array of structs - snapshot per byte | +331% | +332% |
| Scaling 400 users - snapshot per byte | +333% | +331% |
| Stream Array of structs - snapshot per 64B chunk | +30% | +30% |
| API PartialsStream Qwen 3 structured response - snapshot per 64B chunk | +38% | +38% |
| API PartialsStream Qwen 3 workspace edit - snapshot per 64B chunk | +23% | +23% |
| Stream Array of structs - view read per byte | +4% | +4% |
| Real * - byte by byte discarding | -2..+7% | |
| Retention 100 users - window 4 / 16 / 64 | -59% | -59% |
| Retention 100 users - keep all | -71% | -72% |
| Dictionary 8..512 keys - snapshot per byte / window 16 | -58..-72% | |
| Retention Mesh - window 16 | -21% | -21% |

A snapshot is now a retain, hence the +330% per-byte rows; rows that keep every snapshot pay an
allocation and reseat per cycle.

## One parse path: windowed mode removed, number extents from the block masks

*Recorded 2026-09-21.*

Two changes, 2026-09-20/21, measured separately with interleaved prebuilt binaries under heavy
machine load (floor about ±1.5% on p0).

### Windowed mode is gone

*Recorded 2026-09-21.*

Windowed mode (`JSONParserWindow.swift`, `JSONParserShapes.swift`, the C window indexer, the
long-decimal kernel and `windowThreshold`) was deleted, about 2,300 lines; it was off by default and
won only Canada and Mesh while losing 17–30% on typed string-heavy rows. `dispatchOnce` and the
block walk's re-probe hook (`blockWalkProbeThreshold`, `parseProbing`) survived, leaving `parse` and
`consumeStructuralRun` opcode-identical.

**`JSONParser`'s size is a placement lottery, not a cache-line effect -- measured, after a false
start.** Shrinking the parser from 96 to 80 bytes first read as a ~3–4% typed loss under load; a
clean sweep over seven padded sizes showed otherwise:

| row | 80 | 88 | 96 | 96 again | 104 | 112 | 128 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Dictionary 128 keys - discarding | -0.8% | -0.8% | 0 | 0.0% | 0.0% | -0.7% | +0.1% |
| GitHub events - bulk discarding | +0.2% | -0.1% | 0 | +0.2% | +0.2% | -0.7% | -2.9% |
| Twitter - bulk discarding | +0.3% | +0.2% | 0 | +0.1% | +0.4% | -1.3% | -2.2% |
| Twitter full - bulk discarding | +0.2% | -1.0% | 0 | +0.3% | +0.7% | -0.8% | -3.0% |
| Twitter full - 16KB chunks discarding | -0.4% | -1.3% | 0 | -0.2% | +0.3% | -1.3% | -3.1% |
| Canada - bulk discarding | -1.1% | +0.1% | 0 | +0.1% | +0.1% | -0.4% | -0.1% |
| Retention 100 users - window 16 | -0.3% | 0.0% | 0 | 0.0% | -0.1% | -0.3% | -4.0% |
| Twitter - bulk (raw) | -0.5% | -0.2% | 0 | -0.2% | -0.4% | -0.4% | -0.1% |
| mean of 11 rows | -0.20% | -0.22% | 0 | +0.09% | +0.25% | -0.69% | -1.77% |

80 vs 96 is −0.2%, so the padding was removed; 128 bytes is the worst point. The response is
neither monotone nor 64-periodic, which points to sink placement. A change that grows `JSONParser`
past ~104 bytes must be swept, not A/B'd once.

**The aligned box: built, measured, rejected.** `PartialsStream` as a handle over one
line-aligned allocation of parser, sink and value, with hot code opcode-identical:

| | box, 16-aligned | box, 64-aligned |
| --- | ---: | ---: |
| Twitter bulk / 16 KB | -1.0 / -1.1% | -0.9 / -1.2% |
| GitHub / LLM / GSoC | -0.7 / -0.7 / -0.6% | -0.7 / -0.8 / -0.5% |
| Canada / Mesh | +0.4 / +0.3% | +0.4 / +0.3% |
| Twitter escaped byte by byte | 0.0% | 0.0% |
| mean of 20 | -0.10% | -0.28% |

64- and 16-alignment are indistinguishable, and the box costs string and object rows about a point,
so it was not kept (patch at `~/.cache/sspab/s13/aligned_box.patch`).

### Number extents from the block masks

*Recorded 2026-09-21.*

The classifier now emits a `scalar_end` mask (whitespace, `,` and brackets), so the walk reads a
number's end with a shift, AND and bit count instead of running `streamNumberRunEnd` per token.
Error parity holds by construction: a longer extent means a malformed token, `emitNumber` fails it
with `.invalidNumber`, and the walk hands it back to the scalar loop, which reports the same error.
As shipped (gate unchanged) the mean was +0.3%, all within the floor.

With the gate forced open, mask extents vs the scan:

| row | raw | typed |
| --- | ---: | ---: |
| Mesh | +20.4% | +12.7% |
| Canada | +3.9% | +8.3% |
| Numbers small integers | +31.9% | -- |
| Numbers large integers | +10.6% | +3.1% |
| Numbers floats | +8.4% | +2.6% |
| Qwen 3 workspace edit | +5.0% | +0.9% |
| Twitter / GitHub / CITM | +2.0 / +2.2 / +0.9% | +0.7 / +0.4 / +0.3% |
| GSoC / LLM | -0.2 / -0.2% | -0.6 / 0.0% |

The ungated walk against the shipped gated parser still loses, so the gate stays:

| row | raw | typed |
| --- | ---: | ---: |
| Canada | -5.1% | -8.5% |
| Mesh | -7.4% | -11.6% |
| Qwen 3 workspace edit | -27.6% | -2.1% |
| Qwen 3 structured response | -11.6% | -0.6% |
| LLM message | -2.1% | -2.6% |
| Twitter escaped | -3.7% | -1.9% |
| Numbers wide exponent floats / large integers | -28% / -25% | -15% / -9% |
| Twitter / CITM / GitHub / GSoC | within +-1% | within +-1% |

Mesh's walk penalty fell from −26.4% to −7.4%. The entry condition that later landed is in "When
the walk runs: a signal in the ladder, a verdict per block"; a `Twitter spaced` corpus was added for
it.

## Separators after the token: number arrays and the key's colon

*Recorded 2026-09-28.*

Three changes, 2026-09-22..28 (`1f92f5b`, `289c859`, `bda6aeb`), each taking a separator together
with the token before it so neither the ladder nor the block walk makes a trip for a byte that emits
nothing. A/Bs use `-align-all-functions=6` builds and the median of five interleaved rounds.
Minified, spaced and indented separator rows were added (`SeparatorShapeBenchmarks.swift`).

### Landed: `fuseNumberRun`, an array's numbers taken without the ladder

*Recorded 2026-09-28.*

`fuseNumberRun` takes an array's comma, one optional space and the next number in a loop, falling
back to the ladder for anything else; events and errors are unchanged. Placement decided the result:

| | inline in the number arm | `@inline(never)`, entered at an array's comma |
| --- | ---: | ---: |
| Mesh typed | +25.6% | +22.7% |
| Mesh raw | | +19.9% |
| Mesh dynamic | | +16.9% |
| Canada typed | +0.7% | +2.2% |
| Twitter escaped typed | -1.6% | >= -0.4% |
| LLM raw | -1.8% | |
| byte-fed number rows | -1.6..-3.0% | about 0 |
| GSoC / Twitter escaped raw | | -2.0% / -1.1% |

The inline loop changed register allocation for every ladder path, so it went out of line behind a
cheap guard, which became the default rule for new structural-run fast paths.

### Landed: the key's colon, taken with the key in the block walk

*Recorded 2026-09-28.*

An in-block key now checks the byte after its closing quote and, if it is `:`, moves straight to
`.value`, saving a mask-loop iteration. Typed: Twitter +5.9%, Twitter spaced +6.3%, CITM +4.5%,
Twitter full +3.3%, GitHub +2.8%, GSoC +2.0%, no typed row below −0.3%; raw indented keyless rows
−1.9..−4.1%.

### Rejected: the value's comma, taken with the value in the block walk

*Recorded 2026-09-28.*

Testing for `,` after each value in the walk gave a +0.5% typed mean (CITM +1.0%, literals indented
−1.2%) for seven copies of the tail (1,344 → 1,760 instructions); the binary cost was judged larger
than the gain. Patch at `~/.cache/sspab/s13/rejected_comma.patch`.

### Landed: indented number arrays leave the walk for `fuseNumberRun`, with a predicted indent

*Recorded 2026-09-28.*

The walk spent ~275 instructions per number in an indented array against `fuseNumberRun`'s 196. The
walk's number arm now hands an array's comma to `fuseNumberRun`, which takes a whole whitespace run
using a predicted indent (`numberRunIndent`, a parser field at padding offset 9) checked by a
predicted branch; counting the indent directly put a load on the scan's critical path. Against
`289c859`:

| row | raw | typed |
| --- | ---: | ---: |
| Separators numbers indented | +45.3% | +36.7% |
| Separators number pairs indented | +6.3% | -1.1% |
| Separators literals indented | +5.9% | +1.9% |
| GSoC | +3.1% | |
| other typed rows | | within -1.5% |

−1.5% is the layout floor on these builds; the ladder is byte-identical.

### Measured: the whole series against where it started

*Recorded 2026-09-28.*

The branch (`t3code/unify-parser-path`, from `c89324a`) was fast-forwarded onto `new-architecture`
at `d8da86d`; upstream's own commits measured flat over the period.

| row | raw | typed |
| --- | ---: | ---: |
| Mesh | +14.0% | +12.3% |
| LLM message | | +6.7% |
| GitHub events | +6.9% | |
| Twitter | +6.6% | +2.1% |
| GSoC 2018 | +5.9% | +2.3% |
| Canada | +5.4% | -0.7% |
| CITM catalog | +5.2% | +0.9% |
| Twitter escaped | -5.8% | +1.7% |
| Qwen search | | -4.6% |
| Separators numbers indented | | +47.5% |
| Separators literals spaced | -21.8% | -6.2% |
| Separators literals minified | -7.7% | |
| Separators records minified | -4.9% | |
| Separators strings minified | | -4.8% |

The separator-row losses are not attributed; the suspects are the stateless signal (`515429e`) and
the escape staging (`06dc4a3`).

## Design notes relocated from source comments

*Recorded 2026-09-15.*

Rationale moved out of source comments, each site keeping a one-line pointer to its section here.
Numbers are arm64 (M1 Pro) unless stated.

### Raw parser (`JSONParser*.swift`)

*Recorded 2026-09-15.*

#### The structural block walk

*Recorded 2026-09-15.*

`JSONParserBlocks.swift` walks 64-byte blocks driven by masks from
`stream_parsing_classify_structural_block`, replacing the whitespace, string and number scans and
the per-string non-ASCII reduction; every arm restates `consumeStructural` and hands anything
unsettled back to the scalar loop. The grid re-anchors at each token's end, so carries are always
zero; the anchored alternative took GSoC/LLM from +15%/−3% to −9%/−20%. The walk is `@inline(never)`
so its hoisted constants stay out of `consumeStructuralRun`'s prologue.

#### When the walk runs: a signal in the ladder, a verdict per block

*Recorded 2026-09-21.*

The walk is entered when the ladder sees whitespace followed by whitespace or a quote, and left on a
block the classifier marks `ladder_block`; both tests depend only on the bytes at the cursor. The
census of whitespace runs that fixed the rule:

| corpus | runs | one byte | two or more |
| --- | ---: | ---: | ---: |
| CITM catalog | 76,337 | 33.9% | 66.1% |
| Twitter | 28,826 | 46.3% | 53.7% |
| GitHub events | 2,526 | 45.2% | 54.8% |
| GSoC 2018 | 41,713 | 45.5% | 54.5% |
| Twitter spaced | (Python `json.dumps`) | 100% | 0% |
| Mesh | 73,024 | 100% | 0% |
| Canada / LLM / Twitter escaped / Qwen | <= 18 | -- | -- |

Against the previous strike-count gate:

| row | raw | typed |
| --- | ---: | ---: |
| CITM catalog | -1.4% | +2.7% |
| Twitter full | -- | +2.5% |
| Dictionary 128 keys / Retention 100 users | -- | +2.1 / +2.0% |
| LLM message | -1.2% | +1.6% |
| GitHub events | -0.6% | +1.5% |
| GSoC 2018 | -0.6% | +1.1% |
| Qwen 3 workspace edit / structured | -0.7 / -1.6% | +1.1 / +0.3% |
| Twitter / Twitter escaped / Twitter spaced | -0.3 / -0.7 / -1.0% | +0.8 / +0.6 / +0.4% |
| byte-fed rows (6) | +0.3 .. +2.7% | |
| Canada | +1.2% | -1.4% |
| Mesh | -3.9% | **-5.5%** |
| mean of 41 rows | | +0.23% |

Mesh is the one real loss (−5.5%), from the signal's cost in the whitespace slow path. The spellings
that lost:

| spelling | what happened |
| --- | --- |
| signal on any whitespace byte; walk left only on a whitespace-free block | Mesh -7.0% raw / -10.6%: it enters on `, ` and stays |
| signal as `return ~i` to an outer driver loop that calls the walk | rows that never signal -1..-3% (Canada -1.9%, Mesh -2.9%): a second exit from the ladder's loop |
| the same signal as `i = ~i; break` | 169 stack accesses against 191, and *worse*: Canada -5.2%, Mesh -6.0% |
| two whitespace bytes only (no quote) | Twitter spaced -5.0%: Python-style objects want the walk |
| signal read off the scan's results (run >= 2, or stopped on a quote) | Mesh -3.2% but Canada raw -7.1%, Qwen raw -5.5%, `Pretty printed users - 64B` -10.6%, Qwen typed -1.6% |
| lookahead byte reused: when it is neither whitespace nor a quote it goes straight to the dispatch (`i += 1; byte = next`), skipping the scan | Mesh +3.6% (raw +2.1%), and the rest down: Twitter escaped -3.5%, Retention -2.9%, Canada -2.6%, Qwen -2.6/-2.4%, Twitter full -2.1%; raw Canada -4.5%, Qwen -5.2/-5.0% (mean -1.43%, floor -0.22%). 21 fewer instructions and 19 fewer stack accesses in the `NullSink` run; the compiler gave the shortcut its own edge into the token dispatch (and a free `next >= 0x40` tier) |
| the same, as `i += 1; continue` (no new edge into the dispatch; the byte is reloaded at the loop head) | 8 rounds, Mesh floor 0.0%: Mesh **+2.8%**, Mesh 16KB +0.7%, raw Mesh -2.4%; CITM -0.5%, Canada 0.0%; Twitter spaced -2.8% and Twitter escaped -2.4% on rows whose floor read -1.6% and -1.8% in that run. Not rejected by these numbers alone; re-tried on top of the fused signal below and closed there (Mesh -3.8%, LLM -2.5%) |

The signal was then fused into one AND and one branch (`signalBitmap` as a computed `static var`,
since a `static let` cost a lazy addressor call). `sig` is the fused test; `sigfus` adds the
`i += 1; continue` shortcut:

| row | `sig` raw / typed | `sigfus` raw / typed |
| --- | ---: | ---: |
| GSoC 2018 | +2.8 / +1.0% (16KB +0.9%) | +2.3 / +0.3% |
| CITM catalog | +2.4 / +0.7% (16KB +1.2%) | +0.8 / +1.2% |
| GitHub events | +0.6 / +0.5% | +0.5 / +0.8% |
| Twitter / spaced / full | +0.8 / +0.8 / -- ; +0.4 / +0.2 / +0.3% | +0.9 / +1.0 / -- ; +0.7 / +0.1 / +0.8% |
| Qwen 3 structured / workspace edit | 0.0 / 0.0 ; +0.7 / 0.0% | +0.8 / +1.1 ; -0.1 / -1.0% |
| LLM message | -1.3 / 0.0% (16KB +0.2%) | +1.5 / **-2.5%** (16KB -2.2%) |
| Mesh | -2.0 / -0.9% (16KB +0.5%) | +2.2 / **-3.8%** (16KB -0.6%) |
| Twitter escaped | +0.7 / -0.3% | +0.9 / -0.9% |
| Canada (24 whitespace bytes: never signals) | -1.3 / -2.6% (16KB -2.6%) | +0.1 / -4.5% |
| Retention 100 users / Dictionary 128 keys (minified: never signal) | +3.2 / +0.8% | +3.0 / +2.3% |
| mean of 34 rows | +0.22% | +0.11% |

`sig` landed; `sigfus` is closed (LLM typed −2.5%, Mesh typed −3.8%).

#### Staging the escaped string tail: the scan's load is the copy

*Recorded 2026-09-21.*

Typed `LLM message` is an escape-cycle benchmark (median 14-byte runs between escapes), and
`coalescedEscapedStringTail` scanned each run and then copied it. `streamStringRunStaging` stores each
scanned 16-byte block into the coalescing buffer as it scans, so the copy is the scan's load. Only
the tail changed (719 → 594 instructions for `PartialSink`):

| row | raw (`- bulk`) | typed (`- bulk discarding`) |
| --- | ---: | ---: |
| LLM message | +5.7% | +5.8% (16KB +5.9%) |
| Twitter escaped | -3.2% | +1.3% (16KB +1.3%) |
| GSoC | +0.9% | +1.5% |
| Twitter | +0.5% | +1.0% |
| CITM | +0.9% | -1.1% |
| GitHub | -0.5% | -0.3% |
| Qwen structured | 0.0% | -1.5% |
| Twitter full | | -0.2% |
| Dictionary 128 keys | | -1.7% |
| Retention 100 users | | -3.1% |

Retention and Dictionary never reach the tail; their losses are layout from the tail's smaller size.

#### Lending `StreamString`'s tail to the scan (built, measured, rejected)

*Recorded 2026-09-22.*

A sink requirement (`stringStorage()`, `lendsStringStorage`) let `PartialSink` lend the
`StreamString` tail so staging stored straight into it, removing the flush copy. Fixing three codegen
traps on the way (bridgeable `[StreamBlock<UInt8>]`, `blocks = []` allocating, and an `init()` that
assigns fields in its body costing two retain/release pairs per value) brought it from −5.6% to the
final shape:

| row | raw (`- bulk`) | typed (`- bulk discarding`) |
| --- | ---: | ---: |
| GSoC | -2.0% | +4.1% (16KB +4.1%) |
| LLM message | -0.2% | -1.4% (16KB -1.0%) |
| Twitter | +0.1% | -1.7% (16KB -1.5%) |
| Twitter escaped | -0.4% | -0.5% (byte-fed -1.9%) |
| GitHub | | -1.1% |
| Twitter spaced | | -0.9% |
| Canada | | -0.6% (16KB -0.6%) |
| Qwen workspace / structured | | -0.6% / -0.2% |
| Retention 100 users | | +5.8% |
| **mean** | | **-0.04%** |

Rejected for a −0.04% mean: a lend pays only for strings longer than the parser's buffer, and LLM's
early promotion costs more than the one copy it avoids. Patch at `~/.cache/sspab/s13/rejected_lend/`.

#### Skipping a subtree inside the block walk (built, measured, rejected)

*Recorded 2026-09-15.*

Doing a `.skip` in place inside the block walk won on small subtrees (Twitter +3.5%, GitHub +3.1%)
but lost on large ones (CITM −3.7%, LLM −1.4%), because subtrees outliving the block are re-read; the
sweep mean was +4.07% against +5.24%, so it was not kept.

#### The skip block scanner

*Recorded 2026-09-15.*

`JSONParserSkip.swift` scans a skipped subtree 64 bytes at a time (`stream_parsing_classify_skip_block`),
visiting only brackets outside strings and delivering only the matching close. The block loop is out
of line because inlining its hoisted constants into `consumeSkipRun` cost byte-fed Twitter escaped
−5.1%; UTF-8 validation is deferred to the first all-ASCII block, and bracket kinds are read from the
byte rather than from extra masks.

#### Two copies of the structural run, and why the body must be `@_transparent`

*Recorded 2026-09-15.*

`structuralRun(blocks:)` is instantiated twice with a literal flag, because sharing one loop cost the
ladder registers (Mesh −7.3%, Canada −4.0%). The shared body must be `@_transparent`:
`@inline(__always)` cost Mesh 4.0% and `@inlinable` 7.4%, while `@_transparent` measured +0.00%. On
x86 the block copy is a call, since inlining both cost Mesh −7.8%.

#### Reading an escaped string value inside the structural run

*Recorded 2026-09-15.*

`consumeEscapedStringInRun` finishes an escaped string value inside the run instead of handing it
back for a rescan. It must not fuse the following comma, because `self.depth`/`self.containers` are
stale inside the run; zeroing `self.depth` makes the fusion decline, which cost less than either
storing the run's registers first or threading a `fusing` flag (byte-fed LLM −5%).

#### The escape scratch: a reserved region, not a stack local

*Recorded 2026-09-15.*

Eight bytes reserved past `bufferCapacity` give a decoded escape a stable in-memory address; a
`withUnsafeBytes` local instead cost −10..−14% on escape rows. The whole word is stored
unconditionally: a per-byte loop turned Twitter escaped from +4.3% to −2.2%.

#### Coalescing escaped string content

*Recorded 2026-09-15.*

From the first backslash, `coalescedEscapedStringTail` copies content into the parser's buffer and
hands it over per buffer-full (LLM chunks 26,076 → 2,003). Every sink takes this path, accepting
~11% on a counting sink over a second delivery mode. The tail is `@inline(never)` (inline cost raw
LLM −52%), the coalescing flag is a compile-time literal, and both buffer appends are wide bounded
stores.

#### `parse(byte:)`'s one-shape fast path

*Recorded 2026-09-15.*

`parse(byte:)` drives `dispatchOnce` directly and checks first for an ordinary ASCII byte inside a
string value, delivering it with one `stringChunk` call. The condition order (state, then byte range)
was measured; `deliverStringByte` is `@inline(never)`.

#### `trimmingIncompleteUTF8` must be forced inline

*Recorded 2026-09-15.*

Left to the optimizer it stopped being inlined into the byte-fed `consumeStringRun<PartialSink>`
copy and cost byte-fed LLM 1.4%; forcing it restores the previous code.

#### `sequenceLength`: counted, not branched, and not a nibble table

*Recorded 2026-09-15.*

A UTF-8 lead's length is counted as three independent compares plus one. A packed nibble table lost
2–4% across the corpus from its 10-byte immediate inlining into `parse`; the counting form gained
Twitter +1.4%, Twitter escaped +2.0%, LLM +1.8%, at Canada −3.7% (layout).

#### `JSONParser`'s field order is a cache-line decision

*Recorded 2026-09-15.*

Everything a parse touches lives in the first 64 bytes, with small fields narrowed rather than
bit-packed. New one-byte fields go in the padding at offset 9; anywhere earlier turned every
`consumeStructuralRun` specialisation's `strh` into `sturh`.

### Scanners and C shims (`StreamScanners.swift`, `StreamParsingShims`)

*Recorded 2026-09-15.*

#### The structural block classifier's two-table encoding

*Recorded 2026-09-15.*

A byte's classes are `lo_table[b & 0xF] & hi_table[b >> 4]`; the eight class bits were rearranged to
free room, and whitespace takes a separate low-nibble lookup. Measured on Twitter: this spelling 9.43
ns/block, `(c & 0x01) | (v == 0x20)` 9.87, compare-derived operators 10.53.

#### `find_escaped` stays scalar

*Recorded 2026-09-15.*

The escape finder's `bs_bits + starts` carry chain has no NEON equivalent (no segmented scan) and runs
on idle integer ports. Two NEON forms measured +7..+31% slower per block, and a `bs_bits == 0`
early-out +0.7..+17.6% slower.

#### The x86 escalation bound in `streamStringRun`

*Recorded 2026-09-15.*

On x86-64 the scanner runs two SIMD16 blocks inline before escalating to `streamStringRunWide`, with
the limit folded into the loop bound (`narrowLimit`). A per-iteration counter cost CITM −2.6% and Qwen
search −5.0%; gating on `streamHasAVX2` inline cost CITM −9.9%, so the check stays behind
`@inline(never)`.

#### The first-hit lane: a branchless combination, because x86 un-does `cmov`

*Recorded 2026-09-15.*

`streamFirstHitLane` reads the mask as two 64-bit words and takes trailing zeros over eight, replacing
a sixteen-way branch ladder. The halves are combined arithmetically, because x86's cmov converter
turned a ternary back into branches:

| | lane |
| --- | --- |
| low has a hit | `lowCount / 8` (0 ... 7, mask is 0) |
| low is empty | `8 + highCount / 8` (8 ... 16, mask is all ones) |

#### `streamHashBytes`: FNV's shape, not its arithmetic

*Recorded 2026-09-15.*

The key hash keeps FNV's form but feeds two accumulators from one SIMD16 load, halving the multiply
dependency chain; keys under sixteen bytes take a bounded word ladder.

### Typed layer (`PartialSink`, schemas, sinks, conversions)

*Recorded 2026-09-15.*

#### `PartialSink`'s frame stack: a fixed allocation, two slots of headroom, and the overflow frame

*Recorded 2026-09-15.*

The frame stack is one allocation of `JSONParser.maximumDepth + 2` frames, avoiding `Array`'s
uniqueness and bounds checks. `pushOverflowFrame` keeps overflow balanced by pushing one ignored frame
for the first over-deep container and counting the rest; the first version left the top frame on the
parent.

#### The SIMD lane store bypasses the known-slot resolution

*Recorded 2026-09-15.*

`PartialSink.storeSIMDDoubleLane` stores a `SIMD2/3/4<Double>` lane directly, since every fact
`knownScalarSlot` resolves is constant for those routes. `storeNumber` stays `@inline(__always)`
(outlined, it cost the lane path 3%).

#### Three `init(exactly:)` calls, and what they actually lowered to

*Recorded 2026-09-15.*

The generic float conversion's cost was three `init(exactly:)` calls, not genericity; replacing them
(with `Self(_:)`, `streamMaxExactPow10`, and nothing) made the `Double` specialisation straight-line,
so the non-generic `Double` body was deleted and `Float` gained the same three tiers.

#### `streamEiselLemireAny`: a guarded bridge, not `.map`

*Recorded 2026-09-15.*

Superseded by `StreamFastFloatConvertible` ("Extensible fast decimal conversion"). The bridge used
foldable type tests and `guard let`, because `.map` formed a real closure in the unspecialised generic.

#### Initial-value templates for generic containers, and when a hoist pays

*Recorded 2026-09-15.*

Generic containers cannot hold a stored static template, so each open paid a generic-metadata lookup.
7a21472 hoisted the optional-container template into the schema builder (CITM discarding +39.6%);
05bace4 did the same for container builders, where a blanket hoist split by element type:

| blanket hoist | Δ |
| --- | ---: |
| Canada capacity hint / dynamic coordinates - discarding | +20..27% wall |
| Mesh capacity hint / dynamic influences - discarding | +9.7..12.2% |
| CITM catalog, Twitter full - discarding | **-5.4..-7.8%** |
| `Schema 48 members` first/last/undeclared | **-18..-22%** |

A hoist must pay for the closure context it creates, so builders choose per element type (initially
on `_streamInitialValueIsExpensive`). The template is owned through `_streamOwnedTemplate` rather
than leaked.

#### `StreamEventBatchingSink`: the third looser contract, and the flush's borrow discipline

*Recorded 2026-09-15.*

A deferred rejection reports the token current at the flush, `StreamEventRecord.end` is unpopulated,
and skipped subtrees are delivered in full. `flush` calls the consumer outside every array borrow,
holding the arrays with `withExtendedLifetime`, so a re-entrant consumer cannot mutate a live batch.

### Streaming collections (`StreamArray`, `StreamDictionary`, `StreamString`, `StreamBlock`)

*Recorded 2026-09-15.*

#### Correction: the frozen-tail chain is not what shipped

*Recorded 2026-09-15.*

The freeze/compact/`spare` chain in "The open element moves into the storage" is not in the code;
`StreamBlockHeader` has only `count` and `capacity`. The open element is held inline in
`StreamArray.pending`, so a value copy is a snapshot, at the cost of one element move per element.
The section's other three properties still hold.

#### Landed: ordinary copy-on-write on the tail

*Recorded 2026-09-19.*

Sharing a tail block on a written-past rule was unsound once a value had two copies (`var b = a`
appends collided). `nextSlot` now calls `ensureUniqueTail`; regression tests and a Thread Sanitizer
harness pass. Measured on x86_64 Linux:

| Benchmark | Before µs | CoW µs | Change | Mallocs |
| --- | ---: | ---: | ---: | ---: |
| Real Canada — bulk discarding | 6,021.12 | 6,901.76 | -12.8% | 1,398 → 1,398 |
| Real Mesh — bulk discarding | 2,263.04 | 2,527.23 | -10.5% | 352 → 352 |
| Dictionary 512 keys — discarding | 225.15 | 248.45 | -9.4% | 39 → 39 |
| Dictionary 128 keys — discarding | 56.35 | 62.11 | -9.3% | 33 → 33 |
| Retention 100 users — keep all | 410.88 | 478.72 | -14.2% | 28 → 122 |
| Retention Mesh — window 16 | 153,000 | 161,000 | -5.0% | 603 → ≈70,000 |
| Stream Array of structs — snapshot per byte | 408.83 | 411.65 | -0.7% | 26 → 26 |
| Real Twitter — bulk discarding | 474.37 | 469.76 | +1.0% | 132 → 132 |
| Real GitHub events — bulk discarding | 73.41 | 71.87 | +2.1% | 80 → 80 |

Canada, Mesh and the dictionary rows pay the check and code growth alone; the retention rows also
copy a tail per retained snapshot. ARM numbers are not in yet.

#### Block teardown: `deinitialize(count:)`, not a `move()` loop

*Recorded 2026-09-15.*

`StreamBlock.deinit` is emitted once generically, so a `move()` loop memmoved every element onto the
stack (1.19 MB per Twitter full parse). It is now one `deinitialize(count:)` behind an `_isPOD`
guard; without the guard the double array lost 10%.

#### StreamArray block sizing for small trivial elements

*Recorded 2026-09-15.*

Trivial elements of at most sixteen bytes get 2 KB blocks (`blockByteShift`) instead of 32 elements,
since `prepareSlot` was 4.0% of typed Mesh and 3.0% of Canada. A 64-byte ceiling cost CITM 1.2% for no
gain.

#### `_appendClosed`: the whole-value route skips the open element

*Recorded 2026-09-15.*

Whole-token routes commit straight into the block slot, skipping `pending`'s move and tag writes.
`appendSealed` is `@inline(__always)` here, since outlined it was slower than the `_openElement` round
trip.

#### `StreamArray.streamSchema` must be `@inlinable`, and cached

*Recorded 2026-09-15.*

`@inlinable` lets a container-rooted parse specialise its schema closures in the client module
(unspecialised: ~2.9% in `swift_getGenericMetadata`). The schema is cached per type, now through the
public `StreamSchemaCache`; concrete `Partial`s read through a `private static let streamSchemaEntry`
because a lookup by type cost 85 ns a stream:

```
                                          static let     lookup by type     entry
Setup Flat struct - schema read (ns)        151-197          262-285        163-201
Layer Flat struct bulk - stream (MB/s)        52-56            46-49          50-55
Stream Flat struct - discarding (ns)      2845-3033        3037-3253      3043-3143
```

`StreamArray.sealedCount` is `@inlinable` so the client-specialised `drainPending` does not call the
generic getter.

#### `StreamDictionary._openValue`: three shapes, each measured

*Recorded 2026-09-15.*

Fusing `drainPending()` into the open was 32% slower on dictionary rows; folding the two overloads into
one body lost specialisation (dictionary rows −2/3, GSoC −20%). The template is `UnsafePointer<Value?>`
so the open is one `initializeWithCopy` rather than five 1 KB copies.

#### `StreamDictionary.slot` is force-inlined to avoid staging `self`

*Recorded 2026-09-15.*

Out of line, the non-mutating `slot` call made the caller copy the whole 2,164-byte dictionary twice
per key; `@inline(__always)` removes the copy.

#### `StreamString`: the first overflow append sizes the schedule from the whole byte count

*Recorded 2026-09-15.*

The first overflow append sizes the block schedule from the whole byte count in hand (a hint uses
half), so a bulk span lands in one block. Typed LLM +73.7% and GSoC +11.6% over b01cfd6, LLM mallocs
2,069 → 576, at no memory cost.

### Public API

*Recorded 2026-09-15.*

#### `PartialsStream`'s entry points must stay `@inlinable`

*Recorded 2026-09-15.*

`init(initialValue:from:)` must build the root schema in the client module (~2.9% otherwise), and
`next(_:)` must be visible so `JSONParser.parse` specialises (opaque, it was half the wall clock of
byte-fed rows and 3% of bulk).

#### Address first, view once: the Swift 6.3 PDAE crash

*Recorded 2026-09-15.*

Swift 6.3 crashes in `PredictableDeadAllocationElimination` on a generic function returning
`Optional<T.View>`. Branches yield a raw `UnsafeMutableRawPointer?` and a single exit forms the view
with `_overrideLifetime`, as in `_streamMemberAddress` and the collection view subscripts; new
`View`-returning generic APIs should keep this shape until 6.3 is dropped.

#### Extensible fast decimal conversion

*Recorded 2026-09-30.*

`StreamFastFloatConvertible` adds one requirement, `streamConvertDecimal(magnitude:exponent:negative:)`,
and a generic Eisel–Lemire kernel built through `BinaryFloatingPoint` supports `Float16`, `Float`,
`Double` and `Float80`, with a cold binary16 fallback correction. 1,017 tests pass. Measured on
x86_64 (Swift 6.3.3), before/after/after/before p50:

| Real payload | Mode | Before MB/s | After MB/s | Change |
| --- | --- | ---: | ---: | ---: |
| CITM catalog | bulk | 1638.5 | 1559.0 | -4.9% |
| CITM catalog | bulk discarding | 595.0 | 588.0 | -1.2% |
| Canada | bulk | 529.0 | 552.0 | +4.3% |
| Canada | bulk discarding | 342.0 | 336.0 | -1.8% |
| Mesh | bulk | 566.5 | 600.0 | +5.9% |
| Mesh | bulk discarding | 352.5 | 364.0 | +3.3% |
| Qwen 3 search tool call | bulk | 464.0 | 444.5 | -4.2% |
| Qwen 3 search tool call | bulk discarding | 112.0 | 106.5 | -4.9% |
| Twitter | bulk | 1210.0 | 1225.0 | +1.2% |
| Twitter | bulk discarding | 1358.0 | 1368.5 | +0.8% |

The aggregate is −0.2% with mixed per-case effects; ARM throughput was not measured. A follow-up
simplification removed 62 lines, kept the Float/Double instruction sequences identical, and measured
−0.1%.
## `StreamString` holds one reference

*Recorded 2026-10-06.*

`StreamInlineString` beat `StreamString` on its field rows (298 µs against 471) by being plain data.
A decomposition put most of the gap in the two arrays `StreamString` carried (`blocks` and `tail`):
an outlined call per member materialised, two dependent loads per inline test, and six
`swift_release` calls per record on teardown.

### The layout

*Recorded 2026-10-06.*

`StreamString` is now the 64 inline bytes, `storageBits`, and one optional `tail` reference (a
`StreamStringChunk` whose header carries the sealed blocks), `nil` while inline; 88 bytes → 80. The
inline test becomes `tail == nil`, a copy is one retain, and the blocked append is one uniqueness
check plus an inline `memcpy`. Promotion is one-way, a seal allocates the next tail immediately, and
the type is now `@unchecked Sendable`.

### The initialiser trap

*Recorded 2026-10-06.*

The first build had an outlined copy and destroy of `StreamString` in every member open, because an
`init()` that assigned its properties built `self` in a stack slot whose ARC ops were not paired.
Declaring every property's default and leaving `init()` empty removed the call.

### Measured (x86_64, pinned layout, best of 2 interleaved gated passes, wall p50)

*Recorded 2026-10-06.*

| row | before | after | Δ |
|---|---:|---:|---:|
| Real Twitter - bulk discarding | 458.5 µs | 448.0 µs | −2.3% |
| Real Twitter - bulk / 16KB chunks discarding | | | −0.4% / −0.1% |
| Real Twitter full - bulk discarding | 1,379 µs | 1,263 µs | −8.5% |
| Real Twitter generic - bulk discarding | 478.0 µs | 452.6 µs | −5.3% |
| Real GSoC 2018 - bulk discarding | 3,883 µs | 3,387 µs | −12.8% |
| Real GitHub events - bulk discarding | 75.1 µs | 65.2 µs | −13.2% |
| Real Qwen 3 structured response - bulk discarding | 37.9 µs | 33.3 µs | −12.1% |
| Real Qwen 3 workspace edit tool call - bulk discarding | 63.0 µs | 56.0 µs | −11.1% |
| Real LLM message - bulk discarding | 778.8 µs | 756.7 µs | −2.8% |
| Real LLM message - snapshot per 1400B chunk | 1,221 µs | 1,164 µs | −4.6% |
| Real CITM catalog - bulk discarding | 2,687 µs | 2,656 µs | −1.1% |
| Real Canada / Mesh - bulk discarding (controls) | | | +0.9% / +0.3% |
| Real Twitter full String storage - bulk discarding | 1,774 µs | 1,793 µs | +1.1% |
| Inline string Fields StreamString - bulk | 469.5 µs | 389.4 µs | −17.1% |
| Inline string Array StreamString short - bulk | 102.8 µs | 92.3 µs | −10.2% |
| Inline string Array StreamString medium - bulk | 356.1 µs | 302.8 µs | −15.0% |
| Inline string Dictionary StreamString short - bulk | 283.4 µs | 266.0 µs | −6.1% |
| Stream Long string - snapshot per byte | 527.4 µs | 348.7 µs | −33.9% |
| Fields of three strings, teardown only | 40.0 µs | 19.0 µs | −52.5% |

Malloc counts unchanged except GSoC (8,650 → 8,581); the `String storage` row's +1.1% is noise. ARM
was not measured. The remaining `Fields` gap (389 against ~300) is what only plain data has: teardown
visiting each element and an 80-byte member.

### `StreamInlineString` removed

*Recorded 2026-10-06.*

`StreamInlineString` (OS 26 only, fixed capacity, overflow failed the parse, its own erased sink
route) was removed; a bounded field is now a `StreamString` checked after the parse. Its sink code
shrank (`stringChunk` 332 → 203 bytes) and the parse stayed flat within placement noise (Twitter
−0.5..+0.7%, GSoC −1.4%, CITM +1.5%), malloc counts identical.

## Frames name their schema by position

*Recorded 2026-10-08.*

`enterField` returned a `StreamFrame` with a strong `schema` that the sink dropped, so a schema
built inside the closure could be freed while the parse wrote through it. `StreamFrame` now carries
`childIndex` into the entering schema's new `children` (or `reentering`, -1), so a frame's schema is
always owned by its parent, and the debug weak-reference audit is deleted. The trade-off: a
hand-written schema can no longer reach itself through another schema. With the new fields declared
last the parse is instruction-identical except `valueTarget()`'s `enterField` branch; a
hand-written 100,000-deep `enterField` row went 121.0 → 113.7 ns (−6%), macro rows within ±1%
(CITM +2.8%, bimodal). ARM was not measured.


## `StreamBase64Data`

*Recorded 2026-10-09.*

A base64 string decodes into its own type, `StreamBase64Data`, in the core (works without Foundation
and under Embedded), while `Data` keeps parsing a string as UTF-8 text. It accepts
`Data(base64Encoded:)`'s rule except `====`, reports rejection as `.conversionFailed` at the closing
quote, catches a string ending mid-group via the conversions rather than a string-end hook, and
compares only `bytes` for equality.

### The loop

*Recorded 2026-10-09.*

Each group is one four-byte load and four lookups into shifted 256-entry `UInt32` C tables ORed
together (modp_b64's layout), one compare to reject, one four-byte store. The table compares three
scalar loops on 1 MiB; the four-table loop won. The output staging and growth were then fixed
(heap staging on Linux, ten doublings).

| loop | µs | MB/s of text |
|---|---:|---:|
| 256-byte sextet table, shifts, three one-byte stores | 589 | 2,375 |
| four shifted tables, one four-byte store | **366** | **3,817** |
| the same, two groups per eight-byte load and store | 454 | 3,080 |

### Measured

*Recorded 2026-10-09.*

`Base64 1MiB` rows (x86_64, pinned layout, best of three gated passes, wall p50):

| row | first version | scalar (a510f496) | mallocs |
|---|---:|---:|---:|
| `StreamBase64Data` bulk | 578.6 µs | **441.1 µs** (3,175 MB/s) | 362 → 20 |
| `StreamBase64Data` per 1400B | 766.5 µs | **617.0 µs** (2,271 MB/s) | 1,029 → 30 |
| `StreamString` keeping the text, bulk | | 143.6 µs (9,791 MB/s) | 196 |
| `JSONDecoder` decoding `Data` | | 1,956.9 µs (714 MB/s) | 30 |
| `Data(base64Encoded:)` on the text alone | | 508.9 µs (2,751 MB/s) | 18 |

The scalar version was 4.4x `JSONDecoder` but three times the cost of keeping the text. Parser and
sink code instruction-identical; real-world rows within ±1.1%. ARM was not measured.

### The vector tier

*Recorded 2026-10-09.*

Muła and Lemire's block decoder runs before the scalar loop: eight groups per block with AVX2 (out of
line in `AVX2.c`) and sixteen with NEON (inline), handing any block with a non-alphabet byte back to
the scalar loop. Chunks now decode straight into spare capacity instead of staging. The first table
shows the kernels alone (one AVX2 block per iteration ships); the second the `Base64 1MiB` rows.

| kernel | 12 KB decoded | 96 KB | 1 MiB |
|---|---:|---:|---:|
| scalar four-table loop | 3,104 | 3,108 | 3,096 |
| AVX2, one block an iteration | **18,043** | **17,501** | 14,085 |
| AVX2, four blocks, one validity branch | 16,723 | 16,436 | **15,238** |

| row | scalar (a510f496) | AVX2, staged | AVX2, direct |
|---|---:|---:|---:|
| `StreamBase64Data` bulk | 442.4 µs | 168.8 µs | **167.6 µs** (8,382 MB/s) |
| `StreamBase64Data` per 1400B | 618.0 µs | 344.1 µs | **324.9 µs** (4,324 MB/s) |
| `StreamString` keeping the text, bulk | 144.3 µs | 144.0 µs | 144.5 µs |

Bulk is now 3.0x `Data(base64Encoded:)` and 11.7x `JSONDecoder`; per 1400B is still twice bulk.
Parser and sink functions instruction-identical; real-world rows within −0.2..+1.2%.

### On arm64

*Recorded 2026-10-13.*

On an M1 Pro the NEON kernel is bound by SIMD issue and Firestorm prices `tbl` by table width (first
table). The tables are now indexed by `text >> 2` (32 four-byte buckets), with `sli` packing and one
overlapping tail block replacing the scalar remainder; two blocks per iteration and aklomp's
128-entry lookup were measured and not taken. The `Base64 1MiB` rows went bulk +12.8%, per 1400B
+9.8%, with real-world rows within −0.7..+2.5%. The AVX2 kernel took the same tail block, checked
under Rosetta but not measured.

| instruction | cycles |
|---|---:|
| `add`, `sli`, one- and two-register `tbl`, one-register `tbx` | 0.26 |
| three-register `tbl` | 0.51 |
| four-register `tbl` | 0.78 |
| four-register `tbx` | 1.04 |

| kernel | 1.4 KB | 16 KB | 128 KB | 1.4 MB |
|---|---:|---:|---:|---:|
| first port: nibble classes, `/` compare, shift-OR packing | 14,237 | 13,661 | 13,664 | 13,689 |
| the same with `sli` packing | 14,913 | 14,330 | 14,373 | 14,387 |
| `text >> 2` buckets and `sli` packing | **17,244** | **16,535** | **16,536** | **16,632** |
| the same, two blocks an iteration, one validity branch | 17,181 | 16,727 | 16,779 | 16,811 |
| 128-entry `tbl`/`tbx` lookup (aklomp/base64's NEON64) | 14,740 | 14,133 | 14,152 | 14,139 |
| the load and store alone | 53,163 | 50,806 | 51,525 | 51,627 |

| row | first port (29d438cc) | buckets + `sli` | + tail block |
|---|---:|---:|---:|
| `StreamBase64Data` bulk | 162.3 µs | 143.6 µs | **143.9 µs** (9,716 MB/s) |
| `StreamBase64Data` per 1400B | 249.6 µs | 233.2 µs | **227.3 µs** (6,151 MB/s) |
| `StreamString` keeping the text, bulk | 106.6 µs | 106.8 µs | 105.9 µs |

### The storage

*Recorded 2026-10-14.*

Decoded bytes moved from `[UInt8]` to `StreamBase64Data.Storage`, a `ManagedBuffer` whose tail holds
the first bytes and whose later growth `realloc`s a `malloc` block; `bytes` is a
`RandomAccessCollection` view with array copy-on-write rules. Three traps first made it slower:
uniqueness asked after binding, `swift_beginAccess` on class fields, and returning the reference
from `reserve` (2,004 retains). Per 1400B −12.7% and 2,000 short values −14.7%, bulk unchanged;
parser code opcode-identical.

| row | `[UInt8]` | `Storage` | median p50 / min p0 |
|---|---:|---:|---:|
| `StreamBase64Data` bulk | 144.1 µs | 143.7 µs | −0.3% / 0.0% |
| `StreamBase64Data` per 1400B | 228.6 µs | **199.7 µs** (7,000 MB/s) | **−12.7% / −13.8%** |
| `StreamBase64Data`, 2,000 short values | 368.1 µs | **314.1 µs** | **−14.7% / −14.8%** |
| `StreamString` keeping the text, bulk | 107.1 µs | 105.2 µs | −1.9% / −0.2% |

## `StringInfo`: where a span sits in its string

*Recorded 2026-10-15.*

`StreamStringConvertible` now has the single requirement `streamAppend(utf8:info:)`, with
`StringInfo.flags` marking `.begin` and `.end`; `streamAppend(utf8:)` and `finishString` are gone.
The raw parser is unchanged; the first table maps the sink callbacks. The whole-string path lost
closure calls and retain pairs (`writeTableString` 113 → 71 instructions): typed Twitter full
`String` storage −13%, Twitter custom text −4.4%, mean −0.89% at p0 over 59 rows, nothing slower
than +0.7%. `StringInfoTests` holds the contract on every route.

| sink callback | before | now |
|---|---|---|
| `stringBegin` | `applyString(…, Span())` | the same call, carrying `.begin` |
| `stringChunk` | `applyString(…, bytes)` | the same call, carrying `[]` |
| `stringEnd` | `finishString?(…)`, nil for all ordinary storage | `applyString(…, Span(), .end)` |
| `string(_:)`, matched field, `custom` table entry or `delegated` member | open with an empty span, the bytes, then `finishString` if set | **one call** carrying `[.begin, .end]` |

| row | before | after | change |
|---|---:|---:|---:|
| Twitter full `String` storage, bulk | 1,294.6 µs | **1,126.3 µs** | **−13.0% / −12.9%** |
| Twitter full `String` storage, 16KB chunks | 1,305.4 µs | **1,136.0 µs** | **−13.0% / −12.7%** |
| Twitter custom text, bulk | 260.5 µs | **249.1 µs** | **−4.4% / −5.7%** |
| LLM message `String` storage, bulk | 641.8 µs | **615.5 µs** | **−4.1% / −4.8%** |
| LLM message `String` storage, snapshot per 1400B | 1,126.4 µs | **1,090.1 µs** | **−3.2% / −3.5%** |
| Qwen 3 workspace edit, bulk | 33.1 µs | 32.6 µs | −1.5% / −3.0% |
| Twitter escaped, byte by byte | 5,486.0 µs | 5,413.9 µs | −1.3% / −1.6% |
| LLM message, bulk | 390.9 µs | 393.7 µs | +0.7% / −1.2% |

### `.validatedUTF8`

*Recorded 2026-10-15.*

`StringInfo.Flags.validatedUTF8`, opt-in via `PartialSink(root:schema:validatedUTF8:)` and set by
`PartialsStream`, lets `String`'s conformance skip the SIMD validator for spans of 32 bytes or more.
Taking that path at every length first cost byte-fed LLM 22.6% from the `#available` runtime call.
LLM `String` storage +11.8..+17.6%, geomean +1.20% over 60 rows. Correction: the ASCII scan stays,
because without it `String(copying:)` marks the string non-ASCII.

| row | before | after | change |
|---|---:|---:|---:|
| LLM message `String` storage, bulk | 1,716 | **1,988** | **+15.9% / +17.4%** |
| LLM message `String` storage, 16KB chunks | 1,607 | **1,855** | **+15.4% / +17.0%** |
| LLM message `String` storage, snapshot per 16384B | 1,587 | **1,866** | **+17.6% / +16.8%** |
| LLM message `String` storage, snapshot per 1400B | 963 | **1,077** | **+11.8% / +12.3%** |
| Twitter full `String` storage, bulk | 551 | 570 | +3.4% / +2.9% |
| LLM message `String` storage, byte by byte | 30 | 31 | +3.3% / 0.0% |

---

## The generic API review: async termination fixed, four findings recorded

*Recorded 2026-09-16.*

A review of the public API surface above the JSON scanning kernels, measured on x86_64 Linux (ARM
unmeasured).

### Existing surface

*Recorded 2026-09-16.*

The table lists the public surface reviewed. Insertion-order dictionary equality, bytewise string
equality and the nil-subscript no-op are documented contracts, not bugs.

| Area | Available behavior |
| --- | --- |
| Raw events | `StreamParseSink`, whole/chunked strings, number tokens plus `NumberInfo`, advisory subtree skipping, commit boundaries, batching and replay |
| Typed streams | `PartialsStream`, snapshots, borrowed views, consuming finalization, allocation reuse/reset, synchronous byte/chunk collection, single-subscriber async partials |
| Conversion | Initial values, strict partial-to-value conversion, recursive defaulting, raw-representable enums, custom string/number/boolean/null conversion |
| Collections | `StreamArray` with random access, mutable elements and range replacement; insertion-ordered `StreamDictionary`; bridging to standard arrays and string-keyed dictionaries |
| Text | Blocked `StreamString`, UTF-8/scalar views, character iteration, comparison as `String` compares, bytewise search and prefix/suffix checks, interpolation and Codable |
| Standard types | Signed/unsigned integer widths including availability-gated 128-bit types, Float/Double, Bool, String, Optional, arrays and string-keyed dictionaries |
| Fixed storage | `InlineArray` and SIMD2/3/4 with exact JSON arity checks |
| Optional integrations | Foundation Data (decoded string UTF-8, not base64), Decimal, PersonNameComponents; CGFloat; Tagged; swift-collections initializers/bridges (not general parseable conformances) |

### Trivial fix

*Recorded 2026-09-16.*

`AsyncPartialsSequence.AsyncIterator.next()` now terminates after any thrown error, via a terminal
flag shared across iterator copies, with regression tests for each failure path.

### Bugs for discussion

*Recorded 2026-09-16.*

Four findings: (1) shared-tail appends after a copy overwrote each other's slots, since resolved by
the copy-on-write change below; (2) dictionary lookup changes canonical-equivalence behaviour once a
key stops being pending; (3) malformed UTF-8 character traversal can emit content twice; (4) public
indexing on `StreamArray` and `StreamEventBatch` lacks bounds checks. Reproductions live in
`GenericReviewTests.swift`; the two Unicode cases remain expected failures.

### Validation

*Recorded 2026-09-16.*

764 tests passed serially with four known issues; the parallel run tripped an allocation-count test
from suite interference. A paired before/after benchmark sweep (x86_64 Linux, ARM unmeasured)
showed raw/typed changes of −0.9..+1.9% and async −3.1..+6.6%; only the async driver changed.

#### Corpus throughput

*Recorded 2026-09-16.*

Median payload MB/s, original → patched, raw and typed.

| Corpus | Raw MB/s | Typed MB/s |
| --- | ---: | ---: |
| Twitter | 1177 → 1169 | 1345 → 1342 |
| Twitter escaped | 687 → 687 | 932 → 932 |
| Canada | 530 → 530 | 373 → 373 |
| CITM catalog | 1541 → 1528 | 636 → 649 |
| GSoC 2018 | 2791 → 2777 | 931 → 937 |
| GitHub events | 1394 → 1396 | 905 → 906 |
| LLM message | 2281 → 2283 | 1491 → 1490 |
| Mesh | 405 → 404 | 320 → 319 |

#### Async throughput

*Recorded 2026-09-16.*

Async rows, change from median wall time (positive is faster).

| Qwen 3 workload / chunk size | MB/s, original → patched | Throughput change |
| --- | ---: | ---: |
| search tool call - 16B chunks | 16 → 17 | +6.6% |
| search tool call - 256B chunks | 46 → 48 | +4.4% |
| search tool call - 64B chunks | 36 → 34 | -3.1% |
| structured response - 1400B chunks | 225 → 219 | -3.1% |
| structured response - 16384B chunks | 269 → 267 | -0.4% |
| structured response - 64B chunks | 64 → 63 | -1.1% |
| workspace edit tool call - 1400B chunks | 283 → 283 | -0.3% |
| workspace edit tool call - 16384B chunks | 344 → 344 | +0.3% |
| workspace edit tool call - 64B chunks | 64 → 63 | -2.2% |

---

## Landed: ordinary copy-on-write on streaming collection tails

*Recorded 2026-09-16.*

The shared-tail corruption from the review is fixed with ordinary copy-on-write, without writer
tokens or parser exemptions. Measured on x86_64 Linux; ARM unmeasured.

### Implementation

*Recorded 2026-09-16.*

`StreamArray.nextSlot()` makes the tail unique (checked before binding a strong reference) before
returning a writable slot; this covers every append path and `StreamDictionary` pending inserts.
Sealed blocks stay shared, and a shared tail copies only its initialized elements.

### Correctness

*Recorded 2026-09-16.*

769 tests passed with the two known Unicode failures; the corruption reproductions now pass, new
divergent-append and ownership tests were added, and a core-only Thread Sanitizer harness (64
workers × 16 rounds) reported no races.

### Assembly analysis

*Recorded 2026-09-16.*

On x86_64 Linux (ARM unverified), the roomy-tail path now calls `ensureUniqueTail` /
`swift_isUniquelyReferenced_native`; `openKnownSIMDDoubleElement` grew 1,035 → 1,151 bytes, and the
`Double` number appender grew as the table shows, with the check in its per-number loop.

| Property | Before | COW |
| --- | ---: | ---: |
| Function size | 742 bytes | 913 bytes |
| Stack allocation, excluding saved registers | 88 bytes | 120 bytes |
| Roomy-tail steady-state uniqueness check | None | Direct call to `swift_isUniquelyReferenced_native` |

### Benchmark method

*Recorded 2026-09-16.*

Baseline `e13ef7cd` against the COW tree over 52 rows. Typed Canada fell 12.8% and typed Mesh 10.5%
with unchanged allocation counts, retained 100-user states 11.8–14.2%, dictionary discard rows
5.7–9.4%; async and raw controls stayed within a few percent. A reverse-order confirmation (table)
reproduced the losses. The implementation was kept for review; inlining only the fast uniqueness
check or a scoped bulk-append API are the follow-ups named.

| Confirmation row | First sweep | Reverse-order repeat |
| --- | ---: | ---: |
| Dictionary 128 keys - discarding | -9.3% | -8.8% |
| Real Canada - bulk | -1.0% | -1.1% |
| Real Canada - bulk discarding | -12.8% | -12.7% |
| Real Mesh - bulk | +2.3% | +2.5% |
| Real Mesh - bulk discarding | -10.5% | -10.3% |
| Real Qwen 3 workspace edit tool call - bulk discarding | -5.6% | -2.4% |
| Retention 100 users - keep all | -14.2% | -14.5% |
| Retention 100 users - window 16 | -12.2% | -11.8% |
| Retention Mesh - window 16 | -5.0% | -5.5% |


#### Full paired sweep

*Recorded 2026-09-16.*

The full before/after sweep, by row group.

##### Real-world payloads

*Recorded 2026-09-16.*

| Benchmark | Before µs | COW µs | Throughput change | Mallocs before → COW |
| --- | ---: | ---: | ---: | ---: |
| Real CITM catalog - bulk | 1,133.57 | 1,101.82 | +2.9% | 17 → 17 |
| Real CITM catalog - bulk discarding | 2,648.06 | 2,723.84 | -2.8% | 2,291 → 2,291 |
| Real Canada - bulk | 4,247.55 | 4,292.61 | -1.0% | 17 → 17 |
| Real Canada - bulk discarding | 6,021.12 | 6,901.76 | -12.8% | 1,398 → 1,398 |
| Real GSoC 2018 - bulk | 1,197.06 | 1,177.60 | +1.7% | 17 → 17 |
| Real GSoC 2018 - bulk discarding | 3,497.98 | 3,510.27 | -0.4% | 8,650 → 8,650 |
| Real GitHub events - bulk | 46.94 | 45.53 | +3.1% | 17 → 17 |
| Real GitHub events - bulk discarding | 73.41 | 71.87 | +2.1% | 80 → 80 |
| Real LLM message - bulk | 471.30 | 458.50 | +2.8% | 17 → 17 |
| Real LLM message - bulk discarding | 721.41 | 727.55 | -0.8% | 592 → 592 |
| Real Mesh - bulk | 1,788.93 | 1,747.97 | +2.3% | 17 → 17 |
| Real Mesh - bulk discarding | 2,263.04 | 2,527.23 | -10.5% | 352 → 352 |
| Real Qwen 3 search tool call - bulk | 1.80 | 1.72 | +4.3% | 17 → 17 |
| Real Qwen 3 search tool call - bulk discarding | 5.45 | 5.36 | +1.6% | 23 → 23 |
| Real Qwen 3 structured response - bulk | 12.13 | 11.87 | +2.2% | 17 → 17 |
| Real Qwen 3 structured response - bulk discarding | 37.92 | 38.56 | -1.7% | 99 → 99 |
| Real Qwen 3 workspace edit tool call - bulk | 24.45 | 24.21 | +1.0% | 17 → 17 |
| Real Qwen 3 workspace edit tool call - bulk discarding | 61.79 | 65.44 | -5.6% | 122 → 122 |
| Real Twitter - bulk | 538.62 | 536.58 | +0.4% | 17 → 17 |
| Real Twitter - bulk discarding | 474.37 | 469.76 | +1.0% | 132 → 132 |
| Real Twitter escaped - bulk | 820.74 | 811.52 | +1.1% | 17 → 17 |
| Real Twitter escaped - bulk discarding | 602.11 | 592.38 | +1.6% | 125 → 125 |
| Real Twitter full - bulk discarding | 1,362.94 | 1,372.16 | -0.7% | 1,145 → 1,145 |

##### Retained collections and snapshot control

*Recorded 2026-09-16.*

| Benchmark | Before µs | COW µs | Throughput change | Mallocs before → COW |
| --- | ---: | ---: | ---: | ---: |
| Dictionary 128 keys - discarding | 56.35 | 62.11 | -9.3% | 33 → 33 |
| Dictionary 128 keys - keep all | 275.71 | 287.74 | -4.2% | 270 → 395 |
| Dictionary 128 keys - window 16 | 293.63 | 309.76 | -5.2% | 270 → 395 |
| Dictionary 32 keys - discarding | 15.98 | 17.25 | -7.3% | 29 → 29 |
| Dictionary 32 keys - keep all | 52.51 | 55.58 | -5.5% | 78 → 107 |
| Dictionary 32 keys - window 16 | 59.10 | 62.69 | -5.7% | 78 → 107 |
| Dictionary 512 keys - discarding | 225.15 | 248.45 | -9.4% | 39 → 39 |
| Dictionary 512 keys - keep all | 1,998.85 | 2,034.69 | -1.8% | 1,040 → 1,548 |
| Dictionary 512 keys - window 16 | 2,029.57 | 2,101.25 | -3.4% | 1,040 → 1,548 |
| Dictionary 8 keys - discarding | 5.33 | 5.66 | -5.7% | 24 → 24 |
| Dictionary 8 keys - keep all | 11.72 | 12.19 | -3.9% | 29 → 35 |
| Dictionary 8 keys - window 16 | 13.83 | 14.29 | -3.2% | 29 → 35 |
| Retention 100 users - keep all | 410.88 | 478.72 | -14.2% | 28 → 122 |
| Retention 100 users - window 16 | 502.27 | 571.90 | -12.2% | 28 → 122 |
| Retention 100 users - window 4 | 499.20 | 565.76 | -11.8% | 28 → 122 |
| Retention 100 users - window 64 | 498.18 | 569.34 | -12.5% | 28 → 122 |
| Retention 8KB document - keep all | 2,019.33 | 2,051.07 | -1.5% | 7,960 → 7,960 |
| Retention Mesh - window 16 | 153,000.00 | 161,000.00 | -5.0% | 603 → ≈70,000 |
| Retention Mesh capacity hint - window 16 | 170,000.00 | 181,000.00 | -6.1% | 4,130 → ≈77,000 |
| Stream Array of structs - snapshot per byte | 408.83 | 411.65 | -0.7% | 26 → 26 |

##### Async APIs

*Recorded 2026-09-16.*

| Benchmark | Before µs | COW µs | Throughput change | Mallocs before → COW |
| --- | ---: | ---: | ---: | ---: |
| API AsyncSequence Qwen 3 search tool call - 16B chunks | 33.98 | 34.49 | -1.5% | 29 → 29 |
| API AsyncSequence Qwen 3 search tool call - 256B chunks | 12.68 | 12.85 | -1.3% | 29 → 29 |
| API AsyncSequence Qwen 3 search tool call - 64B chunks | 16.96 | 16.59 | +2.2% | 29 → 29 |
| API AsyncSequence Qwen 3 structured response - 1400B chunks | 51.58 | 52.32 | -1.4% | 106 → 106 |
| API AsyncSequence Qwen 3 structured response - 16384B chunks | 44.00 | 44.00 | +0.0% | 105 → 105 |
| API AsyncSequence Qwen 3 structured response - 64B chunks | 180.48 | 176.38 | +2.3% | 105 → 105 |
| API AsyncSequence Qwen 3 workspace edit tool call - 1400B chunks | 83.78 | 84.42 | -0.8% | 128 → 128 |
| API AsyncSequence Qwen 3 workspace edit tool call - 16384B chunks | 68.42 | 69.50 | -1.6% | 128 → 128 |
| API AsyncSequence Qwen 3 workspace edit tool call - 64B chunks | 363.26 | 368.13 | -1.3% | 128 → 128 |

---

## Landed: synchronous iteration, scoped views and selective observation

*Recorded 2026-09-16.*

Adds a synchronous partials iterator, scoped views, and selective field observation. Swift 6.3.3 on
x86_64 Linux, single sweeps; ARM is untested.

### Synchronous iterator and scoped views

*Recorded 2026-09-16.*

776 tests passed, seven new. The first table is bulk controls; the second compares the iterator
(whole snapshots) against scoped views on the Qwen payloads. No scanner, sink or storage code changed.

| Payload | Baseline MB/s | New APIs MB/s | Throughput change |
|---|---:|---:|---:|
| CITM catalog | 636 | 624 | -1.9% |
| Canada | 326 | 359 | +10.0% |
| GSoC 2018 | 947 | 952 | +0.5% |
| GitHub events | 905 | 910 | +0.6% |
| LLM message | 1491 | 1522 | +2.1% |
| Mesh | 286 | 300 | +4.8% |
| Twitter full | 454 | 464 | +2.1% |

| Payload/chunk | Iterator MB/s | Scoped view MB/s |
|---|---:|---:|
| Qwen 3 search tool call - 16B chunks | 25 | 38 |
| Qwen 3 search tool call - 256B chunks | 67 | 82 |
| Qwen 3 search tool call - 64B chunks | 50 | 65 |
| Qwen 3 structured response - 1400B chunks | 250 | 266 |
| Qwen 3 structured response - 16384B chunks | 290 | 295 |
| Qwen 3 structured response - 64B chunks | 84 | 122 |
| Qwen 3 workspace edit tool call - 1400B chunks | 304 | 317 |
| Qwen 3 workspace edit tool call - 16384B chunks | 355 | 360 |
| Qwen 3 workspace edit tool call - 64B chunks | 84 | 132 |

### Selective observation

*Recorded 2026-09-16.*

788 tests passed, twelve new. The first projection/filtering build was slower than plain snapshots
from generic adapter overhead; the adapters now expose their bodies for specialization.

### Field parsing states and final validation

*Recorded 2026-09-16.*

810 tests passed. Opt-in observers run through a forwarding `FieldObservationSink` with a
constant-size tracker; the existing scanner, `PartialSink` and layouts are untouched. The tables
show bulk controls and the sync/async API rows: projection beats whole snapshots synchronously, rich
field tracking costs appreciably more, and async adapters stay slower than plain async snapshots.

| Bulk payload | Pre-API MB/s | Observation build MB/s | Throughput change |
|---|---:|---:|---:|
| CITM catalog | 636 | 639 | +0.3% |
| Canada | 326 | 334 | +2.2% |
| GSoC 2018 | 947 | 943 | -0.4% |
| GitHub events | 905 | 903 | -0.3% |
| LLM message | 1491 | 1459 | -2.2% |
| Mesh | 286 | 299 | +4.6% |
| Twitter full | 454 | 466 | +2.6% |

| Synchronous payload/chunk | Whole snapshots | Scoped views | Project + filter | Field state + filter |
|---|---:|---:|---:|---:|
| Qwen 3 search tool call - 16B chunks | 25 | 38 | 33 | 14 |
| Qwen 3 search tool call - 256B chunks | 71 | 83 | 75 | 53 |
| Qwen 3 search tool call - 64B chunks | 52 | 66 | 63 | 35 |
| Qwen 3 structured response - 1400B chunks | 250 | 269 | 262 | 217 |
| Qwen 3 structured response - 16384B chunks | 293 | 300 | 296 | 273 |
| Qwen 3 structured response - 64B chunks | 83 | 122 | 109 | 52 |
| Qwen 3 workspace edit tool call - 1400B chunks | 309 | 336 | 331 | 267 |
| Qwen 3 workspace edit tool call - 16384B chunks | 346 | 368 | 365 | 337 |
| Qwen 3 workspace edit tool call - 64B chunks | 84 | 133 | 125 | 57 |

| Async payload/chunk | Whole snapshots | Project + filter | Field state + filter |
|---|---:|---:|---:|
| Qwen 3 search tool call - 16B chunks | 16 | 12 | 9 |
| Qwen 3 search tool call - 256B chunks | 47 | 36 | 33 |
| Qwen 3 search tool call - 64B chunks | 33 | 27 | 23 |
| Qwen 3 structured response - 1400B chunks | 225 | 202 | 192 |
| Qwen 3 structured response - 16384B chunks | 265 | 248 | 246 |
| Qwen 3 structured response - 64B chunks | 61 | 50 | 37 |
| Qwen 3 workspace edit tool call - 1400B chunks | 287 | 258 | 241 |
| Qwen 3 workspace edit tool call - 16384B chunks | 344 | 328 | 313 |
| Qwen 3 workspace edit tool call - 64B chunks | 61 | 51 | 43 |

#### Final setup-guard confirmation

*Recorded 2026-09-16.*

After requiring complete field reflection, all 22 observer tests passed; field observation at 64-byte
chunks stayed costly (sync 35/52/57, async 23/39/41 MB/s) and bulk controls stayed near baseline.

| Bulk payload | Final confirmation MB/s |
|---|---:|
| CITM catalog | 639 |
| Canada | 334 |
| GSoC 2018 | 963 |
| GitHub events | 918 |
| LLM message | 1487 |
| Mesh | 299 |
| Twitter full | 465 |


### Review revision: shared boxing and generated field selection

*Recorded 2026-09-16.*

The observer now shares `AsyncPartialsSequence.Box<State>`, and the reflection SPI is replaced by a
macro-generated `streamObservationFields`. 811 tests passed. Measured against `e169dfd5` on x86_64
Linux (ARM unmeasured): async observer allocations fell by one per workload, sync observation was
2.7–4.7% slower, bulk controls −3.5..+2.3%, read as small mixed differences.

| Benchmark | Before MB/s | After MB/s | Throughput change |
| --- | ---: | ---: | ---: |
| API AsyncObservedField Qwen 3 search tool call - 64B chunks | 22 | 23 | +2.1% |
| API AsyncObservedField Qwen 3 structured response - 64B chunks | 41 | 39 | -2.8% |
| API AsyncObservedField Qwen 3 workspace edit tool call - 64B chunks | 41 | 43 | +3.6% |
| API AsyncSequence Qwen 3 search tool call - 64B chunks | 35 | 34 | -1.7% |
| API AsyncSequence Qwen 3 structured response - 64B chunks | 63 | 64 | +0.9% |
| API AsyncSequence Qwen 3 workspace edit tool call - 64B chunks | 63 | 64 | +1.3% |
| API ObservedField Qwen 3 search tool call - 64B chunks | 35 | 34 | -3.3% |
| API ObservedField Qwen 3 structured response - 64B chunks | 52 | 51 | -2.7% |
| API ObservedField Qwen 3 workspace edit tool call - 64B chunks | 58 | 55 | -4.7% |
| Real CITM catalog - bulk discarding | 636 | 616 | -3.1% |
| Real Canada - bulk discarding | 333 | 341 | +2.3% |
| Real GSoC 2018 - bulk discarding | 954 | 955 | +0.2% |
| Real GitHub events - bulk discarding | 900 | 902 | +0.4% |
| Real LLM message - bulk discarding | 1484 | 1500 | +1.1% |
| Real Mesh - bulk discarding | 299 | 289 | -3.5% |
| Real Twitter full - bulk discarding | 465 | 460 | -1.0% |

---

## Landed: completed-value conversions

*Recorded 2026-09-17.*

Adds `StreamCompletedValueConversion`, `ConvertedPartial` and
`@StreamParseableMember(completedConversion:)`; converted containers use their source schema with
completion records outside the parser frames. No scanning kernel changed.

### Tests

*Recorded 2026-09-17.*

834 tests passed with the two known Unicode issues, covering completion timing, split strings,
nested and duplicate conversions, optionals, error types, truncation and macro diagnostics.

### Assembly and implementation adjustment

*Recorded 2026-09-17.*

The first version grew frame push/pop from 88/65 to 857/393 bytes with schema retain/release on
every container, costing typed Canada ~15% and CITM ~9%. Checking conversion metadata in a borrowed
scope and outlining the conversion path brought push/pop to 121/85 bytes with no retain/release on
the ordinary path.

### Benchmark method

*Recorded 2026-09-17.*

Saved pre-change, initial and adjusted executables, Swift 6.3.3 on x86_64 Linux (ARM unmeasured),
median of three-second runs, plus paired Qwen rows with and without a `StreamString` → `String`
conversion.

### Final control results

*Recorded 2026-09-17.*

| Benchmark | Before MB/s | Final MB/s | Throughput change |
| --- | ---: | ---: | ---: |
| API AsyncObservedField Qwen 3 search tool call - 64B chunks | 23 | 22 | -4.5% |
| API AsyncObservedField Qwen 3 structured response - 64B chunks | 40 | 39 | -3.7% |
| API AsyncObservedField Qwen 3 workspace edit tool call - 64B chunks | 39 | 40 | +2.8% |
| API AsyncSequence Qwen 3 search tool call - 64B chunks | 35 | 35 | -1.7% |
| API AsyncSequence Qwen 3 structured response - 64B chunks | 64 | 62 | -2.9% |
| API AsyncSequence Qwen 3 workspace edit tool call - 64B chunks | 63 | 64 | +1.6% |
| API ObservedField Qwen 3 search tool call - 64B chunks | 35 | 34 | -1.8% |
| API ObservedField Qwen 3 structured response - 64B chunks | 52 | 51 | -0.9% |
| API ObservedField Qwen 3 workspace edit tool call - 64B chunks | 56 | 55 | -1.9% |
| Real CITM catalog - bulk | 1572 | 1543 | -1.8% |
| Real CITM catalog - bulk discarding | 619 | 620 | +0.1% |
| Real Canada - bulk | 544 | 523 | -3.9% |
| Real Canada - bulk discarding | 343 | 328 | -4.4% |
| Real GSoC 2018 - bulk | 2845 | 2853 | +0.2% |
| Real GSoC 2018 - bulk discarding | 963 | 960 | -0.3% |
| Real GitHub events - bulk | 1501 | 1476 | -1.5% |
| Real GitHub events - bulk discarding | 897 | 891 | -0.7% |
| Real LLM message - bulk | 2319 | 2337 | +0.7% |
| Real LLM message - bulk discarding | 1465 | 1602 | +9.3% |
| Real Mesh - bulk | 418 | 410 | -2.1% |
| Real Mesh - bulk discarding | 289 | 294 | +1.7% |
| Real Twitter - bulk | 1223 | 1213 | -0.9% |
| Real Twitter - bulk discarding | 1332 | 1341 | +0.7% |
| Real Twitter full - bulk discarding | 459 | 457 | -0.3% |

Typed CITM recovered to baseline and Twitter full −0.3%; typed Canada was −4.4% alongside −3.9% raw.
The initial container regression was mostly recovered.

### Opt-in conversion cost

*Recorded 2026-09-17.*

| Qwen workload, 64-byte chunks | Source only MB/s | Completed conversion MB/s | Throughput change |
| --- | ---: | ---: | ---: |
| Qwen 3 search tool call | 76 | 53 | -29.1% |
| Qwen 3 structured response | 128 | 120 | -5.9% |
| Qwen 3 workspace edit tool call | 124 | 119 | -4.2% |

The converted rows do extra work (conversion, retained result, larger snapshot); the small search
payload pays the most (~3.3 µs). Conversions are not promised to be zero-cost.

### Typed conversion errors and Embedded Swift

*Recorded 2026-09-17.*

`ConversionError` is now inferred from the strategy's typed `throws` (`Never` when nonthrowing), and
the conversion API is available under Embedded Swift, checked by the wasm smoke. Measured on x86_64
Linux (ARM unmeasured); typed rows below. A focused repeat put GSoC back near baseline, kept Canada
+7.6%, and left raw GitHub −5.3% unresolved with no raw parser logic changed.

| Typed payload | Before MB/s | Typed errors MB/s | Throughput change |
|---|---:|---:|---:|
| CITM catalog | 620 | 631 | +1.6% |
| Canada | 328 | 353 | +7.5% |
| GSoC 2018 | 958 | 902 | -5.9% |
| GitHub events | 885 | 896 | +1.2% |
| LLM message | 1590 | 1565 | -1.6% |
| Mesh | 294 | 291 | -1.1% |
| Twitter | 1348 | 1349 | +0.1% |
| Twitter full | 457 | 461 | +0.8% |

## Landed: a chunk-cut number hands the rest of its array back to `fuseNumberRun`

*Recorded 2026-11-09.*

`Real Mesh - 16KB chunks` ran 15% behind `Real Mesh - bulk`, raw and typed, and no other corpus
showed a chunking gap. A number the chunk cuts resumes in `.number`, and `consumeNumber` finished
it with `fuseAfterValue`, which sends the next number back to `.number` through the dispatcher —
one dispatch and one 16-byte whitespace scan per number, for the rest of the array. Mesh's arrays
hold 10–33K numbers, so every chunk boundary lands inside one and the whole remainder of the chunk
ran that way. `consumeNumber` now calls `fuseNumberRun` at an array's comma when two more bytes
are in the chunk, as the structural run's number arm does. Byte-fed input never has the two bytes
and takes `fuseAfterValue` as before.

Aligned builds, 3 interleaved rounds, median p0 (machine under build load, floor about ±2%):

| Row | Change |
| --- | ---: |
| Real Mesh - 16KB chunks | +16.3% |
| Real Mesh - 16KB chunks discarding | +16.3% |
| Real Mesh - bulk | -0.1% |
| Real Mesh - bulk discarding | -1.4% |
| Real Canada - 16KB chunks / discarding | -0.2% / -0.2% |
| Real Twitter - 16KB chunks / discarding | -0.3% / -0.1% |
| Real CITM catalog - 16KB chunks / discarding | -0.3% / -1.2% |
| Real Twitter escaped - byte by byte / discarding | -0.2% / -0.9% |
| Real LLM message - byte by byte / discarding | -1.6% / -0.0% |
| Fast Literals / Pretty printed users - byte by byte | +2.2% / +2.3% |
| Fast Escaped string / Long string - byte by byte | -1.5% / +0.0% |
