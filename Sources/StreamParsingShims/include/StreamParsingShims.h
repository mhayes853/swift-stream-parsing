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

// Whether any byte has its high bit set. This is the NEON equivalent of
// `simd_reduce_max(value) >= 0x80`, exposed here so every arm64 platform gets the same
// two-instruction reduction rather than only Apple platforms where Swift's `simd` module is
// available.
STREAM_PARSING_SIMD_SHIM int
stream_parsing_any_high_u8(stream_parsing_u8x16 value) {
  return vmaxvq_u8((uint8x16_t)value) >= 0x80;
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

#include <stddef.h>

// Stage-1 window indexer for the windowed parse path (NEW_ARCHITECTURE.md, "Stage-1
// extraction"). One pass over `len` bytes (at most 32 KB) in 64-byte blocks, writing to
// `indices` the chunk-relative position (`base` + offset) of every byte a consuming walk must
// visit: each structural character outside a string, each unescaped quote, and the first byte
// of each number or literal. Returns how many were written. Two per-block bitmaps, one bit per
// block, are written alongside: `needs_scan` marks blocks holding a backslash or a control byte
// inside a string, so a string whose blocks are clear can be emitted whole without a scan;
// `non_ascii` marks blocks holding a byte >= 0x80, so validation runs only where it can fail.
//
// Windows start at a token boundary outside any string, so there is no carried state in; a
// short final block is copied into a whitespace-padded scratch and its bits past `len` masked.
// `indices` needs `len + 8` slots: extraction writes in unconditional groups of eight. The
// bitmaps need `(len + 4095) / 4096` words each and are cleared here.
size_t stream_parsing_index_window(const uint8_t *p, size_t len, uint32_t base,
                                   uint32_t *indices, uint64_t *needs_scan,
                                   uint64_t *non_ascii);

// A simple decimal of more than sixteen bytes, parsed in one pass from a known extent: one
// vector classification (digits, dots) decides the shape -- optional '-', digits, at most one
// interior '.', no exponent, no leading zero, at most 19 digits -- and the digits are then
// accumulated with no per-block validation. Anything else returns 0 and the caller takes the
// grammar walk. Reads 32 bytes from `p`; the caller guarantees they are mapped. Measured in
// the number kernel lab (NEW_ARCHITECTURE.md): +24% on Canada's 18-digit floats and a loss on
// anything short, which is why the caller gates it on length.
STREAM_PARSING_SIMD_SHIM uint64_t stream_parsing_swar8(uint64_t w) {
  w -= 0x3030303030303030ULL;
  w = (w * 10) + (w >> 8);
  w = (((w & 0x000000FF000000FFULL) * (100 + (1000000ULL << 32)))
       + (((w >> 16) & 0x000000FF000000FFULL) * (1 + (10000ULL << 32)))) >> 32;
  return w;
}

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
