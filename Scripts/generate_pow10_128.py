#!/usr/bin/env python3
"""Generate the normalized 128-bit powers used by Eisel-Lemire."""

from pathlib import Path


MIN_EXPONENT = -342
MAX_EXPONENT = 308
MASK_64 = (1 << 64) - 1
OUTPUT = (
    Path(__file__).resolve().parents[1]
    / "Sources"
    / "StreamParsingShims"
    / "Pow10_128.c"
)


def normalized_power(exponent: int) -> int:
    """Return floor(10^exponent * 2^(127 - floor(log2(10^exponent))))."""
    if exponent >= 0:
        numerator, denominator = 10**exponent, 1
    else:
        numerator, denominator = 1, 10 ** (-exponent)

    binary_exponent = numerator.bit_length() - denominator.bit_length()
    if binary_exponent >= 0:
        if numerator < denominator << binary_exponent:
            binary_exponent -= 1
    elif numerator << -binary_exponent < denominator:
        binary_exponent -= 1

    shift = 127 - binary_exponent
    if shift >= 0:
        return (numerator << shift) // denominator
    return numerator // (denominator << -shift)


def main() -> None:
    count = MAX_EXPONENT - MIN_EXPONENT + 1
    lines = [
        "// Generated: 128-bit truncated powers of ten for the Eisel-Lemire float parser.",
        f"// Extent: 10^{MIN_EXPONENT} ... 10^{MAX_EXPONENT} "
        f"({count} entries, {count * 16:,} bytes).",
        "// Each entry is the top 128 bits of 10^q, truncated, normalised so bit 127 is set, stored",
        "// high word first. Regenerate with `Scripts/generate_pow10_128.py`; do not edit by hand.",
        "//",
        "// Storage lives here rather than in Swift because a Swift `[UInt64]` global is a heap",
        "// allocation behind a lazy `swift_once` reached through an addressor, with a bounds check per",
        "// access -- the same reason `streamSimpleEscapeTable` is a `StaticString`. A C array is",
        "// `.rodata`, costs no startup work, and stays inside the Embedded subset.",
        '#include "StreamParsingShims.h"',
        "",
        "const uint64_t stream_parsing_pow10_128_storage[] = {",
    ]
    for exponent in range(MIN_EXPONENT, MAX_EXPONENT + 1):
        value = normalized_power(exponent)
        high, low = value >> 64, value & MASK_64
        lines.append(
            f"  UINT64_C(0x{high:016x}), UINT64_C(0x{low:016x}),  // 10^{exponent}"
        )
    lines.append("};")
    lines.append("")
    generated = "\n".join(lines)
    if not OUTPUT.exists() or OUTPUT.read_text() != generated:
        OUTPUT.write_text(generated)


if __name__ == "__main__":
    main()
