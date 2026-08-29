#ifndef STAGE_ONE_LAB_H
#define STAGE_ONE_LAB_H

#include <stddef.h>
#include <stdint.h>

// Stage-1 extraction lab: measures what a simdjson-style classification pass costs on this
// project's corpora, chunked with carries the way a streaming parser would have to run it.
// This target exists only for the Benchmarks package; nothing here ships. If a kernel
// graduates, it moves to StreamParsingShims.
//
// State carried between windows. A window boundary is any position the Swift driver chooses;
// every window except the last must be a multiple of 64 bytes so the padded-tail path only
// ever runs at the end of the document.
typedef struct {
  // All ones if the next byte begins inside a string, else zero.
  uint64_t prev_in_string;
  // 1 if the previous byte ended an odd-length backslash run (so the next byte is escaped).
  uint64_t prev_ends_odd_backslash;
  // 1 if the previous byte was a non-quote scalar (continues a number/literal token).
  uint64_t prev_scalar;
} sp1_carry_t;

// Tier 1: backslash/quote masks, escape parity, in-string mask. Returns a checksum of the
// in-string masks so the work cannot be dead-code eliminated.
uint64_t sp1_string_mask_pass(const uint8_t *p, size_t len, sp1_carry_t *carry);

// Tier 1.5: tier 1 plus structural/whitespace classification and scalar-start detection,
// producing the final index bits per block but not extracting them. Checksum of the bits.
uint64_t sp1_full_masks_pass(const uint8_t *p, size_t len, sp1_carry_t *carry);

// Tier 2: tier 1.5 plus bits-to-indices extraction. Writes absolute positions (base + offset
// in this window) to `out` and returns how many were written. `out` needs 8 slots of slack
// beyond the true entry count: extraction writes in unconditional groups of 8.
size_t sp1_index_pass(
  const uint8_t *p, size_t len, uint32_t base, sp1_carry_t *carry, uint32_t *out
);

// Synthetic stage 2: load one byte at every index position. Models the cache traffic of a
// consuming pass without modeling its work, which is what the sub-chunk size sweep needs.
uint64_t sp1_touch_pass(const uint8_t *p, const uint32_t *idx, size_t count);

#endif

// MARK: - Number kernel lab

// A parsed number in the parser's own terms: magnitude, decimal exponent, digit count and the
// NumberInfo flag bits (1 negative, 2 fraction, 4 exponent, 8 overflowed).
typedef struct {
  uint64_t magnitude;
  int32_t exponent;
  uint32_t digit_count;
  uint32_t flags;
} sp_lab_number;

// Single pass over a number whose extent is known: one vector classification decides whether
// the token is a simple decimal — optional '-', digits, at most one interior '.', no exponent,
// at most 19 digits — and rejects it otherwise (returns 0, `out` untouched). Digits are then
// accumulated with no per-block validation. Reads up to 32 bytes from `p`; the caller pads.

// Two extents, both classified before either is parsed, so the compiler can schedule the two
// independent chains together. Returns 1 only if both were handled.

// One-vector variant for extents of at most 16 bytes: half the classification cost of the
// 32-byte form, for the 9-16 byte floats that Mesh is made of. Reads 16 bytes from `p`.

#include <string.h>
#if defined(__aarch64__)
#include <arm_neon.h>
#endif
// Kernels inline so the Swift caller pays no call per number; the boundary was the first
// measurement's confound.
// MARK: - Number kernel lab

static const uint64_t sp_lab_pow10[20] = {
  1ULL, 10ULL, 100ULL, 1000ULL, 10000ULL, 100000ULL, 1000000ULL, 10000000ULL, 100000000ULL,
  1000000000ULL, 10000000000ULL, 100000000000ULL, 1000000000000ULL, 10000000000000ULL,
  100000000000000ULL, 1000000000000000ULL, 10000000000000000ULL, 100000000000000000ULL,
  1000000000000000000ULL, 10000000000000000000ULL
};

static inline uint64_t sp_lab_load64(const uint8_t *p) {
  uint64_t w;
  memcpy(&w, p, 8);
  return w;
}

// Eight ASCII digits, little endian, to their value. No validation: the caller has classified.
static inline uint64_t sp_lab_swar8(uint64_t w) {
  w -= 0x3030303030303030ULL;
  w = (w * 10) + (w >> 8);
  w = (((w & 0x000000FF000000FFULL) * (100 + (1000000ULL << 32)))
       + (((w >> 16) & 0x000000FF000000FFULL) * (1 + (10000ULL << 32)))) >> 32;
  return w;
}

// `count` digits (1...19) starting at `q`, no validation.
static inline uint64_t sp_lab_digits(const uint8_t *q, unsigned count) {
  uint64_t value = 0;
  while (count >= 8) {
    value = value * 100000000ULL + sp_lab_swar8(sp_lab_load64(q));
    q += 8;
    count -= 8;
  }
  if (count > 0) {
    // Left-justify the remaining digits into an eight-digit field padded with '0' in front:
    // bytes move up by (8 - count) positions and the low bytes become ASCII zeros.
    uint64_t w = (sp_lab_load64(q) << ((8 - count) * 8))
               | (0x3030303030303030ULL >> (count * 8));
    value = value * sp_lab_pow10[count] + sp_lab_swar8(w);
  }
  return value;
}

#if defined(__aarch64__)
// Classification of up to 32 bytes: bit i of `digits` set where byte i is '0'...'9', of `dots`
// where it is '.'. Bytes past `len` are not masked here; the shape test masks them.
static inline void sp_lab_classify(const uint8_t *p, uint32_t *digits, uint32_t *dots) {
  uint8x16_t v0 = vld1q_u8(p);
  uint8x16_t v1 = vld1q_u8(p + 16);
  const uint8x16_t zero = vdupq_n_u8('0');
  const uint8x16_t nine = vdupq_n_u8(9);
  const uint8x16_t dot = vdupq_n_u8('.');
  uint8x16_t d0 = vcleq_u8(vsubq_u8(v0, zero), nine);
  uint8x16_t d1 = vcleq_u8(vsubq_u8(v1, zero), nine);
  const uint8x16_t bit_mask = {
    0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80,
    0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80
  };
  uint8x16_t s = vpaddq_u8(vandq_u8(d0, bit_mask), vandq_u8(d1, bit_mask));
  s = vpaddq_u8(s, s);
  s = vpaddq_u8(s, s);
  *digits = vgetq_lane_u32(vreinterpretq_u32_u8(s), 0);
  uint8x16_t t = vpaddq_u8(vandq_u8(vceqq_u8(v0, dot), bit_mask), vandq_u8(vceqq_u8(v1, dot), bit_mask));
  t = vpaddq_u8(t, t);
  t = vpaddq_u8(t, t);
  *dots = vgetq_lane_u32(vreinterpretq_u32_u8(t), 0);
}
#else
static inline void sp_lab_classify(const uint8_t *p, uint32_t *digits, uint32_t *dots) {
  uint32_t d = 0, o = 0;
  for (int i = 0; i < 32; i++) {
    if ((uint8_t)(p[i] - '0') <= 9) { d |= 1u << i; }
    if (p[i] == '.') { o |= 1u << i; }
  }
  *digits = d;
  *dots = o;
}
#endif

// The shape test and the parse, from classification masks. Returns 0 for anything that is not
// a simple decimal; those go to the existing grammar walk.
static inline int sp_lab_decimal_from_masks(
  const uint8_t *p, size_t len, uint32_t digits, uint32_t dots, sp_lab_number *out
) {
  if (len == 0 || len > 21) { return 0; }
  unsigned start = p[0] == '-';
  if (start >= len) { return 0; }
  uint32_t body = (len == 32 ? 0xFFFFFFFFu : ((1u << len) - 1u)) & ~((1u << start) - 1u);
  // Every body byte is a digit or the one dot; the dot is interior to the digits.
  uint32_t dot = dots & body;
  if (((digits | dot) & body) != body) { return 0; }
  if (dot & (dot - 1)) { return 0; }
  unsigned digit_count = (unsigned)len - start - (dot != 0);
  if (digit_count > 19) { return 0; }
  unsigned int_digits, frac_digits, dot_at = 0;
  if (dot) {
    dot_at = (unsigned)__builtin_ctz(dot);
    if (dot_at == start || dot_at == len - 1) { return 0; }
    int_digits = dot_at - start;
    frac_digits = (unsigned)len - dot_at - 1;
  } else {
    int_digits = digit_count;
    frac_digits = 0;
  }
  if (int_digits > 1 && p[start] == '0') { return 0; }
  uint64_t magnitude = sp_lab_digits(p + start, int_digits);
  if (frac_digits) {
    magnitude = magnitude * sp_lab_pow10[frac_digits] + sp_lab_digits(p + dot_at + 1, frac_digits);
  }
  out->magnitude = magnitude;
  out->exponent = -(int32_t)frac_digits;
  out->digit_count = digit_count;
  out->flags = start | (dot != 0 ? 2u : 0u);
  return 1;
}

static inline int sp_lab_decimal(const uint8_t *p, size_t len, sp_lab_number *out) {
  uint32_t digits, dots;
  sp_lab_classify(p, &digits, &dots);
  return sp_lab_decimal_from_masks(p, len, digits, dots, out);
}

static inline int sp_lab_decimal_pair(
  const uint8_t *p0, size_t len0, const uint8_t *p1, size_t len1,
  sp_lab_number *out0, sp_lab_number *out1
) {
  uint32_t d0, o0, d1, o1;
  sp_lab_classify(p0, &d0, &o0);
  sp_lab_classify(p1, &d1, &o1);
  int a = sp_lab_decimal_from_masks(p0, len0, d0, o0, out0);
  int b = sp_lab_decimal_from_masks(p1, len1, d1, o1, out1);
  return a & b;
}

#if defined(__aarch64__)
static inline void sp_lab_classify16(const uint8_t *p, uint32_t *digits, uint32_t *dots) {
  uint8x16_t v0 = vld1q_u8(p);
  const uint8x16_t zero = vdupq_n_u8('0');
  const uint8x16_t nine = vdupq_n_u8(9);
  const uint8x16_t dot = vdupq_n_u8('.');
  const uint8x16_t bit_mask = {
    0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80,
    0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80
  };
  uint8x16_t d = vandq_u8(vcleq_u8(vsubq_u8(v0, zero), nine), bit_mask);
  uint8x16_t o = vandq_u8(vceqq_u8(v0, dot), bit_mask);
  // Fold the two masks together: one pairwise-add chain instead of two.
  uint8x16_t s = vpaddq_u8(d, o);
  s = vpaddq_u8(s, s);
  s = vpaddq_u8(s, s);
  uint32_t both = vgetq_lane_u32(vreinterpretq_u32_u8(s), 0);
  *digits = both & 0xFFFF;
  *dots = both >> 16;
}
#else
static inline void sp_lab_classify16(const uint8_t *p, uint32_t *digits, uint32_t *dots) {
  uint32_t d = 0, o = 0;
  for (int i = 0; i < 16; i++) {
    if ((uint8_t)(p[i] - '0') <= 9) { d |= 1u << i; }
    if (p[i] == '.') { o |= 1u << i; }
  }
  *digits = d;
  *dots = o;
}
#endif

static inline int sp_lab_decimal16(const uint8_t *p, size_t len, sp_lab_number *out) {
  if (len > 16) { return 0; }
  uint32_t digits, dots;
  sp_lab_classify16(p, &digits, &dots);
  return sp_lab_decimal_from_masks(p, len, digits, dots, out);
}
