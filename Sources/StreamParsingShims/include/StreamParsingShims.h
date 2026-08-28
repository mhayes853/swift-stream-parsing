#ifndef STREAM_PARSING_SHIMS_H
#define STREAM_PARSING_SHIMS_H

#include <stdint.h>

#define STREAM_PARSING_SIMD_SHIM static inline __attribute__((always_inline))

// The one SIMD operation Swift's SIMD API cannot express: a byte table lookup. On arm64 it is
// `tbl`, and the UTF-8 validator's three nibble tables are each one instruction with it. The
// wrapper takes and returns an `ext_vector_type` so Swift imports it as `SIMD16<UInt8>`, and it
// is `static inline` so the call disappears into the Swift caller. Platforms without it take the
// validator's portable path; `#if arch(arm64)` on the Swift side is what selects this one.
#if defined(__aarch64__) && defined(__ARM_NEON)
#include <arm_neon.h>

typedef uint8_t stream_parsing_u8x16 __attribute__((ext_vector_type(16)));

STREAM_PARSING_SIMD_SHIM stream_parsing_u8x16
stream_parsing_tbl1q_u8(stream_parsing_u8x16 table, stream_parsing_u8x16 indices) {
  return (stream_parsing_u8x16)vqtbl1q_u8((uint8x16_t)table, (uint8x16_t)indices);
}

// The UTF-8 validator's block kernel, whole: the three nibble table lookups ANDed (Keiser and
// Lemire's special cases), XORed with 0x80 where a continuation is required by a three byte lead
// two back or a four byte lead three back. Nonzero lanes are errors. The three "previous byte"
// views are supplied by the caller as overlapping unaligned loads at `i - 1`, `i - 2`, `i - 3`.
//
// Two things were measured before this shape was kept. Composing the kernel from the primitives
// above on the Swift side ran 2.6x slower: Swift's SIMD operators are lane loops that LLVM
// re-vectorizes, and a shift or compare whose result feeds a fifteen lane `ext` came out half
// vectorized with the last lanes patched one at a time. And lane shifting the views from a
// carried block with `ext` instead of loading them was 10% slower on the validator alone: the
// loads issue on the load ports, where `ext` competes with the kernel's own vector ALU work.
STREAM_PARSING_SIMD_SHIM stream_parsing_u8x16
stream_parsing_utf8_block_errors(stream_parsing_u8x16 current_block,
                                 stream_parsing_u8x16 previous1_block,
                                 stream_parsing_u8x16 previous2_block,
                                 stream_parsing_u8x16 previous3_block,
                                 stream_parsing_u8x16 previous_high_table,
                                 stream_parsing_u8x16 previous_low_table,
                                 stream_parsing_u8x16 current_high_table) {
  uint8x16_t current = (uint8x16_t)current_block;
  uint8x16_t previous1 = (uint8x16_t)previous1_block;
  uint8x16_t previous2 = (uint8x16_t)previous2_block;
  uint8x16_t previous3 = (uint8x16_t)previous3_block;
  uint8x16_t special = vandq_u8(
      vandq_u8(vqtbl1q_u8((uint8x16_t)previous_high_table, vshrq_n_u8(previous1, 4)),
               vqtbl1q_u8((uint8x16_t)previous_low_table, vandq_u8(previous1, vdupq_n_u8(0x0F)))),
      vqtbl1q_u8((uint8x16_t)current_high_table, vshrq_n_u8(current, 4)));
  uint8x16_t third = vqsubq_u8(previous2, vdupq_n_u8(0xE0 - 0x80));
  uint8x16_t fourth = vqsubq_u8(previous3, vdupq_n_u8(0xF0 - 0x80));
  uint8x16_t must_continue = vandq_u8(vorrq_u8(third, fourth), vdupq_n_u8(0x80));
  return (stream_parsing_u8x16)veorq_u8(special, must_continue);
}
#endif

// MARK: - x86: the UTF-8 validator
//
// Keiser and Lemire's lookup kernel at 32 bytes a block, with AVX2's `vpshufb`. This is the same
// algorithm `stream_parsing_utf8_block_errors` runs above with `tbl`, and the same one
// `streamValidateUTF8Scalar` recomputes with range compares everywhere else -- three spellings of
// one set of error classes.
//
// **AVX2 or nothing.** There is deliberately no SSSE3 or SSE2 twin: a machine without AVX2 keeps
// the portable Swift validator, which is already correct and already pinned against the standard
// library's decoder. Carrying narrower C tiers would mean carrying their differential tests too,
// for hardware this library is not being tuned for.
//
// Unlike the arm64 shims above these are `static` but **not** `always_inline`. Clang will not
// force-inline a function carrying a target attribute into a caller compiled without that
// feature -- it is a hard LLVM `report_fatal_error`, not a diagnostic -- so the inliner has to be
// left free to decline. That costs nothing here: `streamValidateUTF8` is already `@inline(never)`
// on the Swift side and already runs once per non-ASCII string run, so the call that was there is
// the call that is here.
#if defined(__x86_64__)

#include <immintrin.h>
#include <stddef.h>
#include <string.h>

// Storage class included deliberately: these are file-static, and `static` has to sit
// alongside the target attribute rather than be spelled separately at each definition.
#define STREAM_PARSING_AVX2_FN static __attribute__((target("avx2")))

// Every lane of the block agreed with zero, i.e. no lane carried an error class.
#define STREAM_PARSING_AVX2_ALL_ZERO(v) \
  (_mm256_movemask_epi8(_mm256_cmpeq_epi8((v), _mm256_setzero_si256())) == (int)0xFFFFFFFF)

// The error-class bits, and the three nibble tables built from them. These are the Swift tables
// (`streamUTF8PreviousHighTable`, `streamUTF8PreviousLowTable`, `streamUTF8CurrentHighTable`)
// byte for byte, kept here so the loop can broadcast them once rather than take them as
// arguments the way the arm64 block shim does.
#define STREAM_UTF8_TOO_SHORT         (1 << 0)
#define STREAM_UTF8_TOO_LONG          (1 << 1)
#define STREAM_UTF8_OVERLONG_3        (1 << 2)
#define STREAM_UTF8_TOO_LARGE         (1 << 3)
#define STREAM_UTF8_SURROGATE         (1 << 4)
#define STREAM_UTF8_OVERLONG_2        (1 << 5)
#define STREAM_UTF8_TOO_LARGE_1000    (1 << 6)
#define STREAM_UTF8_OVERLONG_4        (1 << 6)
#define STREAM_UTF8_TWO_CONTINUATIONS (1 << 7)
#define STREAM_UTF8_CARRY \
  (STREAM_UTF8_TOO_SHORT | STREAM_UTF8_TOO_LONG | STREAM_UTF8_TWO_CONTINUATIONS)

// Indexed by the high nibble of the previous byte.
static const uint8_t stream_parsing_utf8_previous_high[16] = {
  STREAM_UTF8_TOO_LONG, STREAM_UTF8_TOO_LONG, STREAM_UTF8_TOO_LONG, STREAM_UTF8_TOO_LONG,
  STREAM_UTF8_TOO_LONG, STREAM_UTF8_TOO_LONG, STREAM_UTF8_TOO_LONG, STREAM_UTF8_TOO_LONG,
  STREAM_UTF8_TWO_CONTINUATIONS, STREAM_UTF8_TWO_CONTINUATIONS,
  STREAM_UTF8_TWO_CONTINUATIONS, STREAM_UTF8_TWO_CONTINUATIONS,
  STREAM_UTF8_TOO_SHORT | STREAM_UTF8_OVERLONG_2,
  STREAM_UTF8_TOO_SHORT,
  STREAM_UTF8_TOO_SHORT | STREAM_UTF8_OVERLONG_3 | STREAM_UTF8_SURROGATE,
  STREAM_UTF8_TOO_SHORT | STREAM_UTF8_TOO_LARGE | STREAM_UTF8_TOO_LARGE_1000
    | STREAM_UTF8_OVERLONG_4
};

// Indexed by the low nibble of the previous byte.
static const uint8_t stream_parsing_utf8_previous_low[16] = {
  STREAM_UTF8_CARRY | STREAM_UTF8_OVERLONG_3 | STREAM_UTF8_OVERLONG_2 | STREAM_UTF8_OVERLONG_4,
  STREAM_UTF8_CARRY | STREAM_UTF8_OVERLONG_2,
  STREAM_UTF8_CARRY,
  STREAM_UTF8_CARRY,
  STREAM_UTF8_CARRY | STREAM_UTF8_TOO_LARGE,
  STREAM_UTF8_CARRY | STREAM_UTF8_TOO_LARGE | STREAM_UTF8_TOO_LARGE_1000,
  STREAM_UTF8_CARRY | STREAM_UTF8_TOO_LARGE | STREAM_UTF8_TOO_LARGE_1000,
  STREAM_UTF8_CARRY | STREAM_UTF8_TOO_LARGE | STREAM_UTF8_TOO_LARGE_1000,
  STREAM_UTF8_CARRY | STREAM_UTF8_TOO_LARGE | STREAM_UTF8_TOO_LARGE_1000,
  STREAM_UTF8_CARRY | STREAM_UTF8_TOO_LARGE | STREAM_UTF8_TOO_LARGE_1000,
  STREAM_UTF8_CARRY | STREAM_UTF8_TOO_LARGE | STREAM_UTF8_TOO_LARGE_1000,
  STREAM_UTF8_CARRY | STREAM_UTF8_TOO_LARGE | STREAM_UTF8_TOO_LARGE_1000,
  STREAM_UTF8_CARRY | STREAM_UTF8_TOO_LARGE | STREAM_UTF8_TOO_LARGE_1000,
  STREAM_UTF8_CARRY | STREAM_UTF8_TOO_LARGE | STREAM_UTF8_TOO_LARGE_1000
    | STREAM_UTF8_SURROGATE,
  STREAM_UTF8_CARRY | STREAM_UTF8_TOO_LARGE | STREAM_UTF8_TOO_LARGE_1000,
  STREAM_UTF8_CARRY | STREAM_UTF8_TOO_LARGE | STREAM_UTF8_TOO_LARGE_1000
};

// Indexed by the high nibble of the current byte.
static const uint8_t stream_parsing_utf8_current_high[16] = {
  STREAM_UTF8_TOO_SHORT, STREAM_UTF8_TOO_SHORT, STREAM_UTF8_TOO_SHORT, STREAM_UTF8_TOO_SHORT,
  STREAM_UTF8_TOO_SHORT, STREAM_UTF8_TOO_SHORT, STREAM_UTF8_TOO_SHORT, STREAM_UTF8_TOO_SHORT,
  STREAM_UTF8_TOO_LONG | STREAM_UTF8_OVERLONG_2 | STREAM_UTF8_TWO_CONTINUATIONS
    | STREAM_UTF8_OVERLONG_3 | STREAM_UTF8_TOO_LARGE_1000 | STREAM_UTF8_OVERLONG_4,
  STREAM_UTF8_TOO_LONG | STREAM_UTF8_OVERLONG_2 | STREAM_UTF8_TWO_CONTINUATIONS
    | STREAM_UTF8_OVERLONG_3 | STREAM_UTF8_TOO_LARGE,
  STREAM_UTF8_TOO_LONG | STREAM_UTF8_OVERLONG_2 | STREAM_UTF8_TWO_CONTINUATIONS
    | STREAM_UTF8_SURROGATE | STREAM_UTF8_TOO_LARGE,
  STREAM_UTF8_TOO_LONG | STREAM_UTF8_OVERLONG_2 | STREAM_UTF8_TWO_CONTINUATIONS
    | STREAM_UTF8_SURROGATE | STREAM_UTF8_TOO_LARGE,
  STREAM_UTF8_TOO_SHORT, STREAM_UTF8_TOO_SHORT, STREAM_UTF8_TOO_SHORT, STREAM_UTF8_TOO_SHORT
};

// A run's first block, and any run shorter than one, is validated out of a zeroed scratch: zero
// reads as ASCII, which is exactly what lies before a run (a quote, an escape, a chunk boundary
// `completePendingUTF8` already settled) and what must follow it. Layout mirrors
// `streamValidateUTF8Scalar`'s, widened for the 32 byte block: [0,3) the three bytes before, then
// [3,35) the block, then zero.
#define STREAM_PARSING_UTF8_PROLOGUE 3

// Nonzero lanes are errors: the three nibble lookups ANDed (Keiser and Lemire's special cases),
// XORed with 0x80 where a continuation is required by a three byte lead two back or a four byte
// lead three back.
STREAM_PARSING_AVX2_FN __m256i
stream_parsing_utf8_errors(__m256i current, __m256i previous1, __m256i previous2,
                           __m256i previous3, __m256i ph, __m256i pl, __m256i ch) {
  const __m256i nibble = _mm256_set1_epi8(0x0F);
  __m256i special = _mm256_and_si256(
      _mm256_and_si256(
          _mm256_shuffle_epi8(ph, _mm256_and_si256(_mm256_srli_epi16(previous1, 4), nibble)),
          _mm256_shuffle_epi8(pl, _mm256_and_si256(previous1, nibble))),
      _mm256_shuffle_epi8(ch, _mm256_and_si256(_mm256_srli_epi16(current, 4), nibble)));
  __m256i third = _mm256_subs_epu8(previous2, _mm256_set1_epi8((char)(0xE0 - 0x80)));
  __m256i fourth = _mm256_subs_epu8(previous3, _mm256_set1_epi8((char)(0xF0 - 0x80)));
  __m256i must_continue =
      _mm256_and_si256(_mm256_or_si256(third, fourth), _mm256_set1_epi8((char)0x80));
  return _mm256_xor_si256(special, must_continue);
}

// One block out of `scratch`, whose prologue holds the three bytes before it.
#define STREAM_PARSING_UTF8_SCRATCH_BLOCK(scratch, ph, pl, ch)                 \
  stream_parsing_utf8_errors(                                                  \
      _mm256_loadu_si256((const __m256i *)((scratch) + 3)),                    \
      _mm256_loadu_si256((const __m256i *)((scratch) + 2)),                    \
      _mm256_loadu_si256((const __m256i *)((scratch) + 1)),                    \
      _mm256_loadu_si256((const __m256i *)((scratch) + 0)), (ph), (pl), (ch))

STREAM_PARSING_AVX2_FN int
stream_parsing_utf8_validate_avx2(const unsigned char *p, ptrdiff_t from, ptrdiff_t to) {
  ptrdiff_t count = to - from;
  const __m256i ph =
      _mm256_broadcastsi128_si256(_mm_loadu_si128((const __m128i *)stream_parsing_utf8_previous_high));
  const __m256i pl =
      _mm256_broadcastsi128_si256(_mm_loadu_si128((const __m128i *)stream_parsing_utf8_previous_low));
  const __m256i ch =
      _mm256_broadcastsi128_si256(_mm_loadu_si128((const __m128i *)stream_parsing_utf8_current_high));

  {
    // The first block, and any run shorter than one: there is no narrower tier to hand a short
    // run to, so this path covers every length.
    unsigned char scratch[64] = { 0 };
    memcpy(scratch + STREAM_PARSING_UTF8_PROLOGUE, p + from,
           (size_t)(count < 32 ? count : 32));
    if (!STREAM_PARSING_AVX2_ALL_ZERO(
            STREAM_PARSING_UTF8_SCRATCH_BLOCK(scratch, ph, pl, ch))) {
      return 0;
    }
  }

  ptrdiff_t i = from + 32;
  for (; i + 64 <= to; i += 64) {
    // Adjacent blocks are independent because each reconstructs its three previous-byte views
    // with overlapping loads. Keep both error DAGs in flight, then pay one scalar reduction and
    // branch for the pair. The validator reports only validity; the scalar diagnostic walk finds
    // the offending byte after a failure, so combining the error vectors loses no information.
    const unsigned char *q0 = p + i;
    const unsigned char *q1 = q0 + 32;
    __m256i err0 = stream_parsing_utf8_errors(
        _mm256_loadu_si256((const __m256i *)q0),
        _mm256_loadu_si256((const __m256i *)(q0 - 1)),
        _mm256_loadu_si256((const __m256i *)(q0 - 2)),
        _mm256_loadu_si256((const __m256i *)(q0 - 3)), ph, pl, ch);
    __m256i err1 = stream_parsing_utf8_errors(
        _mm256_loadu_si256((const __m256i *)q1),
        _mm256_loadu_si256((const __m256i *)(q1 - 1)),
        _mm256_loadu_si256((const __m256i *)(q1 - 2)),
        _mm256_loadu_si256((const __m256i *)(q1 - 3)), ph, pl, ch);
    if (!STREAM_PARSING_AVX2_ALL_ZERO(_mm256_or_si256(err0, err1))) return 0;
  }

  for (; i + 32 <= to; i += 32) {
    // The "previous byte" views are overlapping unaligned loads rather than lane shifts off a
    // carried block: the loads issue on the load ports, where a shift would compete with the
    // kernel's own vector ALU work. The arm64 shim's header comment measures the same choice.
    const unsigned char *q = p + i;
    __m256i err = stream_parsing_utf8_errors(
        _mm256_loadu_si256((const __m256i *)q),
        _mm256_loadu_si256((const __m256i *)(q - 1)),
        _mm256_loadu_si256((const __m256i *)(q - 2)),
        _mm256_loadu_si256((const __m256i *)(q - 3)), ph, pl, ch);
    if (!STREAM_PARSING_AVX2_ALL_ZERO(err)) return 0;
  }

  if (i < to) {
    // `i >= from + 32`, so the three bytes before the tail are the run's own. The tail is at most
    // 31 bytes, which one block over a zeroed scratch covers.
    unsigned char scratch[64] = { 0 };
    memcpy(scratch, p + i - 3, 3);
    memcpy(scratch + STREAM_PARSING_UTF8_PROLOGUE, p + i, (size_t)(to - i));
    if (!STREAM_PARSING_AVX2_ALL_ZERO(
            STREAM_PARSING_UTF8_SCRATCH_BLOCK(scratch, ph, pl, ch))) {
      return 0;
    }
  }
  return 1;
}

// MARK: - x86: the string run scanner, wide tier
//
// The escalation tier behind `streamStringRun`. Swift scans the first two 16 byte blocks inline;
// a run that survives both is long by definition, and only then does it reach this. On the corpus
// that is 9.7% of twitter's runs (43.7% of its string bytes), 25.4% of github_events' and 1.0% of
// citm's -- so a document made of short keys pays the escalation test and nothing else.
//
// `containsNonASCII` comes out cheaper here than the Swift SIMD16 path computes it. That path
// builds a lane index mask, selects the bytes before the terminator with `replacing(with:where:)`,
// ORs them into the accumulator and reduces -- five vector ops on the hit path. `vpmovmskb` of the
// raw block *is* the per byte high bit, so masking off the bytes at and after the terminator is
// one AND against `(1 << lane) - 1`.
//
// The flag stays exact, which the parser depends on: a validated ASCII run skips UTF-8 validation
// entirely, so a false negative would let invalid UTF-8 through.
STREAM_PARSING_AVX2_FN ptrdiff_t
stream_parsing_string_run_avx2(const void *base, ptrdiff_t from, ptrdiff_t to,
                               int *out_non_ascii) {
  const unsigned char *p = (const unsigned char *)base;
  const __m256i quote = _mm256_set1_epi8('"');
  const __m256i escape = _mm256_set1_epi8('\\');
  const __m256i control = _mm256_set1_epi8(0x1F);
  __m256i seen = _mm256_setzero_si256();  // OR of every byte scanned in full
  ptrdiff_t i = from;

  for (; i + 32 <= to; i += 32) {
    __m256i c = _mm256_loadu_si256((const __m256i *)(p + i));
    __m256i hit = _mm256_or_si256(
        _mm256_or_si256(_mm256_cmpeq_epi8(c, quote), _mm256_cmpeq_epi8(c, escape)),
        _mm256_cmpeq_epi8(_mm256_min_epu8(c, control), c));  // c <= 0x1F
    unsigned m = (unsigned)_mm256_movemask_epi8(hit);
    if (m) {
      unsigned lane = (unsigned)__builtin_ctz(m);
      unsigned high = (unsigned)_mm256_movemask_epi8(c) & ((1u << lane) - 1u);
      *out_non_ascii = ((unsigned)_mm256_movemask_epi8(seen) | high) != 0;
      return i + (ptrdiff_t)lane;
    }
    seen = _mm256_or_si256(seen, c);
  }

  // At most 31 bytes, and only where a chunk ends inside a run.
  int hi = _mm256_movemask_epi8(seen) != 0;
  for (; i < to; ++i) {
    unsigned char b = p[i];
    if (b == '"' || b == '\\' || b < 0x20) break;
    hi |= (b >= 0x80);
  }
  *out_non_ascii = hi;
  return i;
}

// Whether the AVX2 kernels above may be called at all. Resolved on first use and cached; every
// later call is a load and a predicted branch. Read once per run from an out-of-line Swift
// function, never from an inlined scan loop.
static inline int stream_parsing_has_avx2(void) {
  enum { STREAM_UTF8_UNKNOWN = 0, STREAM_UTF8_NONE = 1, STREAM_UTF8_AVX2 = 2 };
  static int tier = STREAM_UTF8_UNKNOWN;
  int cached = tier;
  if (__builtin_expect(cached == STREAM_UTF8_UNKNOWN, 0)) {
    __builtin_cpu_init();
    cached = __builtin_cpu_supports("avx2") ? STREAM_UTF8_AVX2 : STREAM_UTF8_NONE;
    // Benign race: every thread computes the same value, and the write is a single aligned int.
    tier = cached;
  }
  return cached == STREAM_UTF8_AVX2;
}

// 1 = valid, 0 = invalid. `from`/`to` bound the run; nothing before `from` is part of a sequence
// and no sequence may run past `to`, matching `streamValidateUTF8Scalar`.
// Precondition: `stream_parsing_has_avx2()`.
// `ptrdiff_t` rather than `long`: both import to Swift as `Int`, and only one of them is
// 64 bits everywhere Swift runs -- `long` is 32 bits on Windows.
static inline int stream_parsing_utf8_validate(const void *base, ptrdiff_t from,
                                               ptrdiff_t to) {
  const unsigned char *p = (const unsigned char *)base;
  ptrdiff_t count = to - from;
  if (count <= 0) return 1;

  // A sequence cut by the end of the run. The block test sees the lead and never the missing
  // continuation, so the last three bytes are checked against what may legally sit there.
  // Identical to `streamValidateUTF8Scalar`'s prologue.
  //
  // 0xC0, not 0x80: a run may legally *end* on a continuation byte -- that is what the last byte
  // of every multi-byte scalar is. What cannot sit there is a lead whose continuations the run
  // does not contain. These are `utf8TwoByteFloor` / `utf8ThreeByteFloor` / `utf8FourByteFloor`.
  if (p[to - 1] >= 0xC0) return 0;
  if (count >= 2 && p[to - 2] >= 0xE0) return 0;
  if (count >= 3 && p[to - 3] >= 0xF0) return 0;

  return stream_parsing_utf8_validate_avx2(p, from, to);
}

#endif  // __x86_64__

// The Eisel-Lemire power-of-ten table, defined in `Pow10_128.c` and generated -- see the header
// comment there. The array is declared incomplete because Swift imports a sized C array as a
// tuple of that many elements. As with the Double table below, an always-inlined accessor avoids
// a pointer variable's dependent load and lets the caller materialise the array address directly.
extern const uint64_t stream_parsing_pow10_128_storage[];

STREAM_PARSING_SIMD_SHIM const uint64_t *stream_parsing_pow10_128(void) {
  return stream_parsing_pow10_128_storage;
}

// These are part of the generated table's shape, not runtime data. Keeping them as macros lets
// Swift fold both range checks and the index bias instead of loading two exported C globals.
#define STREAM_PARSING_POW10_128_MIN_EXPONENT (-342)
#define STREAM_PARSING_POW10_128_MAX_EXPONENT (308)

// Exact `double` values of 10^q for q in 0 ... 22, defined in `Pow10_Double.c` and generated --
// see the header comment there. Same reason as above for living in C: `.rodata` instead of a
// lazily allocated Swift array global.
//
// Reached through an always-inlined accessor rather than a `const double *const` global, because
// a pointer variable costs a dependent load of the pointer itself before the load of the entry.
// The accessor folds into the Swift caller as the `adrp`/`add` pair that materialises the table's
// address, so only the entry is loaded. The array is declared incomplete because Swift imports a
// sized C array as a tuple of that many elements.
extern const double stream_parsing_pow10_double_storage[];

STREAM_PARSING_SIMD_SHIM const double *stream_parsing_pow10_double(void) {
  return stream_parsing_pow10_double_storage;
}

#define STREAM_PARSING_POW10_DOUBLE_MIN_EXPONENT (0)
#define STREAM_PARSING_POW10_DOUBLE_MAX_EXPONENT (22)
#define STREAM_PARSING_POW10_DOUBLE_COUNT (23)

#endif
