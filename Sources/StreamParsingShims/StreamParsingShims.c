#include "StreamParsingShims.h"

#include <string.h>

// The header's `static inline` functions are what the Swift side inlines; this file holds the
// one out-of-line kernel, the stage-1 window indexer. Its three block algorithms are simdjson's
// stage 1 restated: the paper's odd-backslash-run escape finder, quote parity as a prefix XOR
// (carryless multiply by all ones), and the nibble-table character classifier. The entry
// definition and the per-block flags are pinned by `StageOneIndexTests` against a scalar
// reference. The measurement that chose this shape is in NEW_ARCHITECTURE.md.

// Classification tables. A byte is in a class iff
// (lo_table[b & 0xF] & hi_table[b >> 4]) has the class bit set:
//   0x01 comma, 0x02 colon, 0x04 brackets/braces  -> structural = v & 0x07
//   0x08 space, 0x10 tab/LF/CR                    -> whitespace = v & 0x18
// hi_table[0] carries only the 0x10 bit so that NUL, whose low nibble shares space's row,
// falls through as a scalar and is rejected by the walk; simdjson's table classifies it as
// whitespace.
static const uint8_t stream_parsing_index_lo_table[16] = {
  0x08, 0, 0, 0, 0, 0, 0, 0, 0, 0x10, 0x12, 0x04, 0x01, 0x14, 0, 0
};
static const uint8_t stream_parsing_index_hi_table[16] = {
  0x10, 0, 0x09, 0x02, 0, 0x04, 0, 0x04, 0, 0, 0, 0, 0, 0, 0, 0
};

// Escaped positions: bit i set iff byte i follows an odd-length backslash run.
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

typedef struct {
  uint64_t backslash;
  uint64_t quote;
  uint64_t structural;
  uint64_t whitespace;
  uint64_t control;    // byte < 0x20, per byte: it is masked by in_string before use
  unsigned non_ascii;  // any byte >= 0x80 in the block: a flag, so a reduce, not a mask
} stream_parsing_block_classes;

#if defined(__aarch64__) && defined(__ARM_NEON)

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

// The block classifier is in two speeds. The quote and backslash masks come first and are all
// the in-string parity needs; a block that turns out to lie entirely inside a string — most
// of every block on the string-heavy corpora — gets its two flags from reduces on the raw
// vectors and never runs the table lookups, the structural and whitespace movemasks, or the
// extraction. A block with any structure gets the full classification.
typedef struct {
  uint8x16_t v0, v1, v2, v3;
} stream_parsing_block_vectors;

static inline void stream_parsing_classify_strings(
  const uint8_t *p, stream_parsing_block_vectors *v, uint64_t *backslash, uint64_t *quote
) {
  v->v0 = vld1q_u8(p);
  v->v1 = vld1q_u8(p + 16);
  v->v2 = vld1q_u8(p + 32);
  v->v3 = vld1q_u8(p + 48);
  const uint8x16_t bs = vdupq_n_u8('\\');
  const uint8x16_t q = vdupq_n_u8('"');
  *backslash = stream_parsing_movemask4(
    vceqq_u8(v->v0, bs), vceqq_u8(v->v1, bs), vceqq_u8(v->v2, bs), vceqq_u8(v->v3, bs)
  );
  *quote = stream_parsing_movemask4(
    vceqq_u8(v->v0, q), vceqq_u8(v->v1, q), vceqq_u8(v->v2, q), vceqq_u8(v->v3, q)
  );
}

// Flags for a block entirely inside a string: any control byte, any non-ASCII byte. Reduces,
// not movemasks — the walk only asks whether, never where.
static inline unsigned stream_parsing_interior_flags(
  const stream_parsing_block_vectors *v, uint64_t backslash
) {
  uint8x16_t lo = vminq_u8(vminq_u8(v->v0, v->v1), vminq_u8(v->v2, v->v3));
  uint8x16_t hi = vmaxq_u8(vmaxq_u8(v->v0, v->v1), vmaxq_u8(v->v2, v->v3));
  unsigned needs_scan = backslash != 0 || vminvq_u8(lo) < 0x20;
  unsigned non_ascii = vmaxvq_u8(hi) >= 0x80;
  return needs_scan | (non_ascii << 1);
}

static inline void stream_parsing_classify_rest(
  const stream_parsing_block_vectors *v, stream_parsing_block_classes *c
) {
  uint8x16_t v0 = v->v0, v1 = v->v1, v2 = v->v2, v3 = v->v3;
  const uint8x16_t space = vdupq_n_u8(0x20);
  c->control = stream_parsing_movemask4(
    vcltq_u8(v0, space), vcltq_u8(v1, space), vcltq_u8(v2, space), vcltq_u8(v3, space)
  );
  c->non_ascii = vmaxvq_u8(vmaxq_u8(vmaxq_u8(v0, v1), vmaxq_u8(v2, v3))) >= 0x80;

  const uint8x16_t lo_table = vld1q_u8(stream_parsing_index_lo_table);
  const uint8x16_t hi_table = vld1q_u8(stream_parsing_index_hi_table);
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
  c->structural = stream_parsing_movemask4(
    vtstq_u8(c0, op_bits), vtstq_u8(c1, op_bits), vtstq_u8(c2, op_bits), vtstq_u8(c3, op_bits)
  );
  c->whitespace = stream_parsing_movemask4(
    vtstq_u8(c0, ws_bits), vtstq_u8(c1, ws_bits), vtstq_u8(c2, ws_bits), vtstq_u8(c3, ws_bits)
  );
}

#else  // Portable scalar path: correct everywhere, fast nowhere; arm64 is the tuned target.

static inline uint64_t stream_parsing_prefix_xor(uint64_t bitmask) {
  bitmask ^= bitmask << 1;
  bitmask ^= bitmask << 2;
  bitmask ^= bitmask << 4;
  bitmask ^= bitmask << 8;
  bitmask ^= bitmask << 16;
  bitmask ^= bitmask << 32;
  return bitmask;
}

typedef struct {
  const uint8_t *p;
} stream_parsing_block_vectors;

static inline void stream_parsing_classify_strings(
  const uint8_t *p, stream_parsing_block_vectors *v, uint64_t *backslash, uint64_t *quote
) {
  v->p = p;
  uint64_t b = 0, q = 0;
  for (int i = 0; i < 64; i++) {
    uint64_t bit = 1ULL << i;
    if (p[i] == '\\') { b |= bit; }
    if (p[i] == '"') { q |= bit; }
  }
  *backslash = b;
  *quote = q;
}

static inline unsigned stream_parsing_interior_flags(
  const stream_parsing_block_vectors *v, uint64_t backslash
) {
  unsigned needs_scan = backslash != 0, non_ascii = 0;
  for (int i = 0; i < 64; i++) {
    if (v->p[i] < 0x20) { needs_scan = 1; }
    if (v->p[i] >= 0x80) { non_ascii = 1; }
  }
  return needs_scan | (non_ascii << 1);
}

static inline void stream_parsing_classify_rest(
  const stream_parsing_block_vectors *v, stream_parsing_block_classes *c
) {
  c->control = 0; c->structural = 0; c->whitespace = 0; c->non_ascii = 0;
  for (int i = 0; i < 64; i++) {
    uint8_t byte = v->p[i];
    uint64_t bit = 1ULL << i;
    if (byte < 0x20) { c->control |= bit; }
    if (byte >= 0x80) { c->non_ascii = 1; }
    uint8_t cls = stream_parsing_index_lo_table[byte & 0xF]
                & stream_parsing_index_hi_table[byte >> 4];
    if (cls & 0x07) { c->structural |= bit; }
    if (cls & 0x18) { c->whitespace |= bit; }
  }
}

#endif

typedef struct {
  uint64_t prev_in_string;
  uint64_t prev_ends_odd_backslash;
  uint64_t prev_whitespace;  // 1 if the previous byte was whitespace
} stream_parsing_index_carry;

// One block: the index bits, plus the two per-block flags folded into `flags` as bit 0
// (needs scan) and bit 1 (non-ASCII).
static inline uint64_t stream_parsing_index_block(
  const uint8_t *p, stream_parsing_index_carry *carry, unsigned *flags
) {
  stream_parsing_block_vectors v;
  stream_parsing_block_classes c;
  stream_parsing_classify_strings(p, &v, &c.backslash, &c.quote);
  uint64_t escaped = stream_parsing_find_escaped(c.backslash, &carry->prev_ends_odd_backslash);
  uint64_t quote = c.quote & ~escaped;
  uint64_t in_string = stream_parsing_prefix_xor(quote) ^ carry->prev_in_string;
  carry->prev_in_string = (uint64_t)((int64_t)in_string >> 63);
  if (quote == 0 && in_string == ~0ULL) {
    // String interior, edge to edge: nothing to index. The whitespace carry is moot, since the
    // next byte is inside the string too. The quote test is not redundant: an opening quote at
    // bit 0 alone also makes the parity all ones, and that quote is an entry.
    carry->prev_whitespace = 0;
    *flags = stream_parsing_interior_flags(&v, c.backslash);
    return 0;
  }
  stream_parsing_classify_rest(&v, &c);
  // `in_string` covers the opening quote through the byte before the closing quote, so it
  // masks structural bytes inside string content. A number or literal is indexed only when
  // whitespace precedes it; one that directly follows a structural byte sits at the walk's
  // cursor and is found there. Together that makes every gap between the cursor and the next
  // entry that *begins* with whitespace pure whitespace, so the walk never scans one
  // (NEW_ARCHITECTURE.md, "Dropping the pseudo-structurals").
  uint64_t scalar = ~(c.structural | c.whitespace | c.quote) & ~in_string;
  uint64_t after_whitespace = (c.whitespace << 1) | carry->prev_whitespace;
  carry->prev_whitespace = c.whitespace >> 63;
  uint64_t needs_scan = c.backslash | (c.control & in_string);
  *flags = (unsigned)(needs_scan != 0) | (c.non_ascii << 1);
  return (c.structural & ~in_string) | quote | (scalar & after_whitespace);
}

// Bits to indices in unconditional groups of eight. Spelled out: as a counted `for` clang left
// it a 12-instruction loop with a taken branch per index; unrolled a slot is six instructions.
// `bits | (bits == 0)` keeps ctz defined once the bits run out; the garbage slots past the
// returned end are overwritten by the next block or fall inside the caller's slack.
#define STREAM_PARSING_EXTRACT_SLOT(i)                                   \
  do {                                                                   \
    uint64_t safe = bits | (uint64_t)(bits == 0);                        \
    out[i] = base + (uint32_t)__builtin_ctzll(safe);                     \
    bits &= bits - 1;                                                    \
  } while (0)

static inline uint32_t *stream_parsing_extract_indices(
  uint64_t bits, uint32_t base, uint32_t *out
) {
  if (bits == 0) { return out; }
  uint32_t *end = out + __builtin_popcountll(bits);
  do {
    STREAM_PARSING_EXTRACT_SLOT(0);
    STREAM_PARSING_EXTRACT_SLOT(1);
    STREAM_PARSING_EXTRACT_SLOT(2);
    STREAM_PARSING_EXTRACT_SLOT(3);
    STREAM_PARSING_EXTRACT_SLOT(4);
    STREAM_PARSING_EXTRACT_SLOT(5);
    STREAM_PARSING_EXTRACT_SLOT(6);
    STREAM_PARSING_EXTRACT_SLOT(7);
    out += 8;
  } while (bits != 0);
  return end;
}

size_t stream_parsing_index_window(const uint8_t *p, size_t len, uint32_t base,
                                   uint32_t *indices, uint64_t *needs_scan,
                                   uint64_t *non_ascii) {
  size_t words = (len + 4095) / 4096;
  for (size_t w = 0; w < words; w++) {
    needs_scan[w] = 0;
    non_ascii[w] = 0;
  }
  stream_parsing_index_carry carry = {0, 0, 0};
  uint32_t *cursor = indices;
  size_t block = 0;
  size_t i = 0;
  for (; i + 64 <= len; i += 64, block++) {
    unsigned flags;
    uint64_t bits = stream_parsing_index_block(p + i, &carry, &flags);
    needs_scan[block >> 6] |= (uint64_t)(flags & 1) << (block & 63);
    non_ascii[block >> 6] |= (uint64_t)(flags >> 1) << (block & 63);
    cursor = stream_parsing_extract_indices(bits, base + (uint32_t)i, cursor);
  }
  if (i < len) {
    uint8_t tmp[64];
    memset(tmp, ' ', sizeof tmp);
    memcpy(tmp, p + i, len - i);
    unsigned flags;
    uint64_t bits = stream_parsing_index_block(tmp, &carry, &flags) & ((1ULL << (len - i)) - 1);
    needs_scan[block >> 6] |= (uint64_t)(flags & 1) << (block & 63);
    non_ascii[block >> 6] |= (uint64_t)(flags >> 1) << (block & 63);
    cursor = stream_parsing_extract_indices(bits, base + (uint32_t)i, cursor);
  }
  return (size_t)(cursor - indices);
}
