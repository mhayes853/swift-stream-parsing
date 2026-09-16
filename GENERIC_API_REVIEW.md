# Generic API review

Scope: the public raw sink/batch surface, typed stream drivers, conversion protocols and
schemas, streaming collections and text algorithms, and supported-type integrations. This
is a review above the JSON scanning kernels, not a new parser-conformance audit.

## Existing surface

| Area | Available behavior |
| --- | --- |
| Raw events | `StreamParseSink`, whole/chunked strings, number tokens plus `NumberInfo`, advisory subtree skipping, commit boundaries, batching and replay |
| Typed streams | `PartialsStream`, snapshots, borrowed views, consuming finalization, allocation reuse/reset, synchronous byte/chunk collection, single-subscriber async partials |
| Conversion | Initial values, strict partial-to-value conversion, recursive defaulting, raw-representable enums, custom string/number/boolean/null conversion |
| Collections | `StreamArray` with random access, mutable elements and range replacement; insertion-ordered `StreamDictionary`; bridging to standard arrays and string-keyed dictionaries |
| Text | Blocked `StreamString`, bounded `StreamInlineString`, UTF-8/scalar views, character iteration, bytewise comparison/search, prefix/suffix checks, interpolation and Codable |
| Standard types | Signed/unsigned integer widths including availability-gated 128-bit types, Float/Double, Bool, String, Optional, arrays and string-keyed dictionaries |
| Fixed storage | `InlineArray` and SIMD2/3/4 with exact JSON arity checks |
| Optional integrations | Foundation Data (decoded string UTF-8, not base64), Decimal, PersonNameComponents; CGFloat; Tagged; swift-collections initializers/bridges (not general parseable conformances) |

Dictionary equality is intentionally insertion-order-sensitive, string equality/search is
intentionally bytewise, and assigning nil to the streaming dictionary subscript is explicitly
documented as a no-op. These are surprising differences from standard types, but not accidental
bugs by their current contracts.

## Trivial fix

`AsyncPartialsSequence.AsyncIterator.next()` must terminate after **any** thrown error.
Previously a parse failure could consume further upstream input and throw again, an upstream
failure could be followed by JSON finalization, and a rejected subscriber threw repeatedly.
The fix shares a terminal flag across iterator copies and sets it on every error path. The
owning iterator remains independent of a rejected subscriber's termination.

Regression coverage includes parser failure, upstream cancellation error, finalization failure,
rejected subscribers, copied iterators, and successful completion. This follows the
[AsyncIteratorProtocol contract](https://developer.apple.com/documentation/swift/asynciteratorprotocol).

## Bugs for discussion

1. **Resolved in the COW follow-up: branching collection mutation overwrites shared storage.**
   Ordinary tail copy-on-write now protects appends. See [COW_EVALUATION.md](COW_EVALUATION.md)
   for the implementation, concurrency checks and performance results. The original finding:
   `StreamArray.nextSlot()` assumes slots after this value's tail count are unused. After
   `var b = a`, both values can append into that same slot. For example, starting with `[1]`,
   append `2` to `a` and `3` to `b`: `a` becomes `[1, 3]`. `StreamDictionary` inherits this through
   its stored values. Nontrivial elements also risk overwritten ownership;
   independently mutated Sendable copies can race on shared slots and the block header.
   A serial high-water check alone would not fix concurrent writers. Decide between ordinary
   CoW for every shared append, or a storage design that distinguishes the writer from immutable
   snapshots. This touches the main append path and needs ARM assembly analysis and benchmarks.

2. **Medium: dictionary lookup changes when an entry stops being pending.**
   Pending-key comparisons in the subscript and borrowed view use `String.==`, which recognizes
   canonical equivalence; stored lookup hashes and compares UTF-8 bytes. Querying decomposed
   `e\u{301}` for a composed `é` entry can succeed while pending and fail after the next key.
   Decide whether keys use byte identity or Swift string identity, then apply that decision to
   pending lookup, stored lookup, equality, hashing and standard-dictionary bridging. Keeping
   byte identity is cheap, but bridging two canonically equivalent keys to `[String: Value]`
   necessarily collapses them and should be documented.

3. **Medium: malformed UTF-8 character traversal can duplicate content.**
   The shared `characterSpan(at:)` decodes a window and emits its first grapheme, but if any
   malformed byte in that window changes the decoded byte count it advances by only one scalar.
   For UTF-8 bytes of `a` plus a combining acute accent followed by `FF`, it emits the combined
   character and then emits the accent again. Both streaming string types use this helper.
   Separately, scalar decoding repairs each byte, while Swift's repairing `String` decoder can
   replace a whole malformed subsequence; comments claiming equivalence need reconciliation.
   Choose a consistent repairing contract and preserve source-byte offsets while segmenting.

4. **Safety hardening: public indexing reaches unchecked pointers.**
   `StreamArray`'s getter and `uniqueSlotAddress` lack a lower-bound check: a negative index in
   a tail-only array can reach memory before its allocation. `StreamEventBatch.bytes/info/end`
   similarly do not range-check event indices. These are invalid caller inputs, unlike the
   valid-input bugs above, but a safe public API should trap rather than access arbitrary memory.
   Consider checked public access with explicitly unchecked internal helpers; benchmark the
   inlined parser callers before choosing the split.

The first three findings have executable reproductions in
`Tests/StreamParsingTests/GenericReviewTests.swift`. The array and dictionary cases now pass as
normal regression tests; the two Unicode cases remain expected failures. The validation below
records the original async-only review; the subsequent COW results are in `COW_EVALUATION.md`.

## Suggested additions, in priority order

Follow-up: items 1 and 3 now have implementations. See [STREAM_OBSERVATION.md](STREAM_OBSERVATION.md)
for synchronous iteration, scoped views, projection and duplicate filtering, and
[OBSERVATION_API_EVALUATION.md](OBSERVATION_API_EVALUATION.md) for validation. Projection preserves
available field values and carries document completion separately. Opt-in `observeField`
adds missing/null/incomplete/complete states for direct stored fields without changing ordinary
typed storage; nested/computed path selection is explicitly unsupported in this first version.

1. **Lazy synchronous partials and scoped view consumption.** Add a sequence/iterator counterpart
   to the eager `[Value]`-returning `Sequence.partials`, plus a callback-based driver that lends a
   view after each chunk. This bounds retained state and lets callers avoid whole-tree snapshots.
   Specify single-pass/copy behavior, errors, and the final emission explicitly.
2. **Streaming search state.** Add a reusable UTF-8 matcher that returns byte ranges across chunks
   (for example, KMP with a precomputed prefix table). Current `range(of:from:)` retries a full
   comparison at each candidate and callers must track overlap themselves. Benchmark repeated-
   prefix adversarial needles as well as typical short delimiters; do not replace the existing
   small-needle path without evidence.
3. **Selective observation.** Add projection/change-filtering operators for partial streams so a
   renderer can observe one field, or only changed snapshots. Keep absence, null, incomplete
   content and document completion distinguishable; completion must not disappear as a duplicate.
4. **Path-aware raw filtering and owned event batches.** A JSON-pointer/path sink adapter would
   make selective consumers easier to write. An explicitly owned batch type would support queues
   and replay beyond a borrowed callback. Document that today's `.skip` validates only structure
   and that the batching adapter does not honor skips or retain original event end offsets.
5. **Explicit string-backed conversions.** Add opt-in strategies/wrappers for UUID, URL, dates,
   and base64 data, converting only at a complete-token boundary. Appending fragments directly
   into these types cannot represent intermediate states; keep raw partial text available and
   define invalid-completed-value errors separately from missing values.

## Validation

- The pre-fix focused run reproduced three async lifecycle failures and all four known-issue
  expectations (the collection bug has both array and dictionary reproductions).
- `swift test --traits StreamParsingSwiftCollections,StreamParsingTagged --no-parallel
  --skip-build`: 764 tests in 77 suites passed, with four explicitly acknowledged known issues.
- The parallel run hit the existing `Stream Init Reuses The Cached Schema` test: its global
  allocation counter included 13 allocations from concurrent work, exceeding its threshold
  of fewer than 10. The complete serial rerun passed. This test needs per-type accounting or
  process isolation to avoid suite interference; marking just its suite serialized is insufficient.
- Real-world benchmarks: the initial smoke sweep completed 38 bulk rows. A separate, clean
  sequential before/after comparison completed 25 rows per executable, with no concurrent
  builds or tests: eight corpora through raw and typed APIs, plus nine async API rows.
  Swift 6.3.3, x86_64 Linux, release configuration, default three-second benchmark duration.
  Original and patched executables were preserved separately; no source swapping was used.
  The raw/typed median wall-clock throughput changes ranged from -0.9% to +1.9%; async changes
  ranged from -3.1% to +6.6%. This single paired sweep shows no large regression, but does not
  establish statistical significance for the smaller differences.
The implementation change is confined to the async driver; no critical parsing kernel or SIMD/
SWAR algorithm is modified. ARM performance and CoreGraphics behavior cannot be verified on
this x86_64 Linux host.

### Corpus throughput

Median payload MB/s; each cell is original → patched. `bulk` is the raw counting sink;
`bulk discarding` materializes typed partials.

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

### Async throughput

The percentage uses median wall-clock time (original / patched − 1), because the benchmark's
payload MB/s metric rounds to integers. Positive means faster.

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

Reproduce the selected workload set with the benchmark tool using these whole-name filters:

```text
Real (Twitter|Twitter escaped|Canada|CITM catalog|GSoC 2018|GitHub events|LLM message|Mesh) - bulk( discarding)?
API AsyncSequence .*
```
