#include "StreamParsingShims.h"

// The escaped string tail's block kernel (`JSONParser.coalescedEscapedBlocks`): string content
// copied to the coalescing buffer with its escapes decoded and its UTF-8 validated, 64 bytes at a
// time.
//
// The loop it replaces (`streamStringRunStaging` under `coalescedEscapedStringTail`) restarts its
// scan at every escape and leaves a 16-byte loop through a reduction whose outcome is the data's:
// on prose with an escape every few dozen bytes that is a mispredicted branch per escape. A first
// block kernel that branched on "does this block hold an escape" and walked the backslash mask
// measured no better (raw `LLM message` -0.6%): the same number of unpredictable events, one per
// block instead of one per escape. So nothing here branches on where the escapes are. Every block
// is stored whole, and then two escapes are decoded whether or not the block has two -- an escape
// that is not there is given position 64, where everything it writes lands past the output cursor
// and is overwritten by the next block. What is left to predict is rare, or regular: a third
// escape, the closing quote, a `\u` (decoded in the same out-of-line walk as the third escape).
//
// The input cursor does not depend on the data (but for a `\u` across a block's end), so
// consecutive blocks overlap in the pipeline; the output cursor's only recurrence is one add. A
// backslash that is a block's last byte is carried as a bit rather than by moving the next block.
//
// That makes it a fixed cost per block (about 125 instructions; measured 6.4 ns on an M1 Pro for
// plain ASCII, 9.7 ns on `LLM message` with its validation and its mispredicted third escapes),
// which wins wherever escapes are dense and loses to the per-run loop wherever they are not. So
// it hands text back: see the end of the loop.
//
// Out of line and in a translation unit, unlike the classifiers in the header: it is entered once
// per run of blocks rather than once per token, and one copy serves every sink specialisation.
#if defined(__aarch64__) && defined(__ARM_NEON)

// `streamSimpleEscapeTable` (StreamScanners.swift) widened to every byte value: the decoded byte
// for a selector that is a simple escape, zero for everything else (`u` included). The two tables
// are held to each other by `EscapedTailBlockTests`, which sends every selector byte through both;
// so are the hex digits and the surrogate rules below, against `unicodeEscapeEnd`.
static const uint8_t stream_parsing_simple_escape[256] = {
  ['"'] = '"', ['\\'] = '\\', ['/'] = '/', ['b'] = 0x08,
  ['f'] = 0x0C, ['n'] = 0x0A, ['r'] = 0x0D, ['t'] = 0x09,
};

// A hex digit's value plus one, zero for every other byte, so four lookups ORed down say "all
// hex" in one test.
static const uint8_t stream_parsing_unescape_hex_digit[256] = {
  ['0'] = 1, ['1'] = 2, ['2'] = 3, ['3'] = 4, ['4'] = 5, ['5'] = 6, ['6'] = 7, ['7'] = 8,
  ['8'] = 9, ['9'] = 10,
  ['a'] = 11, ['b'] = 12, ['c'] = 13, ['d'] = 14, ['e'] = 15, ['f'] = 16,
  ['A'] = 11, ['B'] = 12, ['C'] = 13, ['D'] = 14, ['E'] = 15, ['F'] = 16,
};

// Four hex digits as a UTF-16 code unit, or a value past 0xFFFF when one of them is not a digit.
static inline __attribute__((always_inline)) uint32_t
stream_parsing_unescape_hex_quad(const uint8_t *digits) {
  uint32_t a = stream_parsing_unescape_hex_digit[digits[0]];
  uint32_t b = stream_parsing_unescape_hex_digit[digits[1]];
  uint32_t c = stream_parsing_unescape_hex_digit[digits[2]];
  uint32_t d = stream_parsing_unescape_hex_digit[digits[3]];
  if (a == 0 || b == 0 || c == 0 || d == 0) return 0x10000;
  return ((a - 1) << 12) | ((b - 1) << 8) | ((c - 1) << 4) | (d - 1);
}

// The scalar a `\uXXXX` escape at `escape` (block offset `p`, the block's escape starts `starts`)
// spells and, through `taken`, how many source bytes it is. Zero bytes for everything the
// per-escape path has a diagnostic for -- a digit that is not one, a surrogate without its other
// half -- which is therefore left exactly where it was. The caller keeps twelve bytes readable,
// and five in front of `escape` when `p` is at least six.
//
// A surrogate pair whose halves are both in the block is two escapes, six bytes each: the high
// half checks the low one and decodes the pair, and the low half, recognised by the escape that
// began six bytes back being a high surrogate (`second`), makes nothing. Every escape before it
// in the block decoded, or the walk would have stopped, so that high half has already checked
// this one's digits. Only a high half whose partner lies past the block takes twelve. Measured:
// taking twelve at every pair made the walk clear the partner's bit from its mask with a `csel`
// on `taken`, which put the whole decode -- two table lookups deep -- on the path to the next
// escape's position; on `twitterescaped` that cost the walk 8% (161.7 against 149.5 us).
static inline __attribute__((always_inline)) uint32_t
stream_parsing_unescape_unicode(const uint8_t *escape, ptrdiff_t p, uint64_t starts,
                                ptrdiff_t *taken, int *second) {
  *taken = 0;
  *second = 0;
  if (escape[1] != 'u') return 0;
  uint32_t unit = stream_parsing_unescape_hex_quad(escape + 2);
  if (unit < 0xD800 || (unit >= 0xE000 && unit <= 0xFFFF)) {
    *taken = 6;
    return unit;
  }
  if (unit >= 0xDC00) {
    // `D` then `8` to `B`: the escape six bytes back was a high surrogate.
    if (unit <= 0xDFFF && p >= 6 && ((starts >> (p - 6)) & 1) && escape[-5] == 'u'
        && stream_parsing_unescape_hex_digit[escape[-4]] == 0xD + 1
        && (uint32_t)stream_parsing_unescape_hex_digit[escape[-3]] - (0x8 + 1) <= 3) {
      *taken = 6;
      *second = 1;
    }
    return 0;
  }
  if (escape[6] != '\\' || escape[7] != 'u') return 0;
  uint32_t low = stream_parsing_unescape_hex_quad(escape + 8);
  if (low < 0xDC00 || low > 0xDFFF) return 0;
  *taken = p + 6 >= 64 ? 12 : 6;
  return 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
}

// Four `\uXXXX` escapes in a row, each a three-byte scalar that is not a surrogate (U+0800 to
// U+D7FF, U+E000 to U+FFFF), decoded together from the 24 bytes at `escape` (32 are read): their
// 12 bytes of UTF-8 in the low lanes of `*utf8`, junk in the top four. 0 when the 24 bytes are
// anything else, and then nothing is concluded -- the scalar decode takes the escape as before.
//
// Text in a script outside Latin serialised ASCII-only (Python's `json.dumps` default; all of
// `twitterescaped`, 31,770 of whose 31,818 `\u` escapes are three-byte scalars, 85% of them in
// runs of eight or more) is runs of exactly these. Three-byte scalars alone make the encoding a
// fixed shuffle: escape i's digits n0..n3 sit at 6i + 2 .. 6i + 5 and its UTF-8 is
//   0xE0 | n0,   0x80 | n1 << 2 | n2 >> 2,   0x80 | (n2 & 3) << 4 | n3,
// so two `tbl` gathers (each byte's two digit sources) and two per-lane shifts make all twelve.
// `two` (a constant at each call) asks the same of the first two escapes only, the first 12 bytes
// and 6 of UTF-8: a run's remainder, which otherwise went one escape at a time through the scalar
// decode (the kernel alone on `twitterescaped`: 69.0-70.7 -> 62.9-65.8 us).
static inline __attribute__((always_inline)) int
stream_parsing_unescape_four_bmp(const uint8_t *escape, uint8x16_t *utf8, const int two) {
  const uint8x16_t a = vld1q_u8(escape);
  const uint8x16_t b = vld1q_u8(escape + 16);
  // What the 24 bytes must be where they are not digits -- `\` then `u`, every six -- and which
  // lanes are digits. The eight lanes of `b` past the 24 bytes are neither, and pass.
  const uint8x16_t expect_a = {'\\', 'u', 0, 0, 0, 0, '\\', 'u', 0, 0, 0, 0, '\\', 'u', 0, 0};
  const uint8x16_t expect_b = {0, 0, '\\', 'u', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
  const uint8x16_t digit_a = {0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0,
                              0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0xFF, 0xFF};
  const uint8x16_t digit_b = {0xFF, 0xFF, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0};
  const uint8x16_t past_b = {0, 0, 0, 0, 0, 0, 0, 0,
                             0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};
  // A digit's value: `0`-`9` by subtraction, `a`-`f` and `A`-`F` folded to lower case first.
  const uint8x16_t decimal_a = vsubq_u8(a, vdupq_n_u8('0'));
  const uint8x16_t decimal_b = vsubq_u8(b, vdupq_n_u8('0'));
  const uint8x16_t letter_a = vsubq_u8(vorrq_u8(a, vdupq_n_u8(0x20)), vdupq_n_u8('a'));
  const uint8x16_t letter_b = vsubq_u8(vorrq_u8(b, vdupq_n_u8(0x20)), vdupq_n_u8('a'));
  const uint8x16_t is_decimal_a = vcltq_u8(decimal_a, vdupq_n_u8(10));
  const uint8x16_t is_decimal_b = vcltq_u8(decimal_b, vdupq_n_u8(10));
  const uint8x16_t is_digit_a = vorrq_u8(is_decimal_a, vcltq_u8(letter_a, vdupq_n_u8(6)));
  const uint8x16_t is_digit_b = vorrq_u8(is_decimal_b, vcltq_u8(letter_b, vdupq_n_u8(6)));
  const uint8x16_t shape_a = vbslq_u8(digit_a, is_digit_a, vceqq_u8(a, expect_a));
  const uint8x16_t shape_b =
      vorrq_u8(vbslq_u8(digit_b, is_digit_b, vceqq_u8(b, expect_b)), past_b);
  const uint8x16x2_t nibbles = {{
      vbslq_u8(is_decimal_a, decimal_a, vaddq_u8(letter_a, vdupq_n_u8(10))),
      vbslq_u8(is_decimal_b, decimal_b, vaddq_u8(letter_b, vdupq_n_u8(10))),
  }};
  // Output byte 3i + r: `x` is n0, n1, n2 for r = 0, 1, 2 and `y` is nothing, n2, n3.
  const uint8x16_t x_index = {2, 3, 4, 8, 9, 10, 14, 15, 16, 20, 21, 22, 0xFF, 0xFF, 0xFF, 0xFF};
  const uint8x16_t y_index = {0xFF, 4, 5, 0xFF, 10, 11, 0xFF, 16, 17, 0xFF, 22, 23,
                              0xFF, 0xFF, 0xFF, 0xFF};
  const uint8x16_t x = vqtbl2q_u8(nibbles, x_index);
  const uint8x16_t y = vqtbl2q_u8(nibbles, y_index);
  const uint8x16_t x_mask = {0x0F, 0x0F, 0x03, 0x0F, 0x0F, 0x03, 0x0F, 0x0F, 0x03,
                             0x0F, 0x0F, 0x03, 0, 0, 0, 0};
  const int8x16_t x_shift = {0, 2, 4, 0, 2, 4, 0, 2, 4, 0, 2, 4, 0, 0, 0, 0};
  const int8x16_t y_shift = {0, -2, 0, 0, -2, 0, 0, -2, 0, 0, -2, 0, 0, 0, 0, 0};
  const uint8x16_t marks = {0xE0, 0x80, 0x80, 0xE0, 0x80, 0x80, 0xE0, 0x80, 0x80,
                            0xE0, 0x80, 0x80, 0, 0, 0, 0};
  *utf8 = vorrq_u8(vorrq_u8(marks, vshlq_u8(vandq_u8(x, x_mask), x_shift)), vshlq_u8(y, y_shift));
  // Three bytes and not a surrogate, on lane 3i where `x` is n0 and the lane after it n1: at
  // least U+0800 (n0 != 0 or n1 >= 8), and not D800-DFFF (n0 == 0xD and n1 >= 8).
  const uint8x16_t n1_high = vcgeq_u8(vextq_u8(x, x, 1), vdupq_n_u8(8));
  const uint8x16_t wide = vorrq_u8(vtstq_u8(x, x), n1_high);
  const uint8x16_t surrogate = vandq_u8(vceqq_u8(x, vdupq_n_u8(0xD)), n1_high);
  const uint8x16_t lead4 = {0xFF, 0, 0, 0xFF, 0, 0, 0xFF, 0, 0, 0xFF, 0, 0, 0, 0, 0, 0};
  const uint8x16_t lead2 = {0xFF, 0, 0, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
  const uint8x16_t lead = two ? lead2 : lead4;
  const uint8x16_t range = vornq_u8(vbicq_u8(wide, surrogate), lead);
  if (two) {
    // Only the first 12 bytes of `a` are looked at, and nothing of `b`.
    const uint8x16_t past_a = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF};
    return vminvq_u8(vandq_u8(vorrq_u8(shape_a, past_a), range)) == 0xFF;
  }
  return vminvq_u8(vandq_u8(vandq_u8(shape_a, shape_b), range)) == 0xFF;
}

// Whether a `\u` escape's first digit is one a run of three-byte scalars mostly begins with:
// anything but `0` and `d`/`D`. A filter only; the run's own check is the exact one.
static inline __attribute__((always_inline)) int
stream_parsing_unescape_run_lead(uint8_t digit) {
  return digit != '0' && (digit | 0x20) != 'd';
}

// `stream_parsing_unescape_four_bmp` from the escape at `s + q`, written from `e`, for as long as
// it holds and the run starts at or before `reach`, then two more if they are there; returns where
// the run stopped.
//
// Out of line, entered once per run. Two inline forms measured worse end to end: with literal
// constants LLVM kept all fourteen in vector registers across the block loop, eight of them
// callee-saved and saved on every kernel entry; with the constants behind a pointer made opaque
// by an empty `asm`, the block loop was spill-free and the kernel alone as fast, yet raw
// `Twitter escaped` gained +6.2% over the per-escape walk where this form gains +20.8%.
//
// The first test turns away an escape whose digits, or the next one's, begin with `0` or `d`
// (below U+1000, or U+D000 up and the surrogates): text whose escapes are mixed -- two-byte
// scalars, surrogate pairs, `Fast Unicode escaped string` -- otherwise paid for the shape check
// at every escape and decoded none of them (the kernel alone on that document: 4.9 us before
// any of this, 13.6 with the check unguarded, 8.8 with this test; what is left is the call and
// the pair taken as two escapes). It is here and not at the call: in the walk, the
// two more loads and compares cost `LLM message` 3% end to end, through a register the block
// loop then spilled.
static __attribute__((noinline)) ptrdiff_t
stream_parsing_unescape_bmp_run(const uint8_t *s, ptrdiff_t q, uint8_t *e, ptrdiff_t reach) {
  uint8x16_t utf8;
  if (!stream_parsing_unescape_run_lead(s[q + 2]) || !stream_parsing_unescape_run_lead(s[q + 8])) {
    return q;
  }
  while (q <= reach && stream_parsing_unescape_four_bmp(s + q, &utf8, 0)) {
    vst1q_u8(e, utf8);
    e += 12;
    q += 24;
  }
  if (q <= reach && stream_parsing_unescape_four_bmp(s + q, &utf8, 1)) {
    vst1q_u8(e, utf8);
    q += 12;
  }
  return q;
}

// A scalar's UTF-8 encoding little-endian in a word, and its length (`JSONParser.utf8Word`).
static inline __attribute__((always_inline)) uint32_t
stream_parsing_unescape_utf8(uint32_t scalar, ptrdiff_t *length) {
  if (scalar < 0x80) {
    *length = 1;
    return scalar;
  }
  if (scalar < 0x800) {
    *length = 2;
    return (0xC0 | (scalar >> 6)) | ((0x80 | (scalar & 0x3F)) << 8);
  }
  if (scalar < 0x10000) {
    *length = 3;
    return (0xE0 | (scalar >> 12)) | ((0x80 | ((scalar >> 6) & 0x3F)) << 8)
        | ((0x80 | (scalar & 0x3F)) << 16);
  }
  *length = 4;
  return (0xF0 | (scalar >> 18)) | ((0x80 | ((scalar >> 12) & 0x3F)) << 8)
      | ((0x80 | ((scalar >> 6) & 0x3F)) << 16) | ((0x80 | (scalar & 0x3F)) << 24);
}

// What follows an escape's selector, copied again one byte to the left of where the block store
// put it. Sixty-four bytes however many are left in the block: two `ldp`/`stp` pairs against a
// variable-length copy, and the slack the loop bound reserves is for exactly this.
static inline __attribute__((always_inline)) void
stream_parsing_unescape_recopy(uint8_t *target, const uint8_t *source) {
  uint8x16_t r0 = vld1q_u8(source);
  uint8x16_t r1 = vld1q_u8(source + 16);
  uint8x16_t r2 = vld1q_u8(source + 32);
  uint8x16_t r3 = vld1q_u8(source + 48);
  vst1q_u8(target, r0);
  vst1q_u8(target + 16, r1);
  vst1q_u8(target + 32, r2);
  vst1q_u8(target + 48, r3);
}

// The lowest set bit's index, 64 for none (`rbit` + `clz`, which answers 64 for zero by itself).
static inline __attribute__((always_inline)) ptrdiff_t
stream_parsing_unescape_first(uint64_t bits) {
  return bits != 0 ? (ptrdiff_t)__builtin_ctzll(bits) : 64;
}

// Which backslashes of a block begin an escape, and through `escaped` which bytes are a selector
// (the byte after such a backslash, itself a backslash or not). `next_is_escaped` carries "the
// block before ended on an escape's backslash" in and out. This is simdjson's newer escape
// scanner, not `stream_parsing_find_escaped`: that one marks only the byte after an odd-length run,
// which is the question a quote asks, and says nothing of the backslashes inside the run.
//
// A backslash not already a selector may begin an escape. Subtracting those from the odd bits
// (with their successors set) carries through each run, leaving a pattern whose XOR with the odd
// bits marks every second position of a run from its own start: the selectors, and one past an
// odd run's end.
static inline __attribute__((always_inline)) uint64_t
stream_parsing_unescape_starts(uint64_t backslash, uint64_t *next_is_escaped, uint64_t *escaped) {
  const uint64_t odd_bits = 0xAAAAAAAAAAAAAAAAULL;
  uint64_t potential = backslash & ~*next_is_escaped;
  uint64_t code = (((potential << 1) | odd_bits) - potential) ^ odd_bits;
  *escaped = code ^ (backslash | *next_is_escaped);
  uint64_t starts = code & backslash;
  *next_is_escaped = starts >> 63;
  return starts;
}

// The UTF-8 validator's three nibble tables (`streamUTF8PreviousHighTable`,
// `streamUTF8PreviousLowTable`, `streamUTF8CurrentHighTable` in StreamScanners.swift), byte for
// byte; `EscapedTailBlockTests` holds them to the Swift ones through
// `stream_parsing_unescape_utf8_table`. Here rather than passed in: the Swift tables are
// computed getters that out-of-module sink specialisations call rather than inline, three `bl`s
// and three vector spills on every kernel entry, where these are three loads.
#define STREAM_UTF8_TOO_SHORT (1 << 0)
#define STREAM_UTF8_TOO_LONG (1 << 1)
#define STREAM_UTF8_OVERLONG_3 (1 << 2)
#define STREAM_UTF8_TOO_LARGE (1 << 3)
#define STREAM_UTF8_SURROGATE (1 << 4)
#define STREAM_UTF8_OVERLONG_2 (1 << 5)
#define STREAM_UTF8_TOO_LARGE_1000 (1 << 6)
#define STREAM_UTF8_OVERLONG_4 (1 << 6)
#define STREAM_UTF8_TWO_CONTINUATIONS (1 << 7)
#define STREAM_UTF8_CARRY \
  (STREAM_UTF8_TOO_SHORT | STREAM_UTF8_TOO_LONG | STREAM_UTF8_TWO_CONTINUATIONS)
#define STREAM_UTF8_HIGH_LOW (STREAM_UTF8_CARRY | STREAM_UTF8_TOO_LARGE | STREAM_UTF8_TOO_LARGE_1000)

static const uint8_t stream_parsing_unescape_utf8_tables[3][16] = {
  // Indexed by the high nibble of the previous byte.
  {
    STREAM_UTF8_TOO_LONG, STREAM_UTF8_TOO_LONG, STREAM_UTF8_TOO_LONG, STREAM_UTF8_TOO_LONG,
    STREAM_UTF8_TOO_LONG, STREAM_UTF8_TOO_LONG, STREAM_UTF8_TOO_LONG, STREAM_UTF8_TOO_LONG,
    STREAM_UTF8_TWO_CONTINUATIONS, STREAM_UTF8_TWO_CONTINUATIONS,
    STREAM_UTF8_TWO_CONTINUATIONS, STREAM_UTF8_TWO_CONTINUATIONS,
    STREAM_UTF8_TOO_SHORT | STREAM_UTF8_OVERLONG_2,
    STREAM_UTF8_TOO_SHORT,
    STREAM_UTF8_TOO_SHORT | STREAM_UTF8_OVERLONG_3 | STREAM_UTF8_SURROGATE,
    STREAM_UTF8_TOO_SHORT | STREAM_UTF8_TOO_LARGE | STREAM_UTF8_TOO_LARGE_1000
      | STREAM_UTF8_OVERLONG_4,
  },
  // Indexed by the low nibble of the previous byte.
  {
    STREAM_UTF8_CARRY | STREAM_UTF8_OVERLONG_3 | STREAM_UTF8_OVERLONG_2 | STREAM_UTF8_OVERLONG_4,
    STREAM_UTF8_CARRY | STREAM_UTF8_OVERLONG_2,
    STREAM_UTF8_CARRY,
    STREAM_UTF8_CARRY,
    STREAM_UTF8_CARRY | STREAM_UTF8_TOO_LARGE,
    STREAM_UTF8_HIGH_LOW, STREAM_UTF8_HIGH_LOW, STREAM_UTF8_HIGH_LOW, STREAM_UTF8_HIGH_LOW,
    STREAM_UTF8_HIGH_LOW, STREAM_UTF8_HIGH_LOW, STREAM_UTF8_HIGH_LOW, STREAM_UTF8_HIGH_LOW,
    STREAM_UTF8_HIGH_LOW | STREAM_UTF8_SURROGATE,
    STREAM_UTF8_HIGH_LOW, STREAM_UTF8_HIGH_LOW,
  },
  // Indexed by the high nibble of the current byte.
  {
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
    STREAM_UTF8_TOO_SHORT, STREAM_UTF8_TOO_SHORT, STREAM_UTF8_TOO_SHORT, STREAM_UTF8_TOO_SHORT,
  },
};

uint8_t stream_parsing_unescape_utf8_table(int table, int nibble) {
  return (unsigned)table < 3 ? stream_parsing_unescape_utf8_tables[table][nibble & 15] : 0;
}

__attribute__((noinline, aligned(64)))
stream_parsing_unescape_result stream_parsing_unescape_blocks(
    const uint8_t *src, ptrdiff_t n, uint8_t *dst, ptrdiff_t room) {
  const stream_parsing_u8x16 utf8_previous_high =
      (stream_parsing_u8x16)vld1q_u8(stream_parsing_unescape_utf8_tables[0]);
  const stream_parsing_u8x16 utf8_previous_low =
      (stream_parsing_u8x16)vld1q_u8(stream_parsing_unescape_utf8_tables[1]);
  const stream_parsing_u8x16 utf8_current_high =
      (stream_parsing_u8x16)vld1q_u8(stream_parsing_unescape_utf8_tables[2]);
  const uint8x16_t backslash = vdupq_n_u8('\\');
  const uint8x16_t space = vdupq_n_u8(0x20);
  const uint8x16_t flip = vdupq_n_u8(0x02);
  ptrdiff_t in = 0;
  ptrdiff_t out = 0;
  // Whether the block before this one ended on the backslash of an escape, whose selector is then
  // this block's first byte; whether it held a non-ASCII byte; how many more blocks are to be
  // validated on the strength of the last one that did; and whether it was validated in full.
  uint64_t carry = 0;
  int previous_high = 0;
  ptrdiff_t validating = 0;
  int wide = 0;
  // Blocks in a row without an escape.
  ptrdiff_t quiet = 0;
  uint32_t reason = STREAM_PARSING_UNESCAPE_POSITIONAL;

  while (in + STREAM_PARSING_UNESCAPE_SOURCE_SLACK <= n
         && out + STREAM_PARSING_UNESCAPE_TARGET_SLACK <= room) {
    const uint8_t *s = src + in;
    uint8_t *d = dst + out;
    uint8x16_t v0 = vld1q_u8(s);
    uint8x16_t v1 = vld1q_u8(s + 16);
    uint8x16_t v2 = vld1q_u8(s + 32);
    uint8x16_t v3 = vld1q_u8(s + 48);
    vst1q_u8(d, v0);
    vst1q_u8(d + 16, v1);
    vst1q_u8(d + 32, v2);
    vst1q_u8(d + 48, v3);

    uint64_t bs = stream_parsing_movemask4(
        vceqq_u8(v0, backslash), vceqq_u8(v1, backslash),
        vceqq_u8(v2, backslash), vceqq_u8(v3, backslash));
    // A quote or a control byte in two operations a vector: flipping bit 1 swaps 0x22 with 0x20
    // and keeps everything below 0x20 below it, so "at most 0x20" afterwards is exactly those.
    uint64_t term = stream_parsing_movemask4(
        vcleq_u8(veorq_u8(v0, flip), space), vcleq_u8(veorq_u8(v1, flip), space),
        vcleq_u8(veorq_u8(v2, flip), space), vcleq_u8(veorq_u8(v3, flip), space));
    // Where the non-ASCII bytes are, to four bytes: three pairwise maxima leave one byte per
    // group of four, and the `shrn` movemask makes that a nibble per group.
    uint64_t high_groups = vget_lane_u64(vreinterpret_u64_u8(vshrn_n_u16(vreinterpretq_u16_u8(
        vcltzq_s8(vreinterpretq_s8_u8(
            vpmaxq_u8(vpmaxq_u8(v0, v1), vpmaxq_u8(v2, v3))))), 4)), 0);
    int high = high_groups != 0;

    // UTF-8, over the source: an escape is ASCII there, so it ends a sequence exactly as the end
    // of the run it closes did for the per-run loop.
    //
    // *When* to check. A block with a non-ASCII byte must be, and what follows its last such byte
    // must be, which is where a cut sequence shows. Branching on exactly that was measured and is
    // the wrong test: in prose with a non-ASCII character every few hundred bytes (`LLM message`:
    // a third of its blocks, in three thousand separate stretches) it goes the data's way, and it
    // resolves a reduction and an `fmov` after the load. So a non-ASCII block turns validation on
    // for the sixteen blocks from it, ASCII or not: text with such characters is checked
    // throughout, text with none never is, and the branch changes its mind once per kilobyte of
    // plain ASCII at most.
    //
    // *What* to check. All four vectors, every block, cost that same prose 38% of this kernel
    // (4.7 of 12.4 ns a block): its non-ASCII is one dash or quote at a time. So one vector is
    // checked, placed a byte ahead of the first non-ASCII group. Its sixteen lanes reach the byte
    // after the last non-ASCII one -- the lane a cut sequence is reported in -- whenever those
    // bytes span at most three groups, and only a block where they do not (text *in* another
    // script, where that is every block and the branch is as predictable) pays for all four. A
    // block with none puts the vector on its own first bytes, which is the check that the block
    // before did not end mid-sequence. The lookup's three views of the bytes before each lane
    // are loads at -1/-2/-3 from the vector, so four bytes in front of `src` are the caller's to
    // keep readable.
    validating = high ? STREAM_PARSING_UNESCAPE_VALIDATION_RUN : validating - 1;
    if (__builtin_expect(validating > 0, 0)) {
      ptrdiff_t first_group = high ? __builtin_ctzll(high_groups) >> 2 : 0;
      ptrdiff_t last_group = high ? (63 - __builtin_clzll(high_groups)) >> 2 : 0;
      const uint8_t *w = s + 4 * first_group - 1;
      uint8x16_t errors = (uint8x16_t)stream_parsing_utf8_block_errors(
          (stream_parsing_u8x16)vld1q_u8(w), (stream_parsing_u8x16)vld1q_u8(w - 1),
          (stream_parsing_u8x16)vld1q_u8(w - 2), (stream_parsing_u8x16)vld1q_u8(w - 3),
          utf8_previous_high, utf8_previous_low, utf8_current_high);
      wide = (last_group - first_group > 2) | wide;
      if (__builtin_expect(wide, 0)) {
        wide = last_group - first_group > 2;
        errors = vorrq_u8(errors, (uint8x16_t)stream_parsing_utf8_block_errors(
            (stream_parsing_u8x16)v0, (stream_parsing_u8x16)vld1q_u8(s - 1),
            (stream_parsing_u8x16)vld1q_u8(s - 2), (stream_parsing_u8x16)vld1q_u8(s - 3),
            utf8_previous_high, utf8_previous_low, utf8_current_high));
        errors = vorrq_u8(errors, (uint8x16_t)stream_parsing_utf8_block_errors(
            (stream_parsing_u8x16)v1, (stream_parsing_u8x16)vld1q_u8(s + 15),
            (stream_parsing_u8x16)vld1q_u8(s + 14), (stream_parsing_u8x16)vld1q_u8(s + 13),
            utf8_previous_high, utf8_previous_low, utf8_current_high));
        errors = vorrq_u8(errors, (uint8x16_t)stream_parsing_utf8_block_errors(
            (stream_parsing_u8x16)v2, (stream_parsing_u8x16)vld1q_u8(s + 31),
            (stream_parsing_u8x16)vld1q_u8(s + 30), (stream_parsing_u8x16)vld1q_u8(s + 29),
            utf8_previous_high, utf8_previous_low, utf8_current_high));
        errors = vorrq_u8(errors, (uint8x16_t)stream_parsing_utf8_block_errors(
            (stream_parsing_u8x16)v3, (stream_parsing_u8x16)vld1q_u8(s + 47),
            (stream_parsing_u8x16)vld1q_u8(s + 46), (stream_parsing_u8x16)vld1q_u8(s + 45),
            utf8_previous_high, utf8_previous_low, utf8_current_high));
        // The four vectors end with the block, so a sequence cut by its end shows in the next
        // block's first lane, which that block's one vector need not cover: the block after a
        // wide one is checked wide too, whatever it holds.
      }
      if (vmaxvq_u8(errors) != 0) {
        // Not necessarily an error in this value -- the bytes checked may lie past its closing
        // quote -- so nothing is concluded here: the per-run loop takes it from the block's
        // first byte.
        reason = STREAM_PARSING_UNESCAPE_INVALID;
        break;
      }
    }

    uint64_t carry_in = carry;
    // The backslashes that begin an escape, the bytes that are a selector, and the quotes and
    // control bytes that are not one.
    uint64_t escaped;
    uint64_t starts = stream_parsing_unescape_starts(bs, &carry, &escaped);
    uint64_t stops = term & ~escaped;

    // The selector of the last block's final backslash, which that block found to be simple and
    // whose decoded byte the block store above has just overwritten. About one escape in 64.
    if (carry_in) d[0] = stream_parsing_simple_escape[s[0]];

    // Two escapes, present or not. An absent one has position 64: its selector read is `s[65]`,
    // its decoded byte and its recopy land at or past `d + 64 - removed`, which is past
    // everything this block produces.
    ptrdiff_t p0 = stream_parsing_unescape_first(starts);
    uint64_t rest = starts & (starts - 1);
    ptrdiff_t p1 = stream_parsing_unescape_first(rest);
    rest &= rest - 1;
    ptrdiff_t has0 = p0 < 64;
    ptrdiff_t has1 = p1 < 64;
    uint8_t decoded0 = stream_parsing_simple_escape[s[p0 + 1]];
    uint8_t decoded1 = stream_parsing_simple_escape[s[p1 + 1]];
    uint8_t *e0 = d + p0;
    uint8_t *e1 = d + p1 - has0;
    e0[0] = decoded0;
    stream_parsing_unescape_recopy(e0 + 1, s + p0 + 2);
    e1[0] = decoded1;
    stream_parsing_unescape_recopy(e1 + 1, s + p1 + 2);
    ptrdiff_t removed = has0 + has1;
    // `\u`, or a selector with a diagnostic.
    int unhandled = (int)((has0 & (decoded0 == 0)) | (has1 & (decoded1 == 0)));

    // Two tests, not one ORed: the first is known from the masks, the second only after the
    // selector and the table have been loaded, and a branch cannot resolve before its last input.
    // The first is the one the data decides (a third escape in one block in nine of `LLM
    // message`); kept apart, its mispredictions are found two loads sooner.
    // How far this block moves the input: 64, but for a `\u` escape across its end.
    ptrdiff_t advance = 64;
    if (__builtin_expect((rest | stops) != 0, 0) || __builtin_expect(unhandled, 0)) {
      // A third escape, a stop, or an escape that is not simple: the block again, in order. The
      // stores above are either what this writes too or past where it ends.
      //
      // `\u` escapes are decoded here and nowhere else in the kernel, so a block that has one
      // always comes this way; in text that has them at all that is as predictable as not
      // coming. Measured: stopping at each for the caller to decode cost 17 ns an escape (the
      // call out and back in, and the block read twice), which was 3% of raw `GSoC 2018`.
      ptrdiff_t t = stream_parsing_unescape_first(stops);
      uint64_t pending = t < 64 ? starts & ((1ULL << t) - 1) : starts;
      ptrdiff_t k = 0;
      ptrdiff_t stop_at = t;
      while (pending != 0) {
        ptrdiff_t p = (ptrdiff_t)__builtin_ctzll(pending);
        uint8_t *e = d + p - k;
        uint8_t decoded = stream_parsing_simple_escape[s[p + 1]];
        pending &= pending - 1;
        if (decoded != 0) {
          e[0] = decoded;
          stream_parsing_unescape_recopy(e + 1, s + p + 2);
          k += 1;
          continue;
        }
        // Marked unlikely for the register allocator rather than the branch predictor: the call
        // clobbers the vector registers the block loop keeps its constants in, and at the walk's
        // usual frequency LLVM saved them on every entry to the walk (LLM's and GSoC's third
        // escapes and closing quotes) instead of around the call.
        if (__builtin_expect(s[p + 6] == '\\' && s[p + 18] == '\\', 0)) {
          // Possibly a run of three-byte scalars: four at a time for as long as it lasts, past
          // this block if need be, but only as far as the run's reads and the recopy after it
          // stay inside the source and its writes inside the target (the output never runs
          // ahead of the input, so the source's bound serves both). Measured on
          // `twitterescaped`, the kernel alone: 161.7 -> 70.2 us; bounded to the block's own
          // slack (a run starting at or before byte 52) it was 85.2.
          ptrdiff_t reach = (n - in < room - out ? n - in : room - out) - 88;
          ptrdiff_t q = stream_parsing_unescape_bmp_run(s, p, e, reach);
          if (q != p) {
            e += (q - p) >> 1;
            k += (q - p) >> 1;
            stream_parsing_unescape_recopy(e, s + q);
            pending = q >= 64 ? 0 : pending & (~0ULL << q);
            if (q > 64) {
              advance = q;
              carry = 0;
              break;
            }
            continue;
          }
        }
        ptrdiff_t taken;
        int second;
        uint32_t scalar = stream_parsing_unescape_unicode(s + p, p, starts, &taken, &second);
        if (taken == 0) {
          stop_at = p;
          break;
        }
        // One to four bytes in one store (none for a pair's second half); the recopy begins
        // where they end.
        ptrdiff_t made;
        uint32_t word = stream_parsing_unescape_utf8(scalar, &made);
        made = second ? 0 : made;
        __builtin_memcpy(e, &word, 4);
        stream_parsing_unescape_recopy(e + made, s + p + taken);
        k += taken - made;
        if (p + taken > 64) {
          // The escape runs past the block (no stop can lie inside one), so nothing of the block
          // is left and the next begins behind the escape rather than at the next 64. This is
          // the one place the input cursor follows the data, with the run above.
          advance = p + taken;
          carry = 0;
          break;
        }
      }
      if (stop_at < 64) {
        // `src[consumed]` is the quote, the control byte or the backslash.
        in += stop_at;
        out += stop_at - k;
        carry = 0;
        reason = STREAM_PARSING_UNESCAPE_STOP;
        break;
      }
      removed = k;
    }

    in += advance;
    out += advance - removed;
    previous_high = high;

    // A long stretch with no escape in it is not this kernel's text: every block still pays for
    // two escapes it does not have, and the per-run loop's sixteen-byte scan, which pays for none
    // and does not even copy a run longer than the buffer, is more than twice as fast there
    // (measured, a megabyte after one escape: 24.5 against 9.9 GB/s). The two meet at about one
    // escape per 256 bytes. So after sixteen blocks without one the rest of the run is the
    // loop's, and it sends the text back here when the run has ended. Measured, whole parse:
    // letting go after four blocks cost raw `LLM message` 18% against eight (4.25 for 5.18
    // GB/s: paragraphs handed over and taken back); eight and sixteen are level there; and at an
    // escape per 256 bytes four is -13% on the per-run loop alone, eight -3%, sixteen level.
    quiet = starts != 0 ? 0 : quiet + 1;
    if (__builtin_expect(quiet >= STREAM_PARSING_UNESCAPE_QUIET_RUN, 0)) {
      reason = STREAM_PARSING_UNESCAPE_QUIET;
      break;
    }
  }

  if (carry) {
    // Left mid-content with the last byte taken a backslash: it produced nothing, and its escape
    // is whoever reads next's to decode.
    in -= 1;
  } else if (reason != STREAM_PARSING_UNESCAPE_STOP && previous_high) {
    // Left mid-content after a non-ASCII block, whose last sequence may continue past it. The
    // bytes of a cut sequence are given back, so the next reader starts on its lead. They are
    // the source's own bytes at the end of the output too: the test is on the source, where an
    // escape is ASCII whatever it decodes to.
    const uint8_t *end = src + in;
    ptrdiff_t back = 0;
    if (end[-1] >= 0xC0) {
      back = 1;
    } else if (end[-2] >= 0xE0) {
      back = 2;
    } else if (end[-3] >= 0xF0) {
      back = 3;
    }
    in -= back;
    out -= back;
  }

  stream_parsing_unescape_result result = { in, (out << 2) | (ptrdiff_t)reason };
  return result;
}

#endif
