# Ordinary collection copy-on-write

This follows the shared-tail corruption finding in `GENERIC_API_REVIEW.md`. The implementation
uses ordinary copy-on-write, with no writer tokens, atomic slot reservation, or special exemption
for parser-owned arrays.

## Implementation

`StreamArray.nextSlot()` makes a tail unique before returning a writable slot in it. The
uniqueness check happens before binding the tail to a local strong reference. This covers public
appends, scalar parser appends, committing an open element, template-based element opening, and
`StreamDictionary`'s insertion of pending values. Dictionary replacement already used the checked
mutable-slot path.

The existing growth path remains intact: a full block is sealed and can stay shared without
being copied; the next append uses a new block. Growing a small full tail still moves its contents
if uniquely owned and copies them otherwise. Shared-tail appends copy only initialized elements,
retaining the existing tail capacity. Sealed blocks and the inline pending element keep their
existing behavior. Every block mutation, including its initialized-count header, now requires
unique ownership through the collection implementation.

## Correctness

- Full serial suite with Foundation, swift-collections and Tagged integrations: **769 tests in
  77 suites passed**, with the two pre-existing Unicode expected failures. Command:
  `swift test --traits StreamParsingSwiftCollections,StreamParsingTagged --no-parallel`.
- Array and dictionary corruption reproductions now pass as normal tests.
- Added interleaved divergent appends around small-tail and sealed-block boundaries, weak-reference
  checks for correct element release, mutation of a retained parser snapshot, two streams seeded
  from the same nested collection, and independent-task mutation of shared seeds.
- Updated the old sharing test to require detached tails and unchanged snapshot headers.
- A separate core-only Thread Sanitizer harness passed with **64 concurrent workers × 16 rounds**.
  Each round appended 300 integers and mutated copied nested dictionaries; it checked both the
  divergent results and the unchanged seeds. No race report was emitted. This instruments the
  library as well as the harness; it is not a claim that the entire test suite ran under TSan.

The sanitizer core was built with:

```sh
swift build --scratch-path .build-cow-tsan --target StreamParsingCore \
  --sanitize=thread --disable-default-traits
```

## Assembly analysis

Swift 6.3.3, `-O`, x86_64 Linux. Both client-specialized probes and the actual release benchmark
executable were inspected. This host has no ARM Swift SDK, so ARM assembly and timings remain
unverified.

Three client probes called shipped `_appendClosed` for `Int` and `StreamString`, and
`_openElement(copying:)` for `Int`. The old roomy-tail path did capacity checks and address
arithmetic without a uniqueness call. The new probes call specialized `ensureUniqueTail`, which
calls `swift_isUniquelyReferenced_native` and returns immediately for a unique tail. There is no
extra retain ahead of that check to manufacture sharing. The shared branch allocates a new block:
`Int` elements copy through `memcpy`, while `StreamString` elements use `swift_arrayInitWithCopy`
so their reference ownership is preserved. The old block is released after copying.

The actual SIMD element opener used by Canada's coordinates and Mesh's influences also changes:
`PartialSink.openKnownSIMDDoubleElement` grows from 1,035 to 1,151 bytes. Each of its six SIMD
route arms gains an outlined specialized `ensureUniqueTail` call on the roomy-tail commit path
(one such call for the selected route, not six calls per element). The helper then checks the
reference count. This is directly relevant to the two corpus rows with the largest bulk losses.

The actual `Double` specialization of `_streamArrayNumberAppender` in the benchmark binary has
a different inlining outcome from these small probes:

| Property | Before | COW |
| --- | ---: | ---: |
| Function size | 742 bytes | 913 bytes |
| Stack allocation, excluding saved registers | 88 bytes | 120 bytes |
| Roomy-tail steady-state uniqueness check | None | Direct call to `swift_isUniquelyReferenced_native` |

The runtime check is in the per-number loop, followed by a branch around the block-copy path.
The floating-point value is spilled before the call and reloaded for the element store. The
initial pending-element drain still calls the specialized helper. Extra calls, spills and code
size are potential costs even when snapshots are discarded; the shared case additionally pays
allocation and element copying. These observations explain what changed, not how fast it is:
end-to-end timings below determine the performance impact.

## Benchmark method

Two release executables were preserved: baseline commit `e13ef7cd` and the COW working tree. They ran sequentially
with the same tool and filters, default three-second per-row duration, with no concurrent builds,
tests or sanitizer runs. The 52 selected rows cover all eleven main real-world payloads through raw
and typed bulk paths, Twitter's full typed model, all nine public async rows, all seven retention
rows, twelve dictionary rows (8/32/128/512 keys; discard/keep-all/window-16), and the array-of-structs
snapshot-per-byte row.

Percentages use `before median wall time / after median wall time - 1`: positive is faster.
Payload MB/s is the benchmark's integer-valued median metric. Allocation counts are medians per
benchmark iteration. Raw parser rows and the retained string-only document are controls.

The first sweep shows a throughput loss concentrated in collection-heavy typed parsing and
retained array snapshots. Typed Canada fell 12.8% (374 → 326 MB/s) and typed Mesh 10.5%
(319 → 286 MB/s), while their bulk allocation counts stayed at 1,398 and 352. Thus the bulk
regression is not caused by unexpectedly copying unique tails. Uniqueness checks, register
spills, and changes to generated code are plausible contributors; the assembly does not by
itself apportion the runtime cost.

Retaining 100-user states loses 11.8–14.2% throughput and increases allocations from 28 to 122.
Dictionary discard rows lose 5.7–9.4% with unchanged allocations; retained dictionary rows lose
1.8–5.7%, with additional tail copies. The Mesh window rows rise from 603 to approximately
70,000 allocations and from 4,130 to approximately 77,000 with capacity hints, losing 5.0% and
6.1% throughput respectively. The benchmark formats these counts in thousands, so those two
allocation figures are approximate.

The public async rows range from -1.6% to +2.3%, and the snapshot-per-byte row that immediately
drops each state loses 0.7%. Raw controls range from -1.0% to +4.3%. Small changes at that scale
should not be treated as statistically established gains or losses from one sweep.

A nine-row confirmation ran in reverse order (COW first, original second). It reproduced the
Canada, Mesh, dictionary and retained-user losses. The workspace tool-call loss was smaller on
repeat, so its magnitude is less stable. The ordinary COW implementation is retained for review;
no alternate ownership scheme or follow-up optimization has been applied.

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

For the next discussion, first separate avoidable call/code-layout costs from the unavoidable
cost of detaching a shared tail. Inlining only the fast uniqueness check while outlining the
copy path is an ordinary-COW experiment worth measuring, particularly for the SIMD opener;
it cannot remove the runtime check itself. A scoped bulk-append API that establishes uniqueness
once per block/batch is another possibility, provided no snapshot can be taken during that
borrow. Neither requires weakening independent value semantics. ARM measurements should precede
any decision about the performance acceptable for the primary target.


### Full paired sweep

#### Real-world payloads

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

#### Retained collections and snapshot control

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

#### Async APIs

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

