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

// The scalar a `\uXXXX` escape at `escape` spells and, through `taken`, how many source bytes it
// is: six, or twelve for a surrogate pair. Zero bytes for everything the per-escape path has a
// diagnostic for -- a digit that is not one, a surrogate without its other half -- which is
// therefore left exactly where it was. The caller keeps twelve bytes readable.
static inline __attribute__((always_inline)) uint32_t
stream_parsing_unescape_unicode(const uint8_t *escape, ptrdiff_t *taken) {
  *taken = 0;
  if (escape[1] != 'u') return 0;
  uint32_t unit = stream_parsing_unescape_hex_quad(escape + 2);
  if (unit < 0xD800 || (unit >= 0xE000 && unit <= 0xFFFF)) {
    *taken = 6;
    return unit;
  }
  if (unit > 0xDBFF || escape[6] != '\\' || escape[7] != 'u') return 0;
  uint32_t low = stream_parsing_unescape_hex_quad(escape + 8);
  if (low < 0xDC00 || low > 0xDFFF) return 0;
  *taken = 12;
  return 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
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

__attribute__((noinline, aligned(64)))
stream_parsing_unescape_result stream_parsing_unescape_blocks(
    const uint8_t *src, ptrdiff_t n, uint8_t *dst, ptrdiff_t room,
    stream_parsing_u8x16 utf8_previous_high, stream_parsing_u8x16 utf8_previous_low,
    stream_parsing_u8x16 utf8_current_high) {
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
        ptrdiff_t taken;
        uint32_t scalar = stream_parsing_unescape_unicode(s + p, &taken);
        if (taken == 0) {
          stop_at = p;
          break;
        }
        // One to four bytes in one store; the recopy begins where they end.
        ptrdiff_t made;
        uint32_t word = stream_parsing_unescape_utf8(scalar, &made);
        __builtin_memcpy(e, &word, 4);
        stream_parsing_unescape_recopy(e + made, s + p + taken);
        k += taken - made;
        // A pair's second backslash is the next escape start, when it is in this block at all.
        if (taken == 12) pending &= pending - 1;
        if (p + taken > 64) {
          // The escape runs past the block (no stop can lie inside one), so nothing of the block
          // is left and the next begins behind the escape rather than at the next 64. This is
          // the one place the input cursor follows the data.
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
