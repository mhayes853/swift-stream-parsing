## Plan: JSONStreamParser Invalid Syntax Handling

### Goals
- Add syntax error reporting to `JSONStreamParser` without adding configuration yet.
- Prioritize tests first, then implementation.
- Keep streaming semantics clear when invalid syntax appears mid-stream.

### Tests (write first)
Add a new test suite under `JSONStreamParser tests`:
- `JSONError tests`

Proposed tests (invalid JSON samples, each should assert error emission and streaming behavior):
- `{"a":}` (missing value)
- `{"a" 1}` (missing colon)
- `{"a": 1,}` (trailing comma)
- `{"a": [1,]}` (trailing comma in array)
- `{"a": [1 2]}` (missing comma in array)
- `{"a": "unterminated}` (unterminated string)
- `{"a": "\u12"}` (invalid unicode escape)
- `{"a": \n }` (invalid escape in string)
- `{"a": 1` (missing closing brace)
- `[1, 2` (missing closing bracket)
- `][` (unexpected token in neutral mode)
- `{"a": tru}` (invalid literal)
- `{"a": -}` (invalid number)
- `{"a": 01}` (leading zero in number)
- `{"a": 1e}` (invalid exponent)
- `{"users":[{"id":1,"name":"Ada"},{"id":2,"name":"Grace"}],"meta":{"count":2},` (missing closing brace on larger payload)
- `{"catalog":{"items":[{"sku":"a1","price":9.99},{"sku":"b2","price":12.50}], "currency":"USD"} "extra":true}` (missing comma between object members in larger payload)
- `[{"type":"event","payload":{"values":[1,2,3]}},{"type":"event","payload":{"values":[4,5,6]}},]` (trailing comma in larger array payload)
- `{"data":[{"id":1,"tags":["a","b","c"]},{"id":2,"tags":["d","e","f"]}]` (missing closing brace on larger payload)

Test expectations:
- Add one dedicated test that uses `expectJSONStreamedValues` to confirm streamed values emitted before the error are preserved.
- All other syntax tests should only assert `JSONStreamParsingError` once invalid syntax is detected.
- After the first syntax error, no additional partials should be emitted for trailing bytes.

### Error Representation
- Introduce `JSONStreamParsingError` (Swift `Error`).
- Shape of the error:
  - `reason` enum (e.g. unexpectedToken, invalidNumber, unterminatedString, invalidEscape, invalidUnicode, missingDelimiter, mismatchedClose).
  - `position` (line/column) for diagnostics, represented by a dedicated coordinate type (e.g. `JSONStreamParsingPosition` with `line`/`column`).
  - `context` (optional) string or enum for mode (neutral/object/array/key/value).
- Expose through the parser’s existing error channel (e.g. `StreamParsingError` wrapper if needed).

### Streaming Behavior with Errors
- Emit partials up to the last valid byte.
- Once a syntax error is detected, fail the stream and stop emitting further partials.
- For in-progress objects/arrays, do not emit a new partial at the error byte unless the byte completes a valid token.
- Preserve current behavior for valid JSON (no regression in existing tests).

### Syntax Validation Strategy by Mode
`JSONStreamParser` currently uses parsing modes. For each mode, add lightweight checks for invalid characters or missing delimiters:
- Neutral mode:
  - Accept only whitespace, `{`, `[`, `"`, digits, `-`, `t`, `f`, `n`.
  - Any other byte => `unexpectedToken`.
  - `]` or `}` when stack is empty => `mismatchedClose`.
- Object key mode:
  - Expect `"` to start a string key; `}` to close if no pending key; whitespace allowed.
  - Any other byte => `unexpectedToken`.
- Object colon/value separator:
  - After a key string, expect `:` (with optional whitespace).
  - Missing `:` before a value => `missingDelimiter`.
- Array value mode:
  - Expect value token or `]` if empty/after comma.
  - Comma handling should enforce value between delimiters.
- String mode:
  - Treat any character after `\` as valid; only detect unterminated strings and invalid `\u` length/hex if the parser explicitly processes unicode escapes later.
  - Track unterminated string at end-of-input.
- Number mode:
  - Validate minus, leading zero rules, fractional digits, and exponent format.
  - Reject stray `+`, missing digits after `-`, `.` or `e/E`.
- Literal mode:
  - Only accept `true`, `false`, `null` with exact spelling.

### Implementation Steps (after tests)
- Add `JSONStreamParsingError` and wire it into the parser’s error reporting path.
- Add validation checks per mode at the byte-processing boundary.
- Ensure error detection is deterministic and uses the current byte offset.
- Update parser to stop processing after first syntax error.
