## Plan: JSONStreamParser Configuration Support

### Goals
- Support configurable JSON syntax behaviors via `JSONStreamParserConfiguration` while preserving existing parsing behavior by default.
- Add dedicated tests for configuration combinations and ensure baseline parsing remains stable.

### Test Plan
1) Create a new sub test suite `JSONConfiguration tests` within `JSONStreamParser tests`.
2) Add targeted tests that toggle one configuration at a time:
   - Allow/disallow trailing commas in arrays and objects.
   - Allow/disallow comments (line and block).
   - Allow/disallow single-line comments (//) in neutral, key-finding, and value positions.
   - Allow/disallow single-quoted strings.
   - Allow/disallow single-quoted object keys (e.g., `{'key': 1}`).
   - Allow/disallow unquoted object keys.
   - Allow/disallow leading plus sign in numbers.
   - Allow/disallow leading zeros in numbers.
   - Allow/disallow NaN/Infinity (if supported as non-standard literals).
   - Allow/disallow whitespace control characters outside standard JSON whitespace.
3) Add combination tests to cover interactions (multiple flags enabled at once):
   - Allow trailing commas + comments in nested objects/arrays.
   - Unquoted keys + single-quoted strings in the same object.
   - Comments + unquoted keys in the same object.
   - Leading plus + leading zero + exponent formats.
   - Hex numbers + leading decimal point (ensure leading decimal point only affects decimal parsing).
4) Add tests that confirm configuration changes do not affect streaming behavior:
   - Emitted partials still align with array indices and object keys.
   - Ignored keys still advance internal state even when config toggles are enabled.
   - Invalid single-quoted string cases still surface correct syntax errors (e.g., unterminated single-quoted strings, mismatched quote types).
   - Invalid unquoted key cases still surface correct syntax errors (e.g., whitespace or punctuation inside an unquoted key).
   - Invalid single-quoted key cases still surface correct syntax errors (e.g., unterminated single-quoted keys or mismatched delimiters in object keys).

### Configuration Surface (Proposed)
- `allowTrailingCommas: Bool` (default false)
- `allowComments: Bool` (default false)
- `allowSingleQuotedStrings: Bool` (default false)
- `allowUnquotedKeys: Bool` (default false)
- `allowLeadingPlus: Bool` (default false)
- `allowLeadingZeros: Bool` (default false)
- `allowNonFiniteNumbers: Bool` (default false) // NaN/Infinity
- `allowControlCharactersInStrings: Bool` (default false)
- `allowUnicodeEscapesWithoutBraces: Bool` (default false) // if relevant to current escape handling
- `allowHexNumbers: Bool` (default false)
- `allowLeadingDecimalPoint: Bool` (default false) // .123 => 0.123

### Implementation Plan
1) Add the new `JSONConfiguration tests` suite and baseline tests for each configuration flag.
2) Update `JSONStreamParserConfiguration` to include the new syntactic toggles with explicit defaults. Condense the booleans into an `OptionSet` (e.g., `JSONSyntaxOptions`) stored on `JSONStreamParserConfiguration` while providing computed properties (or initializers) for convenience and backward compatibility.
3) Thread configuration into parsing logic with minimal disruption:
   - `parseNeutral`: when encountering `,` before `]`/`}` and `allowTrailingCommas == true`, accept and transition to “expecting close or value” state; otherwise keep throwing `trailingComma`.
   - `parseNeutral` and `parseKeyFinding`: when encountering `/` and `allowComments == true`, enter a `comment` mode (line/block) and ignore bytes until comment end; otherwise throw `unexpectedToken`.
   - Single-line comment specifics: on `//` enter `comment` mode configured for single-line; consume bytes until `\n` or `\r`, then return to the prior mode (neutral or keyFinding), preserving container state and delimiter expectations.
   - Add tests for single-line comments embedded in multi-line arrays and objects (e.g., comment between elements or between object entries) to ensure parser resumes correctly after newline boundaries.
   - `parseString`: allow starting quote of `'` when `allowSingleQuotedStrings == true`; otherwise throw `unexpectedToken`.
   - `parseKeyFinding`/`parseKeyCollecting`: allow `'` as a key delimiter when `allowSingleQuotedStrings == true`, and ensure closing delimiter matches the opening quote.
   - `parseKeyFinding`: if `allowUnquotedKeys == true`, accept identifier-style keys and collect until `:` or whitespace; otherwise only allow `"`-delimited keys.
   - Number parsing (`parseInteger`/`parseFractionalDouble`/`parseExponentialDouble`):
     - If `allowLeadingPlus == true`, accept `+` as a sign at the beginning of numbers.
     - If `allowLeadingZeros == true`, allow `0` followed by more digits without error.
     - If `allowNonFiniteNumbers == true`, recognize `NaN`/`Infinity` as literals.
     - If `allowHexNumbers == true`, accept `0x`/`0X` prefixed hex digits and parse into integer/float accumulators as appropriate (reject hex floats unless explicitly supported).
     - If `allowLeadingDecimalPoint == true`, accept `.` followed by digits at value-start and treat as `0.xxx` for number parsing.
   - String escape handling: if `allowControlCharactersInStrings == true`, do not error on ASCII < 0x20; otherwise keep strict validation.
4) Ensure configuration checks are localized to the earliest decision points in each mode to avoid state drift:
   - Keep existing stack/array index updates unchanged.
   - Preserve current error precedence (e.g., missing comma vs missing closing brace) by checking config before throwing.
5) Run full JSONStreamParser tests and update any expectations based on configuration defaults.

### Validation Checklist
- Default configuration behaves identically to current strict JSON parsing.
- Non-standard syntax is accepted only when the corresponding flag is enabled.
- Configuration toggles do not alter emitted partials or internal stack behavior.
