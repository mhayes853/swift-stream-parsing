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

// The arm64 movemask, which Swift cannot spell: `vshrn_n_u16` takes an immediate, so it does not
// import at all (`cannot find 'vshrn_n_u16' in scope`) and there is no portable SIMD operator
// that lowers to it. Reading the vector as eight `uint16_t` and narrowing each by a four bit
// shift folds every input byte to a nibble of the result: lane `n` of the input lands in nibble
// `n` of the returned word, 0xF where the byte was 0xFF and 0x0 where it was 0x00.
//
// This is the idiom every first-hit-lane problem in the scanners has been working around. Swift's
// two options were a `uminv` reduction, which is a dependent vector chain that a short run pays
// in full, and a per lane `umov` + branch ladder, which is sixteen moves, sixteen branches and
// sixteen constant-materialising exit blocks. One `shrn` plus one `fmov` answers both "is there a
// terminator in this block" and "which lane" -- `rbit`/`clz` on the complement gives the lane in
// a general register, with no second pass over the vector.
//
// Kept deliberately as a leaf returning a scalar rather than a kernel returning a struct: that is
// the shape that survived in `stream_parsing_utf8_block_errors` and the shape that did not in the
// `streamStringRun` port, whose better kernel still made the parse slower at the boundary.
STREAM_PARSING_SIMD_SHIM uint64_t
stream_parsing_movemask_u8(stream_parsing_u8x16 value) {
  return vget_lane_u64(
      vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8((uint8x16_t)value), 4)), 0);
}
#endif

// MARK: - x86: the AVX2 tier
//
// Defined in `AVX2.c`, not here. The kernels need `immintrin.h`, and a modular header that
// includes it forces the toolchain to build the `_Builtin_intrinsics` module -- which some
// x86-64 SDKs (Android's, for one) cannot do. The definitions carry `target("avx2")`, which
// already barred Clang from inlining them into callers built without the feature, so an
// out-of-line definition costs nothing that was not already being paid.
//
// `ptrdiff_t` rather than `long`: both import to Swift as `Int`, and only one of them is
// 64 bits everywhere Swift runs -- `long` is 32 bits on Windows.
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
