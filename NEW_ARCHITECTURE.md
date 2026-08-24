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
- **One form per token.** A key is always whole; a string always arrives as
  `stringBegin`/`stringChunk`/`stringEnd`. The collapsed forms both protocols once declared are
  gone — `key(_:)`'s chunked trio because no parser could keep the promise, and `string(_:)`
  because in two rounds of parser work nothing ever called it (see the dead-code pass at the end).
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

### Whitespace: one compare in front of the run scan

Whitespace was the last class still scanned a byte at a time, at four compares each, and it runs
before *every* structural byte. How much there is to find is a property of the document, not of
JSON. Counting runs outside strings:

| document | whitespace | runs | 1 byte | ≥ 16 bytes |
| --- | ---: | ---: | ---: | ---: |
| canada | 0% | 0 | – | – |
| llm_message | 17% | 0 | – | – |
| github_events | 19% | 2526 | 45% | 0% |
| gsoc-2018 | 19% | 41713 | 45% | 0% |
| twitter | 26% | 28826 | 46% | 2% |
| citm_catalog | 71% | 76337 | 34% | 59% |

`llm_message` is the instructive one: 17% whitespace, none of it where this scan can see it. It is
all inside string values, so the scan's job there is to leave, 100% of the time.

So the shipped form is **one compare, then out of line**: every whitespace byte is ≤ 0x20 and
every byte that may legally follow one is > 0x20, which settles the empty case without touching a
vector, and only what survives is scanned SIMD16 like every other class.

**What the inlined body costs is the whole design constraint here, and it is not the scan.** This
is `@inline(__always)` into the parse loop, so anything spelled in it is paid in that loop's
register pressure by every document — including ones the code never runs on. Three variants, p50
MB/s change against the pristine control:

| variant | citm | twitter | twitterescaped | unicode escapes |
| --- | ---: | ---: | ---: | ---: |
| vector body inlined | +22% | +7% | −18% | −35% |
| one byte run peeled inline | +20% | +8% | −18% | −34% |
| **shipped: one compare, then out of line** | **+21%** | **+7%** | **−1%** | **−2%** |

`twitterescaped` is 0.5% whitespace and `unicode escapes` has none. Both lose 18–35% to code that
never executes on them, and both recover the moment it moves out of line. The peel was an attempt
to buy back the one byte run — 45% of runs everywhere — and it re-triggered the cliff for a 1–3%
gain on `github_events`, so it was dropped. The single compare and the vector body are the two
things worth inlining and out-lining respectively; there is no third thing to add.

The width test guarding the vector call is not a tail guard. Fed one byte at a time `to - from`
is 1 at every call, and routing that through the vector body splats four constants to scan one
byte, which cost `twitter` byte by byte 20%.

A scalar loop behind the same early-out was also measured and lost 2–5% *everywhere*, including
rows it cannot touch — the early-out only pays when the run scan behind it is the vector one.

### The parse loop is a dispatcher, and a structural byte costs a call

Read the release binary before designing anything here. For `FastCountingSink`, `parse` is **1284
bytes, 322 instructions, 18 calls and no SIMD at all**: it is a thin dispatcher, and every token
class — `consumeStructural` (1044 B), `consumeStringRun` (1204 B), `consumeNumber` (928 B),
`consumeUnicodeDigit` (356 B) — is a separate function it calls out to. Only `streamWhitespaceEnd`
(68 B) is small enough to be inlined into it.

So **a structural byte's cost is a call, a return and a re-entry into the dispatch switch**, not
the byte's own work. That reframes the whole loop: structural bytes are 20–25% of token dense
JSON and they arrive in runs — `},{"`, `":`, `,"`, `[[` — and each byte of a run was paying that
round trip. `consumeStructuralRun` keeps the loop while the state stays structural, so a run costs
one call. `State`'s cases are ordered with the seven structural ones first so the loop's exit test
is one unsigned compare.

**The `@inline` attributes on it are load bearing, not tuning.** Left to choose, the optimizer did
the exact inverse of the design on both axes:

| | HEAD | unforced | forced |
| --- | ---: | ---: | ---: |
| `parse` | 1284 | 1424 | **1252** |
| `consumeStructural` | 1044 | 1064 | **0** |
| `consumeStructuralRun` | – | 0 | **1240** |

It inlined the *run loop* into `parse`, growing the dispatcher, and still called
`consumeStructural` once per byte — the call the run exists to delete. `@inline(never)` on the run
and `@inline(__always)` on `consumeStructural` produce the intended shape: the run is one
self-contained function, and `parse` ends up smaller than it started. Benchmarking the unforced
build would have shown the idea failing on its own merits when it had simply not been built.

Measured with a control either side of the candidate (controls agreed within 1–8%, all drift in
one direction, so each row is quoted as the range against both):

| document | before | after | Δ |
| --- | ---: | ---: | ---: |
| citm_catalog | 1211 | 1425 | +16 to +20% |
| canada | 679 | 776 | +14 to +15% |
| twitter | 808 | 911 | +10 to +16% |
| github_events | 962 | 1073 | +11 to +13% |
| gsoc-2018 | 2134 | 2187 | +2 to +4% |
| twitterescaped | 473 | 501 | +3 to +10% |
| llm_message | 1640 | 1646 | ±1% |

**Corpus aggregate 1071 → 1181 MB/s, +10.2%.** `canada` is the result worth noting: 0% whitespace
and almost nothing but `[`, `,` and numbers, so it is nearly pure structural runs and gains 15%
from a change that touches no scanning at all. `llm_message` is flat because it is one long string
value — it has almost no structural runs to coalesce.

The cost lands where the run cannot form: fed one byte at a time a run is always length one, so
the loop is pure overhead, and `Fast Pretty printed users` and `Fast Unicode escaped string` lose
7–8% byte by byte. The real corpus byte-fed rows gain anyway (`llm_message` +8%, `twitterescaped`
+4%), so this was kept.

### The run loop subsumes the transition it would have been fused with

The colon after a key looked like the best fusion available: it follows the key's closing quote
with no whitespace between them in every document measured — 61,145 keys across the corpus, no
exceptions, because no printer emits `"key" :` — so peeking one byte from `consumeStringRun` hits
100% of the time and skips a dispatcher round trip. It was built, and the corpus aggregate moved
from 1187 to 1188 MB/s. Nothing.

Trace the calls and it is not close, it is exactly zero. Parsing `"a":"b"` after the run loop
exists:

- `consumeStringRun` reads the key, sees the quote, leaves in `.afterKey`
- `consumeStructuralRun` reads `:` → `.value`, *stays in its loop* because that is structural,
  reads `"` → `.inString`, leaves
- `consumeStringRun` reads the value

Fusing the colon moves it into the first call — and the second call still has to happen, for the
quote. **One compare added, no call removed.** The run loop had already coalesced the colon with
the byte after it, which is the thing that made the round trip disappear in the first place.

The distinction that matters for anything similar: **a fusion only pays if it consumes everything
structural before the next non-structural token**, because otherwise the run loop still runs. The
colon fails that test — a value's opening quote always follows it.

Byte fed feeding is where the peek is pure loss — the chunk ends at the quote, so `i < to` fails
and the compare never hits — and every byte fed row lost 3–6%.

### Fusing the comma, which does pass that test

The `,` after a value passes where the colon failed: consuming the comma, the whitespace after it
and the next value's first byte leaves nothing structural behind, so the whole
`consumeStructuralRun` call for that member disappears. `fuseAfterValue` runs at the two sites a
value can close, `consumeStringRun` and `consumeNumber`.

**Covering only objects is worse than covering neither.** The first version fused `,` + `"` for
object members only, and `canada` — 111,129 commas, every one inside an array of numbers — paid
the test on each and got nothing back:

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

Adding the array arm costs the object dense documents 1–7% — the helper is inlined at two sites,
so it is bigger code in both — and buys 12% on `canada`. The aggregate prefers it because `canada`
is 2.25 MB of the 9.6 MB corpus, and because arrays of numbers are a real shape: coordinates,
embeddings, time series. `llm_message` is the one that goes the other way, and it is one long
string value with almost no commas either way.

`parse` stays 1252 bytes through all of it. The growth lands in `consumeStringRun` (996 → 1372)
and `consumeNumber` (912 → 1272), which is the point of putting the fusion there: those are
already out of line, so the duplication that sank the whitespace-in-dispatch attempt is harmless
here. **Where code is added matters more than how much.**

The cost is byte fed feeding, 2–6% across the board, for the same reason the colon peek lost
there: a one byte chunk can never contain the bytes being fused, so the test is pure overhead.
Streaming at realistic chunk sizes gains fully — the 16 KB rows track the bulk rows throughout.

### Escapes decoded in the string run

An escape was the most dispatcher-expensive thing in the format: `\\n` cost two iterations,
`\\uXXXX` five, and a surrogate pair eleven, all to produce at most four bytes of content. When the
whole escape is in the chunk, `consumeStringRun` decodes it and keeps scanning.
`streamHexQuad` takes the four hex digits as one `SIMD4<UInt8>`: fold case with the 0x20 bit that
digits already carry, test the digit and letter ranges together, select nibbles from whichever
matched, and weight them by place value in one multiply.

| document | before | after | Δ |
| --- | ---: | ---: | ---: |
| twitterescaped | 513 | 724 | **+41.1%** |
| twitterescaped, unchecked | 547 | 805 | **+47.2%** |
| unicode escapes (synthetic) | 410 | 1019 | **+148.5%** |
| gsoc-2018 | 2413 | 2521 | +4.5% |
| llm_message | 1712 | 1735 | +1.3% |
| citm_catalog / twitter / canada / github_events | — | — | ±0.4% |

**Corpus aggregate 1259 → 1324 MB/s, +5.1%.**

**Only the simple escapes are inlined, and that split is the whole result.** With the `\\u` decode
spelled inline next to them, `Fast Escaped string` — `a\\nb\\t` repeated, not one `\\u` in it — lost
**18.5%**, and every string heavy document 1–5%, while the escape dense documents gained either
way. Moving `fusedUnicodeEscapeEnd` out of line turned that −18.5% into +2.6% and *increased* the
wins it was supposed to cost (+41.1% against +39.0% on `twitterescaped`). A `\\u` escape is five
bytes of work saving five dispatcher iterations, so it can afford a call; `\\n` is one byte and
cannot.

This is the third time the same rule decided a design, at a third level of the call tree — the
parse loop for whitespace, `consumeStringRun` for the fusions, and now inside the fusion itself.
`parse` is 1252 bytes throughout; `consumeStringRun` went 1372 → 1780 and holds only the escapes
that are cheap enough to belong there.

**Only escapes with no diagnostics attached are fused.** A bad hex digit, a lone surrogate, an
unrecognised escape character, a pending high surrogate, or an escape running past the chunk all
return nil and fall back to the per byte states, which commit nothing first. That is what keeps
error offsets and resumption identical: the fused path never reports anything, so it cannot report
it in the wrong place. `JSONChunkBoundaryTests` pins `\\u0041`, `\\u00e9`, `\\u20ac`, `\\u0000` and
surrogate pairs at every split, including the boundaries *inside* a pair, which is where the
twelve byte fusion hands back to the state machine mid-escape.

### Discovering whitespace instead of scanning for it

Most JSON on a wire is minified, so the lookahead scan's one compare per structural byte buys
nothing on `canada` or `llm_message`. The obvious fix is to stop looking ahead: every state's byte
switch already has an arm for bytes it does not recognise — it is where `unexpectedToken` is
thrown from — and a whitespace byte is exactly such a byte. Let it fall in there, consume the run
whole, and a minified document pays *literally zero*, not even a compare. No flag, no prediction,
no warmup, self-adapting by construction.

It was built and it is 10–18% slower nearly everywhere:

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

**`canada` is the whole argument.** It has zero whitespace, so "pays literally zero" was
arithmetically true for it — and it still lost 2%. The saving was real and irrelevant, because the
reasoning was about the wrong resource.

There is one whitespace test in the lookahead design and there are *five* in this one: `.value`,
`.afterValue`, `.key`, `.afterKey` and `.done` each reject unrecognised bytes separately, so each
needs its own copy. `consumeStructural` is `@inlinable` and inlines into the parse loop, so the
change removed one compare from the loop body and added five, plus a three-case enum return.
The loop got bigger, and by now the pattern is unmistakable: `twitterescaped` −17% and unicode
escapes −32% are the same two documents, with the same two numbers, that rejected the inlined
vector body and the inlined one-byte peel above. Whitespace is ~0% of both. They are not measuring
whitespace handling at all, they are measuring how much code is in the loop.

**One compare in one place beats zero compares in five places.** The parse loop is register bound,
not work bound, and any restructuring that pays for a saving with duplicated code in that loop
will lose no matter how sound the saving looks in isolation. `llm_message` gaining 2% is the only
thing that went as predicted, and it is the one document whose whitespace is entirely inside
string values, so the loop never grew for it in the first place.

Kept from the attempt: `JSONConformanceTests` now pins whitespace in every legal position for each
of the four whitespace bytes, that the control bytes below 0x20 which are *not* whitespace are
still rejected in each of those positions, and that a whitespace-only document is rejected.
Trailing whitespace is the one worth keeping a test on — it is the only thing `.done` ever
legally sees, and a design that stops scanning ahead has to teach that arm the difference.

### Literals are already fast enough to be unmeasurable

`consumeLiteral` walking a `static let [[UInt8]]` looks like an obvious win to replace with one
masked word compare: `true` and `null` are a `UInt32`, `false` a `UInt32` and a byte. It was
built, and it is a wash.

Literals are 3.4% of `twitter`'s bytes, 0.55% of `github_events`', 0.29% of `citm_catalog`'s and
0.01% of `gsoc-2018`'s, so no real document can resolve the change at all. Against a purpose
built 62% literal payload (`Payloads.literals`, kept as `Fast Literals`, which is the only
benchmark in the suite that exercises this path):

| variant | bulk | byte by byte |
| --- | ---: | ---: |
| **shipped: byte loop over the nested array** | **345** | **147** |
| masked word compare | 346 | 138 |

Even where literals are most of the document the word compare is +0.3% bulk and −6% byte fed,
where the whole-token path can never fire and is pure added branch. The array is a compile time
constant and the optimizer was already folding the indirection the rewrite existed to remove.
Reverted, and recorded here so it is not rebuilt.

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

**The leading word is only a dispatch key, not an equality check.** Every case also checks the
decoded UTF-8 length: without that, a short key followed by a decoded NUL collides with zero
padding. Keys longer than eight bytes compare each remaining padded word as well, so equal-length
keys sharing their first eight bytes cannot alias. Both were real bugs found by boundary tests.

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
  value before the value arrives. A mismatched container now throws `.typeMismatch`, but it can
  still leave that initial slot in the partial value observed when the error is caught.
- ~~A container at a destination that cannot hold it is discarded silently.~~ Known destinations
  now throw `.typeMismatch`, matching scalar behavior. Unknown object keys remain discardable:
  `pendingField == -1` distinguishes them from known fields whose schemas reject the container.
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
  contend where the value typed schema did not. `ConcurrentParsingTests` now pins correctness
  under concurrent parses of one type — many tasks, chunked and bulk, each result compared against
  a serial parse of the same payload — but nothing measures the contention, which is the part that
  would show up as a throughput cliff rather than as a wrong answer.
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
  measurements here are what it would buy. (Since answered and landed; see "StreamString: bytes
  accumulate, `String` is a read" below.)

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
is what a document id is.

`NumberParseBenchmarks.swift` kept all six variants registered and cross-checked them against
each other before timing anything. It has since been deleted, because keeping it was a mistake of
exactly the kind this document is supposed to catch: the six strategies were private
re-implementations, so when the eight-digit block moved from SWAR to SIMD (below), production
changed and the file's "shipped" row did not. It measured a fork of the parser, and no benchmark
could have caught that. The numbers above stand as the record of the decision; the number path is
now measured through the real parser, on payloads of the same token shapes, by the `Numbers` rows
in `ParserShapeBenchmarks.swift`.

### Digit block width

The block above began as a 64-bit SWAR conversion. The measurement isolated just the
digit-run-to-integer step and walked the width, because a block tier only fires on runs at least
as long as itself. ns per digit run, p50, relative to SWAR8:

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

The benchmark that produced this table is not in the tree, and cannot be: `streamParseEightDigits`
and the scanners around it are `package`, and the benchmark suite is a separate SwiftPM package,
so it cannot see them. That is why the deleted number strategy file forked them in the first
place. The block is covered by `StreamScannerTests` for correctness and by the `Numbers` payload
rows for its effect end to end, but the width comparison above cannot currently be re-run. Making
the scanners `public` under an underscored name — as `StreamDictionary._openValue` already is —
would fix that, at the cost of a wider public surface.

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

---

## The benchmark suite: production only, and the shapes nobody measured

The suite had grown to 305 benchmarks, and 182 of them — 60% — were seven key table strategies
swept over two key shapes and four counts. Six of the seven were prototypes whose decision had
shipped; the seventh was the real `StreamDictionary`, measured through its `String` subscript
rather than through `_openValue(forKey:)`, which is the route the parser takes. So the largest
group in the suite was archaeology, and the part of it that was not measured the wrong entry
point.

The rule now: **a benchmark measures shipped code.** A strategy comparison earns its table in
this document and is then deleted. Keeping the losers looks like diligence and is the opposite —
`NumberParseBenchmarks.swift` is the proof, above. The one exception is a decision that has been
made and *not applied*: `StringAppendBenchmarks` still registers `unsafe init` and `byte buffer`
against production's `streamAppend`, because that replacement has not landed.

Removed: six prototype key tables (`Keys` goes from 182 rows to 31), six forked number strategies
(30), the materialising dictionary sink, and three Stream rows that were duplicates — `Scaling 100
users` in both variants was the same call on the same payload as `Stream Array of structs`, and
`snapshot read per byte` differed from `snapshot per byte` only in what the blackHole took.

One row was dropped for being wrong rather than redundant. The span route's "miss" benchmark
probed absent keys through `_openValue`, which has no non-inserting form — so it was measuring an
insert, which `build` already measures, and paying a full dictionary copy per iteration to do it.
That copy is also what intermittently tripped the harness's retain accounting.

### What had no coverage at all

Five axes, all of them shipped surface:

| axis | why it was a hole |
| --- | --- |
| `bufferCapacity` | defaults to 4096, never swept; the supplied-buffer initializer appeared once, hardcoded |
| depth | capped at 64 by the container bitmask; nothing else in the suite nested past three |
| chunk boundaries | every chunked row fed powers of two, which land inside a token only by accident |
| schema width | key matching scans member words; no model declared more than six members |

### Buffer capacity, depth, schema width

Capacity is flat: 64, 256, 4096 and 65536 B all parse the array of structs at 16–17 µs, so the
default costs nothing and shrinking it buys nothing. What the setting decides is whether a
document parses at all — see `BufferCapacityTests`. The parser's own malloc is real but small:
417 ns and one malloc allocating, against 333 ns and zero supplied, on the flat struct.

Depth costs about 27 ns per level (objects, 16 levels 625 ns against 63 levels 1875 ns), and an
array level is less than half an object level — 750 ns for 63 array levels — which is the key
that is not there.

Schema width was the surprise: hitting the first of 48 members and hitting the last measure the
same, 83 µs both, with an undeclared key at 78 µs. **Key matching is not linear in member count.**
The generated matcher switches on the leading word rather than scanning, so the "scan over
precomputed words" framing used elsewhere in this document describes the fallback, not the cost.

### Real datasets

`twitter.json` was the only non-synthetic payload, and it is the easy member of its corpus. The
rest of `yyjson_benchmark`'s set is in `Resources/` now — `canada` (float geometry), `citm_catalog`
(deep, repeated keys), `gsoc-2018` (large, long strings), `twitterescaped`, `github_events` —
plus a generated `llm_message.json`: an assistant message of escaped markdown, fenced code and
tool-use objects, which is the shape the convenience layer exists for and the only large payload
in the suite that is also escape-dense. Three of these are bigger than any cache the parse runs
in, which nothing else here was.

Bulk, MB/s p50: GSoC 1888, LLM message 1370, CITM 964, GitHub events 889, Twitter 705, Canada 671,
Twitter escaped 438. **Canada and Twitter escaped are the floor, and both for the same reason** —
per-byte work the SIMD run scanner cannot skip, coordinates in one case and six-byte `\u` escapes
in the other.

Real chunk sizes are covered where they were not before: 16 KB is a TLS record, and the LLM rows
sweep 1400 (an MTU), 16 KB and 64 KB. The convenience layer is flat across all three — view read
290/308/310 MB/s — which extends the earlier finding that feed granularity, not observation
frequency, is what moves the view path.

NDJSON is deliberately absent: the parser rejects a second top-level document with
`trailingContent`, so there is nothing to measure until that is a supported mode.

### Tests, where speed is not the question

Concurrency and malformed input were on the list of missing benchmarks and are tests instead,
because what matters about them is whether they are correct. `ConcurrentParsingTests` puts many
tasks on one type's shared schema and compares every result against a serial parse of the same
payload. Depth and buffer capacity are both: `DepthLimitTests` pins the cap from both sides, in
both container kinds, and under alternating nesting that puts a different bit at every level;
`BufferCapacityTests` pins which tokens the capacity actually bounds.

That last suite corrected a wrong assumption on the way in. Capacity does not bound a *string* of
any kind, escaped or not — strings are emitted as chunks, so they drain the buffer as they fill
it, and a 16 KB escaped body decodes intact at a 64 B capacity. Only keys and numbers have to
arrive whole. The suite pins both halves, since "capacity is the longest token in the document" is
the natural reading and it is wrong in the direction that matters.

The suite is 201 benchmarks now, against 305 — a third the size, covering five axes it did not
touch before and one dataset family it had only the friendliest member of.

---

## Review round: state that outlived its token, an offset a fusion moved, and a schema per `[`

A read through the whole of `Fast/` looking for correctness, with the performance cost of each fix
measured rather than argued. Four findings, all confirmed against the built library before
anything was changed, and all four fixed here. The measurements below are one session's; a
pristine control was run in the same session wherever a number was close, since the machine drifts
about 25% between sessions.

### A sink rejection reported the wrong byte, and got one more token after it

`parse` reads the sink's failure once per token with the cursor as the offset. `fuseAfterValue`
runs *before* that read and moves the cursor past the comma and onto the next token, so:

| document | sink rejects | reported | should be |
|:---------|:-------------|---------:|----------:|
| `[1,2]`  | `number`     |        3 |         2 |
| `["a","b"]` | `stringEnd` |       6 |         4 |

Byte 3 is the `2` — a different value from the one that was refused. The string case also
delivered `stringBegin` for `"b"` to a sink that had already failed. Nothing pinned this:
`ErrorOffsetTests` had no sink rejection case at all, and `PartialSinkFailureTests` checked the
reason without the offset.

The fusion now bails when the sink has already failed, which leaves the cursor at the token end —
the same offset the unfused path reports. That is the point: where a rejection surfaces no longer
depends on whether the bytes after it happened to be fusable, which is the same guarantee the rest
of `ErrorOffsetTests` exists for. Both new rows are checked at every split position.

The test is third in the guard, after the two register compares, and reads the field `checkSink`
reads a few instructions later. Cost, against a rerun of the same build to separate it from noise:

| payload | before | after | run to run spread |
| :-------- | -------: | ------: | ------------------: |
| Canada | 848 MB/s | 842 | 0.2% |
| Nested arrays | 353 | 349 | 0.0% |
| Array of structs | 553 | 545 | 0.4% |
| GSoC 2018 | 2523 | 2493 | 1.0% |
| CITM catalog | 1476 | 1478 | — |

Under 1% and mostly inside the spread, including on `canada`, which is the payload that punished
the last test added at this site by -3.8%. This one is on the far side of the comma compare, so
the commas that fuse nothing never reach it.

### A `StreamSchema` per `[`, and the benchmark that could not see it

`StreamSchema` is a class, and `enterField` runs once per container *occurrence*. The macro emitted
the field's schema as an argument expression:

```swift
case StreamField.hashtags:
  return _streamEnterArrayField(&p.pointee.hashtags, element: _streamSchema(for: String.Partial.self))
```

so every `[` reaching that field allocated the element schema and then the array schema — two
class instances and a closure context, measured at 17.5 and 18.1 ns, against the 12.6-23.4 ns this
document budgets for a whole *number*. `Int.streamSchema === Int.streamSchema` is `false`, and so
is `StreamArray<Int>.streamSchema === StreamArray<Int>.streamSchema`: those are computed
properties, because a stored static cannot be declared in a generic type or a protocol extension.
Only the macro's own `static let streamSchema` was ever shared.

**No benchmark in the suite could see this**, which is the part worth keeping. Every model here
declared its containers on the *root* — `statuses`, `rows`, `content`, `values` — so `enterField`
ran once per document and the cost rounded to nothing. Real responses do not look like that;
twitter's `entities` carries three container fields inside each of a hundred statuses.
`Fields per element` is that shape, 200 elements with three container fields each, and it is a
prerequisite for the fix rather than a decoration on it.

The macro now hoists each container field's schema to a `private static let` on the generated
`Partial` and passes it to `_streamEnterContainerField`, which takes a finished schema instead of
an element's. The `element:` pair it replaces is gone.

| | before | after | |
| :--- | ---: | ---: | ---: |
| Fields per element — malloc | 2,017 | 816 | **-59.5%** |
| Fields per element — wall p50 | 631 µs | 509 µs | **-19.3%** |
| Fields per element — throughput | 33 MB/s | 41 MB/s | **+24%** |
| Schema 48 members — malloc | 17 | 16 | -1 (the one root array) |
| Twitter matched keys — malloc | 293 | 292 | -1 (ditto) |

The residual 816 is container storage — a `StreamArray` tail and a `StreamDictionary`'s two
buffers per element — not schemas. And the one-allocation drop on every root-container model is
the arithmetic confirming why the old suite was blind to it.

`Optional.streamSchema` was the same defect in a worse place: its closures called
`Wrapped.streamSchema` *inside* each apply, so a scalar behind an optional destination allocated a
schema per **token**. It resolves the wrapped schema once and captures it now.

What is not fixed: the computed `streamSchema` on scalar roots, `StreamArray` and
`StreamDictionary` still builds per access. Generic static stored properties are rejected outright
by the compiler, so there is nowhere to put the cache that does not cost a lock, and a lock in the
core is worse than the allocation for an embedded target. After the hoist those accessors are
reached once per `Partial` type and once per parse for a root, not per container, so the remaining
exposure is the aliased-container spelling that routes through `StreamContainerPartial`.

### `paddedWord` had the padding and did not take it

`StreamParsingLayout.keyPaddingByteCount` — sixteen zeroed bytes behind every key span — exists so
a generated matcher can load a whole word without a bounds check. `paddedWord`, the one function
with that guarantee and the first thing a matcher does to every key in a document, was a byte at a
time loop.

It is a bounded wide load now: one 8-byte load when the span has eight bytes left, and a 4/2/1
halving ladder for the tail. Bounded by the *span* rather than by the padding, deliberately —
`paddedWord` is public on `Span<UInt8>`, so it has to be correct on a span that carries no padding,
and reading into the padding would make every caller outside the parser an overread for a gain the
ladder already collects. No vector below eight bytes: NEON has no masked load, so a partial vector
cannot be read without overreading or a per lane loop, and most JSON keys are short — `id`, `text`,
`user`, `name` — so the tail is the case worth spelling out rather than the fallback.

The function itself, timed against the loop it replaced over a realistic key mix in one binary:
**6.35 ns → 0.98 ns per key, -84.6%.** At document level, through the raw sink that calls it on
every key:

| payload | before | after |
| :-------- | -------: | ------: |
| CITM catalog | 1476 MB/s | 1498 |
| Twitter | 945 | 957 |
| GSoC 2018 | 2493 | 2511 |
| Array of structs | 545 | 551 |

+0.7% to +3.3%, and about the same through the partials path. `Schema 48 members` cannot resolve
it: those rows are ~80 µs with wall clock quantized to 1 µs, so their own noise floor is 1.25% and
they moved ±2.6% in both directions across runs of the same build.

### A note on reading these numbers

`Real GSoC 2018` showed -3.8% in the combined after run and reproduced on a recheck, which looked
like a regression until it was isolated. Run alone against a stashed pristine control in the same
session it is equal or faster at every percentile — p0 2591/2592, p50 2501/2513 — and run inside
the seventeen benchmark batch it drops to 2427. It is the largest payload in the suite at 3.2 MB,
so it is the one most sensitive to the cache and thermal state the preceding benchmarks leave
behind. Batch position is a variable here, and a number from a filtered run is not comparable to
one from a batch containing it.

### Also found, not fixed

- `PartialSink.keyChunk` routes each fragment through `key(_:)`, so a multi-chunk key would keep
  only the last fragment's match and, for a dictionary, create an entry per fragment. Unreachable:
  `emitBufferedKey` always emits a key whole. But `keyBegin`/`keyChunk`/`keyEnd` are protocol
  requirements the parser advertises and `PartialSink` cannot honour, so one of the two should go.
  **Resolved** — see "A key has no chunked form" below; the trio went.
- `JSONParser.init(buffer:)` has no minimum size check. The allocating initializer floors capacity
  at 64 and `BufferCapacityTests` pins that; the caller supplied one takes anything, and
  `escapeScratchOffset` at `count - 4` and the pending UTF-8 hold at `count - 8` are outside a
  buffer under sixteen bytes. `appendToBuffer`'s guard covers the key and number region only.
- `resolveScalarTarget` does not clear `pendingDictionaryFrame` where `valueTarget` does, so the
  frame outlives the value and its storage pointer is invalidated by the next `_openValue`. Latent
  — every value is preceded by a key that overwrites it — but it is the one place the "an element
  pointer stays valid for that element's lifetime" invariant is not enforced by construction.
- A raw control byte inside a string reports `.unterminatedString`, because that is the only
  remaining `else` in `consumeStringRun`. Reasons are coarse by decision; this one is misleading.
- `finish()` emits a buffered number before it checks depth, so `[1` delivers `number(1)` and then
  throws `unterminatedContainer`.

---

## StreamString: bytes accumulate, `String` is a read

The accumulation type "The append itself, isolated" priced and parked is now in. `String.Partial`
is `StreamString`, so every parsed string field accumulates raw UTF-8 and decodes when read,
rather than materializing an intermediate `String` per chunk — where a chunk is an
escape-delimited run, which for escaped markdown meant one per ~80 bytes even in bulk.

The layout is `StreamArray`'s, for `StreamArray`'s reasons: sealed 512-byte `ContiguousArray`
blocks plus a filling tail, so a snapshot shares sealed storage forever and an append after a
snapshot copies at most the tail. One property `StreamArray` does not have falls out of sealing
exactly on fill: the block boundaries are a function of the byte count alone, so two equal
strings pair up block for block — equality is a paired memcmp and hashing feeds the hasher
identical chunks without normalizing anything. The tail's first allocation is sized to the bytes
in hand rather than to 512, because most JSON strings are one short append and a 512-byte
reservation per screen name is the allocation profile this type exists to remove; a tail that
grows a second time jumps straight to 512.

The API question answered itself by precedent: `Array.Partial` is `StreamArray` and
`Dictionary.Partial` is `StreamDictionary` for storage reasons, and a string under accumulation
has the same reasons. The macro already emits `String.Partial` for field types, so the flip
routed every generated `Partial` with no macro change. Substrings are byte offsets — `utf8` is a
`RandomAccessCollection` view, `String(value.utf8[n...])` decodes just the suffix, and a range
inside one block decodes in place with no gathering copy. Materialization always takes the
repairing decode, because unchecked-mode bytes can be invalid UTF-8 and an unvalidated
construction is not an option on any path. Equality is byte-wise where `String`'s is canonical —
NFC and NFD spellings compare unequal here, as they do in the JSON grammar — and heterogeneous
`==` against `String` exists in the optional shapes, because a partial's fields are optional and
`partial.title == expected` is the comparison every client writes. That operator set is why the
382 existing tests compiled and passed with zero edits.

Measured on the same 30-row `Layer` batch as the session's pristine baseline, p50, with the
counting-sink controls inside the known drift (LLM 1876→1831, Twitter 919→907, CITM 1454→1451):

| Layer, partial sink | before | after | mallocs |
| --- | --- | --- | --- |
| LLM message bulk | 382 MB/s, 2798 µs | **600 MB/s, 1782 µs** | 9088 → 6019 |
| LLM message 16KB chunks | 382 MB/s | **599 MB/s** | 9144 → 6022 |
| LLM message byte by byte | 30 MB/s, 35 ms | **62 MB/s, 17 ms** | 3735 → 6283 |
| Twitter bulk | 515 MB/s | 512 MB/s | 288 → 327 |
| CITM catalog bulk | 408 MB/s | 399 MB/s | 1932 → 2201 |

The stream rows track their partial-sink rows as before (LLM bulk 379 → 586 MB/s). The document
the convenience layer exists for got +57% in bulk and 2.05x byte-fed, which is the escape-run
arithmetic paying out: the value-materialization gap on LLM message was 2082 µs and the append
path's share of it is gone.

`StringAppendBenchmarks` now measures the production type against `String`'s own conformance
(which remains the path for a `String` used directly as a root), and the isolation agrees with
the layer rows about where each side wins. p50, 8 KB accumulated then materialized:

| | by 1 B | by 64 B | by 4096 B | fresh 14 B | fresh 23 B |
| --- | --- | --- | --- | --- | --- |
| `String.streamAppend` | 199 µs | 13 µs | 833 ns | 83 ns, 0 mallocs | 208 ns |
| `StreamString` | **42 µs** | **4.6 µs** | 2.8 µs | 208 ns, 1 malloc | 208 ns |

The two right columns are the accepted costs in isolation: at 4 KB chunks the block seals and the
gathering decode cost more than `String`'s single append — though this row materializes every
iteration, which the parse path only does when a field is read — and a fresh sub-15-byte token
pays the tail malloc that `String`'s inline form avoided. Those are exactly the shapes behind
Twitter's and CITM's flat-but-not-better rows.

Two costs were accepted knowingly. Twitter and CITM wall clock is flat at the drift boundary, but
their malloc counts rose (+39, +269): a string that fit `String`'s 15-byte inline form cost zero
mallocs and every non-empty `StreamString` allocates one tail. An inline small form inside
`StreamString` is the follow-up if those payloads ever need the mallocs back; it was not bought
here because the wall clock says it is not yet being paid for. And byte-fed LLM message still
sits at 62 MB/s against the counting sink's 127: the per-byte append is now a uniqueness check, a
capacity check and a store, so what remains is the per-chunk scalar-target resolution — the
"batching in the sink" lever, which is the other half of the split the append measurements
predicted and is untouched.

Also untouched by design: CITM's 150K retains on the dictionary key path and Twitter's routing
gap (919 counting vs 556 partial with no values written), which are the next two largest costs in
the layer and are not string problems.

### The `StringProtocol` question, and the bridge instead

`StreamString` cannot conform to `StringProtocol` and should not try: the protocol constrains
`Index == String.Index`, which is opaque and only mintable from an actual `String`'s views, and
`Element == Character`, which requires grapheme segmentation the stdlib does not expose — and the
stdlib's contract names `String` and `Substring` as the only valid conformers, which generic code
(see `_ephemeralString`, specialized for exactly those two) is entitled to assume. A conformance
that compiles would materialize a `String` inside nearly every requirement, reinstating the cost
the type exists to remove, under `String`'s canonical semantics where `StreamString`'s identity
is deliberately byte-wise.

What shipped instead: byte-wise `hasPrefix`/`hasSuffix`/`contains` (one `streamBytesEqual` walk
per block the window touches, sharing `utf8Matches` with `==`; `contains` is a first-byte scan,
quadratic only for the pathological caller), and `Substring.init(_:)` from a `StreamString` or a
`utf8` slice as the explicit bridge — one repairing decode, then the full `String` API for
anything generic over `StringProtocol`. Equality and the gather copy also now go through
`streamBytesEqual` and one-memcpy-per-block respectively; a fully contiguous backing was
considered and rejected because a single region would relocate on growth, which is exactly what
sealed-block sharing exists to avoid. Marking `streamAppend` `@inlinable` measured flat (594 vs
600 MB/s on `Layer LLM message bulk - partial sink`, batch position noise): `append(utf8:)`
already specialized through the inlinable schema closure, so the attribute is consistency, not
speed.

The comparison surface got its own rows (`StringCompareBenchmarks`), because nothing on the parse
path compares strings and the `Layer` rows are blind to it. Measured against an `elementsEqual`
control, stash-style in one session, p50 on equal operands (equality's worst case):

| | `streamBytesEqual` | `elementsEqual` control | `String == String` |
| --- | --- | --- | --- |
| compare 23 B | 42 ns | 83 ns | — |
| compare 8 KB | **250 ns** | 10 µs | 625 ns, 1 malloc |
| compare 8 KB vs `String` | 333 ns | 10 µs | — |
| contains, match at end of 8 KB | 7.7 µs | 7.7 µs | — |
| hasSuffix 6 B of 8 KB | 83 ns | 83 ns | — |

`elementsEqual` over `UnsafeBufferPointer<UInt8>` never becomes a memcmp — ~1.2 ns per byte, 40x
under the SIMD16 walk at 8 KB — so the shared-helper rewrite is what makes block-paired equality
faster than `String`'s own `==` on the same bytes. Ordering uses the sibling
`streamCompareBytes` kernel: it finds the first unequal SIMD lane from the xor and compares that
lane directly, rather than probing equality and then walking the same window again. Dedicated
ordering rows pinned the effect, p50 wall clock in the same session:

| ordering | equality probe + byte walk | `streamCompareBytes` |
| --- | --- | --- |
| 23 B, difference at end | 83 ns | 83 ns |
| 8 KB, equal | 333 ns | 292 ns |
| 8 KB, difference at byte 511 | 250 ns | **83 ns** |
| 8 KB, difference at value end | 500 ns | **292 ns** |

The searchers moved not at all: `contains` is bounded by its per-byte first-byte scan through the
view subscript, not by the match, which is where a SIMD scan would go if a real workload ever
cares; `hasSuffix` is one 6-byte compare either way.

### The API round: scalars, forward characters, and one index currency

The collection story landed where the `StringProtocol` analysis pointed: conformances live on
views, not on the type. `unicodeScalars` is a `BidirectionalCollection` of `Unicode.Scalar` with
`Int` byte-offset indices — the same currency as `utf8`, so an index moves freely between the
views — decoding table-free (the narrowed second-byte ranges reject overlong forms and
surrogates) and repairing ill-formed bytes as one U+FFFD per byte, the same policy as the
`String` decode, so the views cannot disagree about garbage.

`characters` is a forward `Sequence` of the same `Character` values produced by iterating a
`String`. Grapheme segmentation is not public API and its tables are not something this package
should carry, so a small decoded window delegates each boundary to `String`'s own breaker; the
window grows when an extended grapheme cluster fills it. The sequence deliberately does not vend
integer character indices: `StreamString`'s integers are UTF-8 byte offsets, while `String` uses
opaque `String.Index` values to distinguish valid character boundaries.

The rest of the round: `append` (StringProtocol / `StreamString` block-wise / `Character`),
`+=`/`+`, `TextOutputStream` (an accumulator is an output stream — `print(x, to: &value)`
appends), `TextOutputStreamable` (block-at-a-time with cuts backed off to scalar boundaries, so
no chunk decodes a torn character and the whole value is never materialized), custom string
interpolation (segments append as bytes; the reflection catch-all is `#if !Embedded`, which the
wasm build enforced by failing until it was), `Comparable` (byte-wise lexicographic, which for
UTF-8 *is* scalar-value order, through one SIMD-backed pass per 512-byte window), and a quoted
`debugDescription`. Declined on the standing principle that members never materialize: `count`
(grapheme count would lie or decode; `utf8Count` stays the only
spelling), `lowercased()`/case mapping, and locale- or regex-anything.

`range(of:from:)` closed the round once the index contract was settled: offsets the type hands
out denote real boundaries; offsets a caller invents denote bytes, and the API answers for the
byte named. The result is `Range<Int>` in the one currency — it feeds `utf8[range]` and
`String(_:)`/`Substring(_:)` directly — with the byte-wise consequences stated rather than
hidden: a match in well-formed text is scalar-aligned by UTF-8 self-synchronization, not
necessarily grapheme-cluster-aligned (searching `"e"` finds the `e` inside a decomposed `"é"`,
pinned in tests). `contains` is now `range(of:) != nil`, and the resumable `from:` parameter is
the marker-scanning loop the delta use case wanted.

## Routing: frames borrow their schema, and two rewrites that measurement rejected

`StreamString` moved `LLM message`'s partial sink from 382 to 600 MB/s, so the question became
what the *other* documents were spending. The counting sink is the control: the same parse with
a sink that counts tokens and does nothing else, so counting minus partial is what routing a
token into a value costs and nothing more.

The `partial sink, no values` row existed only for `Twitter` and `LLM message`, which is the pair
that answered least. Adding it for the three widest gaps meant solving one problem first: the
control renames scalar keys so nothing matches, and that cannot work on a **dictionary**, which
matches every key by construction and treats a value its schema refuses as a type mismatch rather
than an ignored key. So the dictionary control sits one level lower — `BenchmarkDiscardedScalar`
opens the entry under its key and accepts and discards the token — which holds `enterKey` and the
entry's storage constant and removes only the scalar conversion. Narrower than the object control,
and it is exactly the narrowness that made the answer legible.

Bulk, p50, one batch:

| Payload | counting | no values | matched | routing | values | routing share |
|---|---:|---:|---:|---:|---:|---:|
| Dictionary | 540 | 102 | 103 | 7.95 ns/B | −0.10 ns/B | **100%** |
| CITM catalog | 1451 | 437 | 405 | 1.60 ns/B | 0.18 ns/B | 90% |
| Twitter | 935 | 551 | 525 | 0.75 ns/B | 0.09 ns/B | 89% |
| Array of structs | 547 | 205 | 111 | 3.05 ns/B | 4.13 ns/B | 42% |
| LLM message | 1768 | 1505 | 608 | 0.10 ns/B | 0.98 ns/B | 9% |

`Dictionary` settles it: 540 → 102 without writing a value, and writing all 100 values costs
nothing measurable — identical mallocs, identical retains. The 5.3x gap is `enterKey` and opening
the entry. `CITM catalog` says the same at scale: 135,000 of its 150,000 retains and 1,690 of its
1,692 mallocs happen with no value written. `LLM message` is the inverse and confirms
`StreamString` did its job — 91% of what is left there is writing bytes. `Array of structs` is the
one payload where values are the larger half, at 4.13 ns/B against `LLM message`'s 0.98: that is
`StreamString` paying block allocation on 200 tiny strings, which is the inline-small-form
follow-up, not a routing problem.

Building those rows surfaced two sharp edges. `runLayerPartialSink` never checked
`sink.streamFailure` — a rejection is recorded, not thrown, so the first versions of the models
measured the bail-out path and read as fast rows; there is now a `precondition` there, and it
caught the second edge immediately. `_streamSchema(for:)` picks a schema **by overload, not by
conformance**, so a hand-written `StreamParseableRoot` matching none of the convertible overloads
lands on the `@_disfavoredOverload` catch-all — a scalar schema that refuses every token — and its
own `streamSchema` is never read. `StreamParseableObject` is the conformance that forwards.

### Durability before borrowing

The plan was to stop `PartialSink` retaining the schema in every frame it copies. That is sound
only while every schema a frame can carry outlives the parse, and the claim that it already did
was wrong. The macro hoists `private static let streamContainerSchema_<field>` and passes it to
`_streamEnterField`, but the `StreamParseableObject` overload **ignored** it and called
`_streamEnterObject`, which reads `T.streamSchema` per entry. For a generated `Partial` that is a
stored static, so it was harmless. For a hand-written conformance whose `streamSchema` is computed
it allocated a fresh schema per entry whose only owner was the frame — `PersonNameComponents` in
`Support/Foundation.swift` is one in this tree, and it is exactly the retroactive-conformance shape
a user would write.

So `StreamParseableObject` now refines `StreamContainerPartial`, and the object entry helpers take
the schema rather than reading it. The parent evaluates a child's `streamSchema` once into its own
`private static let`, which means a retroactive conformance gets durability without its author
doing anything. That closes the ownership graph: an object or container field's schema is the
parent's hoisted static, an element or value schema is captured by the container schema that
produced it, the root's is `rootSchema`, and an ignored subtree's is `ignoredStreamSchema`.

### The witness rewrite, measured and rejected

`SchemaDispatchBenchmarks` prices a schema call through a stored `@Sendable` closure at 17.0 ns
against 4.6 ns for a bare function pointer, the difference being one retain/release pair. The
replacement was going to be a witness metatype: `any StreamSchemaWitness.Type` stored on the
schema, which carries the same two words a closure does with type metadata as the context, and
metadata is not refcounted. `@convention(thin)` is not an option — it cannot carry metadata, and
forming a thin function *reference* crashes the compiler under Swift 6 mode.

The dispatch measured exactly as predicted: **witness 4.8 ns, generic witness 4.2 ns, thin 4.8 ns,
thick closure 17.0 ns, direct 3.2 ns.** Carrying a generic parameter costs nothing. Both rows are
kept in the file.

It made the parser slower anyway, in two independent ways, and both are the reason this section
records a rejection rather than a design.

The generic builders were the larger half: **Dictionary 103 → 36 MB/s, CITM 405 → 269, Array of
structs 111 → 90.** `_streamArraySchema` and `_streamDictionarySchema` are `@inlinable`, so the
closure body they built was *specialized* at the schema-construction site — `Element` concrete,
`StreamArray<Element>` laid out, `streamInitialValue()` direct. A generic witness reached through
an existential metatype is not specialized: every one of those goes through runtime generic
metadata. The step-1 probe missed it because the generic probe never touched its parameter, which
is the flaw in that measurement worth remembering.

The object path was the smaller half and a wash on its own — Twitter +1.7%, LLM −0.5%, CITM −2.5% —
while *adding* retains (Dictionary 313 → 513, CITM 150,000 → 164,000), because a protocol witness
passes its arguments owned rather than guaranteed, so handing `self` to the witness costs a pair.

The premise was wrong at the real call site. The 17 ns closure cost is real in a micro-benchmark
that defeats the optimizer with a global `var`; in `PartialSink` the schema is reached through
`top.pointee.schema` in the same module and the closure load is already a borrow. Twitter's
16,000 retains against roughly 37,000 schema calls was the evidence sitting in the results the
whole time: it was never one retain per call.

### What did work: `BorrowedFrame`

`StreamFrame` is unchanged — a schema handed across the public API is an ordinary strong reference.
`PartialSink` lowers to a `BorrowedFrame` with an `unowned(unsafe)` schema the moment it receives
one and never stores a `StreamFrame`, so the frame stack, `pendingDictionaryFrame` and the frame
half of the scalar target stop retaining. The struct is trivial, so pushing and popping a frame is
a store and a decrement and `deinitialize` on the stack is a no-op.

| Payload | before | after | retains |
|---|---:|---:|---|
| Dictionary — partial sink | 103 | **119** (+15.5%) | 313 → 311 |
| CITM catalog — partial sink | 405 | **429** (+5.9%) | 150,000 → **129,000** |
| Twitter — partial sink | 525 | 534 | 16,000 → **13,000** |
| LLM message — partial sink | 608 | 603 | 13,000 → 12,000 |
| Array of structs — partial sink | 111 | 111 | 1,913 → 1,811 |

The counting-sink rows moved −4.6% to +5.1% across the same two runs with nothing touching them,
so that is the session's noise floor and only `Dictionary` and `CITM catalog` clear it on wall
clock. The retain counts are exact and clear it everywhere. `Dictionary` gains 15% while saving
two retains, which says its win is the trivial frame — a store instead of an ARC pair on every
`pendingDictionaryFrame` set and clear — rather than the retains.

`ScalarTarget.schema` stayed **strong**, against the plan and because of the measurement.
Borrowing it made `LLM message` go 604 → 485 MB/s with retains rising 12,000 → 37,000: a stored
closure loaded off an `unowned(unsafe)` reference has to be converted to a strong one first, where
the same load off a strong stored property is a borrow the optimizer gets for free, and that
target is re-read once per `stringChunk`. Twitter, which routes many short scalars and few chunks,
preferred the borrow by 11%. The string path is the larger of the two.

### The tripwire

`unowned(unsafe)` trades a guarantee for speed, so the violation has to be reported rather than
discovered. `StreamSchemaBorrowAudit` holds every borrowed schema **weakly** and checks for
deallocation at `pushFrame` and at scalar resolution. A weak reference rather than a refcount:
`isKnownUniquelyReferenced` at the borrow depends on whether the caller's temporary is still
alive, which differs between `-Onone` and `-O`, so it both false-positives and false-negatives.
Deallocation is the thing that actually matters. It is per sink rather than global, so there is
no shared mutable state to race on, and `#if DEBUG && !hasFeature(Embedded)` because Embedded
Swift has no `weak`.

`SchemaBorrowAuditTests` proves it fires — a tripwire that cannot trip reads as a guarantee and
is worse than none. The failing model is hand-written because the macro hoists a nested schema and
so cannot express the mistake, and the test observes stderr rather than only the exit status, so
it cannot pass on an unrelated crash.

Still open, and now measured rather than suspected: `Dictionary` at 119 MB/s against a 515 MB/s
counting sink is still the worst ratio in the suite, and it is `enterKey` and `StreamDictionary`'s
entry, not the schema call. The byte-fed floor is untouched — every byte-fed row sits at 9–12 ns/B
regardless of payload, including `Long string`, which is 8 KB of two tokens, because
`consumeStringRun` buffers keys but emits string values straight from the input span and so fires
`stringChunk` once per byte.

---

## The optional seam: one level of optionality, a field that is not zero, and a key that is whole

An audit pass over the sink and the conversion machinery found three defects that share a shape:
an optional in a type position is stripped where the *schema* is built and kept where the
*storage* is declared, so the schema and the memory it writes through describe different types.
None of them had coverage — the suite was 420 green before the pass and stayed green after the
fixes.

### A scalar arriving at an object was absorbed by its first field

`resolveScalarTarget` named the destination with a field identifier, and used `0` for both "field
zero of this object" and "this value itself" — an array element, a dictionary value, a bare scalar
root. A generated object schema switches on that identifier, so the two collided:

```
["abc"]      into StreamArray<Person.Partial>       →  [Partial(name: "abc", count: nil)]
{"k":"abc"}  into StreamDictionary<Person.Partial>  →  [k: Partial(name: "abc", count: nil)]
[null]       into StreamArray<Person.Partial>       →  [Partial(name: nil, count: nil)]
```

A string arriving where an object belongs was written into whichever member the type declared
first, silently. `[5]` was a type mismatch only because `name` could not hold a number: reorder
the declaration so `count` comes first and the number lands in it just as quietly.

The fix is a sentinel. `StreamSchema.wholeValueField` is `-1`, and the array, dictionary and
scalar-root branches of `resolveScalarTarget` pass it. A negative field cannot collide with a
declared one, so an object schema's `default: return false` — which every generated schema already
has, along with `PersonNameComponents` — turns those back into the mismatches they are. Scalar
schemas ignore the field and are untouched, which is why an element that really is a scalar still
costs nothing.

It lives on `StreamSchema` rather than on `PartialSink`, which is where it is produced, because it
is part of the contract of the closures that *read* it and `PartialSink` is generic over its root:
`PartialSink.wholeValueField` does not compile, and a hand-written schema reaching for
`PartialSink<Something>.wholeValueField` would have to name a root it knows nothing about.

The same collision made `Optional`'s `applyNull` clear the whole optional whatever field the null
named. That schema is the element schema for a `StreamArray<Person.Partial?>`, so
`[{"name":"a","count":null}]` produced `[nil]` — the null on one member wiped the element and took
the member already parsed into it. It now clears only on a negative field and delegates otherwise.

Free, and measured rather than assumed. Same-session control against the same filter, p50
`Payload MB/s`:

| Row (`Layer … bulk - partial sink`) | before | after |
| --- | ---: | ---: |
| Array of structs | 111 | 112 |
| Dictionary | 129 | 128 |
| Flat struct | 79 | 79 |
| Twitter | 553 | 556 |
| CITM catalog | 425 | 426 |

Every row is inside the ±5% noise floor, and `Malloc (total)` and `Retains` are identical to the
byte on all five — 1811, 308, 23, 114, 2280 — which is the counter to trust here. The sentinel is
an immediate constant where a zero used to be; there was never anything for it to cost.

### A `Partial` stored two levels of optionality and understood one

`partialTypeName` kept the property's own `?` — `Int?.Partial` *is* `Int?` — and the members mode
appended another, so `var maybe: Int?` became a member of type `Int??` while every schema emitted
for it described `Int`. Nothing bridged that gap:

- **Scalars were rejected outright.** `streamApply` has `inout T` and `inout T?` overloads and no
  `inout T??`, so a value fell through to the `@_disfavoredOverload` no-op, which reports `false`,
  which the sink reports as `.typeMismatch`. `{"maybe":5}` did not parse.
- **Containers dropped their contents in silence.** `_streamEnterContainerField` materialised the
  outer optional with `Optional.streamInitialValue()` — `nil` — and handed the array schema a
  frame over the `nil` inner. `{"scores":[1,2]}` finished clean with `Optional(nil)` in it.
- **Only `null` worked**, because `Int??` is still `StreamNullable`. The two tests that covered
  optional members both fed `null`, which is why the suite was green over this.

`partialTypeName` now describes the *wrapped* type, which is the same type every schema is built
from, and `memberTypeName` adds one `?` when the mode calls for it **or** the source property was
optional. An optional property is already optional; the mode only decides what happens to the ones
that are not. `Optional<Int>` written in generic form is unwrapped too, through a shared
`unwrappedType` that `fieldShape` and `schemaExpression` now also use — the sugar-only test left
that spelling on the old path, which is a worse place to be than uniformly wrong.

Macro codegen only, so there is nothing to measure: the emitted member is one optional narrower
and the emitted schema is unchanged.

### An optional dictionary member did not compile

`streamPartialValue` emitted `self.counts.mapValues(\.streamPartialValue)` for a
`[String: Int]?`, reaching for `mapValues` on the optional. It maps through it now.


### A key has no chunked form

`StreamParseSink` declared `key(_:)` *and* `keyBegin`/`keyChunk`/`keyEnd`, with `key(_:)` defaulted
to fan out to the trio. `PartialSink` answered `keyChunk` by routing each fragment through
`key(_:)`, which for a `.match` schema keeps only the last fragment's answer and for a
`.dictionary` calls `_openValue` once per fragment — one entry per piece of the key.

Unreachable through `JSONParser`, which is what kept it from being a bug: `consumeStringRun`
copies every key into the parser's buffer so it is contiguous across chunks, and `emitBufferedKey`
emits it whole. But that is not an accident of the current parser, it is the only way a key can be
delivered. `emitBufferedKey` also zeroes `StreamParsingLayout.keyPaddingByteCount` bytes past the
key so a generated matcher can load a whole vector without a bounds check, and a key arriving in
pieces can offer neither contiguity nor padding. So the trio was not an unimplemented capability,
it was a shape the matcher path cannot consume even in principle.

The three requirements are gone and `key(_:)` is a plain one. A sink implements one method where
it used to implement four to get the same event. String values keep their chunked form, because a
string genuinely streams: `consumeStringRun` emits it straight from the input span and never
buffers it, which is exactly the property a key does not have.

Semantically nothing changed — the parser has always called the collapsed form, and every sink in
the tree already overrode `key(_:)` rather than inheriting the fan-out. But one row moved anyway,
and it is worth writing down because the shape of it is instructive. `Layer LLM message bulk -
counting sink` lost ~5-6% at p50, reproduced across six interleaved runs (1689/1718/1710 against
1821/1803/1809) and then isolated: applying *only* this change to an otherwise pristine tree
reproduces it exactly (1703/1684/1697), so it is this and not the sentinel or the macro.

It is code layout, not cost. The same document through the *partial* sink went the other way, and
just as consistently — 579 against 559, ~+3.6% — while `Layer Long string bulk - counting sink`
got faster, `Fast Long string - bulk` and `Fast Non-ASCII string - bulk` were identical to the
digit, and every allocation and ARC counter in the suite was unchanged. A protocol that is three
witnesses smaller specializes into a slightly smaller parse loop, and this parser is already
documented as sitting on inlining cliffs — `parse` at 1284 bytes against 1424, with
`@inline(never)` and `@inline(__always)` applied by force to hold it there. Two rows over the same
payload moving in opposite directions is what that looks like from the outside, and it is not
something to chase by reinstating dead protocol requirements.

The `Flat struct` rows cannot speak to any of this. On the smallest payload in the suite, ~1.2 µs
against a ~42 ns timer grid, the *counting* sink — untouched by every change here — swung -14.3%
at p0 while sitting at 0.0% at p50 between two runs, and the partial sink row read -14.6% in one
batch and +11% in an interleaved one, for the same pair of builds. Neither number means anything.

### Optional elements: open the slot, copy the closures

`[String?]`, `[String: String?]` and `[Person?]` segfaulted. The macro named the storage from the
element type and the schema from the *unwrapped* element type, so the storage was
`StreamArray<StreamString?>` — whose `streamInitialValue()` is `nil` — while the element schema
was `StreamString`'s and wrote straight through the `.none` representation.

The root path never had the bug, because `StreamArray<Element>.streamSchema` passes
`Element.streamSchema` and for an optional element that is `Optional`'s materialising wrapper. So
the obvious fix was to emit what the root path emits. Measured, that costs 2.4x: on a 20,000
element array, release, best of 7, `[Int]` runs at 32.1 ns/element and `[Int?]` through the wrapper
at 73.5. The wrapper has to materialise per token, and having materialised it has to load and call
*another* schema's closure to do the actual write.

What landed instead costs nothing: **32.9 ns/element**, inside the noise of the non-optional path.
Two pieces:

- `_streamOptionalArraySchema` / `_streamOptionalDictionarySchema` open the slot as
  `.some(Wrapped.streamInitialValue())` rather than `nil`. Nothing downstream has to check.
- `_streamOptionalElementSchema` derives the element schema from the wrapped type's by copying
  its closures across **verbatim**. `applyString`, `applyNumber`, `applyBoolean`, `enterField`,
  `appendElement` and `enterKey` are not equivalent closures, they are the *same closure values*
  the non-optional path stores, so a token costs one schema call rather than two. Only `applyNull`
  is new, and only its `wholeValueField` branch.

That last part is only expressible because of the sentinel above. Before it, a null arriving at an
element and a null arriving at the element's first field were the same call with the same
arguments, so there was no way to write an `applyNull` that clears the optional without also
breaking `[{"city":"NYC","postalCode":null}]`. The sentinel is what turned the 2.4x fix into a
free one.

Two consequences worth naming rather than discovering later. An element opened materialised is
visible as `.some` from the opening brace, so `[{}]` into a `[Person?]` reads as one empty
`Person` where the wrapper would have read `nil` until the first matching key — the more
defensible answer, since `{}` is an object, but a different one. And a rejected element holds its
initial value rather than `nil`, which is the behaviour `PartialSinkFailureTests` already pins for
non-optional elements.

Same session, same filter, control against the commit without it, p50 `Payload MB/s`: Array of
structs 111 → 111, Dictionary 127 → 128, Twitter 534 → 543, CITM 400 → 403, LLM message 589 → 589,
`Fast` rows flat to the digit. `Malloc (total)`, `Retains` and `Releases` identical on every row.
The `Flat struct` row read +11.4%, which is that row being unreadable rather than a gain.

Folded in with it: `schemaCases` filled `applyNull` only in its `.scalarOrObject` branch, so a
container field reached no case at all and `{"scores":null}` was a type mismatch however the member
was declared. It emits the same `streamApplyNull(&target)` line now, which clears an optional
member and still refuses a non-optional one through the disfavoured overload.

### `streamElementSchema`: the type answers, not the spelling

Option C fixed the crash and left a cliff. `fieldShape` reads syntax, so only the sugared
spellings reached the new builders:

```
var sugared: [Int?]           → _streamOptionalArraySchema(…)                         32 ns/element
var generic: Array<Int?>      → _streamContainerSchema(for: (Array<Int?>.Partial).self) 77
var aliased: Scores           → _streamContainerSchema(for: (Scores.Partial).self)      77
```

All three are correct; two are 2.4x slower than the other. Worse, the second and third are
unfixable in the macro: recognising `Array<X>` is a race against every way a type can be spelled,
and a `typealias` cannot be resolved by a macro at all, because a macro has no type information.
The same gap covers every root — `partials(of: [Int?].self)`, a bare `StreamArray<Int?>` — and
every container the library composes rather than the macro.

So the answer has to come from the type. Two requirements on `StreamParseableRoot`, both
defaulted to the root forms, and `Optional` the only type that overrides them:

```swift
static var streamElementSchema: StreamSchema { get }      // default: streamSchema
static func streamElementInitialValue() -> Self           // default: streamInitialValue()
```

They sit on `StreamParseableRoot` rather than `StreamInitializable`, which is where
`streamElementInitialValue` would otherwise belong, because `Optional: StreamInitializable` is
declared *unconditionally* — a `where Wrapped: …` extension member can never be its witness, so
the override would silently resolve to the default and the slot would open `nil` again. On
`StreamParseableRoot` the conformance is already conditional and the override lands. The cost is
tightening `_streamArraySchema` and `_streamDictionarySchema` from `StreamInitializable` to
`StreamParseableRoot`, which every caller already satisfied.

`Optional.streamSchema` stays. It is still right for the one position a container does not own:
a bare optional as the parse root, where nothing else can materialise the storage first.

Every spelling now agrees, measured on the same 20,000 element array:

| | before | after |
| --- | ---: | ---: |
| `var xs: [Int]` | 31.9 | 32.4 |
| `var xs: [Int?]` | 32.4 | 31.9 |
| `var xs: Array<Int?>` | **77.0** | **32.6** |
| root `StreamArray<Int>` | 31.6 | 31.5 |
| root `StreamArray<Int?>` | **73.5** | **32.8** |

And it cost nothing elsewhere. Control against the same tree with only these requirements removed,
same session, same filter, p50 `Payload MB/s`: Array of structs 112 → 110, Dictionary 128 → 129,
Twitter 528 → 530, CITM 399 → 395, LLM message 570 → 572, the `Fast` rows +0.0% to +1.2%. Every
allocation and ARC counter identical. `Flat struct` read -6.8% at p50 with p0 unchanged, which is
that row being unreadable — it has swung ±14% between builds of identical code in this same
session.

### An entry exists from the moment its key does

One test changed, and it is a semantic worth stating rather than re-recording. A dictionary is the
only container with a window between opening a slot and filling it: `enterKey` runs at the key,
and the value arrives afterwards. An array has no such window, since `appendElement` and the write
happen in the same call.

Opening the slot materialised makes that window visible for optionals:

```
StreamDictionary<Int>    {"maybe":7}       byte 7 → [maybe: 0]            byte 10 → [maybe: 7]
StreamDictionary<Int?>   {"maybe":null}    byte 7 → [maybe: Optional(0)]  byte 12 → [maybe: nil]
```

The first line is unchanged and always has been: a non-optional value has shown its initial value
in that window since the pending slot became visible. The second used to show `nil`, not because
that was designed but because `Optional.streamInitialValue()` happens to be `nil`.

The rule is that **an entry exists from the moment its key does**, holding the value type's initial
value until the document supplies one — the key having arrived is itself the evidence that a value
is coming. That is what the non-optional path already said, and optionals now say it too.

The alternative, not taken: publish the entry only once its value arrives, so the window reads
`[:]` for every value type. That is more honest for non-optional values as well, but it changes
`StreamDictionary`'s streaming contract across the board and belongs in its own change.

---

## Structural dispatch: the state machine was living in memory

A profile of the release build on the real corpus (`sample`, counting sink, bulk) put
`consumeStructuralRun` at 28% of `canada` and 32% of `citm_catalog` — for runs of two to four
bytes, `],[-` between coordinate pairs and `": "` after every key. The disassembly said why: the
run loop ended every byte with `strb state → [self]` and began the next with `ldrb state ←
[self]`, and `depth` and `containers` were loaded from `self` per byte and stored back on every
push and pop. The optimizer had not promoted them: `self` is inout, the step has seven throw
sites, and the whitespace call sits in the loop. So the loop-carried dependency of a structural
byte was a store-to-load round trip on `state`, not the compares on it.

### Register-resident state

`consumeStructuralRun` now copies `state`, `depth` and `containers` into locals, the step
operates on those, and a `defer` writes them back on every exit including the throwing ones.
`push`/`pop` are gone — the step does the arithmetic on its locals — and `topIsObject` became a
static over `(depth, containers)` with a masking shift, since `depth` is bounded by
`maximumDepth` and the smart shift's overshift guard was two more instructions per use.

The first cut of this measured **slower everywhere**, 2-9%, and it was not drift: the step
computed `topIsObject` once at its top, before the switch, to share it between arms, which put
eight instructions and two branches in front of every byte where the old code paid them only in
the arms that asked. Computed lazily in the arms it is what the promotion promised. Measured with
two binaries built in the same session and run interleaved, A B A B, p50 wall clock:

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

Every row moves the right way, the byte fed canary included — the loop got cheaper without
getting bigger, which is the only kind of change this loop has ever accepted.

### Classifying the window ahead of time, measured and rejected

The natural next step was to stop peeking one byte ahead for whitespace and classify the whole
sixteen byte window once: four compares, a `shrn`-narrowed lane mask (the idiom lowers to one
`shrn` and one `fmov`; a weighted lane sum was tried first and lowered to a lane extraction per
byte), then visit only the content bytes by `trailingZeroBitCount`, with whitespace-only windows
skipped in one step and the byte path kept for the sub-sixteen-byte tail so byte fed input never
saw the vector. Against the register-state build, interleaved, p50:

| benchmark | register state | window classified | peel 2 bytes scalar |
| --- | ---: | ---: | ---: |
| Real CITM catalog, bulk | 1061 µs | 1138 µs (+7.3%) | 1083 µs (-0.0%) |
| Real Canada, bulk | 2628 µs | 2795 µs (+6.4%) | 2672 µs (-0.4%) |
| Real Twitter, bulk | 602 µs | 619 µs (+2.9%) | 598 µs (-1.0%) |
| Real GitHub events, bulk | 49.1 µs | 48.6 µs (-0.9%) | 47.7 µs (-1.3%) |
| Real GSoC 2018 / LLM message, bulk | — | ±0.5% | ±1.5% |
| Fast Pretty printed users, byte by byte | 60.4 µs | 63.8 µs (+5.6%) | 58.8 µs (-3.7%) |

**The window loses because the runs are short.** A structural run is two to four bytes, so the
load, classify, narrow and count chain — a dozen cycles — sits on the critical path at every
entry, and what it buys per byte is the three instructions of a whitespace peek. The other half
of the expected gain was not there to collect: `citm_catalog`'s long indentation runs follow
commas, which `fuseAfterValue` scans, not the structural run. The single space after a colon is
the whitespace this run actually sees, and peeling it scalar (second column) is noise, which is
the same answer the one byte peel gave in the whitespace section — the out of line vector scanner
is a leaf with no dependent latency, and the core hides it. Neither variant is in the tree.

What remains of the structural cost after this is per run, not per byte: `consumeStructuralRun`
is still ~22% of `canada` and ~33% of `citm_catalog`, and a run there is a dispatcher round trip
plus a ten register prologue and epilogue for two to four bytes of work. A table driven step —
byte class then `(state, class)` transition — would trade the predicted compare tree for a
dependent load per byte and does nothing about the entries, so it was not built. The lever on
the entries is fusing `":` + value start into the key's closing quote in `consumeStringRun`,
which is the colon fusion the doc rejected earlier but consuming the value's first byte as
well, so that for `"key": value` the structural run does not happen at all.

### Fusing the colon after a key: measured across seven variants, and rejected

The lever the section above pointed at was fusing `":` and the value's first byte into the key's
closing quote, the way `fuseAfterValue` already fuses the comma. For `"key": "value"` and
`"key": 42` — most of every object in the corpus — that leaves nothing structural before the
value, so the `consumeStructuralRun` call for the member disappears. It was built seven ways and
none of them is a clean win; the whole space is recorded here so it is not rebuilt.

The bulk gains are real and consistent: `Fast Dictionary` -16 to -20%, `GitHub events` -7 to -12%,
`Twitter escaped` -4 to -10%, `CITM` -2 to -4%, `GSoC` -1.5 to -3.6%. What varies between the
variants is what they cost, and every variant costs something:

| variant | shape | disqualifying cost |
| --- | --- | --- |
| recurse | run tail-calls itself for the fused token | the self-call is a real `bl`, not TCO'd — unbounded stack, one frame per token in a chunk; ~34K frames / 5 MB on a single-chunk GSoC, survives the 8 MB main thread and overflows a worker |
| loop, `let isKey` local | switch on the fusion, flip a local, `continue` | local spilled into the content loop; byte fed `Long string` +32%, `LLM message` +31% |
| loop, `isKeyToken` field | as above, flag read from the field | no escaped-string cliff, but the loop back-edge keeps the content loop's live ranges up: byte fed `Long string` +15%, `LLM message` +15%, `Pretty printed` +8% |
| return to dispatcher (three forms: enum, `let isKey`, field flag) | fuse, return the cursor, let `parse` re-enter — the exact shape of the accepted comma fusion | `Fast Escaped string` bulk **+62%**, in every form |
| out of line fusion helpers | the two fusions `@inline(never)` | escaped cliff gone, but the per-boundary call outweighs the structural-run it skips: `Twitter` +6%, `CITM`/`Canada`/`GSoC`/`GitHub` +3-4% |

**The escaped-string cliff is the finding.** `Fast Escaped string` is `a\nb\t` repeated — a bare
string value with no keys, so the fused `fuseAfterKey` never executes on it. It still costs 62% in
every return-to-dispatcher form, purely as inlined code the escape-decode loop has to share
registers with. That is the exact constraint the "escapes decoded in the string run" section
already drew: `consumeStringRun` "holds only the escapes cheap enough to belong there," and its
escape path is at the register ceiling. A second inlined fusion, with its own whitespace scan and
switch, pushes it over. The one variant without the cliff — the field-flag loop — avoids it only
because the loop makes the optimizer treat the fusion as cold, and pays for it on the byte fed
content path instead. The comma fusion fits because it is the *only* fusion in the function; the
colon fusion is the second, and there is no room for it.

So the structural-run cost this was meant to remove stays. Removing it needs the key path to
cost less code, not more — the direction the open items point (zero-copy keys that do not buffer,
whole-string emission that collapses the three string calls), not another inlined scan in the one
function that cannot afford it.

---

## Keys in place: the padding nobody read, and the function that could not hold the branch

A key cost three things the string value next to it did not: a `copyMemory` into the parser's
buffer (a `memmove` libcall for eight bytes — 6% of `citm_catalog` on its own), a validate call
and a sixteen byte zero store in `emitBufferedKey`, and the bookkeeping around them. All of it
existed for two reasons: contiguity when a chunk cuts a key, and the `StreamParsingLayout.
keyPaddingByteCount` guarantee — sixteen zeroed bytes behind every key span so "a generated
matcher can load a whole vector without a bounds check."

Audited, no reader ever took the guarantee. The macro's matcher reads `paddedLeadingWord()` and
`paddedWord(at:)`, both bounded by the span's count (and documented as having to be, because
`paddedWord` is public on any `Span<UInt8>`); the dictionary's `streamHashBytes` and
`streamBytesEqual` are bounded the same way. So the padding was paid on every key for a reader
that did not exist, and the copy it justified was paid on every key for the one-in-thousands that
a chunk actually cuts. **The guarantee is retired**: a key span is a borrow, valid for the call,
readable within its count, with the document's own bytes behind it — which is what a `Span` is
for; a span you have to copy to use may as well be an array. Most consumers reach keys through
the convenience layer anyway.

### Where the in-place read lives is the whole result

The obvious change — in `consumeStringRun`'s key branch, "if the run ends at a quote in this chunk
and nothing is buffered, emit a span into the input" — measured −9 to −12% on the object heavy
corpus and was not acceptable. The three-compare branch and its emission kept enough extra values
live that the function's stack traffic went from 29 accesses to 37, and every byte fed row paid
3-7% for a path it never takes; moving the emission body out of line got it to 33, not 29, and
the tax to 3-4%. This is the same function whose register ceiling the colon fusion hit, and the
lesson is the same: **nothing may be added to `consumeStringRun`**, not even code that only runs
on keys.

So the key moved out of it. A key whose closing quote is in the chunk is read by the *structural
run*: at the opening quote in the `.key` arm, `consumeStructuralRun` runs the string scanner,
emits the span in place, and carries straight on through the colon into the value's first byte —
which is the colon fusion the previous section could not afford inside the string loop, obtained
for free in a function that owns its registers. `fuseAfterValue`'s object arm now stops *at* the
quote with state `.key` rather than entering `.inKey`. Only a key the chunk cuts, or one an
escape has to decode into, still goes through the buffer — and that path is now its own
`consumeKeyRun`, so `consumeStringRun` is values only: no `isKey`, no buffer bookkeeping, no
key emission. Its stack traffic went from 29 to **22**, lower than before the change.

Measured with two binaries built in the same session and run interleaved, three rounds, p50
(byte fed rows at p0, where the session's noise was; the p50s there swung ±5% on unchanged code):

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

Throughput on the bulk rows, from the same p50s: Twitter escaped 823 → 1044 MB/s, CITM 1640 →
1915, GitHub 1357 → 1551, Twitter 1047 → 1191, GSoC 3240 → 3566.

The byte fed cost lands where every fusion's has: a one byte chunk never contains a whole key, so
the scan at the opening quote returns at once and the key takes the buffered path it always
took, and the escape-bearing rows pay 2-5% for the layout around it. Pure string content pays
nothing, which is what splitting `consumeKeyRun` out was for.

Semantics that moved, both deliberate and pinned in `JSONParserBufferTests`: a key contained in
one chunk is handed over in place, like a number, so the buffer capacity no longer limits it (a
200 byte key parses against a 64 byte buffer when it arrives whole, and still throws
`bufferExhausted` when split across chunks); and a key's span aliases the input in bulk and the
parser's buffer byte fed — the tests check the address, not just the bytes. `StreamParsingLayout`
is gone; the only layout fact left in the parser is its own sixteen byte reserved tail, which is
now named for what it is.

### Three cheap fixes from the disassembly, one kept

The profile pass that opened this round flagged three things the release binary was doing that
the source did not intend. Each was built alone and measured interleaved against the tree before
it, three rounds, p50.

**`NumberInfo.Flags` statics were addressor calls — kept.** `public static let negative =
Flags(rawValue: 1 << 0)` in `StreamParsingCore` is reached from a client module through
`unsafeMutableAddressor`, so `emitNumber` made up to four calls per number to fetch four
constants (visible in the `canada` profile as their own symbols). As `@inlinable public static
var` they are immediates. `canada` **−8.1%**, `Fast Nested arrays` −7.6%, `Fast Dictionary`
−3.7%, `citm_catalog` −2.2%, string rows flat.

**The number scanner's first-miss ladder — rejected.** `streamNumberRunEnd` finds the first lane
outside the number class with a per lane loop that the compiler unrolls into sixteen `umov` +
`tbz` pairs, where the string and whitespace scanners use `replacing(with: lanes)` + `uminv`. The
reduction was measured in its place and lost: `citm_catalog` **+10.5%**, `Fast Nested arrays`
+11%, `canada` −2%. The ladder's moves are independent and all issue together, so a miss in lane
one to six — every number under sixteen digits, which is every number in `citm_catalog` —
resolves in one move plus predicted branches; the reduction's `bsl` → `uminv` → `fmov` chain is
dependent latency that a short number pays in full. Only `canada`'s 16+ digit coordinates reach
the second vector, where the reduction is ahead. The ladder stays, and the comment on it now
says why.

**`validateUTF8IfNeeded` as an inline guard over an out of line walk — rejected.** It is an out
of line call at eleven sites, including once per key, and its first two guards return
immediately on any ASCII document. Splitting it measured ±1-2% on every row, inside the noise,
and raised `consumeStringRun`'s stack traffic from 22 to 32 accesses. Nothing goes into that
function without a measured reason, and this had none.

---

## UTF-8 validation in vectors: the three table lookups, and the one instruction Swift cannot say

The scalar validator walked a run sequence by sequence — read the lead, derive the length, check
each continuation, check the second byte against the lead — at ~1.35 GB/s, with four or five
branches per sequence. That was tolerable on `twitter` (15% non-ASCII, ~12% of its strict parse)
and invisible on the ASCII documents. What it did to `llm_message` was not visible until this
landed: its long string values carry a few non-ASCII bytes each, and a run is validated whole, so
a hundred kilobyte run with one `é` in it went through the scalar walk end to end. That, not the
escapes, was most of the 2.3x between its strict and unchecked rows.

### The algorithm

Keiser and Lemire's lookup validator: every UTF-8 error is visible in a window of two adjacent
bytes plus one structural fact. For each lane take the high nibble of the previous byte, its low
nibble, and the high nibble of the current byte; each indexes a sixteen entry table of error
classes (too short, too long, overlong 2/3/4, surrogate, too large); AND the three results, and a
nonzero lane is a pair that all three tables agree is wrong. The structural fact — a continuation
is *required* two bytes after a three byte lead and three after a four byte lead — is a mask XORed
in against the "continuation after continuation" class. A final check that the run does not end
inside a sequence completes it. Sixteen bytes a block, no per-sequence control flow, one
reduction at the end to ask whether anything fired.

Two things the paper takes for granted are not in Swift's SIMD API, and both are reachable:

- **Table lookup.** There is no `tbl` and no shuffle of any kind. A header-only C target,
  `StreamParsingShims`, wraps `vqtbl1q_u8` behind an `ext_vector_type(16)` signature, which Swift
  imports as `SIMD16<UInt8>` and inlines to a single `tbl.16b` (`@_silgen_name` and `@_extern(c)`
  on the LLVM intrinsic were tried first; the former fails instruction selection, the latter
  cannot represent the type). Selected by `#if arch(arm64)`.
- **Lane shifts.** The paper's "previous byte" views come from `ext` on a carried block; the
  shim has `vextq_u8` wrappers too (`stream_parsing_shift_in_1/2/3`, with a portable 64-bit
  arithmetic form behind `streamBytesShiftedIn`, both pinned against the byte definition in
  `Lane shift tests`). The validator does not use them, for a measured reason below: the views
  are overlapping unaligned loads at `i-1`, `i-2`, `i-3` — the bytes are in memory — and the
  first block of a run, a run shorter than a block, and a tail shorter than a block go through a
  32 byte zero-padded scratch instead, zero reading as ASCII, which is what lies outside a run.

### Where the kernel lives, and the two shapes that lost

The first build kept the algorithm in Swift and used the shim only for the three lookups. It
worked and was fast. The attempt to *also* shift the views in from a carried block through the
`ext` shim — the paper's shape — ran **2.6x slower**, and the disassembly was the explanation:
Swift's SIMD operators are per-lane loops that LLVM's SLP vectorizer has to re-vectorize, and a
shift or compare whose result feeds a fifteen lane shuffle came out half vectorized, with lanes
14 and 15 extracted, shifted and reinserted one at a time (`umov`/`ubfx`/`mov.b`, sixteen
triples). Reordering so the shifts ran on loaded data and only flag vectors were `ext`ed moved
the damage rather than removing it. Bitwise AND/OR/XOR on shim outputs re-vectorize reliably;
shifts and compares adjacent to a partial shuffle do not. **So the arm64 block kernel is one C
function** — `stream_parsing_utf8_block_errors`, every step an intrinsic clang lowers directly;
the release function has six `tbl`, no `ext`, and not one lane extraction. The portable path in
Swift is the algorithmic reference, compare-based, with its compares on loaded views.

With the kernel in C, carried block + `ext` versus overlapping loads was measured once more, and
the loads won: **−10.5% on `Fast Non-ASCII string` bulk, −2.4% on `llm_message`**, equal
elsewhere. Three loads issue on the load ports; three `ext` compete with the kernel's own
twenty-odd vector ALU operations. The `ext` wrappers stay in the shim as tested primitives.

Both paths are `package` functions, and `UTF8ValidationTests` holds both to the standard
library's decoder as oracle: every two byte sequence, every three and four byte lead against
every second byte, truncations at every block edge, real text with one byte corrupted at every
position, thirty thousand random strings, at several offsets into a buffer so the first block,
the overlapping middle and the scratch tail each run. Every form above passed it on its first
run; the differential suite is what made the codegen experiments cheap.

The validator answers only valid or not. An invalid run is rare, so the parser's scalar walk
runs behind it to find the byte, and every error offset stays exactly where `ErrorOffsetTests`
pins it. `validateUTF8IfNeeded` keeps its two guards inline — they settle every ASCII run — and
the vector call and the walk behind it are out of line together.

### Measured

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

The ASCII documents do not execute it and do not move. `llm_message` strict is now within ~10%
of its unchecked row, which is what validation should cost on a document that is mostly ASCII.

## Unchecked mode: three flags, and only one of them was ever paying

`JSONParserConfiguration` shipped with three switches — `validatesUTF8`, `validatesNumberGrammar`,
`validatesLiterals` — and one preset, `.unchecked`, that turned all three off at once. Because it
turned them off together, nothing in the suite could say which of them was buying anything. The
answer, measured one flag at a time against strict, best of two rounds, `Payload MB/s`:

| payload | strict | noUTF8 | noNumbers | noLiterals | unchecked |
| --- | ---: | ---: | ---: | ---: | ---: |
| LLM message | 3520 | **+44.0%** | +0.2% | +0.0% | **+44.1%** |
| Twitter | 1433 | +3.5% | +0.6% | +0.6% | +4.4% |
| CITM catalog | 1971 | +1.0% | +0.7% | +0.3% | +1.2% |
| GSoC 2018 | 3681 | +0.0% | +0.1% | +0.2% | −0.2% |
| GitHub events | 1608 | −0.9% | −0.2% | −0.3% | +0.0% |
| Canada | 962 | −1.4% | −1.4% | −1.5% | +0.3% |
| Twitter escaped | 1086 | **−7.3%** | −0.1% | +0.0% | **−5.6%** |

`validatesNumberGrammar` and `validatesLiterals` are worth nothing on any payload, including
`canada`, which is the most number-dense document in the corpus. `validatesUTF8` is the whole of
`unchecked` — noUTF8 and unchecked are within 0.1% of each other on `llm_message` — and it is only
large on the one document that is 64% non-ASCII bytes.

The last row is the one that settled it: **turning validation off makes `twitterescaped` slower.**
`streamStringRunEnd`, the unchecked string scanner, was `@inline(never)` while the validating
`streamStringRun` was inlined, so the unchecked path paid a call per string run and `twitterescaped`
has 51,145 of them. A mode that exists to be faster was 7% slower on an escape-dense document.

So all three went, along with `JSONParserConfiguration`, `JSONStreamFormat.configuration`,
`streamStringRunEnd`, the `tracksNonASCII` branches in `consumeStringRun` and `consumeKeyRun`, and
`severHighSurrogate`'s unchecked half — a lone high surrogate is now unconditionally an error, so
what remains is `loneHighSurrogateError`, which returns the error and stays out of line to keep the
common path at each of its four call sites a compare against zero. 281 lines deleted, 111 added.

Two adversarial tests went with it, both pinning unchecked-only behaviour: the WTF-8 a severed
surrogate used to emit, and the guarantee that severing cleared `highSurrogate` rather than leaving
it to disable `fusedEscapeEnd` for the rest of the document. With validation unconditional the field
is either completed into a pair or thrown on, so it cannot go stale. The validating counterpart
stays. The two `streamStringRunEnd` scanner tests were retargeted at `streamStringRun` rather than
deleted.

### Measured

| granularity | representative rows | delta |
| --- | --- | --- |
| bulk | LLM 3570→3750, GSoC 3756→3844, Non-ASCII 6885→7711 | −2.2% … **+12.0%** |
| 16 KB | LLM 3552→3744, GSoC 3718→3806, Twitter 1433→1452 | **+1.3% … +5.4%** |
| 64 B | Long string 6433→6657, Non-ASCII 2117→2140 | −3.5% … +3.5% |
| 13 B | Escaped 526→567, non-ASCII 453→466 | −1.9% … **+7.8%** |
| 7 B | Escaped 421→447, structs 375→388 | −0.7% … **+6.2%** |
| 3 B | Unicode escaped 312→330, structs 259→267 | **−6.1%** … +5.8% |
| 1 B | Escaped 209→166, Unicode escaped 282→175, LLM 165→140 | **−13% … −38%** |

`llm_message` gains 6% from deleting the option that used to make it 44% faster: the branches cost
more than the branch was worth.

**The regression is at N=1 only, and it is the `parse` inlining cliff, not the validation.**
Removing the `configuration` field flipped an optimiser decision: HEAD emits four `parse` bodies
totalling 441 instructions with the token consumers inlined, and this emits sixteen totalling 1192,
each smaller because `parse` now calls out to `consumeStringRun`, `consumeNumber`,
`consumeUnicodeDigit` and `consumeKeyRun` — twenty `bl` in the body. Byte fed runs `parse` once per
byte, so it pays one call per byte; `Fast Unicode escaped string - byte by byte` is the worst row at
−37.9% and is exactly the one that now calls `consumeUnicodeDigit` per hex digit. By three bytes per
chunk the effect is gone, and byte fed was already 27x off bulk on the same document before this
change. Forcing the consumers back with `@inline(__always)` was tried and made it worse — `parse`
grew from 291 to 625 instructions and gained calls — so it was reverted.

`Fast Unicode escaped string` is the one payload negative at every granularity (−2.2% bulk, −3.5%
at 64 B), and that is unexplained.

---

## The dead-code pass: what nothing was calling

An audit over every declaration in `Sources`, cross-referenced against the library, the tests, the
benchmarks and `EmbeddedSmoke`. Nothing here was a judgement about whether the code was good; the
question asked of each declaration was only whether anything reached it. 309 lines deleted,
13 added.

Two whole files. `Internal/UTF8State.swift` was Bjoern Hoehrmann's DFA decoder plus its two 128
byte tables, left over from the registration-based parser — the new parser validates in vectors
(`streamValidateUTF8`) and walks scalars only to report an error offset. `Internal/String+Capitalized.swift`
was a `StringProtocol` helper for a macro that lives in a different target and could never have
imported it.

The lane-shift shims. `streamBytesShiftedIn`, its arm64 and portable halves, and the three
`stream_parsing_extq_u8_*` wrappers in the C header were the *rejected* half of the UTF-8
validator: the section on it records that carrying a block forward with `ext` measured 10% slower
than overlapping loads, and the shipped kernel takes the loads. What remained was a `package` API
with no caller and a `Lane shift tests` suite whose only subject was itself — a differential test
between two implementations of an operation the library does not perform. The measurement that
settled it stays in the C header's comment, which is the part worth keeping.

Twenty-one ASCII constants (`asciiPipe`, `asciiTrueStart`, `asciiUpperX`, …) and the five `UInt8`
predicates that were their last readers: `hexValue` (the parser has its own static one),
`digitValue`, `isLetter`, `isAlphaNumeric` and `isWhitespace`. The predicates were the interesting
part — `isWhitespace` is a four-way switch, and the structural run classifies whitespace in
vectors precisely so it never asks a question like that per byte.

Four pieces of public surface with no caller anywhere, including the docs: `NumberInfo.isExactInteger`,
`StreamSinkFailure.Reason.capacityExceeded` (no sink ever reports it; the parser's depth cap is a
`JSONParsingError`, not a sink failure), and `PartialsStream.nextSnapshot(_:)`'s two overloads,
which contradict the reason `next(_:)` returns nothing — "returning a value is the same thing as
asking to keep one, and that costs a snapshot."

### Two protocol requirements

`StreamStringConvertible.streamReserve(utf8ByteCount:)` was never invoked through the protocol, and
could not be: the parser learns a string's length by reaching its closing quote. The requirement,
its empty default, and the `String`/`Data`/`Tagged` implementations are gone. `StreamString`'s own
`streamReserve` stays as a plain method — its interpolation initialiser calls it with
`literalCapacity`, which is a length known in advance, from a caller that is not the parser.

`StreamParseSink.string(_:)` was the harder call, because it was not left over — it was ahead.
The collapsed form and its fan-out default were built for a parser that would emit a whole string
in one call, `PartialSink` overrode it, three benchmark sinks implemented it, and "whole-string
emission" sat on the open-candidate list through the keys-in-place and colon-fusion rounds without
ever being taken. `EmbeddedSmoke` had already caught the gap the other way round, from a sink that
counted strings only in the collapsed form and counted zero. Kept, it is a requirement every
conformer must consider for a call that has never happened; the sink protocol's own measurement —
`Layer LLM message bulk - counting sink` p50 −5.8% from dropping the key trio, on code layout
alone — is a reason to prefer the smaller protocol. So it is removed, and the direction is
recorded here instead: if whole-string emission is built, the requirement comes back with it,
and the reason to add it will be a benchmark rather than a shape.

---

## Cheap first tiers: one of three landed, and the census said which

Three scanners are handed the *chunk* end rather than the run end -- `streamStringRun`,
`streamNumberRunEnd`, `streamWhitespaceEnd` -- because finding the run end is what they are for.
None of them can dispatch on length, so the only hybrid shape available is "try cheap, continue
wide": one general-register pass that resolves the common short run and falls into the existing
vector body when it does not. The scanners that take a real extent (`streamHashBytes`,
`streamBytesEqual`, `streamCompareBytes`, `streamAccumulateDigits`) already do this and were left
alone -- a six byte key skips `streamHashBytes`'s block loop today.

A census over the eight corpus documents sized each tier. Spans as the scanner receives them,
excluding those the existing one-byte peel already resolves:

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

All three were built behind a harness that patches a pristine copy of this file, so the control is
byte-identical to HEAD rather than merely equivalent. That mattered: a first attempt that toggled
the tiers by commenting them out left two dead locals behind, which was enough to flip an inlining
decision and grow `consumeStructuralRun` 481 -> 567 in the *control*.

### Landed: two bytes of bitmap test in front of the whitespace vector body

Absolute `Payload MB/s`, p50, three interleaved rounds against a byte-identical HEAD control:

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

`Fast Pretty printed users` +13.7%. No row regresses by more than 1%. The three flat documents are
the three with almost no whitespace outside strings: `canada` has **eighteen** whitespace runs in
2.2 MB, and `llm_message`'s whitespace is all inside string values where this never runs.

The win is there because the width test in `streamWhitespaceEnd` never fires under bulk input --
the bound it reads is the chunk end, not the run end -- so every whitespace run reaches the vector
body, and pays four constant splats, a 16 byte load, six vector operations and a `uminv` cross-lane
reduction plus its transfer to a general register, in order to find a terminator at lane 1.

**What the peel resolves is the one-byte run, and only that.** With a bound of two, a one-byte run
tests byte 0 (whitespace, advance) and byte 1 (not whitespace, return); a two-byte run consumes
both peeled bytes without meeting a terminator and reaches the vector body anyway. So the gain is
proportional to the share of length-one runs, which is what the census measures:

| document | ws runs | len 1 | len 2 | >= 3 | median | gain |
|---|---:|---:|---:|---:|---:|---:|
| mesh | 73,024 | 100% | 0% | 0% | 1 | +6.0% |
| twitter | 28,826 | 46% | 0% | 54% | 7 | +7.2% |
| github_events | 2,526 | 45% | 0% | 55% | 5 | +11.2% |
| gsoc-2018 | 41,713 | 45% | 0% | 55% | 5 | +13.4% |
| citm_catalog | 76,337 | 34% | 0% | 66% | 21 | +6.9% |

**Runs of exactly two do not occur** -- a separator is one byte and an indent is a newline plus its
depth -- so widening the peel buys no new population until four, by which point `citm_catalog`'s
long runs make it negative. That is why the bound is two and not a compromise: at four
`citm_catalog` paid -3.3% and at eight -10.0%.

**It is two tests, so it is written as two tests.** Spelled as a bounded loop it did not unroll:
eight instructions an iteration plus the `min` for the bound and the materialisation of the
bitmap constant, so a one-byte run paid about twenty-three instructions and two loop-latch
branches. Straight-line it is about fourteen ending in a direct `ret`. The whole function is
larger (73 instructions against 69) and every affected document is faster for it -- most sharply
`citm_catalog`, which calls this 76,337 times and went from +0.5% to +6.9%, and `gsoc` from
+10.3% to +13.4%. Two rows regressed under the loop form; none do under this one.

It sits in the out-of-line `streamWhitespaceRunEnd`, not in the inlined `streamWhitespaceEnd`
guard, for the reason that section already documents: peeling a one byte run inline was measured
at -18% on `twitterescaped` and -34% on unicode escapes, documents with no whitespace at all.

`streamWhitespaceRunEnd` also had **no direct test coverage** -- both existing whitespace tests use
buffers under sixteen bytes, so both take the scalar path and neither ever reached the vector body.
A bitmap mutation that dropped tab passed the whole suite. Two tests were added (every byte value
at every position of a 32 byte run, and a naive-oracle sweep over lengths and offsets, both
checking the guarded and vector entry points) and the mutation now fails with 31,734 issues.

### Rejected: a SWAR first word in front of the string scanner

Median -0.4%. It does what it was meant to on short runs -- `Fast Escaped string` **+38.5%** bulk
and +23.5% at 64B chunks -- but `Fast Long string - 64B chunks` measured **-35.5%** and
`Fast Dictionary` -9.7%/-10.5%, and the real-world documents were flat to slightly negative
(`gsoc` +1.0%, `github` +1.6%, `twitter` +0.4%, `citm` -0.4%, `llm_message` -1.4%).

The reason is a gap the census does not show directly: **the tier helps runs of eight bytes or
fewer and actively hurts runs of nine to sixteen**, which previously cost exactly one vector block
and now cost a word *and* a block. A thirteen byte key -- which is what `Payloads.counts` is made
of -- is the worst case, and a 64 byte chunk of one long string is the same story, because
consuming eight bytes leaves 56 that no longer divide into whole blocks. The corpus has plenty of
both sizes, so the two halves cancel.

### Rejected: a bitmap peel in front of the number scanner

Median -1.0%, mean -2.5%: `canada` **-11.7%**, `mesh` -10.3%, `Nested arrays` -7.3%,
`citm_catalog` -4.9%.

`canada` was the predicted counter-case -- none of its 111k numbers are under eight bytes, so
every peeled byte is tax. `mesh` was not predicted, and it is the more useful failure: 58% of its
numbers are under eight bytes, but its *median is four*, and a peel bounded at four never sees the
terminator of a four byte token -- it sits one past the end. The tier only pays on tokens of three
bytes or fewer, and the documents that have those (`twitter`, `github_events`, `llm_message`) are
exactly the ones where numbers are a negligible share of the parse.

If the number scanner is revisited, the better lever is the one the C experiment measured and did
not land: the `umov` ladder that finds the first non-class lane runs up to sixteen `umov`/`cbz`
pairs, and `citm_catalog`'s nine byte numbers and `mesh`'s four byte numbers pay ten and five of
them respectively. A `vshrn_n_u16` movemask reduces that to `rbit`/`clz`/`lsr` and would be a
*small* leaf shim returning a scalar, not a whole kernel returning a struct -- which is the shape
that survived in `stream_parsing_utf8_block_errors` and the shape that did not in the
`streamStringRun` port.


## Porting `streamStringRun` to C: the kernel got better and the parse got slower

The string scanner was rewritten as a C kernel in `StreamParsingShims` and **measured, rejected,
and reverted** (2026-08-22). Nothing from it is in the tree. The reasoning that motivated it was
sound and two of its findings are worth keeping, so both are here with their numbers.

### Why it looked promising

Two properties of C that Swift does not offer, both confirmed before any benchmark ran:

- **A `static inline` C function is bodiless in SIL.** `swiftc -O -emit-sil` on a call to
  `stream_parsing_utf8_block_errors` shows `sil shared [clang ...]` with no body and one `apply`
  at the call site. The whole NEON kernel costs the SIL performance inliner one `apply` of budget
  and is expanded later by LLVM's AlwaysInliner. That is exactly the lever the `@_transparent`
  finding in the number-tail work and the `parse` inlining cliff were both missing.
- **Immediate-taking NEON intrinsics are unreachable from Swift.** `vshrn_n_u16` does not import
  at all (`cannot find 'vshrn_n_u16' in scope`); through a C wrapper it compiles to exactly
  `shrn.8b` + `fmov`. This is the arm64 movemask, and it is the idiom every first-hit-lane problem
  in this file has been working around: `uminv` reductions and per lane `umov` ladders were the
  only two options Swift had.

The port used it. One `shrn` per block answers both "does this block end the run" and "where", so
the loop test costs what `umaxv` + `fmov` cost before and the hit path gets the lane in a general
register for free. Disassembly confirmed the intent: the hit path's serial
`bsl` -> `uminv` -> `dup` -> `cmhi` -> `and` -> `orr` -> `umaxv` -> `smov` chain became two short
independent chains, and the lane-index constant vector that the register allocator had been
spilling to the stack and reloading on every hit disappeared, shrinking `consumeStringRun`'s
frame from 0xb0 to 0x90.

**The kernel really is better, in isolation.** Standalone C harness, 8 KB of ASCII runs of a fixed
length, best of 180 passes, MB/s:

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

Movemask beats the `uminv` shape it replaced by 8-10% at the 16-32 byte lengths that matter most.

### What it cost, and the experiment that found out why

Four interleaved rounds, 34 rows, p50 `Payload MB/s` against a Swift control built from the same
working tree (the control's `consumeStringRun` disassembles mnemonic-for-mnemonic identical to
HEAD except one redundant `mov`, so the harness is sound):

Real-world documents were **flat** -- GSoC bulk +1.7%, LLM message bulk +1.3%, Twitter +0.1%,
CITM 0.0%, Canada +0.5%, GitHub bulk -3.0%. The synthetic string rows were not:
`Fast Non-ASCII string - 64B chunks` **-37.8%**, `Fast Dictionary - 64B chunks` **-15.2%**,
`Fast Long string - byte by byte` **-21.8%**, `Fast Escaped string - 64B chunks` -8.5%. Median
across all rows -0.5%. Bulk rows flat, chunked and byte-fed rows uniformly worse across payloads
that share nothing -- which is the signature the inlining-cliff notes describe, except that
`JSONParser.parse`'s specialisations were byte-identical to the control's, so it was not that.

Two wrong attributions, both disproved by measurement rather than argument, and the second is the
finding worth keeping:

1. **`consumeStructuralRun` grew 481 -> 581 instructions**, and the obvious story was that
   `always_inline` had forced the vector body into the structural dispatcher. It had: the control
   calls `streamStringRun` **out of line** from `consumeStructuralRun` while inlining it into
   `consumeStringRun` and `consumeKeyRun` -- Swift's `@inline(__always)` is a hint the SIL inliner
   weighed and *declined* at exactly the site where declining was right, and C's `always_inline`
   is a directive that cannot decline. Spelling the refusal out by hand (an `@inline(never)`
   wrapper at that call site, the same arrangement `streamWhitespaceRunEnd` already uses) restored
   `consumeStructuralRun` to exactly 481 instructions. **The regressions did not move.** Real, but
   not the cause.
2. **The cost is the Swift/C boundary itself, not the kernel.** A variant transliterating the
   control's *exact* algorithm into C -- `vmaxvq_u8` for `any`, `bsl` + `vminvq_u8` for the lane,
   a lane select for the non-ASCII prefix, no movemask anywhere -- regressed essentially
   identically: `Fast Non-ASCII string - 64B chunks` -39.3% against the movemask kernel's -39.3%,
   `Fast Dictionary - 64B chunks` -12.1% against -14.0%. Whatever is being paid is paid for
   crossing into C, and no choice of kernel avoids it.

The 16-byte struct return (`{intptr_t end; _Bool contains_non_ascii;}`) is a large part of it, but
replacing it does not help on balance: packing the two fields into one word moved
`Fast Non-ASCII string - 64B chunks` from -38.7% to -8.1% and `Fast Dictionary - 64B chunks` from
-15.5% to -4.1%, while costing the rows dominated by call frequency instead -- `Real Twitter -
bulk` -0.3% -> -6.4%, `Real LLM message - bulk` +1.9% -> -5.0%, `Fast Escaped string - 64B chunks`
-9.3% -> -17.9%. No return representation was free.

### What this says about porting kernels to C generally

- **A C kernel cannot participate in Swift's per-call-site inlining decisions.** The SIL inliner
  was making a *correct* refusal in `consumeStructuralRun` that `always_inline` overrides.
  Dropping `always_inline` does not restore the choice either -- LLVM inlines a small leaf
  function anyway (579 instructions against 581). Every site where Swift was declining on purpose
  has to be re-declined by hand.
- **Reach for C for capability, not for speed.** The one unambiguous win is expressing something
  Swift cannot say at all -- `vqtbl1q_u8` and `stream_parsing_utf8_block_errors` earned their
  place that way, and `vshrn_n_u16` would. Moving a kernel Swift *can* already express, to get
  better codegen for it, pays a boundary cost that swamped a kernel measured 8-10% faster in
  isolation.

### The two questions this was built to answer

**Do approaches that failed on Swift codegen succeed in C?** The codegen failures vanish; the
approaches still fail. The 2x unroll of the string scanner was rejected in Swift against three
traps -- `any()` on a composed mask lowering to a real `bl`, a de-inlined `simd_reduce_min`, and
`vector[runtimeIndex]` becoming `str q` plus a reload. In C none of them exist: it compiles to
`ldp q5, q1` for both loads, ten vector ops, one composed `orr`, and a **single** `shrn`/`fmov`
reduction per 32 bytes -- 19 instructions per 32B against 15 per 16B, with zero `bl` and zero
vector spills in the whole function. It still loses: median -1.5% in the parser, and the table
above shows it slower than plain SIMD16 at *every* run length below 256. The Swift-era conclusion
that "the unroll itself is worth only ~+2-3.5%, which does not cover it" was if anything generous.
**The traps were a red herring; the approach was always the problem.**

**Does SIMD always beat SWAR in C?** No -- the crossover is around 40 bytes of run length, and it
is entry cost rather than throughput. SIMD16's fixed per-call cost, a cross-lane reduction plus
two NEON-to-GPR transfers on the hit path, is paid in full by a two-byte run, while SWAR's hit
path stays in general registers (`ctz`, shift, and, test). The parser rows track the table
exactly: SWAR measured **+39.3%** on `Fast Escaped string - bulk` (runs of two bytes or less),
+19.6% on its 64B-chunk row, and +2.3 to +4.7% on Twitter, CITM and GitHub, whose string values
are short -- against **-51.8%** on `Fast Long string - bulk` (one 8 KB run), -31.7% on
`Fast Non-ASCII string - bulk`, -11.9% on LLM message and -9.5% on GSoC. Median -2.3%, so it is
not a candidate as a *replacement*, but the short-run half of that split is the largest single
effect measured in this whole exercise and nothing in the tree exploits it.

Note this does not contradict the run-length table at the top of `StreamScanners.swift`, which
shows SIMD16 ahead of SWAR at every length: that one measured a *Swift* SWAR over whitespace runs,
which is a different kernel in a different language, and the two are not comparable.


## The short integer kernel: eight bytes, backwards

`emitNumber`'s digit loop is **eleven instructions per digit** in the shipped assembly -- `ldrb`,
`sub`, `and`, `cmp`, `cset`, `b.hi`, `mul`, `add`, `add`, `cmp`, `b.ne` -- not the seven the source
reads like. That is what decides where a fixed width kernel can win, and it is lower than the
earlier estimate: the crossover against a flat cost kernel is **two digits**, not five.

Digits are also the wrong axis. Measured on the synthetic rows:

| row | shape | ns/number |
| --- | --- | --- |
| `Numbers small integers` | 2.9 digits, no dot, no exponent | 9.0 |
| `Numbers large integers` | 19 digits, no dot, no exponent | 11.5 |
| `Numbers floats` | 3-6 digits, **dot + exponent** | 14.5 |

Sixteen extra digits cost 2.5 ns. A dot and an exponent cost 5.5 ns. **Segments dominate digits
roughly three to one**, because each segment is its own loop setup, and the eight digit block
carries a thirteen instruction constant preheader that is emitted once per segment.

### The kernel

`streamShortInteger` takes an unsigned integer of one to eight digits -- 0 to 99,999,999 -- with no
sign, no dot and no exponent, and returns its value with no loop and no data dependent branch. Two
choices make it work, and both are the opposite of the rejected branchless tail above:

- **It reads the eight bytes *ending* at the token, not starting at it.** Those bytes are behind the
  cursor, already consumed, in the same buffer, so a single `end >= 8` test makes the read safe. The
  rejected version read forward past the token and needed `streamPaddedWord`'s 4/2/1 ladder to bound
  it.
- **Right alignment removes the scaling step.** The masked off bytes below the token become leading
  zeros, so the eight digit tree's answer is already the token's value. The rejected version left
  aligned and needed a `pow10` switch to divide back down -- a data dependent branch, which is the
  thing that exercise set out to delete.

Eighteen hot path instructions against the rejected version's thirty five. `Numbers small integers`
is `makeMatrix(40,25)`, values 0-999, and is exactly the row the rejected version lost 12% on; this
one gains 7.4%.

**The mask must precede the bias.** Subtracting `0x30` from the whole word borrows out of any byte
below `'0'` and into the token's leading digit. `\n`, `,` and `"` are all below it, so `582`
preceded by a newline read as `482`. The differential test found this because it randomises the
prefix over hostile bytes; a suite padding with spaces or digits would not have. `ShortIntegerKernelTests`
pins it directly.

### SWAR against SIMD, and where each one belongs

Three forms were built and measured, three interleaved rounds, `Payload MB/s` p0 (the wall clock
column changes units per row and cannot be compared raw):

| row | eligible | control | **SWAR** | hybrid | pure SIMD |
| --- | --- | --- | --- | --- | --- |
| `Numbers small integers - bulk` | 100% | 444 | **477 (+7.4%)** | 461 (+3.8%) | 359 (-19.1%) |
| `Real Mesh - bulk` | 57.7% | 682 | **712 (+4.4%)** | 699 (+2.5%) | 644 (-5.4%) |
| `Real Twitter - bulk discarding` | -- | 631 | **647 (+2.5%)** | 636 (+0.8%) | 645 (+2.1%) |
| `Real Canada - bulk` (control) | 0.1% | 951 | 950 | 950 | 950 |
| `Numbers floats - bulk` | 0% | 721 | 699 (-3.1%) | 696 (-3.5%) | 681 (-5.5%) |

The pure SIMD form was not a fair test and its number should not be read as one: `SIMD8<UInt8>`'s
`replacing(with:where:)` with a **runtime** mask half scalarised into an eight lane
`smov`/`umov`/`csel` ladder, and the iota vector spilled to a constant pool. That is the trap the
UTF-8 section already records, in a new place. The hybrid -- mask in the integer domain, convert in
the vector domain -- was clean, verified free of per lane scalarisation in the disassembly, and
**still lost**:

| form | GPR/NEON crossings in `emitNumber` | crossings in the kernel | instructions |
| --- | --- | --- | --- |
| **SWAR** | 5 | **0** | **255** |
| hybrid | 9 | 4 | 269 |
| pure SIMD | 23 | 14 | 306 |

This does not contradict "SIMD8 is 7-13% better than SWAR8" from the digit block table above; it
locates it. **That comparison was the block *inside* `streamAccumulateDigits`, where the loop keeps
data in the vector domain and the crossing amortises over many blocks.** A one shot kernel on a
short token crosses in once and out twice -- the word in, the validity test and the result out --
and the token's length starts life in a GPR, which is what forced the `dup` that broke the pure
form. The rule the two results give together: **SIMD wins where the data is already in vectors and
stays there; SWAR wins where the answer is needed in a GPR and the token is short.**

### What it costs where it does not apply

`Numbers floats` loses 3.1%: 19% of its tokens are six to eight bytes, so they enter the kernel,
fail the digit test on the `.`, and take the walk anyway -- about 380 tokens at ~17 wasted
instructions, which is 3.7% of that parse and matches. `Numbers large integers` loses 2.9%
identically for every variant, which is the code layout signature, not the kernel; its tokens are
nineteen bytes and fail the length check in five instructions.

**No real payload regresses.** Both losses are synthetic rows, and `Numbers floats` is 100%
exponent bearing -- a shape that appears in **0 of 468,000** real corpus numbers.

Hoisting the shape test into `streamNumberRunEndShimmed` was considered and rejected on cost before
being built. The class bits are there for one `and` (`vtstq_u8` discards the `high & low` it
computes), but lanes past the terminator hold the *next* token's bytes -- in `[1,2.5]` the following
number's `.` is in the same block -- so the reduction must be masked to lanes below the terminator,
and that mask plus a horizontal OR (NEON has no `orv`) is ~12 instructions on the scanner's critical
path. It saves ~4 on a token that hits and ~12 on one that misses: worse in the common case. The
`uminv` idiom was already rejected in this same function for the same reason, at citm +10.5%.

### Coverage, and what is left

Every token in the real corpus falls into one of four shapes. The kernel takes the first:

| shape | corpus | who it serves | status |
| --- | --- | --- | --- |
| A, unsigned integer <= 8 digits | 20.4% | llm 100%, github 91%, twitter 78%, mesh 51% | **built** |
| B, unsigned integer 9-16 digits | 8.7% | **citm 93.7%**, twitter 12.6% | open, cheap (one more `ldr`) |
| C, signed or decimal <= 16 digits | 21.1% | **mesh 44.4%**, canada 9.4% | open, needs `tbl` |
| D, decimal 17-19 digits | 49.8% | **canada 90.6%** | open, needs `tbl2` |
| exponent, or > 19 digits | **0.0%** | nothing real | general walk |

D is half the corpus by token count only because canada is 55% of every number in it; by payload,
B and C reach further.

### B, the nine to sixteen digit integer: built, measured, REJECTED

The obvious next kernel by coverage, and it lost. `streamMediumInteger` read a second word at
`end - 16`, masked only the high one (the low word is entirely inside a token of nine or more
digits), and combined with `high * 100_000_000 + low`. Sixteen digits is 9,999,999,999,999,999, so
the combine is exact inside `UInt64` and needs no overflow check. Correct, tested, and not worth
keeping.

Three interleaved rounds against an A-only control, `Payload MB/s` p0:

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

**The selection metric was wrong, and that is the finding.** B was chosen because citm is 93.7%
eligible. But a kernel's benefit scales with tokens *per byte*, while its cost falls on every token
that probes it and declines -- so the metric is eligibility x number density, not eligibility:

| | numbers/KB | B eligible | B eligible per KB |
| --- | --- | --- | --- |
| citm | 8.3 | 93.7% | **7.8** |
| mesh | 100.9 | 4.9% | 4.9 |
| twitter | 3.3 | 12.6% | 0.4 |

citm has the corpus's highest eligibility and its *lowest* number density -- numbers are 7.3% of its
bytes -- so 93.7% coverage bought 1.4%. Meanwhile B declines more expensively than A does: mesh's
long tokens are decimals (42.3% of its tokens, nine to seventeen bytes) and 81% of `Numbers floats`
is nine to eleven bytes, and all of them now paid two loads, two masks, two biases and a digit test
*before* falling through, where A-only rejected them on one compare. **B taxed every payload whose
long tokens are decimals in order to help the one payload whose long tokens are integers and where
numbers barely matter.**

Kept from the work: `streamEightDigitWord` and `streamWordHasNonDigit`, extracted so the forms
cannot drift apart. Also found by the decline test and worth repeating as a rule -- **a `package`
kernel must enforce its own range**: the sixteen digit ceiling was originally tested only in
`emitNumber`, so the function silently wrapped on seventeen digit input rather than declining.

**A methodological failure, recorded because it nearly published a wrong result.** The first A/B
built its A-only control by replacing `if end &- from <= 8 {` with `if true {`, expecting the short
form to decline long tokens. It did not: `shift = 8 * (8 - count)` goes negative, Swift's `<<` is a
smart shift that yields 0 rather than trapping, so `keep` became 0, the digit test passed on a zero
word, and **every number over eight digits parsed as 0 while skipping the walk entirely**. The
control read `Numbers floats` at 952 MB/s -- higher than the 721 measured before any kernel
existed, which should have been the tell. The candidate had a full test suite behind it; the control
had none. **Run the test suite against the control, not just the candidate.**

### C, the decimal kernel: built, measured, REJECTED -- and the size ceiling this exposes

An integer is a decimal whose fraction is empty, so C was meant to subsume both A and B. It does,
exactly: prototyped against the corpus it covered 100% of `mesh`, `citm_catalog`, `github_events`
and `llm_message`, 90.7% of `twitter`, with zero disagreements against the structured walk over
900,000 randomised cases. It was still a large loss.

The design avoided the obvious trap. Rather than removing the dot with a `tbl` shuffle -- whose
index would depend on the dot position and token length, both general purpose register values, and
so would need the `dup` that broke the short integer kernel's SIMD form -- it **splits at the dot**:
`magnitude = integer * 10^fractionDigits + fraction`, so both halves are pure digit runs and reuse
one right aligned parser. No shuffle, no vector domain, no crossings.

One round, `Payload MB/s` p0, against an A-only control:

| row | shape | A | A+C | C only |
| --- | --- | --- | --- | --- |
| **`Real Mesh - bulk`** | 51% A / 44% C | 725 | **622 (-14.2%)** | **570 (-21.4%)** |
| `Numbers floats` | **0% eligible** | 714 | 488 (-31.7%) | 497 (-30.4%) |
| `Numbers small integers` | 100% A | 487 | 468 (-3.9%) | 348 (-28.5%) |
| `Real CITM catalog - bulk` | **94% C** | 2014 | 1966 (-2.4%) | 1983 (-1.5%) |
| `Numbers large integers` | 0% eligible | 1736 | 1647 (-5.1%) | 1647 (-5.1%) |
| `Real GSoC 2018 - bulk` | 0, control | 3867 | 3859 (-0.2%) | 3853 (-0.4%) |

**It loses on the two payloads it exists for.** `mesh` at 44% eligibility loses 14%, `citm` at 94%
loses 2.4%. No mechanism can rescue that, so the SWAR against SIMD comparison for C was never run.

`Numbers large integers` is the row that identifies the cause: it declines at the call site guard in
about five instructions and still loses 5.1%. Nothing but code size explains a payload losing five
percent to a kernel it never enters. **`emitNumber` goes from 255 to 570 instructions**, and that
body is inlined into the path every number in every document walks. C saves roughly sixty
instructions on an eligible token and charges three hundred instructions of instruction cache
footprint to every token everywhere.

### The variable that predicted all three kernels

| kernel | size added to `emitNumber` | eligible/KB on its best payload | outcome |
| --- | --- | --- | --- |
| **A**, unsigned integer <= 8 digits | +40 | 51 (mesh) | **+7.4%, +4.4%, landed** |
| B, unsigned integer 9-16 digits | +65 | 7.8 (citm) | -3.9% worst, rejected |
| C, decimal <= 16 digits | +315 | 42.6 (mesh) | **-14.2%, rejected** |

B was chosen by coverage and lost; C was chosen by coverage times density and lost by more. Neither
metric predicted anything. **Size added to `emitNumber` did.** A wins because it is a small body
that *replaces* the grammar walk for its shape rather than sitting in front of it; every larger
kernel spreads its cost across all tokens and concentrates its benefit in few.

The practical ceiling this sets: **roughly one kernel, and A is it.** Further number work has to
come out of the existing path rather than beside it -- out of lining the `.invalidNumber` error
construction, which still forces a stack frame on every number; deleting `NumberInfo.digitCount`,
written per number and read by nothing; and demoting the exponent walk, twenty instructions on the
hot path for a branch that 0 of 468,000 real corpus numbers take.

### A backward read is invisible to assertions about values

C shipped an out of bounds read past the entire test suite. `streamDigitRun` read sixteen bytes
back from its `end`, and the decimal kernel called it for the integer part with `end` at the dot --
which in `{"a":1.5}` is offset six. It read ten bytes before the buffer.

Two independent reasons nothing caught it. Every kernel unit test padded its token with a prefix
long enough to make the backward read legal, which is the one construction that cannot produce the
failing case. And the parser level tests, which do place numbers at the start of a document, read
out of bounds into memory that happened to be mapped: no fault, no wrong answer, no signal. Only a
release build with a different allocation layout segfaulted.

`NumberBufferBoundsTests` is the answer and is kept regardless of C: a number at every offset from
0 to 24, bare number documents, and byte fed against bulk so the parser's own reassembly buffer is
a third origin for the read. **It only fails under `swift test --sanitize=address`**, and that is
mutation verified -- deleting the `to >= 8` bound from the short integer kernel leaves all 453
tests green, because the out of bounds bytes are masked away before they reach the result, and
reports `heap-buffer-overflow` under ASan. A backward read that lands in mapped memory cannot be
seen by any assertion about values. CI does not currently run a sanitizer pass.

---

## Stage-1 extraction: the census and the budget

The dispatch loop's optimization horizon is one token: scan to the next byte that needs
attention, dispatch on it, repeat. The question on the table is whether shifting that horizon
to a whole chunk — one classification pass extracting quote/whitespace/structural information,
then a consuming pass that walks positions instead of scanning bytes — can beat it, and at what
window size. This section is the pre-work: what the corpora look like through that lens, and
what the extraction pass alone costs, measured before any stage 2 exists. Everything below ran
on 2026-08-23; the kernels live in `Benchmarks/StageOneLab` (a benchmark-only C target — nothing
ships from it) with rows `Stage1 *` in the suite.

The one directly relevant prior measurement — the "simdjson style structural bitmaps are
counterproductive here" microbench early in this document — tested *iterating a dense bitmap*
against testing bytes. It did not test the bits-to-indices decompression simdjson actually
ships, and it predates the parser being fast enough for scan cost to be a large share. It rules
out neither direction measured here.

### The census

One index entry per thing a consuming pass would visit: every structural char outside a string,
every unescaped quote, and the first byte of every number/literal. Per 64-byte block, over each
corpus (`Benchmarks/StageOneLab/stage1_census.py`, single-pass grammar walk):

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

Two populations. The number-dense pair would carry an index more than half the document's own
size — the old density objection, quantified. The string-heavy pair inverts it: 70–94% of their
blocks contain nothing a consuming pass would stop at, so for them the *string mask alone* is
most of the information. A sub-chunk of 64 KB or less also makes every index entry a `u16`,
halving that traffic; nothing below measures that variant yet.

### The kernel and its verification

`StageOneLab.c` is simdjson's stage 1 restated for streaming: the paper's odd-backslash-run
escape finder with a one-bit carry, quote parity via PMULL prefix-XOR, the nibble-table
classifier (`tbl`), the NEON movemask, and 8-at-a-time bits-to-indices — plus what simdjson
never carries: in-string/escape/scalar state flowing across window boundaries, and no padding
(a short tail block is memcpy'd into a whitespace-padded scratch, bits past the end masked).
A Swift scalar reference with identical semantics checks the kernel at registration over all
eight corpora, 130 backslash runs of every parity crossing the 64/128-byte boundaries, and 500
seeded byte-soup buffers, each at whole-buffer and 64/128-byte windows; a mismatch traps before
any row runs. One shared quirk is pinned there: the nibble tables classify NUL as whitespace,
which a real stage 2 must reject itself.

### The budget: what stage 1 costs against the parser it would tax

p50 Payload MB/s, same session; "tax" is the share of the current parser's whole time budget
the pass would consume (`Real <name> - bulk` is the comparator).

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

The string mask runs at effective memory bandwidth and is corpus-independent. Full masks are
flat at ~8.6 GB/s — the classify work is per block, not per token. Extraction is what varies:
it tracks entry density, from 7.4 GB/s on llm_message down to 4.0 on canada/mesh.

What the arithmetic rules out immediately: a full structural index on the string-heavy corpora.
On gsoc-2018 the index pass alone consumes 64% of the parser's entire current budget — a stage 2
would have to walk 110 K positions in a third of the time the current parser takes to do
everything. The full simdjson shape is dead on that population, and not marginally.

What it leaves alive, sharply: the number-dense pair. On canada and mesh the index costs 18–22%,
which leaves stage 2 ~80% of the current budget — and those are exactly the corpora where known
token extents unlock work the dispatch loop structurally cannot do (batching Eisel–Lemire
multiply chains across numbers for ILP). The bar is "beat the current number path by ~27%", and
2.2× kernels have come out of that path before. The string mask as a *substrate* (tier 1, 3–9%
tax on the slow corpora) stays alive too, but on notice: whatever it simplifies in the
structural walk has to buy back its tax first.

### The window sweep, and what the L1 hypothesis actually earned

The prediction was that a second pass over a whole-document chunk re-reads from L2/L3 while a
sub-chunk-sized window keeps it in L1, so extraction should interleave with consumption per
sub-chunk. Measured with a synthetic stage 2 (load one byte per index entry, interleaved per
window — a *lower bound* on real consumption traffic), p50 MB/s:

| corpus | 512B | 4KB | 32KB | 256KB | whole |
| --- | ---: | ---: | ---: | ---: | ---: |
| canada | 3,379 | 3,549 | **3,637** | 3,499 | 3,441 |
| citm_catalog | 4,599 | 4,883 | **5,115** | 4,971 | 4,911 |
| gsoc-2018 | 5,391 | 5,751 | **5,855** | 5,691 | 5,603 |
| twitter | 3,557 | 4,395 | **4,651** | 4,471 | 4,431 |

The shape is the same on all four: 32 KB wins everywhere, whole-document costs 4–6% against it,
and 512B costs 5–24% — per-window overhead (the carry round-trip and the call) eats the
locality gain long before L1 pressure matters. So the hypothesis was directionally right and
quantitatively modest: these corpora top out at 3.2 MB, which sits entirely inside this
machine's 12 MB L2, so "whole chunk" never actually reaches memory — the sweep measured
L1-vs-L2, not L1-vs-DRAM. Two consequences: sub-chunking at tens-of-KB is free structure (it
also buys the u16 index and a fixed scratch), and the penalty for full-document extraction
would grow, not shrink, on documents larger than L2 — but nothing measured here shows the
cliff, and claiming one without a >12 MB payload would repeat the exact mistake the whitespace
discovery section documents.

### What this stage of the experiment decides

Ruled out: full-index two-pass as the *general* architecture (gsoc/llm taxes are unpayable),
and 512B windows. Ruled in for a vertical slice: tier 2 + batched number parsing on the
number-dense corpora, at a 32 KB window, where the budget leaves stage 2 ~80% of current time.
Undecided, needs the slice: whether tier 1's string mask pays for itself as a substrate under
the existing structural walk, and how a real consuming pass (which reads token bytes, not one
byte per token) moves the sweep. The byte-fed path is untouched by construction — any of this
would sit behind a chunk-size gate at `parse`, and the gate lives out of line of both loops.

## The windowed walk: first pass

Built as planned after the section above: stage 1 graduated into `StreamParsingShims`
(`stream_parsing_index_window`: u32 chunk-relative positions plus two per-block bitmaps,
`needs_scan` for a backslash or a control byte inside a string and `non_ascii`), and a
consuming walk in `Fast/JSONParserWindow.swift` behind a chunk-size gate in `parse`. The gate
defaults to off (`windowThreshold: .max`). The dispatcher is untouched: `consumeStructuralRun`
and `consumeNumber` are byte-identical in size against HEAD, `consumeStringRun` and
`consumeKeyRun` moved by one 16-byte alignment slot. Getting the gate to cost nothing took two
tries. The compare in front of every byte measured -3 to -6% on the byte fed rows. Moving the
bulk loop out of `parse` into a shared `parseIncremental` so `parse(byte:)` could skip the
gate fixed those and cost canada bulk -4% over four interleaved rounds, with the loop body
1160 bytes against 1168 — nothing in the code, everything in where it landed. The shape that
measured clean everywhere (canada +0.1%, mesh +0.3%, byte fed 0 to +3.6%) keeps the loop in
`parse` behind the gate and has `parse(byte:)` drive `dispatchOnce`, the loop's body, itself.

### The seam, and the bug it had first

A window starts only in a structural state with nothing buffered, so the indexer needs no
carried state. The walk hands a token back to the dispatcher in three cases — a string whose
closing quote is past the window, a number or literal that reaches the chunk's end, and a key
with an escape — and the dispatcher takes exactly one step. The first version re-indexed a new
window from the handed-back position and hung: a cut string at the chunk's end is handed back
in a structural state, so it was indexed and handed back again forever. The fix is the shape
that should have been obvious: a hand-back forces one `dispatchOnce`, and the walk then
*resumes in the existing index* at the first entry past the dispatcher's cursor. The index is
the truth about positions regardless of who consumed the bytes.

### Correctness

`WindowedParserTests` records every sink event (spans copied, number info, the error if any)
and compares the dispatcher against the windowed path at the *same* chunking — bulk, 64, 100,
1000, 32 KB and 40 KB chunks — across 58 documents covering every error reason, strings longer
than a window, numbers on the window boundary, invalid UTF-8 at several depths, and a rejecting
sink for every event kind. The oracle had to be the same chunking: a byte fed run emits one
string chunk per byte, so it is not a reference for a bulk run. `StageOneIndexTests` pins the
kernel against a scalar reference, including NUL (now a scalar, rejected by the walk, instead
of whitespace as simdjson's table has it). Full suite green, 475 + 28 tests.

### The measurement

Interleaved against a HEAD worktree, three rounds, best p50 MB/s:

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

The last two columns are the decomposition (windowed time = index time + walk time, with the
index time taken from the `Stage1 Index` rows), and they invert the hypothesis this experiment
was built on. The walk consumes the structure-heavy corpora 25-37% faster than the dispatcher
— the positions walk really is cheaper than the scan-and-dispatch loop where there is structure
to dispatch on — and loses every bit of it to the index tax. On the number-dense corpora the
walk is *not* faster at all: canada's profile is walk self time 38%, `emitNumber` 37%, indexer
25%, against the dispatcher's `emitNumber` 42%, `consumeStructuralRun` 26%, `consumeNumber`
25%. The dispatcher's fused comma path is already a tight number loop with no structural
dispatch in it, so known extents buy nothing there, and the index is pure cost. The budget
section above picked canada and mesh as the promising pair because it assumed a stage 2
uniformly faster than the dispatcher; the corpora where that is true are the ones whose
index is most expensive.

### What this decides, and what it leaves open

The plain walk fails the floor the plan set (parity on canada/mesh) and lands on the branch
gated off, where it costs nothing. What it establishes is that the lever is the index, not the
walk: full masks run at 8.6 GB/s and the index at 4.0-5.6, so extraction is roughly half of
stage 1, and the block kernel spends six movemasks per block where the two flag bits could be
an OR-reduce. CITM needs the index under ~29% of dispatcher time to break even, i.e. about
7 GB/s from today's 5.6. Batched Eisel-Lemire remains the only lever on canada and would have
to recover the whole 16%, which its 37% `emitNumber` share makes unlikely on its own. The
windowed rows stay in the suite so the next round measures against these.

## Index cost: three moves, and what each one bought

The first-pass table above said the lever was the index, not the walk, and named three moves.
All three were built in sequence, each measured before the next, with the differential suite
as the gate. Numbers are p50 MB/s from two-round runs against the previous build (drift
reference: the dispatcher rows in the same runs, all within ±1.5%); the final table is a
fresh three-round interleaved A/B against HEAD.

### The extraction loop was not unrolled

The review asked whether the bits-to-indices loop could be unrolled. The assembly said it
never had been: the counted `for (i < 8)` compiled to a twelve-instruction loop with a taken
branch per index — two `rbit`s in the whole 464-instruction kernel. Spelled out as eight slots
it is six instructions per index and no branch; sixteen `rbit`s now. Alongside it the
non-ASCII flag became a `vmaxvq` reduce on the raw vectors (no compare, no movemask), since
the walk only ever asks whether, never where.

### Move 2, first form: the gap check — REJECTED as built

Numbers and literals stopped being indexed; the walk skipped whitespace from its cursor before
every entry and treated a byte short of the entry as a scalar (value state) or an error.
Correct, and canada gained +10% from a third fewer entries. But CITM lost 13% and mesh 8%:
the skip is `streamWhitespaceEnd`, and on pretty-printed input nearly every entry has
whitespace after it, so the walk ran a vector scan per entry over whitespace that the index
used to absorb for free. The census had said this: citm is 71% whitespace, mesh has a space
after every one of 73 K commas.

### Move 2, second form: index a scalar only when whitespace precedes it

`scalar & (whitespace << 1)`, with a one-bit carry. Then any gap that *begins* with a
whitespace byte is pure whitespace — a non-whitespace byte after whitespace would be an entry
— so the walk's gap check is one load and one compare, never a scan; a scalar directly after
a structural byte sits at the cursor and is found there. Minified numbers cost no entry,
pretty-printed ones cost what they always did.

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

Mesh is the one loss and it is not yet explained: its numbers all follow a space so they are
entries as before, and inlining the scalar path (the first suspect) measured exactly 0.0%.
Open. The bug found on the way is worth its line: a block whose only quote is at bit 0 has a
prefix-XOR of all ones, so "all inside a string" must test `quote == 0` too, or the opening
quote is dropped. The byte-soup reference caught it on the first run.

### Move 1: the two-speed block

Quote and backslash masks first; if the block is string interior edge to edge, its two flags
come from `vminvq`/`vmaxvq` reduces and it skips the table lookups, the structural and
whitespace movemasks, and extraction. gsoc-2018 windowed +14.3%, llm_message +18.9%, every
other corpus within ±1.4%. The kernel is now 4 movemasks per full block (was 6) and 2 per
interior block.

### Move 3: routing sparse windows to the dispatcher

Entries per block of the last indexed window below 3 sends the next window through
`dispatchOnce` steps, bounded by where they stop rather than what they scan (so a string
crossing the span still arrives as one chunk); every eighth window is indexed regardless.
gsoc-2018 and llm_message land at −5% against the dispatcher, from −34/−39% at the first pass.

### Where it stands, against HEAD (three rounds, interleaved)

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

Gate off, every dispatcher row is within ±1% of HEAD and the byte fed rows are +1.5%; the
dispatcher's functions are byte-identical in size. Window size is not a variable any more: a
16 KB window measured within ±1% of 32 KB on every corpus with the real walk. Which makes the
mesh row the open question: the same document windowed through 16 KB *chunks* runs at 712
against 619 in bulk, and it is not the window length. Unexplained, and next.

The shape of the table is now the census's shape exactly: the walk wins where structure is
dense and strings are short (github: 6.4 entries/block, 10-byte strings), breaks even on
twitter, and loses a bounded 4–6% everywhere else, where that bound is the routing's probe
cost plus the index tax on windows the walk consumes no faster than the dispatcher.

## Shape loops: the walk stops being a state machine

The index-cost round ended with the walk consuming structure-dense corpora faster than the
dispatcher but replaying its state machine token by token everywhere else: one entry, one
`(state, byte)` switch, one state write, one `checkSink`, and on numbers a `streamNumberRunEnd`
scan for an end the index already held one slot over. Known extents were being used to find
the next byte faster, not to do less. Shape loops are the version where the machine goes away
for the length of a run whose shape the index makes visible in advance.

Both loops live in `Fast/JSONParserShapes.swift`, out of line, entered from one arm of the walk
each, and both are speculative: an element is pattern-checked from the index before any sink
call or state change for it, and the first off-pattern element returns to the walk at a
position the walk understands (just after a `[`/`,`/`{` in the matching state, or at a
separator in `.afterValue`). The loops never throw a grammar error themselves — every
malformed byte is the walk's, whose errors are the dispatcher's — and they emit only through
the walk's own emitters. That is what let the differential suite stay the oracle: 35 new
documents (nested numeric pairs, arrays that stop being numeric mid-way, members with container
values and escaped keys mid-object, every malformed variant, and both shapes straddling a
32 KB window), zero changes to the reference.

### Numeric array subtrees

Per element: one byte test on the element's first byte, one on its separator, `emitNumber` on
the extent `start..<separator` with no scan. `emitNumber` validates on both its paths before it
calls the sink, so an extent it rejects — `2x,` or `1 ,` — falls back with nothing emitted, and
the walk's scanning path re-parses it and reports the dispatcher's reason at the dispatcher's
offset. Nested arrays stay in the loop (Canada's `[x,y]` pairs). Measured against the committed
baseline, two rounds: Canada windowed 893 → 1,118 (+25%); Mesh 619 → 643 (+4%).

Mesh's small gain was a seam bug the profile named: `consumeGapScalar` 175 samples against the
loop's 33. The loop was entered only at `[`, and Mesh's arrays are thousands of elements long,
so after the first window boundary the walk resumed mid-array with no `[` to re-enter on.
Canada's two-element arrays re-enter constantly, which is why it never showed. Entering from
the walk's comma arm inside an array too — `first` derived from the state, since `[1,]` must
still fail — took Mesh to 949 (+50% on the step, +29% over the dispatcher) and Canada to 1,180.

### Object members with scalar values

Per member: three loads at known offsets (quote, quote, colon), the key emitted in place, then
the value by its first byte — clean string, number, literal — and the separator. Four state
transitions become straight-line loads. A container value, an escaped key or string, or
anything malformed falls back at the key or the separator; the walk handles it and re-enters
the loop at the next comma. Two rounds against step 1: GitHub 2,073 → 2,513 (+21%), Twitter
1,464 → 1,832 (+25%), CITM 1,888 → 2,131 (+13%), Twitter escaped 952 → 1,055 (+11%).

Step 1 had cost the object corpora ~3.5% — a call and two loads at every `[` — which step 2
buried; it is noted because the pattern test's cost on non-matching structure is real and
would show again on a corpus of small non-numeric arrays.

### Where it stands, against HEAD (three rounds, interleaved)

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

Gate off, every dispatcher row is within ±0.6% of HEAD and the byte fed rows are +2.2% / 0%;
`consumeStructuralRun`, `consumeNumber`, `consumeStringRun`, `consumeKeyRun` and `parse` are
byte-identical in size to the previous round, and `consumeWindow` shrank by 12 bytes.

The table is now the hypothesis this experiment opened with, confirmed on the corpora it was
made for: the number-dense pair that the first pass measured at "no gain" is +27–29%, because
the walk finally uses extents to do less rather than to scan faster. The four losses are the
string-heavy population, at the bounded 3–6% the routing round left them, and CITM, which
sits on the line (it measured +4% in the two-round step comparison and −4% here; it is 71%
whitespace and its members are short, so the pattern test's cost and the member loop's saving
are the same size). Mesh through 16 KB chunks is the one row that moved the wrong way against
its bulk form (+4% against +29%): every chunk cuts an element, and the seam hands the cut
number to the dispatcher, whose `fuseAfterValue` then carries on through the following
elements before the walk gets the array back. Cheap to fix — the walk can take a `.value`
state back at the next comma — and next.

Open, in order: interleaved digit accumulation for consecutive numbers (Canada's profile is
`emitNumber` 45%, the indexer 22%, the loop 14%); the Mesh-through-chunks seam; and CITM's
line, which a cheaper pattern test or a member loop that also takes container values would
settle.
