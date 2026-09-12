#ifndef STREAM_PARSING_SHIMS_H
#define STREAM_PARSING_SHIMS_H

#include <stdint.h>

#define STREAM_PARSING_SIMD_SHIM static inline __attribute__((always_inline))

// MARK: - simdjson stage 1's two bit algorithms
//
// Shared by the window indexer (StreamParsingShims.c) and the skip scanner's block classifier
// below. They live in the header rather than in that translation unit because the skip
// classifier is inlined into Swift and needs them there.

// Escaped positions: bit i set iff byte i follows an odd-length backslash run. `prev_ends_odd`
// carries the state across blocks: in, whether the previous block ended inside an odd run; out,
// whether this one does.
//
// Deliberately scalar, and measured to stay that way (2026-09-11). The masks it needs
// (0x5555.../0xAAAA...) are already compile-time immediates; the irreducible step is
// `bs_bits + starts`, where the 64-bit adder's carry chain is a one-cycle prefix scan that
// broadcasts each run's start parity to the byte past its end. NEON has no segmented scan:
// a lane-wise version needs six log-steps of `ext`/`and`/`orr` over four vectors (~70 vector ops
// for these 13 scalar ones), and the classifier below is already vector-issue-bound (~130 vector
// ops per block against ~25 integer ops), so this runs for free on idle integer ports. Two NEON
// shapes that kept the carry in a `d` register measured +7..+31% slower per block because LLVM
// split the 64-bit lane chain across domains and paid six `fmov`s; a `bs_bits == 0` early-out
// was +0.7..+17.6% slower per block (a late-resolving branch off an `fmov`) and flat end to end.
// Deleting the step outright bounds any reformulation at ~15% of the kernel, which is invisible
// in the parse. Carryless multiply (`pmull`, see prefix_xor below) gives prefix XOR, an
// unsegmented scan, and cannot recover run-start parity. Harness and variants:
// ~/.cache/sspab/cand_findesc/ from that session.
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
// What `consumeSkipRun` (JSONParserSkip.swift) asks of 64 bytes of a subtree it is scanning to
// the matching close: where the brackets outside strings are, whether the block holds anything
// the wide path refuses to judge, and the two carries that define where the next block starts.
// Everything else the scalar loop does per byte -- whitespace, commas, colons, number and literal
// bytes -- costs nothing here: those bytes are simply not bracket bits.
//
// The whole kernel is in C for the reason the UTF-8 block kernel is: composed from Swift's SIMD
// operators around the movemask shim it comes out half scalarised, because a shift or compare
// whose result feeds the shim is lowered lane by lane. As one `static inline` returning a small
// struct it disappears into the Swift caller, which is what the assembly audit checks.
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

  // A byte is in a class iff (lo_table[b & 0xF] & hi_table[b >> 4]) has the class bit set.
  // Bits 0...6 spell "the scalar switch accepts this byte outside a string", one bit per high
  // nibble row, which makes every row an exact set of low nibbles:
  //   0x01 h=0 {09 0A 0D}         0x02 h=2 {20 22 2B 2C 2D 2E}
  //   0x04 h=3 {30...39 3A}       0x08 h=4 {45}
  //   0x10 h=5 {5B 5D}            0x20 h=6 {61...6F}
  //   0x40 h=7 {70...7B 7D}
  // so `\`, `/`, `|`, `_`, every uppercase letter but E, every control byte that is not
  // whitespace, and every byte >= 0x80 fall out as unaccepted. Bit 7 is the bracket class:
  // {B, D} x {5, 7} is exactly {'[', ']', '{', '}'}, a rectangle, which is the one shape this
  // table form carries for free. Getting the brackets from the same two lookups is why the kinds
  // are not masked out here -- the caller reads the four bracket bytes it actually lands on.
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
// The same 64 bytes, asked the question `consumeStructuralBlocks` (JSONParserBlocks.swift) has:
// where does the next *token* start, where are the string extents, and is there anything in here
// the scalar ladder would judge differently. Whitespace is never read on that path -- it is
// simply absent from `starts` -- and neither is the interior of a string, which the extent
// between two `quote` bits settles whole.
//
// `starts` is the whole trick, and it is one word:
//
//     starts = (~in_string & ~ws & ~quote) | (quote & in_string)
//
// Read it byte by byte. Outside a string, everything that is not whitespace and not a quote is a
// token start candidate (a bracket, a colon, a comma, or the first byte of a number or literal --
// and also the *interior* bytes of those tokens, which the walk clears from the mask when it
// advances its cursor past them, so they cost nothing). The opening quote of a string is the one
// byte that is `in_string` and a quote at once, so it is added back; the closing quote is a quote
// *outside* the string, so it drops out -- which is exactly right, since the extent between the
// two is consumed by whoever visited the opening one. `trailingZeroBitCount` on this mask is
// therefore "the next token start after the cursor", one instruction, whitespace skipped for free.
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
  // string, so this is what the caller passes as `containsNonASCII` for the strings it emits: the
  // validator then runs over each string's own extent and reports at the byte it finds, which is
  // where the scalar path reports it. The ~99% of blocks with no high byte skip the per-string
  // high-bit reduction entirely.
  uint32_t non_ascii;
  // Nonzero: the block holds no whitespace *outside* a string. It is the walk's gate signal, and
  // it is computed here rather than handed out as a mask because one `bic` + `cmp` in the shim is
  // cheaper than another 64-bit field in the returned struct. Whitespace inside a string is
  // deliberately excluded: `LLM message` and both Qwen payloads are full of spaces that live
  // inside string values, and those are bytes the walk skips with its cursor, not bytes the
  // classifier saves anything on.
  uint32_t no_outer_whitespace;
} stream_parsing_structural_classes;

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

  // A block lying edge to edge inside a string needs only its flags and carries: there is no
  // token start in it by construction. (With a zero carry in -- which is what the structural
  // walk always passes, since it hands a string it cannot close in one block to the scalar path
  // -- `in_string` can only be all ones if `quote` is nonzero, so this folds away there. It is
  // kept for the carrying caller.)
  if (quote == 0 && in_string == ~(uint64_t)0) {
    // Edge to edge inside a string: no byte of it is whitespace outside one, by construction.
    out.no_outer_whitespace = 1;
    out.starts = 0;
    out.needs_scalar = vminvq_u8(vminq_u8(vminq_u8(v0, v1), vminq_u8(v2, v3))) < 0x20;
    return out;
  }

  // The same two-table trick the skip classifier documents above, re-encoded. A bit is a
  // rectangle (set of high nibble rows) x (set of low nibbles), and the shipped encoding is
  // exactly full at eight, so two bits have to be *recovered* before whitespace can have one:
  //   * row 5's accepted set {5B,5D} is the bracket rectangle's row-5 half, and row 7's
  //     {70..7B,7D} is {70..7A} plus its row-7 half -- so row 5 needs no bit of its own once
  //     "accepted" is tested as `c != 0` rather than `(c & 0x7F) != 0`, which is legal because
  //     every bracket is an accepted byte. (It is also one instruction cheaper per vector:
  //     `vtstq(c, c)` lowers to `cmeq #0` + `bic`.)
  //   * rows 3 and 7 then share the residual low set {0..A} ({30..3A}, {70..7A}), so one
  //     rectangle {3,7} x {0..A} serves both.
  //
  //   bit 0 0x01  WS3    {0}   x {9,A,D}     09 0A 0D      (whitespace minus space)
  //   bit 1 0x02  ROW2   {2}   x {0,2,B,D,E} 20 22 2B 2D 2E
  //   bit 2 0x04  COMMA  {2}   x {C}         2C
  //   bit 3 0x08  COLON  {3}   x {A}         3A
  //   bit 4 0x10  N37    {3,7} x {0..A}      30..3A 70..7A
  //   bit 5 0x20  ROW6   {6}   x {1..F}      61..6F
  //   bit 6 0x40  E45    {4}   x {5}         45
  //   bit 7 0x80  BRACK  {5,7} x {B,D}       5B 5D 7B 7D
  //
  // `\`, `/`, `|`, `_`, every uppercase letter but E, every non-whitespace control byte and
  // every byte >= 0x80 is in no class at all, which is what `needs_scalar` reads. The walk reads
  // the four bracket bytes and the two operators it lands on out of the line the classifier just
  // touched, so neither `brackets` nor `op` is computed here -- two movemasks the skip
  // classifier's shape would have paid for.
  //
  // Space cannot get a ninth bit (the residual rows provably do not collapse into three
  // rectangles), so whitespace costs one lookup of its own. It is deliberately *not* hung off
  // `c`: indexed by the low nibble it is independent of the class chain and issues alongside it.
  // Measured on the corpus by the kernel harness (~/.cache/sspab/cand_blockkernel): this
  // spelling 9.43 ns/block on twitter against 9.87 for `(c & 0x01) | (v == 0x20)` and 10.53 for
  // deriving the operators with compares instead of table bits.
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
// The window indexer's portable path needs the parity too. The skip scanner's block path is arm64
// only and keeps the scalar loop everywhere else.
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
