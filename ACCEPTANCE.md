# Acceptance tests

Behaviour-level tests of the library's public promises, in the `StreamParsingAcceptanceTests`
target (`Tests/StreamParsingAcceptanceTests`). Unit and regression tests for individual kernels
and code paths stay in `StreamParsingTests`; this target only asks what a user of the library
can observe.

```sh
swift test --filter StreamParsingAcceptanceTests
```

**Data.** Where a behaviour can be exercised on real data, it is. The corpora are the benchmark
package's (`Benchmarks/StreamParsingBenchmarks/Resources`), read by path:

| Corpus | Size | What it stresses |
| --- | --- | --- |
| `twitter.json` | 617 KB | deep heterogeneous objects, optionals, 15% non-ASCII, 64-bit ids |
| `twitterescaped.json` | 549 KB | the same document with every non-ASCII scalar as `\u` escapes |
| `twitterspaced.json` | 481 KB | the same document, re-indented |
| `citm_catalog.json` | 1.6 MB | dictionaries keyed by ids, integer arrays, whitespace |
| `canada.json` | 2.1 MB | 111 126 floating-point coordinates (GeoJSON) |
| `mesh.json` | 707 KB | long number arrays, `SIMD2<Double>` elements |
| `gsoc-2018.json` | 3.2 MB | a dictionary root of long prose strings |
| `github_events.json` | 64 KB | snake_case keys, URLs, nested commits |
| `llm_message.json` | 1.0 MB | an assistant message in the Anthropic Messages format: 546 text blocks, 90 tool-use blocks |

Synthetic inputs are used only for byte-level edges that a real document cannot be made to hit on
purpose: a surrogate pair cut between its halves, an overlong UTF-8 encoding, a 100 000-deep nest.

**Oracles.** The models are both `@StreamParseable` and `Codable` (copied from the benchmark
package's), so `JSONDecoder` reading the same declaration is the reference answer. The raw parser
is checked against `JSONDecoder`'s plain tree. Other oracles: the standard library's correctly
rounded `Double(String)`, `JSONEncoder` for enum wire formats, and the library's own whole-document
result for chunking invariance.

**Chunkings.** `acceptanceChunkings` covers single bytes; 2, 3, and 7; sizes either side of the
16- and 64-byte SIMD blocks (15/16/17, 63/64/65, 127); a 4 KB page; 64 KB; one 16 MB chunk larger
than any corpus; the whole document; and three seeded *variable* schedules. In a variable
schedule, chunk lengths are drawn log-uniformly up to 64 B, 4 KB, and 1 MB, so a single parse
mixes every scale the way a real transport does.

## 1. Real-world fidelity

What the library returns for a real document is what `JSONDecoder` returns for the same
declaration.

| ID | Test | Description |
| --- | --- | --- |
| RW-1 | A typed parse of every corpus equals JSONDecoder's | All nine corpora, parsed through their models and converted to whole values, equal `JSONDecoder`'s decode. |
| RW-2 | The raw event stream of every corpus rebuilds JSONDecoder's tree | The raw `JSONParser` driving a tree-building sink, with no typed layer, reproduces `JSONDecoder`'s plain tree for every corpus. |
| RW-3 | Minified, pretty-printed, and unicode-escaped Twitter decode to one value | Three encodings of the same document give one value, so whitespace and escapes carry no meaning. |
| RW-4 | Every canada coordinate is bit-identical to Foundation's | All 111 126 doubles match by bit pattern, so the sign of zero and the last ulp both count. |
| RW-5 | Integers past 2^53 survive exactly | Twitter ids that have no exact `Double` come back exact, which shows numbers never pass through floating point. |
| RW-6 | A model that reads a few fields skips the rest of a real document | A three-field model over each Twitter variant matches `JSONDecoder`, so skipping unknown subtrees never disturbs what is read. |
| RW-7 | The snake case key strategy reads keys the way JSONDecoder's does | `.convertFromSnakeCase` on GitHub events matches `JSONDecoder`'s own strategy. |

## 2. Chunking invariance

Where the transport cut the bytes never changes the answer.

| ID | Test | Description |
| --- | --- | --- |
| CH-1 | Every corpus parses identically at every chunk size from one byte to all of it | **The variable-chunk-size requirement.** 9 corpora × 18 chunkings = 162 typed parses, from 1 byte through a 16 MB chunk plus the variable schedules. Each must equal `JSONDecoder`. |
| CH-2 | The raw event tree of every corpus does not depend on chunking | The same check on the raw layer, at 1 byte, 63 bytes (just under a block), and a variable schedule. |
| CH-3 | Every two-chunk split of a real GitHub event gives the same value | Every possible single cut of one real event (1.4 KB, its own bytes and escapes), landing inside keys, numbers, escapes, and URLs. |
| CH-4 | A corruption planted in a real document is reported at the same byte under every chunking | A control byte in a tweet, a letter in a canada coordinate, invalid UTF-8 in a GSoC description, and a stray `]` in CITM. Each is reported with the same reason and byte offset under every chunking, at the planted byte, and the same on the skipping path where the `.skip` contract covers it. |
| CH-5 | An async sequence of chunks yields the same value as a synchronous parse | `AsyncSequence.partials(of:from:)` over a variable-chunked LLM message gives the same final value. |

## 3. Streaming semantics

What a consumer sees before the document ends: a faithful, monotone picture of the bytes so far.

| ID | Test | Description |
| --- | --- | --- |
| SS-1 | A small object streams the documented partial after every byte | The README example pinned exactly: one partial per byte; a string appears at its opening quote and grows on every content byte; a number or literal appears only once its token is whole; then one completion partial. |
| SS-2 | A mid-stream snapshot equals a fresh parse of the same prefix and never changes | On Twitter, CITM, and GitHub, a snapshot taken mid-stream equals a new stream fed only that prefix, and later bytes never alter it. State is a function of the bytes so far. |
| SS-3 | Streamed strings and arrays only grow, and numbers appear only once final | Across all 636 blocks of the LLM message, strings and arrays only extend, every partial string is a prefix of the final one, and a number is either absent or final. |
| SS-4 | Nothing half-formed is ever visible | Fed byte by byte through escapes and multi-byte scalars, the stream never shows a half-decoded scalar, a replacement character, or a provisional number. |
| SS-5 | Field observation moves forward only, from missing to complete | `observeField` on a real document runs `missing → incomplete → complete` and never back. Only the final update reports document completion. |
| SS-6 | A zero-copy view agrees with the snapshot at every point | `withView` reads the same values as the copying snapshot at every chunk boundary of the LLM message. |

## 4. Typed layer

Macro models, conversions back to whole values, enums, optionality, and rejection of what a
declaration cannot hold.

| ID | Test | Description |
| --- | --- | --- |
| TL-1 | Strict conversion declines until every required member arrives, then equals JSONDecoder's | `init?(streamPartial:)` returns nil for every prefix of the real LLM message before its last required member; `finish()` then returns a value equal to `JSONDecoder`'s. |
| TL-2 | Total conversion keeps what arrived and fills the rest with initial values | `init(orInitial:)` keeps what arrived and fills the rest with initial values. |
| TL-3 | Null and absence are distinct, and null never fills a non-optional member | `null` and absence are both representable and stay distinct. In the default mode, `null` on a non-optional member leaves it absent; with `partialMembers: .initialValue` it is rejected. |
| TL-4 | A type mismatch is rejected at its token under every chunking | A boolean, number, array, or object where the member cannot hold it raises `.sinkRejectedToken(.typeMismatch)` at the same offset under every chunking. |
| TL-5 | An integer the member cannot represent is rejected / Integers at the edges of their types are exact | Out-of-range values (Int8 ±, negative `UInt`, `Int64.max + 1`, `UInt64.max + 1`, a fraction) are errors, never wrapped or truncated. `Int8.min`, `UInt.max`, `Int64.min`, and `UInt64.max` are exact. |
| TL-6 | Doubles are correctly rounded / A double that overflows to infinity is rejected | Twenty classic decimal-to-binary corner cases (negative zero, 2^53+1, the PHP/Java hang value, subnormal boundaries, `1e23`, 30-digit significands) match the standard library by bit pattern. `1e400` is rejected rather than becoming infinity. |
| TL-7 | A string enum resolves to the shortest case its bytes are still a prefix of | The README's resolution table, checked statically and while streaming. `.live` is superseded by `.livestream` as bytes arrive. |
| TL-8 | An enum with associated values parses Codable's own encoding | Labeled, positional (`_0`), mixed, and no-payload cases round-trip from `JSONEncoder` output, both bulk and byte-fed. |
| TL-9 | Explicit keys, aliases, and non-ASCII keys route to their members | `@StreamParseableMember(key:)`, `keyNames:` aliases, and a non-ASCII key all route correctly. A named key replaces the Swift name, and NFD and NFC spellings are different keys. |

## 5. Text fidelity

Synthetic by design: each row is one byte-level edge.

| ID | Test | Description |
| --- | --- | --- |
| TX-1 | Every escape and UTF-8 width decodes exactly at every cut | Every simple escape, `\u` escapes (including surrogate pairs), and raw 1–4 byte UTF-8, interleaved, decode exactly at every two-chunk cut and byte by byte. |
| TX-2 | Ill-formed UTF-8 is rejected at the same byte at every cut | Overlong encodings, surrogate code points, values past U+10FFFF, invalid lead bytes, lone continuation bytes, and truncated sequences are rejected as `.invalidUTF8` at the same offset at every cut, on the raw and typed paths. |
| TX-3 | Unpaired surrogate escapes are rejected | Lone high, lone low, high followed by a non-low escape, and reversed pairs are rejected, both bulk and byte-fed. |
| TX-4 | Unescaped control characters in strings are rejected | All 32 C0 control bytes are rejected inside values (bulk and byte-fed) and inside keys. |

## 6. Grammar and errors

Exactly RFC 8259: nothing more lenient and nothing stricter.

| ID | Test | Description |
| --- | --- | --- |
| GR-1 | Every valid JSON value shape is accepted, at the root and byte by byte / Duplicate keys are accepted and both members are delivered | Scalars at the root, empty and nested containers, every whitespace byte, and a 10 001-element array all match `JSONDecoder`'s tree. Duplicate keys are legal: both members reach the sink and the policy is the sink's. |
| GR-2 | Malformed documents are rejected, in bulk and byte by byte | 52 malformed documents are rejected: structure (trailing and leading commas, missing colons, mismatched brackets), trailing content, number grammar (leading zeros, `+1`, `.5`, `1.`, hex, NaN/Infinity), bad literals, bad strings, and comments. |
| GR-3 | Every truncation of a real document is accepted mid-stream and refused at finish | For every prefix of a real GitHub event, `next` succeeds (the document could still be completed) and `finish` throws a grammar error located within the bytes given. |
| GR-4 | Nesting is capped at 64 levels and deep input fails cleanly | 64 levels of arrays or objects are accepted, 65 are rejected, and 100 000 open brackets fail with `.depthExceeded` at byte 64 instead of exhausting the stack, under every chunking. |
| GR-5 | An error reports the absolute offset of the offending byte under every chunking | Reason and absolute byte offset are pinned for an unexpected token, a bad literal, a bad escape, trailing content, and a bad number (judged at its delimiter). The result is the same whole, at 1, 2, and 4 bytes. |

## 7. Lifecycle, resources, and the raw layer

| ID | Test | Description |
| --- | --- | --- |
| LC-1 | A stream finishes with the whole model or says why it cannot, and refuses input after failing | The consuming `finish()` returns the whole model for a complete document and throws `incompleteValue` when a required member never arrived. A failed stream throws `parserFailed` on both `next` and `finish`. |
| LC-2 | A reset stream parses the next document as if it were new | `reset()` after a success, after abandoning a document mid-string, and after a failure, then a full Twitter parse that matches `JSONDecoder`. |
| LC-3 | Real documents parse with the minimum buffer under hostile chunking | Every corpus at `bufferCapacity: 64` with chunks of at most 96 bytes matches `JSONDecoder`. Strings stream, so only keys, numbers, and literals need the buffer. |
| LC-4 | A token longer than the buffer is reported, never misparsed | A 100-byte key or number with a 64-byte buffer parses when it arrives whole and is reported as `.bufferExhausted` when byte-fed. |
| LC-5 | Concurrent streams over real documents each get the right answer | Sixteen concurrent streams over Twitter and CITM, each with its own chunking, all match `JSONDecoder`. Shared schema caches stay correct under contention. |
| LC-6 | A sink that skips subtrees sees exactly the top level of a real document | A raw sink answering `.skip` below the root sees each top-level entry once and nothing from skipped interiors (only their matching end calls), on five corpora at three chunkings. |

## Notes from writing these

- **The Twitter `id`/`id_str` fields disagree in the file itself.** The numeric ids in
  `twitter.json` were already rounded upstream, so `id_str` can't be the oracle for RW-5.
  `JSONDecoder`'s exact `Int` is used instead.
- **Truncation reasons vary with the cut.** A document cut after a comma or colon finishes with
  `.unexpectedToken`, while one cut after a value finishes with `.unterminatedContainer`. GR-3
  accepts both; making these consistent would be a small diagnostic improvement.
- **Skipped subtrees don't check number grammar.** That's the documented `.skip` contract, so
  CH-4 holds the canada corruption to the streaming path only.
- **Large `Partial` comparisons need a big stack in debug.** The compiler-derived `==` on a large
  macro `Partial` (Twitter) overflows the 512 KB stack of a Swift Concurrency pool thread in debug
  builds. SS-2 runs that comparison on a 64 MB thread (`onLargeStack`). This is a test-harness
  issue, not a library one.
