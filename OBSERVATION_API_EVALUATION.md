# Observation API validation

Swift 6.3.3, x86_64 Linux, release builds, default three-second benchmark duration.
Measurements were sequential with no builds or tests running concurrently. These are
single sweeps, not statistically established small improvements/regressions. ARM is untested.

## Synchronous iterator and scoped views

`swift test --traits StreamParsingSwiftCollections,StreamParsingTagged --no-parallel`:
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
