# Completed-value conversion validation

The implementation adds `StreamCompletedValueConversion.convertToValue` /
`convertFromValue`, `ConvertedPartial`, and `@StreamParseableMember(completedConversion:)`.
Scalar conversions use ordinary schema application; strings have an optional completion hook.
Converted containers temporarily use their source schema, with completion records outside the
ordinary 24-byte parser frames. No JSON scanning kernel or SIMD/SWAR algorithm changed.

## Tests

`swift test --traits StreamParsingSwiftCollections,StreamParsingTagged --no-parallel`:
**833 tests in 83 suites passed**, with the same two known Unicode issues.
The release benchmark product also built successfully.

The new coverage includes:

- Conversion only at completion, cached reads/EOF, and the independent reverse conversion.
- Whole, empty, escaped, and split strings at every two-chunk boundary, with both window modes.
- Number boundaries, booleans, arrays, fixed-array arity, object sources, and nested conversions.
- Multiple conversions completing at the same container depth, inner before outer.
- Duplicate keys, cached prior numbers during unfinished replacement tokens, and observation.
- Optional fields/roots/elements, dictionary values, initial-value partials, and explicit defaults.
- Original strategy errors retained in partials; conversion failures distinct from source errors.
- Truncation, reset after failure, async termination, and iterator copies.
- Public macro expansion, destinations without parsing/initialization conformances, and round trips.
- Macro snapshots and diagnostics for missing defaults, duplicate strategies, capacity hints,
  and nonliteral strategy arguments.

## Assembly and implementation adjustment

The initial implementation expanded frame push/pop from 88/65 to 857/393 bytes on x86_64.
Inspection found schema retain/release calls before the optional conversion metadata test,
including when parsing ordinary containers. The initial real-data sweep measured typed Canada
about 15% slower and CITM about 9% slower than the saved pre-change executable.

The final implementation checks for conversion metadata in a guaranteed borrowed-schema scope
and outlines the conversion stack operations. Existing schema/sink fields keep their original
order; completion metadata is appended. Ordinary string slots clear their unused scalar target,
so their close does not dispatch a conversion callback.

Final push/pop are **121/85 bytes**. Their ordinary paths have **no retain/release calls**;
they branch to the outlined helpers only for converted values. String begin/end are 320/157
bytes versus 310/64 previously. Of 201 common selected sink/numeric/structural symbols, 196
retain their sizes; all common structural-parser specializations retain their sizes. One
serialized Int number-appender specialization changed from 677 to 853 bytes. These are code-size
and inspected-path observations, not claims that equal sizes imply identical instructions or
that fewer instructions guarantee higher throughput.

## Benchmark method

Swift 6.3.3, x86_64 Linux, release builds. Saved pre-change, initial, and adjusted executables
were run directly with BenchmarkTool, without concurrent builds or tests. Each benchmark uses
the default three-second measurement period; values below are medians. MB/s is rounded by the
benchmark; percentage changes use wall-clock nanosecond medians. ARM remains unmeasured.

Controls cover raw and typed Twitter, Canada, Mesh, CITM catalog, GSoC 2018, GitHub events,
and LLM message, plus typed Twitter full and the existing observation/async APIs at 64-byte
chunks. New paired rows parse the same Qwen payload/model shapes with ordinary string fields
or a completed `StreamString` → `String` conversion on `name` / `summary`. They include parser
construction and snapshots after each chunk; the converted rows also retain source and result.

```text
Real (Twitter|Twitter full|Canada|Mesh|CITM catalog|GSoC 2018|GitHub events|LLM message) - bulk( discarding)?
API (ObservedField|AsyncObservedField|AsyncSequence) .* - 64B chunks
Conversion (source|completed) .*
```

## Final control results

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

Typed CITM recovered to approximately baseline; Twitter full changed −0.3%. Typed Canada was
4.4% slower, alongside a 3.9% slowdown in its raw control. Other typed bulk controls ranged
from −0.7% to +9.3%; the existing observation/async rows ranged from −4.5% to +2.8%. These
single-machine sweeps show the initial large container regression was substantially recovered,
but do not establish statistical significance for small differences or predict ARM behavior.

## Opt-in conversion cost

| Qwen workload, 64-byte chunks | Source only MB/s | Completed conversion MB/s | Throughput change |
| --- | ---: | ---: | ---: |
| Qwen 3 search tool call | 76 | 53 | -29.1% |
| Qwen 3 structured response | 128 | 120 | -5.9% |
| Qwen 3 workspace edit tool call | 124 | 119 | -4.2% |

These rows perform additional work: a completed string conversion, retaining its result beside
the source, and snapshots of the larger partial. The small search payload pays the largest
relative cost (about 3.3 microseconds additional median time). This implementation prioritizes
correct completion semantics and composable source schemas; it does not promise zero-cost
conversions. Concrete UUID/date/URL/base64 strategies are not included in this change.
