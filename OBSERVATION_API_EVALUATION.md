# Observation API validation

Swift 6.3.3, x86_64 Linux, release builds, default three-second benchmark duration.
Measurements were sequential with no builds or tests running concurrently. These are
single sweeps, not statistically established small improvements/regressions. ARM is untested.

## Synchronous iterator and scoped views

`swift test --traits SwiftCollections,Tagged --no-parallel`:
776 tests in 78 suites passed; the two previously known Unicode issues remain acknowledged.
Seven new tests cover emission timing, EOF number flushing, snapshot stability, laziness,
terminal errors, callback failures, and the public overloads.

Bulk controls (baseline measured after the new-API sweep):

| Payload | Baseline MB/s | New APIs MB/s | Throughput change |
|---|---:|---:|---:|
| CITM catalog | 636 | 624 | -1.9% |
| Canada | 326 | 359 | +10.0% |
| GSoC 2018 | 947 | 952 | +0.5% |
| GitHub events | 905 | 910 | +0.6% |
| LLM message | 1491 | 1522 | +2.1% |
| Mesh | 286 | 300 | +4.8% |
| Twitter full | 454 | 464 | +2.1% |

New API rows observe the three real Qwen payloads. The iterator consumes/discards owned
whole-value snapshots; scoped views read the representative name/summary field. Inputs
are identically prechunked outside the timed region, but observation work differs.

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

No scanner, sink, storage, or existing parser fast path was edited. The new
`finishWithView` follows the existing EOF guards/validation and calls the view callback
without copying the root. As a release-code check, all 183 number-appender symbols have
unchanged sizes versus baseline; this is not a claim of instruction-by-instruction identity.

## Selective observation

`swift test --traits SwiftCollections,Tagged --no-parallel`:
788 tests in 79 suites passed; the same two known issues remain acknowledged.
Twelve new tests cover field projection, unrelated-field suppression, optional outputs,
independent snapshots, custom/full-value filtering, completion with identical values,
projection/upstream/EOF errors, copied async iterators, and rejected subscribers.

The initial release implementation called `withView` on chunk updates and
`finishWithView` at EOF, with no root snapshot. Its generic adapter overhead nevertheless
made projection/filtering slower than plain snapshots in the first sweep. The synchronous
adapter chain and generic duplicate filter now expose their bodies for client specialization.
The final table below measures that version, including the opt-in field tracker.

## Field parsing states and final validation

The final serial run passed **810 tests in 80 suites**, including 22 field-observation tests.
The two pre-existing Unicode issues remain acknowledged. Coverage includes missing/null,
string/number/literal/container progress, field completion versus document EOF, aliases and
escaped keys, repeated keys, seeded values, both generated partial-member modes, nested and
skipped subtrees, all two-chunk split points for escaped UTF-8 with both window thresholds,
noncontiguous/byte input, invalid selections and custom schemas, and async lifecycle failures.

The implementation uses a forwarding `FieldObservationSink` only for opt-in observers. Its
constant-size tracker lives outside ordinary partial storage. Number/literal starts are read
from the parser's lexical state after a chunk because those tokens emit only upon completion.
The existing scanner, ordinary `PartialSink`, schemas, and generated partial layouts are untouched.
`ObservedFieldPath` initially used Swift reflection SPI at setup to validate a direct stored field, checks
its schema offset/optionality, and rejects overlapping storage. The slot read is typed by the
validated key path; the root is never snapshotted to extract it. That initial reflection approach
was availability-guarded; the review revision below replaces it with generated key paths.

Release assembly inspection found **195 common numeric/structural symbols with unchanged sizes**
versus the original pre-API binary (not a claim of instruction-by-instruction identity). The new
observing sink has separate structural specializations: 4,293 bytes for `consumeStructuralRun`
and 4,678 bytes for `consumeStructuralRunBlocks`. The observed block loop calls the existing
scalar operations directly for several event kinds, with tracking checks inline; some key and
container wrappers remain outlined. There are no direct tracking allocation/retain/release calls
in that inspected loop. Code size alone does not establish throughput; measurements follow.

The final sweep covers seven real-world bulk controls and nine Qwen payload/chunk combinations
through seven APIs (70 rows). Field selection is validated outside the timed region using a
reusable `ObservedFieldPath`; parser/iterator construction remains timed. Observed and projected
rows include duplicate filtering; ordinary snapshot and scoped-view rows do not. The payloads
and chunk boundaries match, but emission semantics and observation work intentionally differ.

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

API table entries are payload MB/s. On these workloads, synchronous value projection benefits
from avoiding whole-tree snapshots. Rich field tracking costs appreciably more than projection,
and the async adapter pipelines remain slower than plain async snapshots with a trivial consumer.
Reducing renderer work may offset those costs in an application; that is not measured here.
The first synchronous API build's apparent Canada/Mesh gains vary across builds/sweeps and should
not be interpreted as parser optimizations. No scanner optimization was made.

The final setup-only hardening also rejects a partially reflected root; a fresh focused test run
and real-payload confirmation follow below. This validation occurs outside the timed region in
these benchmarks. The existing seven bulk controls and six 64-byte field-observation rows are
rechecked after that guard.

Benchmark whole-name filters for the 70-row sweep:

```text
Real (Twitter full|Canada|Mesh|CITM catalog|GSoC 2018|GitHub events|LLM message) - bulk discarding
API (PartialIterator|ScopedViews|Projected|AsyncProjected|ObservedField|AsyncObservedField|AsyncSequence) .*
```

Build with `swift build --package-path Benchmarks -c release --product StreamParsingBenchmarks`.
The Linux runs used `Benchmarks/.build/x86_64-unknown-linux-gnu/debug/BenchmarkTool-tool`
with `--benchmark-executable-paths` pointing to the saved release executable, `--command run`,
`--format markdown`, `--grouping benchmark`, `--no-progress`, `--time-units nanoseconds`,
and one `--filter` per expression above. Baseline binaries were saved alongside the release
runtime libraries; moving them to `/tmp` without those libraries does not work.

### Final setup-guard confirmation

All 22 observer tests passed again after requiring complete field reflection. The final
release build then completed all 13 requested confirmation rows, with no tests/builds
running during measurement. The rich-observation cost remained: at 64-byte chunks,
synchronous search/structured/workspace measured 35/52/57 MB/s, and async measured
23/39/41 MB/s. Bulk controls below remained close to the original baseline.

| Bulk payload | Final confirmation MB/s |
|---|---:|
| CITM catalog | 639 |
| Canada | 334 |
| GSoC 2018 | 963 |
| GitHub events | 918 |
| LLM message | 1487 |
| Mesh | 299 |
| Twitter full | 465 |

The confirmation used the same seven bulk filters plus
`API (ObservedField|AsyncObservedField) .* - 64B chunks`. The direct benchmark command
also supplied `--baseline-storage-path /tmp/ssp-api-baselines`.


## Review revision: shared boxing and generated field selection

Replaced the observer's extra box with `AsyncPartialsSequence.Box<State>`: ordinary iterators
use `Void`, and field observers use `FieldObservationState`, stored after the existing box
fields. Copies still share the cursor,
termination, subscription identity, and tracking state. Every async `observeField` overload
now documents examples, parameters, result types, completion, and errors.

Removed the reflection SPI and its availability error. The macro generates
`streamObservationFields`, and custom roots opt in by listing all direct stored members.
Validation still checks key-path identity, unique offsets, and schema registration/optionality.
Neither the packed field table nor partial storage layouts changed. The protocol requirement
and generated computed property are used at selection setup, outside the parsing loop.

Validation: **811 tests in 80 suites passed**, with the same two known Unicode issues, using
`swift test --traits SwiftCollections,Tagged --no-parallel`.
Updated 16 macro snapshots and added a custom-root opt-in regression test. Existing tests
cover iterator-copy tracking, subscriptions, aliases, invalid paths, and overlapping fields.
The release benchmark product also built successfully.

Measurements used Swift 6.3.3 on x86_64 Linux, comparing the saved `e169dfd5` release executable
with this revision. Each row reports the benchmark's median (three-second default runs).
All builds/tests had stopped before measurement. MB/s is rounded by the benchmark; percentage
changes use the underlying wall-clock medians. ARM performance remains unmeasured.

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

The async observer's allocation counts fell by exactly one in each workload: search 32→31,
structured response 109→108, and workspace edit 131→130. Ordinary async partial counts stayed
29, 105, and 128 respectively.

Assembly inspection found all **197 common numeric/structural parser symbols unchanged in
size** (not a claim of byte-for-byte identity). Observer construction now calls the shared
box allocator; the separate observer-box allocator is gone. The generic ordinary iterator
factory grew from 283 to 312 bytes, and the observer factory from 270 to 463 bytes because it
now constructs the stream directly instead of wrapping an existing iterator. These sizes
alone do not predict throughput; the end-to-end results above include iterator construction.

Benchmark filters:

```text
Real (Twitter full|Canada|Mesh|CITM catalog|GSoC 2018|GitHub events|LLM message) - bulk discarding
API (ObservedField|AsyncObservedField|AsyncSequence) .* - 64B chunks
```

The first layout put state before the existing fields and showed ordinary async slowdowns
around 3% on a reverse-order repeat. Moving it after those fields brought the final ordinary
async results to −1.7% / +0.9% / +1.3% for search / structured / workspace relative to the initial
baseline. Final async observation changed +2.1% / −2.8% / +3.6%. The allocation reduction is
consistent; these timings do not establish a throughput improvement. Sync observation was
2.7–4.7% slower in this final sweep; bulk controls ranged from −3.5% to +2.3%. Treat these small
mixed differences as measurements on this machine, not a cross-platform performance guarantee.
