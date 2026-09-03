// Generated: the exact `Double` values 10^0 ... 10^22. These are the powers of ten whose odd
// factor, 5^q, fits Double's 53-bit significand; 10^23 and above are rounded values and cannot be
// used as an exact scale without risking a one-ULP error in the final result.
//
// Storage lives here for the same reason `Pow10_128.c` does: a Swift `[Double]` global is a heap
// allocation behind a lazy `swift_once` reached through an addressor, with a bounds check per
// access. A C array is `.rodata`, costs no startup work, and stays inside the Embedded subset.
// The call site only asks for `abs(exponent)`, so a positive table also makes the bounds check the
// exactness check and indexes directly without a bias.
#include "StreamParsingShims.h"

const double stream_parsing_pow10_double_storage[] = {
  0x1.0000000000000p+0,   // 1e0
  0x1.4000000000000p+3,   // 1e1
  0x1.9000000000000p+6,   // 1e2
  0x1.f400000000000p+9,   // 1e3
  0x1.3880000000000p+13,  // 1e4
  0x1.86a0000000000p+16,  // 1e5
  0x1.e848000000000p+19,  // 1e6
  0x1.312d000000000p+23,  // 1e7
  0x1.7d78400000000p+26,  // 1e8
  0x1.dcd6500000000p+29,  // 1e9
  0x1.2a05f20000000p+33,  // 1e10
  0x1.74876e8000000p+36,  // 1e11
  0x1.d1a94a2000000p+39,  // 1e12
  0x1.2309ce5400000p+43,  // 1e13
  0x1.6bcc41e900000p+46,  // 1e14
  0x1.c6bf526340000p+49,  // 1e15
  0x1.1c37937e08000p+53,  // 1e16
  0x1.6345785d8a000p+56,  // 1e17
  0x1.bc16d674ec800p+59,  // 1e18
  0x1.158e460913d00p+63,  // 1e19
  0x1.5af1d78b58c40p+66,  // 1e20
  0x1.b1ae4d6e2ef50p+69,  // 1e21
  0x1.0f0cf064dd592p+73,  // 1e22
};
