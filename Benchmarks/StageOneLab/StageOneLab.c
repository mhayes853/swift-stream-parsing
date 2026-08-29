#include "StageOneLab.h"

#include <string.h>

// The three block algorithms here are simdjson's stage 1, restated: the odd-backslash-run
// escape finder from the simdjson paper (find_odd_backslash_sequences), the quote-parity
// in-string mask via carryless multiply (prefix XOR), and the nibble-table character
// classifier. The index-entry definition matches the census script and the Swift reference
// in StageOneBenchmarks.swift: structural chars outside strings, every unescaped quote, and
// the first byte of every scalar (number/literal) run outside strings.

#if defined(__aarch64__)

#include <arm_neon.h>

// Classification tables. A byte is in a class iff
// (lo_table[b & 0xF] & hi_table[b >> 4]) has the class bit set.
//   0x01 comma, 0x02 colon, 0x04 brackets/braces  -> structural = v & 0x07
//   0x08 space, 0x10 tab/LF/CR                    -> whitespace = v & 0x18
// Known quirk, shared with simdjson's classifier: 0x00 lands in the whitespace class
// (lo 0 hits space's bit, hi 0 hits the control-whitespace bits). The Swift reference
// mirrors it, and a shipping stage 2 would have to reject NUL itself.
static const uint8_t sp1_lo_table[16] = {
  0x08, 0, 0, 0, 0, 0, 0, 0, 0, 0x10, 0x12, 0x04, 0x01, 0x14, 0, 0
};
static const uint8_t sp1_hi_table[16] = {
  0x18, 0, 0x09, 0x02, 0, 0x04, 0, 0x04, 0, 0, 0, 0, 0, 0, 0, 0
};

// simdjson's NEON movemask: one unique bit per lane position within each 8-byte half, then
// three pairwise adds fold 64 compare lanes into one 64-bit mask.
static inline uint64_t sp1_movemask4(
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

// Prefix XOR: bit i of the result is the XOR of bits 0...i of the input. Carryless multiply
// by all-ones is exactly this; PMULL is baseline on every Apple arm64.
static inline uint64_t sp1_prefix_xor(uint64_t bitmask) {
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

#endif  // __aarch64__

// Escaped positions: bit i set iff byte i is preceded by an odd-length backslash run. The
// simdjson paper's find_odd_backslash_sequences, with the one-bit carry for a run that ends
// exactly at the block boundary. Scalar bit math, shared by both architectures.
static inline uint64_t sp1_find_escaped(uint64_t bs_bits, uint64_t *prev_ends_odd) {
  const uint64_t even_bits = 0x5555555555555555ULL;
  const uint64_t odd_bits = ~even_bits;
  uint64_t start_edges = bs_bits & ~(bs_bits << 1);
  // A run continuing from the previous block starts at bit 0 with flipped parity.
  uint64_t even_start_mask = even_bits ^ *prev_ends_odd;
  uint64_t even_starts = start_edges & even_start_mask;
  uint64_t odd_starts = start_edges & ~even_start_mask;
  uint64_t even_carries = bs_bits + even_starts;
  uint64_t odd_carries;
  int ends_odd = __builtin_add_overflow(bs_bits, odd_starts, &odd_carries);
  // The carried-in odd run escapes bit 0 even when this block has no backslashes at all.
  odd_carries |= *prev_ends_odd;
  *prev_ends_odd = (uint64_t)ends_odd;
  uint64_t even_carry_ends = even_carries & ~bs_bits;
  uint64_t odd_carry_ends = odd_carries & ~bs_bits;
  uint64_t even_start_odd_end = even_carry_ends & odd_bits;
  uint64_t odd_start_even_end = odd_carry_ends & even_bits;
  return even_start_odd_end | odd_start_even_end;
}

#if defined(__aarch64__)

// Raw per-class masks for one 64-byte block.
static inline void sp1_class_block(
  const uint8_t *p, uint64_t *bs, uint64_t *quote_raw, uint64_t *op, uint64_t *ws
) {
  uint8x16_t v0 = vld1q_u8(p);
  uint8x16_t v1 = vld1q_u8(p + 16);
  uint8x16_t v2 = vld1q_u8(p + 32);
  uint8x16_t v3 = vld1q_u8(p + 48);

  const uint8x16_t backslash = vdupq_n_u8('\\');
  const uint8x16_t quote = vdupq_n_u8('"');
  *bs = sp1_movemask4(
    vceqq_u8(v0, backslash), vceqq_u8(v1, backslash),
    vceqq_u8(v2, backslash), vceqq_u8(v3, backslash)
  );
  *quote_raw = sp1_movemask4(
    vceqq_u8(v0, quote), vceqq_u8(v1, quote), vceqq_u8(v2, quote), vceqq_u8(v3, quote)
  );
  if (op == NULL) { return; }

  const uint8x16_t lo_table = vld1q_u8(sp1_lo_table);
  const uint8x16_t hi_table = vld1q_u8(sp1_hi_table);
  const uint8x16_t low_nibble = vdupq_n_u8(0x0F);
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
  const uint8x16_t op_bits = vdupq_n_u8(0x07);
  const uint8x16_t ws_bits = vdupq_n_u8(0x18);
  *op = sp1_movemask4(
    vtstq_u8(c0, op_bits), vtstq_u8(c1, op_bits), vtstq_u8(c2, op_bits), vtstq_u8(c3, op_bits)
  );
  *ws = sp1_movemask4(
    vtstq_u8(c0, ws_bits), vtstq_u8(c1, ws_bits), vtstq_u8(c2, ws_bits), vtstq_u8(c3, ws_bits)
  );
}

#else  // portable scalar fallback so the package still builds off arm64; not a benchmark target

static inline void sp1_class_block(
  const uint8_t *p, uint64_t *bs, uint64_t *quote_raw, uint64_t *op, uint64_t *ws
) {
  uint64_t b = 0, q = 0, o = 0, w = 0;
  for (int i = 0; i < 64; i++) {
    uint8_t byte = p[i];
    uint64_t bit = 1ULL << i;
    if (byte == '\\') { b |= bit; }
    if (byte == '"') { q |= bit; }
    uint8_t v = sp1_lo_table[byte & 0xF] & sp1_hi_table[byte >> 4];
    if (v & 0x07) { o |= bit; }
    if (v & 0x18) { w |= bit; }
  }
  *bs = b;
  *quote_raw = q;
  if (op != NULL) {
    *op = o;
    *ws = w;
  }
}

static inline uint64_t sp1_prefix_xor(uint64_t bitmask) {
  bitmask ^= bitmask << 1;
  bitmask ^= bitmask << 2;
  bitmask ^= bitmask << 4;
  bitmask ^= bitmask << 8;
  bitmask ^= bitmask << 16;
  bitmask ^= bitmask << 32;
  return bitmask;
}

#endif  // __aarch64__

// Tier 1 block: quote/escape/in-string only.
static inline uint64_t sp1_string_block(const uint8_t *p, sp1_carry_t *carry) {
  uint64_t bs, quote_raw;
  sp1_class_block(p, &bs, &quote_raw, NULL, NULL);
  uint64_t escaped = sp1_find_escaped(bs, &carry->prev_ends_odd_backslash);
  uint64_t quote = quote_raw & ~escaped;
  uint64_t in_string = sp1_prefix_xor(quote) ^ carry->prev_in_string;
  carry->prev_in_string = (uint64_t)((int64_t)in_string >> 63);
  return in_string;
}

// Tier 1.5 block: the final index bits.
static inline uint64_t sp1_bits_block(const uint8_t *p, sp1_carry_t *carry) {
  uint64_t bs, quote_raw, op, ws;
  sp1_class_block(p, &bs, &quote_raw, &op, &ws);
  uint64_t escaped = sp1_find_escaped(bs, &carry->prev_ends_odd_backslash);
  uint64_t quote = quote_raw & ~escaped;
  uint64_t in_string = sp1_prefix_xor(quote) ^ carry->prev_in_string;
  carry->prev_in_string = (uint64_t)((int64_t)in_string >> 63);
  // in_string covers the opening quote through the byte before the closing quote, so it
  // masks structural bytes and scalars inside string content; quote_raw keeps an escaped
  // quote outside a string (byte soup, not valid JSON) from reading as a scalar.
  uint64_t scalar = ~(op | ws | quote_raw) & ~in_string;
  uint64_t follows_scalar = (scalar << 1) | carry->prev_scalar;
  carry->prev_scalar = scalar >> 63;
  uint64_t scalar_start = scalar & ~follows_scalar;
  return (op & ~in_string) | quote | scalar_start;
}

// Bits to indices, simdjson's shape: unconditional groups of 8 so the common block (census:
// p50 is 10 entries on canada, 0 on gsoc) is branch-free. `bits | (bits == 0)` keeps ctz
// defined once the bits run out; the garbage slots are beyond the returned count and get
// overwritten by the next block.
static inline uint32_t *sp1_extract(uint64_t bits, uint32_t base, uint32_t *out) {
  if (bits == 0) { return out; }
  int count = __builtin_popcountll(bits);
  uint32_t *end = out + count;
  do {
    for (int i = 0; i < 8; i++) {
      uint64_t safe = bits | (uint64_t)(bits == 0);
      out[i] = base + (uint32_t)__builtin_ctzll(safe);
      bits &= bits - 1;
    }
    out += 8;
  } while (bits != 0);
  return end;
}

// The three passes share this window walk: whole 64-byte blocks in place, and a final
// short block copied into a whitespace-padded buffer with the bits past `len` masked off.
// Whitespace padding keeps the padded block's carries truthful for every carry except a
// backslash run cut by the document's end, which is invalid JSON anyway.

uint64_t sp1_string_mask_pass(const uint8_t *p, size_t len, sp1_carry_t *carry) {
  uint64_t sum = 0;
  size_t i = 0;
  for (; i + 64 <= len; i += 64) {
    uint64_t in_string = sp1_string_block(p + i, carry);
    sum = (sum << 1 | sum >> 63) ^ in_string;
  }
  if (i < len) {
    uint8_t tmp[64];
    memset(tmp, ' ', sizeof tmp);
    memcpy(tmp, p + i, len - i);
    uint64_t in_string = sp1_string_block(tmp, carry) & ((1ULL << (len - i)) - 1);
    sum = (sum << 1 | sum >> 63) ^ in_string;
  }
  return sum;
}

uint64_t sp1_full_masks_pass(const uint8_t *p, size_t len, sp1_carry_t *carry) {
  uint64_t sum = 0;
  size_t i = 0;
  for (; i + 64 <= len; i += 64) {
    uint64_t bits = sp1_bits_block(p + i, carry);
    sum = (sum << 1 | sum >> 63) ^ bits;
  }
  if (i < len) {
    uint8_t tmp[64];
    memset(tmp, ' ', sizeof tmp);
    memcpy(tmp, p + i, len - i);
    uint64_t bits = sp1_bits_block(tmp, carry) & ((1ULL << (len - i)) - 1);
    sum = (sum << 1 | sum >> 63) ^ bits;
  }
  return sum;
}

size_t sp1_index_pass(
  const uint8_t *p, size_t len, uint32_t base, sp1_carry_t *carry, uint32_t *out
) {
  uint32_t *cursor = out;
  size_t i = 0;
  for (; i + 64 <= len; i += 64) {
    uint64_t bits = sp1_bits_block(p + i, carry);
    cursor = sp1_extract(bits, base + (uint32_t)i, cursor);
  }
  if (i < len) {
    uint8_t tmp[64];
    memset(tmp, ' ', sizeof tmp);
    memcpy(tmp, p + i, len - i);
    uint64_t bits = sp1_bits_block(tmp, carry) & ((1ULL << (len - i)) - 1);
    cursor = sp1_extract(bits, base + (uint32_t)i, cursor);
  }
  return (size_t)(cursor - out);
}

uint64_t sp1_touch_pass(const uint8_t *p, const uint32_t *idx, size_t count) {
  uint64_t sum = 0;
  for (size_t i = 0; i < count; i++) {
    sum += p[idx[i]];
  }
  return sum;
}
