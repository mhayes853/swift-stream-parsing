// The x86-64 AVX2 tier, out of line.
//
// `immintrin.h` must not be reachable from the umbrella header: from a modular header it forces
// `_Builtin_intrinsics`, which some x86-64 SDKs cannot build. Nothing is lost -- every function
// here carries `target("avx2")`, which already bars inlining into a baseline caller.
#include "include/StreamParsingShims.h"

// MARK: - x86: the UTF-8 validator
//
// Keiser and Lemire's lookup kernel at 32 bytes a block with `vpshufb`; AVX2 or nothing. Never
// `always_inline`: force-inlining one into a baseline caller is a hard LLVM `report_fatal_error`.
#if defined(__x86_64__)

#include <immintrin.h>
#include <stddef.h>
#include <string.h>

// C11 atomics, for the feature cache near the bottom of the file only. A freestanding or
// pre-C11 toolchain that defines `__STDC_NO_ATOMICS__` keeps the plain `int` this used to be:
// the race is benign in practice on every x86 this compiles for, and losing the tier over a
// missing header would not be.
#if defined(__STDC_NO_ATOMICS__)
#define STREAM_PARSING_ATOMIC_INT int
#define STREAM_PARSING_RELAXED_LOAD(p) (*(p))
#define STREAM_PARSING_RELAXED_STORE(p, v) (*(p) = (v))
#else
#include <stdatomic.h>
#define STREAM_PARSING_ATOMIC_INT _Atomic int
#define STREAM_PARSING_RELAXED_LOAD(p) atomic_load_explicit(p, memory_order_relaxed)
#define STREAM_PARSING_RELAXED_STORE(p, v) atomic_store_explicit(p, v, memory_order_relaxed)
#endif

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
// reads as ASCII, which is exactly what lies before and after a run. Layout mirrors
// `streamValidateUTF8Scalar`'s, widened to the 32 byte block: [0,3) the three bytes before,
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
// The escalation tier behind `streamStringRun`; Swift scans the first two 16-byte blocks inline, so
// a run reaching here is long. `containsNonASCII` must stay exact: an ASCII run skips validation.
__attribute__((target("avx2"))) ptrdiff_t
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

// MARK: - x86: the 64-byte block classifiers
//
// The two NEON kernels in StreamParsingShims.h restated for AVX2 bit for bit. `vpshufb` zeroes any
// lane whose index byte has its high bit set, so the low-nibble tables take the raw byte.
#define STREAM_PARSING_BLOCK_FN __attribute__((target("avx2,pclmul,popcnt")))

// A 16-entry table in both 128-bit halves. From a `static const` array, as the validator's are,
// so the table is one `vbroadcasti128` from read-only data rather than a 32-byte literal.
#define STREAM_PARSING_BLOCK_TABLE(table) \
  _mm256_broadcastsi128_si256(_mm_loadu_si128((const __m128i *)(table)))

// One bit per byte of the 64-byte block, ascending: the low register's 32 lanes, then the high
// register's.
STREAM_PARSING_BLOCK_FN static inline uint64_t
stream_parsing_block_mask(__m256i low, __m256i high) {
  return (uint64_t)(uint32_t)_mm256_movemask_epi8(low)
      | ((uint64_t)(uint32_t)_mm256_movemask_epi8(high) << 32);
}

// Bit i becomes the XOR of bits 0...i: one carryless multiply by all ones.
STREAM_PARSING_BLOCK_FN static inline uint64_t
stream_parsing_block_prefix_xor(uint64_t bitmask) {
  __m128i product = _mm_clmulepi64_si128(
      _mm_cvtsi64_si128((long long)bitmask), _mm_set1_epi8((char)0xFF), 0);
  return (uint64_t)_mm_cvtsi128_si64(product);
}

// Lanes holding a byte below 0x20. Unsigned: `vpcmpgtb` is signed and would count every byte
// >= 0x80 as "below", which inside a string is a valid UTF-8 byte, not a control byte.
STREAM_PARSING_BLOCK_FN static inline __m256i
stream_parsing_block_control(__m256i v) {
  return _mm256_cmpeq_epi8(_mm256_min_epu8(v, _mm256_set1_epi8(0x1F)), v);
}

// Whether any byte of the block is below 0x20, for the in-string early outs: one reduction over
// the pair instead of a movemask per register.
STREAM_PARSING_BLOCK_FN static inline uint32_t
stream_parsing_block_any_control(__m256i v0, __m256i v1) {
  return _mm256_movemask_epi8(stream_parsing_block_control(_mm256_min_epu8(v0, v1))) != 0;
}

// The skip classifier's tables: StreamParsingShims.h documents the encoding (bits 0...6 accepted
// by row, bit 7 the bracket rectangle). Byte for byte the NEON kernel's.
static const uint8_t stream_parsing_skip_lo_table[16] = {
  0x46, 0x64, 0x66, 0x64, 0x64, 0x6C, 0x64, 0x64,
  0x64, 0x65, 0x65, 0xF2, 0x22, 0xF3, 0x22, 0x20
};
static const uint8_t stream_parsing_skip_hi_table[16] = {
  0x01, 0x00, 0x02, 0x04, 0x08, 0x90, 0x20, 0xC0,
  0, 0, 0, 0, 0, 0, 0, 0
};

STREAM_PARSING_BLOCK_FN stream_parsing_skip_classes
stream_parsing_classify_skip_block(
  const uint8_t *p, uint64_t in_string_carry, uint64_t ends_odd_carry
) {
  const __m256i v0 = _mm256_loadu_si256((const __m256i *)p);
  const __m256i v1 = _mm256_loadu_si256((const __m256i *)(p + 32));

  const __m256i backslash_byte = _mm256_set1_epi8('\\');
  const __m256i quote_byte = _mm256_set1_epi8('"');
  uint64_t backslash = stream_parsing_block_mask(
      _mm256_cmpeq_epi8(v0, backslash_byte), _mm256_cmpeq_epi8(v1, backslash_byte));
  uint64_t quote = stream_parsing_block_mask(
      _mm256_cmpeq_epi8(v0, quote_byte), _mm256_cmpeq_epi8(v1, quote_byte));
  quote &= ~stream_parsing_find_escaped(backslash, &ends_odd_carry);
  uint64_t in_string = stream_parsing_block_prefix_xor(quote) ^ in_string_carry;

  stream_parsing_skip_classes out;
  out.in_string = (uint64_t)((int64_t)in_string >> 63);
  out.ends_odd = ends_odd_carry;
  // The high bit of every byte is what `vpmovmskb` reads, so "any byte >= 0x80" is one OR and
  // one movemask -- NEON needs a `umaxv` reduction for it.
  out.non_ascii = _mm256_movemask_epi8(_mm256_or_si256(v0, v1)) != 0;

  // Edge to edge inside a string: no brackets by construction, only the control test.
  if (quote == 0 && in_string == ~(uint64_t)0) {
    out.brackets = 0;
    out.needs_scalar = stream_parsing_block_any_control(v0, v1);
    return out;
  }

  const __m256i lo_table = STREAM_PARSING_BLOCK_TABLE(stream_parsing_skip_lo_table);
  const __m256i hi_table = STREAM_PARSING_BLOCK_TABLE(stream_parsing_skip_hi_table);
  const __m256i low_nibble = _mm256_set1_epi8(0x0F);
  const __m256i accepted_bits = _mm256_set1_epi8(0x7F);
  const __m256i zero = _mm256_setzero_si256();

  // Raw-byte index into the low table (see the section comment); masked high nibble into the
  // high one.
  __m256i c0 = _mm256_and_si256(
      _mm256_shuffle_epi8(lo_table, v0),
      _mm256_shuffle_epi8(hi_table, _mm256_and_si256(_mm256_srli_epi16(v0, 4), low_nibble)));
  __m256i c1 = _mm256_and_si256(
      _mm256_shuffle_epi8(lo_table, v1),
      _mm256_shuffle_epi8(hi_table, _mm256_and_si256(_mm256_srli_epi16(v1, 4), low_nibble)));

  uint64_t unaccepted = stream_parsing_block_mask(
      _mm256_cmpeq_epi8(_mm256_and_si256(c0, accepted_bits), zero),
      _mm256_cmpeq_epi8(_mm256_and_si256(c1, accepted_bits), zero));
  // The bracket class is bit 7, and bit 7 is the bit `vpmovmskb` reads: the brackets are the
  // class vectors' own movemask, no test against a splat.
  uint64_t brackets = stream_parsing_block_mask(c0, c1);
  uint64_t control = stream_parsing_block_mask(
      stream_parsing_block_control(v0), stream_parsing_block_control(v1));

  out.brackets = brackets & ~in_string;
  out.needs_scalar = ((control & in_string) | (unaccepted & ~in_string)) != 0;
  return out;
}

// The structural classifier's tables: StreamParsingShims.h documents the encoding (eight class
// bits, whitespace on a separate lookup). Byte for byte the NEON kernel's. The whitespace table's
// fillers need no change for raw-byte indexing: 0xFF equals no byte below 0x80, and row F's 0x00
// equals no byte with a low nibble of F.
static const uint8_t stream_parsing_structural_lo_table[16] = {
  0x12, 0x30, 0x32, 0x30, 0x30, 0x70, 0x30, 0x30,
  0x30, 0x31, 0x39, 0xA2, 0x24, 0xA3, 0x22, 0x20
};
static const uint8_t stream_parsing_structural_hi_table[16] = {
  0x01, 0x00, 0x06, 0x18, 0x40, 0x80, 0x20, 0x90,
  0, 0, 0, 0, 0, 0, 0, 0
};
static const uint8_t stream_parsing_structural_ws_table[16] = {
  0x20, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
  0xFF, 0x09, 0x0A, 0xFF, 0xFF, 0x0D, 0xFF, 0x00
};

STREAM_PARSING_BLOCK_FN stream_parsing_structural_classes
stream_parsing_classify_structural_block(
  const uint8_t *p, uint64_t in_string_carry, uint64_t ends_odd_carry
) {
  const __m256i v0 = _mm256_loadu_si256((const __m256i *)p);
  const __m256i v1 = _mm256_loadu_si256((const __m256i *)(p + 32));

  const __m256i backslash_byte = _mm256_set1_epi8('\\');
  const __m256i quote_byte = _mm256_set1_epi8('"');
  uint64_t backslash = stream_parsing_block_mask(
      _mm256_cmpeq_epi8(v0, backslash_byte), _mm256_cmpeq_epi8(v1, backslash_byte));
  uint64_t quote = stream_parsing_block_mask(
      _mm256_cmpeq_epi8(v0, quote_byte), _mm256_cmpeq_epi8(v1, quote_byte));
  quote &= ~stream_parsing_find_escaped(backslash, &ends_odd_carry);
  uint64_t in_string = stream_parsing_block_prefix_xor(quote) ^ in_string_carry;

  stream_parsing_structural_classes out;
  out.quote = quote;
  out.backslash = backslash;
  out.in_string = (uint64_t)((int64_t)in_string >> 63);
  out.ends_odd = ends_odd_carry;
  out.non_ascii = _mm256_movemask_epi8(_mm256_or_si256(v0, v1)) != 0;

  // Edge to edge inside a string. Dead for the structural walk, which always passes zero carries
  // (see the NEON kernel); kept so the two spellings answer every input alike.
  if (quote == 0 && in_string == ~(uint64_t)0) {
    out.no_outer_whitespace = 1;
    out.strike = 1;
    out.starts = 0;
    out.needs_scalar = stream_parsing_block_any_control(v0, v1);
    return out;
  }

  const __m256i lo_table = STREAM_PARSING_BLOCK_TABLE(stream_parsing_structural_lo_table);
  const __m256i hi_table = STREAM_PARSING_BLOCK_TABLE(stream_parsing_structural_hi_table);
  const __m256i ws_table = STREAM_PARSING_BLOCK_TABLE(stream_parsing_structural_ws_table);
  const __m256i low_nibble = _mm256_set1_epi8(0x0F);
  const __m256i zero = _mm256_setzero_si256();

  __m256i c0 = _mm256_and_si256(
      _mm256_shuffle_epi8(lo_table, v0),
      _mm256_shuffle_epi8(hi_table, _mm256_and_si256(_mm256_srli_epi16(v0, 4), low_nibble)));
  __m256i c1 = _mm256_and_si256(
      _mm256_shuffle_epi8(lo_table, v1),
      _mm256_shuffle_epi8(hi_table, _mm256_and_si256(_mm256_srli_epi16(v1, 4), low_nibble)));

  // Every class bit counts as "accepted" here (NEON's `vtstq(c, c)`), for the reason the NEON
  // kernel gives: every bracket is an accepted byte.
  uint64_t unaccepted = stream_parsing_block_mask(
      _mm256_cmpeq_epi8(c0, zero), _mm256_cmpeq_epi8(c1, zero));
  uint64_t whitespace = stream_parsing_block_mask(
      _mm256_cmpeq_epi8(v0, _mm256_shuffle_epi8(ws_table, v0)),
      _mm256_cmpeq_epi8(v1, _mm256_shuffle_epi8(ws_table, v1)));
  uint64_t control = stream_parsing_block_mask(
      stream_parsing_block_control(v0), stream_parsing_block_control(v1));

  out.no_outer_whitespace = (whitespace & ~in_string) == 0;
  out.starts = (~(in_string | whitespace | quote)) | (quote & in_string);
  out.strike = out.no_outer_whitespace
      | (__builtin_popcountll(out.starts) >= STREAM_PARSING_BLOCK_WALK_DENSE_STARTS);
  out.needs_scalar = ((control & in_string) | (unaccepted & ~in_string)) != 0;
  return out;
}

// MARK: - x86: feature detection
//
// `cpuid` by hand, not `__builtin_cpu_supports`: that builtin needs compiler-runtime symbols the
// Windows toolchain does not link into a Swift package. `cpuid` needs no runtime.
#if defined(_MSC_VER) || defined(_WIN32)
#include <intrin.h>
static void stream_parsing_cpuid(int regs[4], int leaf, int subleaf) {
  __cpuidex(regs, leaf, subleaf);
}
#else
#include <cpuid.h>
static void stream_parsing_cpuid(int regs[4], int leaf, int subleaf) {
  __cpuid_count(leaf, subleaf, regs[0], regs[1], regs[2], regs[3]);
}
#endif

// `xgetbv` reports which register state the *OS* has agreed to save across a context switch: without
// XMM and YMM in XCR0 a `vmovdqu` would lose its upper half at the first preemption. The target
// attribute is what makes the builtin legal to call (the feature is not on for the file); `cpuid`
// having already reported OSXSAVE is what makes the instruction legal to execute.
#if __has_builtin(__builtin_ia32_xgetbv)
__attribute__((target("xsave"))) static unsigned long long stream_parsing_xcr0(void) {
  return (unsigned long long)__builtin_ia32_xgetbv(0);
}
#define STREAM_PARSING_HAS_XCR0 1
#endif

// The feature word both probes below read: `PROBED` once resolved, plus one bit per tier.
enum {
  STREAM_X86_PROBED = 1 << 0,
  STREAM_X86_AVX2 = 1 << 1,
  STREAM_X86_BLOCK_KERNELS = 1 << 2
};

// Resolved on first use and cached; every later call is a relaxed load and a predicted branch.
// `_Atomic` relaxed rather than a plain `int`: racing threads all compute the same value, so no
// ordering is needed, but a plain object written from several threads is a C11 data race -- and a
// load the compiler may split or repeat. Relaxed costs nothing on x86 (a plain `mov` either way).
static int stream_parsing_x86_features(void) {
  static STREAM_PARSING_ATOMIC_INT features = 0;
  int cached = STREAM_PARSING_RELAXED_LOAD(&features);
  if (__builtin_expect(cached == 0, 0)) {
    int avx2 = 0;
    int clmul = 0;
    int popcnt = 0;
    int regs[4] = { 0, 0, 0, 0 };
    stream_parsing_cpuid(regs, 0, 0);
    if (regs[0] >= 7) {  // leaf 7, where the AVX2 bit lives, has to exist at all
      stream_parsing_cpuid(regs, 1, 0);
      clmul = (regs[2] >> 1) & 1;    // ECX bit 1 = PCLMULQDQ
      popcnt = (regs[2] >> 23) & 1;  // ECX bit 23 = POPCNT
      const int osxsave = (regs[2] >> 27) & 1;
      const int avx = (regs[2] >> 28) & 1;
#if defined(STREAM_PARSING_HAS_XCR0)
      const int os_saves_ymm = osxsave && (stream_parsing_xcr0() & 0x6) == 0x6;
#else
      // No way to ask; OSXSAVE alone is the best available answer.
      const int os_saves_ymm = osxsave;
#endif
      if (avx && os_saves_ymm) {
        stream_parsing_cpuid(regs, 7, 0);
        avx2 = (regs[1] >> 5) & 1;  // EBX bit 5 = AVX2
      }
    }
    cached = STREAM_X86_PROBED | (avx2 ? STREAM_X86_AVX2 : 0)
        | (avx2 && clmul && popcnt ? STREAM_X86_BLOCK_KERNELS : 0);
    // Racy by design: every thread computes the same value, so the last writer wins with nothing
    // to order against. See the note on the declaration for why it is still spelled atomically.
    STREAM_PARSING_RELAXED_STORE(&features, cached);
  }
  return cached;
}

// Whether the validator and string-scanner kernels above may be called at all. Read once per
// run from an out-of-line Swift function, never from an inlined scan loop.
int stream_parsing_has_avx2(void) {
  return (stream_parsing_x86_features() & STREAM_X86_AVX2) != 0;
}

// Whether the block classifiers may be called. Read once per parser, into `JSONParser`'s own
// flags, never per block.
int stream_parsing_has_avx2_block_kernels(void) {
  return (stream_parsing_x86_features() & STREAM_X86_BLOCK_KERNELS) != 0;
}

// 1 = valid, 0 = invalid. `from`/`to` bound the run; nothing before `from` is part of a sequence and
// no sequence may run past `to`, matching `streamValidateUTF8Scalar`. `ptrdiff_t` not `long`:
// `long` is 32 bits on Windows. Precondition: `stream_parsing_has_avx2()`.
int stream_parsing_utf8_validate(const void *base, ptrdiff_t from, ptrdiff_t to) {
  const unsigned char *p = (const unsigned char *)base;
  ptrdiff_t count = to - from;
  if (count <= 0) return 1;

  // A sequence cut by the end of the run: the block test sees the lead and never the missing
  // continuation, so the last three bytes are checked against what may legally sit there. Identical
  // to `streamValidateUTF8Scalar`'s prologue. 0xC0, not 0x80: a run may legally end on a
  // continuation byte; what cannot sit there is a lead whose continuations the run does not contain.
  if (p[to - 1] >= 0xC0) return 0;
  if (count >= 2 && p[to - 2] >= 0xE0) return 0;
  if (count >= 3 && p[to - 3] >= 0xF0) return 0;

  return stream_parsing_utf8_validate_avx2(p, from, to);
}

#endif  // __x86_64__
