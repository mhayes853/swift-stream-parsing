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
