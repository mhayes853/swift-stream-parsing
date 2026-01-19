## Plan: JSONStreamParser Invalid Syntax Handling

### Updated Implementation Plan
1) Review existing parser modes and output behavior to identify invariants we must preserve (streamed partials, mode transitions, stack handling). Document these invariants in a short checklist for validating no regressions while adding errors.
2) Add/adjust tests to cover the “no registered path” scenario (e.g. `currentStringPath` is nil in `parseString`) to assert internal state still updates for consumed bytes even when no value is emitted. Add a dedicated test (e.g. `testUnregisteredPathStillUpdatesState`) that feeds a JSON object with an unregistered key followed by a registered key, and asserts that the registered key still parses correctly after the unregistered value is consumed. Example payload: `{"ignored":"alpha","tracked":"beta"}` with only `tracked` registered; expect `tracked` to emit `beta` and no errors.
3) Introduce error types/positions and wire a single error-reporting path that short-circuits parsing after first syntax error without altering successful parsing paths.
4) Add mode-specific syntax validation with minimal disruption to current tokenization: enforce delimiters (colon/comma), mismatched closes, invalid literals/numbers, and unexpected tokens; ensure trailing comma detection in object/array modes via “expecting value vs expecting delimiter” state.
5) Ensure end-of-input validation for unterminated strings/containers and dangling delimiters; confirm trailing bytes after error do not emit new partials while preserving already-emitted partials.
6) Run/adjust tests to verify preserved behavior on valid streams and all error cases (including trailing commas) and finalize any edge-case handling.

### Step 1 Notes: Parsing Invariants Checklist
- `parse(byte:)` always returns the current reducer state after each byte via `PartialsStream`; bytes that do not represent meaningful tokens leave the value unchanged.
- Mode transitions must mirror the current parser: `neutral` dispatches to `string`, `integer`, `fractionalDouble`, `exponentialDouble`, `keyFinding`, `keyCollecting`; numeric modes fall back to `neutral` and reprocess the current byte for delimiters.
- Arrays use `StackElement.array(index)`; `[` pushes index 0 and (if registered) resets the array; `,` increments the index by replacing the last stack element; `]` pops the last element and updates the parent path.
- Objects use `StackElement.object(key)` only after a key is fully collected and `:` is seen; `{` enters `keyFinding` and (if registered) resets the dictionary; `,` in object scope returns to `keyFinding`; `}` pops the last object key and updates the parent path.
- `appendArrayElementIfNeeded` runs before any value token to keep array element slots aligned with streamed partials.
- Strings must advance state even when `currentStringPath` is nil: escape tracking, UTF-8 decoding, and closing quote detection still need to move the mode back to `neutral`.
- Numbers append digits to the accumulator while in numeric modes; on non-digit bytes, the parser resets to `neutral` and replays the byte so delimiters (comma, bracket, brace) are still honored.
- Booleans and null are applied immediately in `neutral` on `t`/`f`/`n` without an explicit literal mode; error handling should not break existing tolerance for those bytes.
