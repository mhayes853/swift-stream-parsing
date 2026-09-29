import StreamParsingShims

#if arch(x86_64)
// x86_64 CPU features, probed once. Both gate AVX2 kernels in the shims.

// A lazily initialised global: every read is a once-token compare, then a load (x86_64
// disassembly). Read it only behind `@inline(never)`, as `streamValidateUTF8` and
// `streamStringRunWide` do -- in an inlined scan loop the accessor cost CITM -9.9%
// (NEW_ARCHITECTURE.md).
@usableFromInline
let streamHasAVX2: Bool = stream_parsing_has_avx2() != 0

// Whether the 64-byte block classifiers (AVX2.c) may be called: AVX2 plus PCLMULQDQ and POPCNT.
// Read once per parser, into `JSONParser.blockKernelsAvailable`, and never on a parse path.
@usableFromInline
let streamHasAVX2BlockKernels: Bool = stream_parsing_has_avx2_block_kernels() != 0
#endif
