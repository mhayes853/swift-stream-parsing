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

// The Eisel-Lemire power-of-ten table, defined in `Pow10_128.c` and generated -- see the header
// comment there. Exposed as a pointer rather than a sized array because Swift imports a
// fixed-size C array as a tuple of that many elements, which is unusable at this size.
extern const uint64_t *const stream_parsing_pow10_128;
extern const int32_t stream_parsing_pow10_128_min_exponent;
extern const int32_t stream_parsing_pow10_128_max_exponent;

#endif
