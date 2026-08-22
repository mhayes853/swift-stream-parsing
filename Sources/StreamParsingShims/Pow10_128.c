// Generated: 128-bit truncated powers of ten for the Eisel-Lemire float parser.
// Extent: 10^-22 ... 10^22 (45 entries, 720 bytes).
// Each entry is the top 128 bits of 10^q, truncated, normalised so bit 127 is set, stored
// high word first. Regenerate rather than edit: see NEW_ARCHITECTURE.md.
//
// Storage lives here rather than in Swift because a Swift `[UInt64]` global is a heap
// allocation behind a lazy `swift_once` reached through an addressor, with a bounds check per
// access -- the same reason `streamSimpleEscapeTable` is a `StaticString`. A C array is
// `.rodata`, costs no startup work, and stays inside the Embedded subset.
#include "StreamParsingShims.h"

static const uint64_t stream_parsing_pow10_128_storage[] = {
  UINT64_C(0xf1c90080baf72cb1), UINT64_C(0x5324c68b12dd6338),  // 10^-22
  UINT64_C(0x971da05074da7bee), UINT64_C(0xd3f6fc16ebca5e03),  // 10^-21
  UINT64_C(0xbce5086492111aea), UINT64_C(0x88f4bb1ca6bcf584),  // 10^-20
  UINT64_C(0xec1e4a7db69561a5), UINT64_C(0x2b31e9e3d06c32e5),  // 10^-19
  UINT64_C(0x9392ee8e921d5d07), UINT64_C(0x3aff322e62439fcf),  // 10^-18
  UINT64_C(0xb877aa3236a4b449), UINT64_C(0x09befeb9fad487c2),  // 10^-17
  UINT64_C(0xe69594bec44de15b), UINT64_C(0x4c2ebe687989a9b3),  // 10^-16
  UINT64_C(0x901d7cf73ab0acd9), UINT64_C(0x0f9d37014bf60a10),  // 10^-15
  UINT64_C(0xb424dc35095cd80f), UINT64_C(0x538484c19ef38c94),  // 10^-14
  UINT64_C(0xe12e13424bb40e13), UINT64_C(0x2865a5f206b06fb9),  // 10^-13
  UINT64_C(0x8cbccc096f5088cb), UINT64_C(0xf93f87b7442e45d3),  // 10^-12
  UINT64_C(0xafebff0bcb24aafe), UINT64_C(0xf78f69a51539d748),  // 10^-11
  UINT64_C(0xdbe6fecebdedd5be), UINT64_C(0xb573440e5a884d1b),  // 10^-10
  UINT64_C(0x89705f4136b4a597), UINT64_C(0x31680a88f8953030),  // 10^-9
  UINT64_C(0xabcc77118461cefc), UINT64_C(0xfdc20d2b36ba7c3d),  // 10^-8
  UINT64_C(0xd6bf94d5e57a42bc), UINT64_C(0x3d32907604691b4c),  // 10^-7
  UINT64_C(0x8637bd05af6c69b5), UINT64_C(0xa63f9a49c2c1b10f),  // 10^-6
  UINT64_C(0xa7c5ac471b478423), UINT64_C(0x0fcf80dc33721d53),  // 10^-5
  UINT64_C(0xd1b71758e219652b), UINT64_C(0xd3c36113404ea4a8),  // 10^-4
  UINT64_C(0x83126e978d4fdf3b), UINT64_C(0x645a1cac083126e9),  // 10^-3
  UINT64_C(0xa3d70a3d70a3d70a), UINT64_C(0x3d70a3d70a3d70a3),  // 10^-2
  UINT64_C(0xcccccccccccccccc), UINT64_C(0xcccccccccccccccc),  // 10^-1
  UINT64_C(0x8000000000000000), UINT64_C(0x0000000000000000),  // 10^0
  UINT64_C(0xa000000000000000), UINT64_C(0x0000000000000000),  // 10^1
  UINT64_C(0xc800000000000000), UINT64_C(0x0000000000000000),  // 10^2
  UINT64_C(0xfa00000000000000), UINT64_C(0x0000000000000000),  // 10^3
  UINT64_C(0x9c40000000000000), UINT64_C(0x0000000000000000),  // 10^4
  UINT64_C(0xc350000000000000), UINT64_C(0x0000000000000000),  // 10^5
  UINT64_C(0xf424000000000000), UINT64_C(0x0000000000000000),  // 10^6
  UINT64_C(0x9896800000000000), UINT64_C(0x0000000000000000),  // 10^7
  UINT64_C(0xbebc200000000000), UINT64_C(0x0000000000000000),  // 10^8
  UINT64_C(0xee6b280000000000), UINT64_C(0x0000000000000000),  // 10^9
  UINT64_C(0x9502f90000000000), UINT64_C(0x0000000000000000),  // 10^10
  UINT64_C(0xba43b74000000000), UINT64_C(0x0000000000000000),  // 10^11
  UINT64_C(0xe8d4a51000000000), UINT64_C(0x0000000000000000),  // 10^12
  UINT64_C(0x9184e72a00000000), UINT64_C(0x0000000000000000),  // 10^13
  UINT64_C(0xb5e620f480000000), UINT64_C(0x0000000000000000),  // 10^14
  UINT64_C(0xe35fa931a0000000), UINT64_C(0x0000000000000000),  // 10^15
  UINT64_C(0x8e1bc9bf04000000), UINT64_C(0x0000000000000000),  // 10^16
  UINT64_C(0xb1a2bc2ec5000000), UINT64_C(0x0000000000000000),  // 10^17
  UINT64_C(0xde0b6b3a76400000), UINT64_C(0x0000000000000000),  // 10^18
  UINT64_C(0x8ac7230489e80000), UINT64_C(0x0000000000000000),  // 10^19
  UINT64_C(0xad78ebc5ac620000), UINT64_C(0x0000000000000000),  // 10^20
  UINT64_C(0xd8d726b7177a8000), UINT64_C(0x0000000000000000),  // 10^21
  UINT64_C(0x878678326eac9000), UINT64_C(0x0000000000000000),  // 10^22
};

const uint64_t *const stream_parsing_pow10_128 = stream_parsing_pow10_128_storage;
const int32_t stream_parsing_pow10_128_min_exponent = -22;
const int32_t stream_parsing_pow10_128_max_exponent = 22;
