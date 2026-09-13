
Interleaved A/B against the committed 16-byte-record build (2c2a25d), two rounds, confirms
it: Real LLM message byte by byte 141 → 89 (−37%), Twitter escaped 135 → 103 (−24%); the
`Fast * - byte by byte` rows −15% (nested arrays, dictionary) to −38% (long string), uniform
across payloads that share nothing, which is the signature of a fixed cost per byte. An
always-inline delivery for `parse(byte:)` measured nothing and flipped `parse`'s inlining
(a 1,388-byte specialisation with 26 calls appeared), so it was reverted. The profile of the
long-string row puts the time in `consumeStringRun` (47%) and the `parse(byte:)` closure
(36%), with the sink's `events` at 11%: the per-byte record, the pending-begin settle and the
flush check on a path that otherwise does one SIMD probe per byte. Reducing it means either
a byte fed fast path that bypasses recording for single-byte string chunks (delivering them
as the call-per-event path did, through a narrower internal seam) or accepting that byte fed
input — already 27× off bulk before this round — pays the batch's fixed cost per byte.
That is a decision for the next round, not this one.
