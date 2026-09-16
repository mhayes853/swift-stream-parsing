#ifndef STREAM_PARSING_SHIMS_H
#define STREAM_PARSING_SHIMS_H

#include <stdint.h>

#define STREAM_PARSING_SIMD_SHIM static inline __attribute__((always_inline))

// MARK: - simdjson stage 1's two bit algorithms
//
// Shared by the window indexer (StreamParsingShims.c) and the classifiers below. They live in
// the header rather than that translation unit because the classifiers are inlined into Swift.

// Escaped positions: bit i set iff byte i follows an odd-length backslash run. `prev_ends_odd`
// carries "the previous block ended inside an odd run" in and out.
// Measured: NEON shapes cost +7..+31% per block and a `bs_bits == 0` early-out +0.7..+17.6%;
// keep it scalar (NEW_ARCHITECTURE.md, "find_escaped stays scalar").
static inline uint64_t stream_parsing_find_escaped(uint64_t bs_bits, uint64_t *prev_ends_odd) {
  const uint64_t even_bits = 0x5555555555555555ULL;
  const uint64_t odd_bits = ~even_bits;
  uint64_t start_edges = bs_bits & ~(bs_bits << 1);
  uint64_t even_start_mask = even_bits ^ *prev_ends_odd;
  uint64_t even_starts = start_edges & even_start_mask;
  uint64_t odd_starts = start_edges & ~even_start_mask;
  uint64_t even_carries = bs_bits + even_starts;
  uint64_t odd_carries;
  int ends_odd = __builtin_add_overflow(bs_bits, odd_starts, &odd_carries);
  odd_carries |= *prev_ends_odd;
  *prev_ends_odd = (uint64_t)ends_odd;
  uint64_t even_carry_ends = even_carries & ~bs_bits;
  uint64_t odd_carry_ends = odd_carries & ~bs_bits;
  return (even_carry_ends & odd_bits) | (odd_carry_ends & even_bits);
}

// MARK: - The block classifiers' results
//
// What the two 64-byte block classifiers hand back, shared by the NEON kernels below (inlined
// into Swift) and AVX2.c's out-of-line ones. The Swift walks read the same fields either way.

// The skip scanner's classes (`stream_parsing_classify_skip_block`).
typedef struct {
  // '{', '[', '}' and ']' outside any string: one bit per byte, ascending. Read only when
  // `needs_scalar` is zero.
  uint64_t brackets;
  // Carry out: all ones if the byte after this block lies inside a string, zero otherwise.
  uint64_t in_string;
  // Carry out: 1 if this block ends inside an odd-length backslash run, so the byte after it is
  // an escape selector.
  uint64_t ends_odd;
  // Nonzero: the block holds a byte the wide path will not judge -- a control byte inside a
  // string, or, outside one, any byte the scalar switch does not accept (which covers every
  // non-ASCII byte and every stray backslash). The caller re-reads the block from its first byte
  // with the scalar loop, which reports whatever it finds, at the offset it finds it.
  uint32_t needs_scalar;
  // Nonzero: the block holds a byte >= 0x80. With `needs_scalar` zero every such byte is inside a
  // string, which is exactly the region the caller must still validate as UTF-8.
  uint32_t non_ascii;
} stream_parsing_skip_classes;

// The structural run's classes (`stream_parsing_classify_structural_block`).
typedef struct {
  // Token start candidates, one bit per byte, ascending. Read only when `needs_scalar` is zero.
  uint64_t starts;
  // Unescaped `"`, one bit per byte: the opening and closing quote of every string in the block.
  // Escaped quotes are removed (`find_escaped`), so the first set bit above an opening quote is
  // that string's closing quote.
  uint64_t quote;
  // Every `\` byte, escaped or not. The walk tests this over a string's extent: a string with no
  // backslash between its quotes is emitted in place, one with any goes to the escape decoder.
  uint64_t backslash;
  // Carry out: all ones if the byte after this block lies inside a string, zero otherwise.
  uint64_t in_string;
  // Carry out: 1 if this block ends inside an odd-length backslash run.
  uint64_t ends_odd;
  // Nonzero: the block holds a byte the wide path will not judge -- a control byte inside a
  // string, or, outside one, any byte the scalar ladder does not accept (every non-ASCII byte and
  // every stray backslash included). The caller re-reads the block from its first byte with the
  // scalar loop, which reports whatever it finds, at the offset it finds it.
  uint32_t needs_scalar;
  // Nonzero: the block holds a byte >= 0x80. With `needs_scalar` zero every such byte is inside a
  // string, so this is the caller's `containsNonASCII` for the strings it emits; the validator
  // then runs each string's own extent and reports at the byte it finds, as the scalar path does.
  uint32_t non_ascii;
  // Nonzero: the block holds no whitespace *outside* a string -- the walk's gate signal, computed
  // here rather than handed out as a mask because one `bic` + `cmp` beats another 64-bit field in
  // the struct. Whitespace inside a string is deliberately excluded: those bytes the walk skips
  // with its cursor anyway, so the classifier saves nothing on them.
  uint32_t no_outer_whitespace;
  // Nonzero: the block is a strike against the walk -- `no_outer_whitespace`, or at least
  // `STREAM_PARSING_BLOCK_WALK_DENSE_STARTS` bits in `starts`. Written by the AVX2 kernel only and
  // read only on x86 (baseline x86-64 has no `popcnt`); arm64's Swift gate recomputes it from the
  // two fields above. Sits in the struct's tail padding, so the size is the same either way.
  uint32_t strike;
} stream_parsing_structural_classes;

// The gate's second strike: a block with at least this many token-start candidates has
// whitespace but nothing to skip (JSONParserBlocks.swift). One constant for both spellings of the
// gate -- the Swift one on arm64 and the AVX2 kernel's `strike`.
#define STREAM_PARSING_BLOCK_WALK_DENSE_STARTS 48

// The one SIMD operation Swift's SIMD API cannot express: a byte table lookup, `tbl` on arm64.
// The `ext_vector_type` signature imports as `SIMD16<UInt8>`, and `static inline` folds the call
// into the Swift caller. `#if arch(arm64)` selects this over the validator's portable path.
#if defined(__aarch64__) && defined(__ARM_NEON)
#include <arm_neon.h>

typedef uint8_t stream_parsing_u8x16 __attribute__((ext_vector_type(16)));

STREAM_PARSING_SIMD_SHIM stream_parsing_u8x16
stream_parsing_tbl1q_u8(stream_parsing_u8x16 table, stream_parsing_u8x16 indices) {
  return (stream_parsing_u8x16)vqtbl1q_u8((uint8x16_t)table, (uint8x16_t)indices);
}

// The UTF-8 validator's block kernel, whole: three nibble table lookups ANDed (Keiser and Lemire's
// special cases), XORed with 0x80 where a three or four byte lead requires a continuation; nonzero
// lanes are errors. The three "previous byte" views are the caller's unaligned loads at i-1/2/3.
// Measured: composed in Swift 2.6x slower, `ext`-shifted views 10% slower; keep the C kernel.
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

// The arm64 movemask Swift cannot spell: `vshrn_n_u16` takes an immediate, so it does not import
// and no portable SIMD operator lowers to it. Lane n of the input lands in nibble n of the result,
// 0xF where the byte was 0xFF. Measured: one `shrn` + `fmov` answers both "any hit" and "which
// lane" against a `uminv` chain or a `umov` ladder; keep it a leaf returning a scalar, not a struct.
STREAM_PARSING_SIMD_SHIM uint64_t
stream_parsing_movemask_u8(stream_parsing_u8x16 value) {
  return vget_lane_u64(
      vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8((uint8x16_t)value), 4)), 0);
}

// Whether any byte has its high bit set. This is the NEON equivalent of
// `simd_reduce_max(value) >= 0x80`, exposed here so every arm64 platform gets the same
// two-instruction reduction rather than only Apple platforms where Swift's `simd` module is
// available.
STREAM_PARSING_SIMD_SHIM int
stream_parsing_any_high_u8(stream_parsing_u8x16 value) {
  return vmaxvq_u8((uint8x16_t)value) >= 0x80;
}

// One bit per byte of a 64-byte block, ascending. `vshrn` folds a 16-lane vector to a nibble per
// lane and is the right tool for "which lane"; this is the other question -- four vectors down to
// one word -- and the bit-weight-plus-pairwise-add form is what NEON has for it.
static inline uint64_t stream_parsing_movemask4(
  uint8x16_t m0, uint8x16_t m1, uint8x16_t m2, uint8x16_t m3
) {
  const uint8x16_t bit_mask = {
    0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80,
    0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80
  };
  uint8x16_t sum0 = vpaddq_u8(vandq_u8(m0, bit_mask), vandq_u8(m1, bit_mask));
  uint8x16_t sum1 = vpaddq_u8(vandq_u8(m2, bit_mask), vandq_u8(m3, bit_mask));
  sum0 = vpaddq_u8(sum0, sum1);
  sum0 = vpaddq_u8(sum0, sum0);
  return vgetq_lane_u64(vreinterpretq_u64_u8(sum0), 0);
}

// Quote parity: bit i becomes the XOR of bits 0...i, which turns a mask of unescaped quotes into
// "is byte i inside a string" -- the opening quote included, the closing one not. One carryless
// multiply by all ones where the target has it, six shift-xors where it does not.
static inline uint64_t stream_parsing_prefix_xor(uint64_t bitmask) {
#if defined(__ARM_FEATURE_AES) || defined(__ARM_FEATURE_CRYPTO)
  return vgetq_lane_u64(
    vreinterpretq_u64_p128(vmull_p64((poly64_t)bitmask, (poly64_t)~0ULL)), 0
  );
#else
  bitmask ^= bitmask << 1;
  bitmask ^= bitmask << 2;
  bitmask ^= bitmask << 4;
  bitmask ^= bitmask << 8;
  bitmask ^= bitmask << 16;
  bitmask ^= bitmask << 32;
  return bitmask;
#endif
}

// MARK: - The skip scanner's block classifier
//
// Measured: composed from Swift's SIMD operators around the movemask shim this comes out half
// scalarised; keep the whole kernel in C, `static inline` so it folds into the Swift caller.

// What `consumeSkipRun` (JSONParserSkip.swift) asks of 64 bytes: the bracket bits outside strings,
// whether the block holds anything the wide path refuses to judge, and the two carries.
STREAM_PARSING_SIMD_SHIM stream_parsing_skip_classes
stream_parsing_classify_skip_block(
  const uint8_t *p, uint64_t in_string_carry, uint64_t ends_odd_carry
) {
  uint8x16_t v0 = vld1q_u8(p);
  uint8x16_t v1 = vld1q_u8(p + 16);
  uint8x16_t v2 = vld1q_u8(p + 32);
  uint8x16_t v3 = vld1q_u8(p + 48);

  const uint8x16_t backslash_byte = vdupq_n_u8('\\');
  const uint8x16_t quote_byte = vdupq_n_u8('"');
  uint64_t backslash = stream_parsing_movemask4(
    vceqq_u8(v0, backslash_byte), vceqq_u8(v1, backslash_byte),
    vceqq_u8(v2, backslash_byte), vceqq_u8(v3, backslash_byte)
  );
  uint64_t quote = stream_parsing_movemask4(
    vceqq_u8(v0, quote_byte), vceqq_u8(v1, quote_byte),
    vceqq_u8(v2, quote_byte), vceqq_u8(v3, quote_byte)
  );
  quote &= ~stream_parsing_find_escaped(backslash, &ends_odd_carry);
  uint64_t in_string = stream_parsing_prefix_xor(quote) ^ in_string_carry;

  stream_parsing_skip_classes out;
  out.in_string = (uint64_t)((int64_t)in_string >> 63);
  out.ends_odd = ends_odd_carry;
  out.non_ascii = vmaxvq_u8(vmaxq_u8(vmaxq_u8(v0, v1), vmaxq_u8(v2, v3))) >= 0x80;

  // A block lying edge to edge inside a string -- most of every block on a payload with long
  // strings -- has no brackets by construction and needs only its two flags, which are reduces
  // rather than three more movemasks. The quote test is not redundant: an opening quote at bit 0
  // alone also makes the parity all ones.
  if (quote == 0 && in_string == ~(uint64_t)0) {
    out.brackets = 0;
    out.needs_scalar = vminvq_u8(vminq_u8(vminq_u8(v0, v1), vminq_u8(v2, v3))) < 0x20;
    return out;
  }

  // A byte is in a class iff (lo_table[b & 0xF] & hi_table[b >> 4]) has the class bit set. Bits
  // 0...6 spell "the scalar switch accepts this byte outside a string", one bit per high nibble
  // row; bit 7 is the bracket class, {B,D} x {5,7} == {'[', ']', '{', '}'} -- a rectangle, the one
  // shape this form carries free. Kinds stay unmasked: the caller reads the bracket byte it hits.
  const uint8x16_t lo_table = {
    0x46, 0x64, 0x66, 0x64, 0x64, 0x6C, 0x64, 0x64,
    0x64, 0x65, 0x65, 0xF2, 0x22, 0xF3, 0x22, 0x20
  };
  const uint8x16_t hi_table = {
    0x01, 0x00, 0x02, 0x04, 0x08, 0x90, 0x20, 0xC0,
    0, 0, 0, 0, 0, 0, 0, 0
  };
  const uint8x16_t low_nibble = vdupq_n_u8(0x0F);
  const uint8x16_t accepted_bits = vdupq_n_u8(0x7F);
  const uint8x16_t bracket_bit = vdupq_n_u8(0x80);
  const uint8x16_t space = vdupq_n_u8(0x20);

  uint8x16_t c0 = vandq_u8(
    vqtbl1q_u8(lo_table, vandq_u8(v0, low_nibble)), vqtbl1q_u8(hi_table, vshrq_n_u8(v0, 4))
  );
  uint8x16_t c1 = vandq_u8(
    vqtbl1q_u8(lo_table, vandq_u8(v1, low_nibble)), vqtbl1q_u8(hi_table, vshrq_n_u8(v1, 4))
  );
  uint8x16_t c2 = vandq_u8(
    vqtbl1q_u8(lo_table, vandq_u8(v2, low_nibble)), vqtbl1q_u8(hi_table, vshrq_n_u8(v2, 4))
  );
  uint8x16_t c3 = vandq_u8(
    vqtbl1q_u8(lo_table, vandq_u8(v3, low_nibble)), vqtbl1q_u8(hi_table, vshrq_n_u8(v3, 4))
  );
  uint64_t accepted = stream_parsing_movemask4(
    vtstq_u8(c0, accepted_bits), vtstq_u8(c1, accepted_bits),
    vtstq_u8(c2, accepted_bits), vtstq_u8(c3, accepted_bits)
  );
  uint64_t brackets = stream_parsing_movemask4(
    vtstq_u8(c0, bracket_bit), vtstq_u8(c1, bracket_bit),
    vtstq_u8(c2, bracket_bit), vtstq_u8(c3, bracket_bit)
  );
  uint64_t control = stream_parsing_movemask4(
    vcltq_u8(v0, space), vcltq_u8(v1, space), vcltq_u8(v2, space), vcltq_u8(v3, space)
  );

  out.brackets = brackets & ~in_string;
  // Inside a string every control byte is a grammar error; outside one, every byte the switch
  // does not accept is. `in_string` covers the opening quote through the byte before the closing
  // quote, so both quotes land on the side that accepts them.
  out.needs_scalar = ((control & in_string) | (~accepted & ~in_string)) != 0;
  return out;
}

// MARK: - The structural run's block classifier
//
// The same 64 bytes, asked `consumeStructuralBlocks`'s question (JSONParserBlocks.swift): where the
// next token starts, where the string extents are, and whether anything needs the scalar ladder.

// `starts` is one word: `(~in_string & ~ws & ~quote) | (quote & in_string)`. Outside a string every
// non-whitespace non-quote byte is a candidate, token interiors included (the walk clears them as
// its cursor advances). The opening quote is the one byte that is both, so it is added back; the
// closing quote drops out, its extent already consumed by whoever visited the opener.
STREAM_PARSING_SIMD_SHIM stream_parsing_structural_classes
stream_parsing_classify_structural_block(
  const uint8_t *p, uint64_t in_string_carry, uint64_t ends_odd_carry
) {
  uint8x16_t v0 = vld1q_u8(p);
  uint8x16_t v1 = vld1q_u8(p + 16);
  uint8x16_t v2 = vld1q_u8(p + 32);
  uint8x16_t v3 = vld1q_u8(p + 48);

  const uint8x16_t backslash_byte = vdupq_n_u8('\\');
  const uint8x16_t quote_byte = vdupq_n_u8('"');
  uint64_t backslash = stream_parsing_movemask4(
    vceqq_u8(v0, backslash_byte), vceqq_u8(v1, backslash_byte),
    vceqq_u8(v2, backslash_byte), vceqq_u8(v3, backslash_byte)
  );
  uint64_t quote = stream_parsing_movemask4(
    vceqq_u8(v0, quote_byte), vceqq_u8(v1, quote_byte),
    vceqq_u8(v2, quote_byte), vceqq_u8(v3, quote_byte)
  );
  quote &= ~stream_parsing_find_escaped(backslash, &ends_odd_carry);
  uint64_t in_string = stream_parsing_prefix_xor(quote) ^ in_string_carry;

  stream_parsing_structural_classes out;
  out.quote = quote;
  out.backslash = backslash;
  out.in_string = (uint64_t)((int64_t)in_string >> 63);
  out.ends_odd = ends_odd_carry;
  out.non_ascii = vmaxvq_u8(vmaxq_u8(vmaxq_u8(v0, v1), vmaxq_u8(v2, v3))) >= 0x80;

  // A block lying edge to edge inside a string needs only its flags and carries: by construction it
  // holds no token start. (Folds away for the structural walk, which always passes a zero carry in;
  // kept for a carrying caller.)
  if (quote == 0 && in_string == ~(uint64_t)0) {
    // Edge to edge inside a string: no byte of it is whitespace outside one, by construction.
    out.no_outer_whitespace = 1;
    out.starts = 0;
    out.needs_scalar = vminvq_u8(vminq_u8(vminq_u8(v0, v1), vminq_u8(v2, v3))) < 0x20;
    return out;
  }

  // The same two-table trick the skip classifier documents above, re-encoded: a bit is a rectangle
  // (high nibble rows) x (low nibbles), and eight bits is exactly full, so two are recovered by
  // testing "accepted" as `c != 0` and by sharing one {3,7} x {0..A} rectangle; whitespace gets its
  // own lookup off the low nibble. Measured (twitter ns/block): 9.43 here, 9.87 and 10.53 otherwise.
  const uint8x16_t lo_table = {
    0x12, 0x30, 0x32, 0x30, 0x30, 0x70, 0x30, 0x30,
    0x30, 0x31, 0x39, 0xA2, 0x24, 0xA3, 0x22, 0x20
  };
  const uint8x16_t hi_table = {
    0x01, 0x00, 0x06, 0x18, 0x40, 0x80, 0x20, 0x90,
    0, 0, 0, 0, 0, 0, 0, 0
  };
  // The low nibbles of 09, 0A, 0D and 20 are distinct, so one table indexed by the low nibble
  // holds "the whitespace byte with this low nibble" and one compare against the raw byte answers
  // it. 0xFF is an impossible value in every row but F, which gets 0x00 (no byte 0x?F is zero).
  const uint8x16_t ws_table = {
    0x20, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
    0xFF, 0x09, 0x0A, 0xFF, 0xFF, 0x0D, 0xFF, 0x00
  };
  const uint8x16_t low_nibble = vdupq_n_u8(0x0F);
  const uint8x16_t space = vdupq_n_u8(0x20);

  uint8x16_t n0 = vandq_u8(v0, low_nibble);
  uint8x16_t n1 = vandq_u8(v1, low_nibble);
  uint8x16_t n2 = vandq_u8(v2, low_nibble);
  uint8x16_t n3 = vandq_u8(v3, low_nibble);
  uint8x16_t c0 = vandq_u8(vqtbl1q_u8(lo_table, n0), vqtbl1q_u8(hi_table, vshrq_n_u8(v0, 4)));
  uint8x16_t c1 = vandq_u8(vqtbl1q_u8(lo_table, n1), vqtbl1q_u8(hi_table, vshrq_n_u8(v1, 4)));
  uint8x16_t c2 = vandq_u8(vqtbl1q_u8(lo_table, n2), vqtbl1q_u8(hi_table, vshrq_n_u8(v2, 4)));
  uint8x16_t c3 = vandq_u8(vqtbl1q_u8(lo_table, n3), vqtbl1q_u8(hi_table, vshrq_n_u8(v3, 4)));

  uint64_t accepted = stream_parsing_movemask4(
    vtstq_u8(c0, c0), vtstq_u8(c1, c1), vtstq_u8(c2, c2), vtstq_u8(c3, c3)
  );
  uint64_t whitespace = stream_parsing_movemask4(
    vceqq_u8(v0, vqtbl1q_u8(ws_table, n0)), vceqq_u8(v1, vqtbl1q_u8(ws_table, n1)),
    vceqq_u8(v2, vqtbl1q_u8(ws_table, n2)), vceqq_u8(v3, vqtbl1q_u8(ws_table, n3))
  );
  uint64_t control = stream_parsing_movemask4(
    vcltq_u8(v0, space), vcltq_u8(v1, space), vcltq_u8(v2, space), vcltq_u8(v3, space)
  );

  out.no_outer_whitespace = (whitespace & ~in_string) == 0;
  out.starts = (~(in_string | whitespace | quote)) | (quote & in_string);
  out.needs_scalar = ((control & in_string) | (~accepted & ~in_string)) != 0;
  return out;
}
#endif

#if !(defined(__aarch64__) && defined(__ARM_NEON))
// The window indexer's portable path needs the parity too. The block classifiers' x86 twins in
// AVX2.c use `pclmulqdq` instead; every other architecture keeps the scalar loops.
static inline uint64_t stream_parsing_prefix_xor(uint64_t bitmask) {
  bitmask ^= bitmask << 1;
  bitmask ^= bitmask << 2;
  bitmask ^= bitmask << 4;
  bitmask ^= bitmask << 8;
  bitmask ^= bitmask << 16;
  bitmask ^= bitmask << 32;
  return bitmask;
}
#endif

// MARK: - x86: the AVX2 tier
//
// Defined in AVX2.c, not here: a modular header including `immintrin.h` forces `_Builtin_intrinsics`,
// which some x86-64 SDKs cannot build. `ptrdiff_t` not `long`: `long` is 32 bits on Windows.
#if defined(__x86_64__)

#include <stddef.h>

// Whether the two kernels below may be called at all. Resolved on first use and cached. Read
// once per process from an out-of-line Swift function, never from an inlined scan loop.
int stream_parsing_has_avx2(void);

// 1 = valid, 0 = invalid. `from`/`to` bound the run; nothing before `from` is part of a sequence
// and no sequence may run past `to`, matching `streamValidateUTF8Scalar`.
// Precondition: `stream_parsing_has_avx2()`.
int stream_parsing_utf8_validate(const void *base, ptrdiff_t from, ptrdiff_t to);

// The escalation tier behind `streamStringRun`: returns the index of the first quote, backslash
// or control byte in `[from, to)`, or `to`, and reports through `out_non_ascii` whether any byte
// before it had its high bit set. Precondition: `stream_parsing_has_avx2()`.
ptrdiff_t stream_parsing_string_run_avx2(const void *base, ptrdiff_t from, ptrdiff_t to,
                                         int *out_non_ascii);

// Whether the two block classifiers below may be called: AVX2 plus PCLMULQDQ (the quote parity)
// and POPCNT (the structural kernel's gate strike). A separate question from
// `stream_parsing_has_avx2` so a (hypothetical) AVX2 part without either keeps the validator and
// the string scanner. Resolved on first use and cached with the same probe.
int stream_parsing_has_avx2_block_kernels(void);

// The two 64-byte block classifiers with the NEON kernels' names, signatures and results, so the
// Swift walks are one source on both architectures. Out of line where NEON's are inlined: a
// `target("avx2")` body cannot be inlined into Swift built for baseline x86-64. AVX2.c documents
// the encoding differences. Precondition: `stream_parsing_has_avx2_block_kernels()`.
stream_parsing_skip_classes stream_parsing_classify_skip_block(
    const uint8_t *p, uint64_t in_string_carry, uint64_t ends_odd_carry);
stream_parsing_structural_classes stream_parsing_classify_structural_block(
    const uint8_t *p, uint64_t in_string_carry, uint64_t ends_odd_carry);

#endif  // __x86_64__

#include <stddef.h>

// Stage-1 window indexer: one pass over `len` bytes in 64-byte blocks, writing to `indices` every
// chunk-relative position a consuming walk must visit; returns how many. `needs_scan`/`non_ascii`
// flag blocks holding a backslash or control byte / a byte >= 0x80. Requires len <= 32 KB starting
// at a token boundary outside any string, len+8 slots in `indices`, (len+4095)/4096 words per bitmap.
size_t stream_parsing_index_window(const uint8_t *p, size_t len, uint32_t base,
                                   uint32_t *indices, uint64_t *needs_scan,
                                   uint64_t *non_ascii);

// A simple decimal of more than sixteen bytes, parsed in one pass from a known extent: one vector
// classification gates the shape (optional '-', digits, at most one interior '.', no exponent, no
// leading zero, at most 19 digits) and the digits accumulate unvalidated; anything else returns 0.
// Reads 32 bytes from `p`. Measured: +24% on Canada's long floats, a loss short -- hence the gate.
STREAM_PARSING_SIMD_SHIM uint64_t stream_parsing_swar8(uint64_t w) {
  w -= 0x3030303030303030ULL;
  w = (w * 10) + (w >> 8);
  w = (((w & 0x000000FF000000FFULL) * (100 + (1000000ULL << 32)))
       + (((w >> 16) & 0x000000FF000000FFULL) * (1 + (10000ULL << 32)))) >> 32;
  return w;
}

// Reads in eight-byte words, so the `count % 8 != 0` tail loads up to seven bytes past `q + count`.
// In bounds only because `stream_parsing_decimal32` rejects `len > 21` and passes slices of the same
// `p`, so the furthest byte is `p + 27`, inside its 32 mapped bytes (`JSONParserShapes.parseNumber`
// guarantees `from &+ 32 <= chunkEnd`). Loosening `len <= 21` without revisiting this reads OOB.
STREAM_PARSING_SIMD_SHIM uint64_t stream_parsing_decimal_digits(const uint8_t *q, unsigned count) {
  static const uint64_t pow10[8] = {
    1ULL, 10ULL, 100ULL, 1000ULL, 10000ULL, 100000ULL, 1000000ULL, 10000000ULL
  };
  uint64_t value = 0;
  while (count >= 8) {
    uint64_t w;
    __builtin_memcpy(&w, q, 8);
    value = value * 100000000ULL + stream_parsing_swar8(w);
    q += 8;
    count -= 8;
  }
  if (count > 0) {
    uint64_t w;
    __builtin_memcpy(&w, q, 8);
    // Left-justify the remaining digits into an eight-digit field padded with '0' in front.
    w = (w << ((8 - count) * 8)) | (0x3030303030303030ULL >> (count * 8));
    value = value * pow10[count] + stream_parsing_swar8(w);
  }
  return value;
}

STREAM_PARSING_SIMD_SHIM void stream_parsing_decimal_classify(
  const uint8_t *p, uint32_t *digits, uint32_t *dots
) {
#if defined(__aarch64__) && defined(__ARM_NEON)
  uint8x16_t v0 = vld1q_u8(p);
  uint8x16_t v1 = vld1q_u8(p + 16);
  const uint8x16_t zero = vdupq_n_u8('0');
  const uint8x16_t nine = vdupq_n_u8(9);
  const uint8x16_t dot = vdupq_n_u8('.');
  const uint8x16_t bit_mask = {
    0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80,
    0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80
  };
  uint8x16_t d0 = vandq_u8(vcleq_u8(vsubq_u8(v0, zero), nine), bit_mask);
  uint8x16_t d1 = vandq_u8(vcleq_u8(vsubq_u8(v1, zero), nine), bit_mask);
  uint8x16_t s = vpaddq_u8(d0, d1);
  s = vpaddq_u8(s, s);
  s = vpaddq_u8(s, s);
  *digits = vgetq_lane_u32(vreinterpretq_u32_u8(s), 0);
  uint8x16_t t = vpaddq_u8(vandq_u8(vceqq_u8(v0, dot), bit_mask), vandq_u8(vceqq_u8(v1, dot), bit_mask));
  t = vpaddq_u8(t, t);
  t = vpaddq_u8(t, t);
  *dots = vgetq_lane_u32(vreinterpretq_u32_u8(t), 0);
#else
  uint32_t d = 0, o = 0;
  for (int i = 0; i < 32; i++) {
    if ((uint8_t)(p[i] - '0') <= 9) { d |= 1u << i; }
    if (p[i] == '.') { o |= 1u << i; }
  }
  *digits = d;
  *dots = o;
#endif
}

STREAM_PARSING_SIMD_SHIM int stream_parsing_decimal32(
  const uint8_t *p, size_t len, uint64_t *magnitude, int32_t *exponent,
  uint32_t *digit_count, uint32_t *flags
) {
  static const uint64_t pow10[20] = {
    1ULL, 10ULL, 100ULL, 1000ULL, 10000ULL, 100000ULL, 1000000ULL, 10000000ULL, 100000000ULL,
    1000000000ULL, 10000000000ULL, 100000000000ULL, 1000000000000ULL, 10000000000000ULL,
    100000000000000ULL, 1000000000000000ULL, 10000000000000000ULL, 100000000000000000ULL,
    1000000000000000000ULL, 10000000000000000000ULL
  };
  if (len == 0 || len > 21) { return 0; }
  uint32_t digits, dots;
  stream_parsing_decimal_classify(p, &digits, &dots);
  unsigned start = p[0] == '-';
  if (start >= len) { return 0; }
  uint32_t body = ((1u << len) - 1u) & ~((1u << start) - 1u);
  uint32_t dot = dots & body;
  if (((digits | dot) & body) != body) { return 0; }
  if (dot & (dot - 1)) { return 0; }
  unsigned count = (unsigned)len - start - (dot != 0);
  if (count > 19) { return 0; }
  unsigned int_digits, frac_digits, dot_at = 0;
  if (dot) {
    dot_at = (unsigned)__builtin_ctz(dot);
    if (dot_at == start || dot_at == len - 1) { return 0; }
    int_digits = dot_at - start;
    frac_digits = (unsigned)len - dot_at - 1;
  } else {
    int_digits = count;
    frac_digits = 0;
  }
  if (int_digits > 1 && p[start] == '0') { return 0; }
  uint64_t value = stream_parsing_decimal_digits(p + start, int_digits);
  if (frac_digits) {
    value = value * pow10[frac_digits] + stream_parsing_decimal_digits(p + dot_at + 1, frac_digits);
  }
  *magnitude = value;
  *exponent = -(int32_t)frac_digits;
  *digit_count = count;
  *flags = start | (dot != 0 ? 2u : 0u);
  return 1;
}

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

// Exact `double` values of 10^q for q in 0 ... 22, generated into `Pow10_Double.c`; in C so it is
// `.rodata` rather than a lazily allocated Swift array global. Reached through an always-inlined
// accessor, not a `const double *const` global, so the address folds into the caller as `adrp`/`add`
// instead of a dependent load. Declared incomplete: Swift imports a sized C array as a tuple.
extern const double stream_parsing_pow10_double_storage[];

STREAM_PARSING_SIMD_SHIM const double *stream_parsing_pow10_double(void) {
  return stream_parsing_pow10_double_storage;
}

#define STREAM_PARSING_POW10_DOUBLE_MIN_EXPONENT (0)
#define STREAM_PARSING_POW10_DOUBLE_MAX_EXPONENT (22)
#define STREAM_PARSING_POW10_DOUBLE_COUNT (23)


#endif
