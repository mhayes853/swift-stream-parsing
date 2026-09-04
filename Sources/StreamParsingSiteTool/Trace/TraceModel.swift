import Foundation

// The shape of `Web/generated/traces.json`.
//
// Every trace is produced by *running the shipped kernels*. Where a step's intermediate values are
// not observable from outside a function -- the per-block masks inside `streamStringRun`, the SWAR
// words inside `streamShortInteger` -- the recorder mirrors the body using the same `package`
// primitives and then asserts the mirrored answer against the real function's. `verified` carries
// that assertion into the bundle, so a mirror that drifts from the kernel shows up in the UI
// rather than quietly animating a lie.

struct TraceBundle: Encodable {
  var generatedAt: String
  var arch: String
  var stringRun: StringRunTrace
  var whitespace: WhitespaceTrace
  var containers: ContainerTrace
  var number: NumberTrace
  /// `streamWhitespaceMissMask`: one `tbl` and a compare where the portable path ORs four.
  var whitespaceTable: TableTrace
  /// `streamNumberRunEndShimmed`: two nibble lookups and `vtstq_u8`, not six compares.
  var numberTable: TableTrace
  /// The Keiser-Lemire validator: three lookups ANDed, then the structural fact XORed in.
  var utf8: UTF8Trace
  /// `streamSimpleEscapeTable`: a direct 128-byte map whose zero doubles as "not an escape".
  var escapes: EscapeTrace
}

/// A kernel that answers a per-lane membership question by indexing a table with part of the byte.
///
/// The same shape covers the whitespace scan (one table, indexed by the low nibble) and the number
/// scan (two, indexed by each nibble, ANDed). Both are recorded by running the shipped kernel over
/// a real block; the table contents are recovered from the kernel itself rather than copied, so a
/// table edited in the parser shows up here without anyone remembering to mirror it.
struct TableTrace: Encodable {
  var kernel: String
  var summary: String
  /// The portable spelling this replaces, for the "why a table" caption.
  var replaces: String
  var sample: String
  /// The sample's bytes. The block the lanes cover is the first sixteen of these; the rest is
  /// what the caller's buffer holds either side of it, which is what the animation's tape draws.
  var bytes: [UInt8]
  var tables: [Table]
  var lanes: [Lane]
  /// How the per-table values are combined into the answer: `equal` or `and`.
  var combine: String
  var verified: Bool

  struct Table: Encodable {
    var name: String
    /// The expression that produces the index, e.g. `byte & 0x0F`.
    var indexedBy: String
    var entries: [UInt8]
    /// `byte` renders entries as hex bytes; `bits` renders them as a bit field.
    var format: String
    /// Bit meanings, low bit first, when `format` is `bits`.
    var bitLabels: [String]
    var note: String
  }

  struct Lane: Encodable {
    var lane: Int
    var byte: UInt8
    var indices: [Int]
    var values: [UInt8]
    /// Whether this lane is in the class the kernel is testing for.
    var hit: Bool
  }
}

/// One 16-byte block through the UTF-8 validator, with all three lookups and the structural fact.
struct UTF8Trace: Encodable {
  var sample: String
  var bytes: [UInt8]
  var tables: [TableTrace.Table]
  var lanes: [Lane]
  var valid: Bool
  var verified: Bool

  struct Lane: Encodable {
    var lane: Int
    var byte: UInt8
    /// The three bytes before this lane, which arrive as lane-shifted views of the block.
    var previous1: UInt8
    var previous2: UInt8
    var previous3: UInt8
    var indices: [Int]
    var values: [UInt8]
    /// The three lookups ANDed together.
    var special: UInt8
    /// `(saturating(prev2 - 0x60) | saturating(prev3 - 0x70)) & 0x80`: a continuation is required
    /// after a three or four byte lead, which no pair of adjacent bytes can express.
    var mustContinue: UInt8
    var error: UInt8
    /// Names of the error bits set, so a lane is never explained by colour alone.
    var classes: [String]
    /// What this byte is: `ascii`, `continuation`, `lead2`, `lead3`, `lead4` or `invalid`.
    var role: String
  }
}

/// The simple-escape table: a byte in, a byte out, zero meaning "not a simple escape".
struct EscapeTrace: Encodable {
  var entries: [Entry]
  /// The whole 128-byte map, recovered by asking the shipped decoder about every index rather than
  /// by copying the `StaticString`. The animation draws it, so it has to be the real thing: eight
  /// non-zero cells out of 128, and every other index answering with the sentinel.
  var map: [UInt8]
  var verified: Bool

  struct Entry: Encodable {
    var byte: UInt8
    var source: String
    var decoded: UInt8?
    var meaning: String
  }
}

struct StringRunTrace: Encodable {
  var sample: String
  var bytes: [UInt8]
  var blocks: [Block]
  var tail: [TailStep]
  var end: Int
  var containsNonASCII: Bool
  var verified: Bool

  struct Block: Encodable {
    var offset: Int
    var bytes: [UInt8]
    var isQuote: [Bool]
    var isBackslash: [Bool]
    var isControl: [Bool]
    var hit: [Bool]
    var anyHit: Bool
    /// 16 when no lane hits, which is how the kernel's bound check doubles as the terminator test.
    var hitLane: Int
    var scannedAfter: [UInt8]
    var nonASCIIAfter: Bool
  }

  struct TailStep: Encodable {
    var offset: Int
    var byte: UInt8
    var terminates: Bool
  }
}

struct WhitespaceTrace: Encodable {
  var sample: String
  var bytes: [UInt8]
  var calls: [Call]

  struct Call: Encodable {
    var from: Int
    var to: Int
    var firstByte: UInt8
    /// The single compare that settles the empty case: every whitespace byte is <= 0x20 and every
    /// byte that may legally follow one is > 0x20.
    var earlyOut: Bool
    /// `early`, `scalar` (fewer than 16 bytes left) or `vector`.
    var path: String
    var end: Int
    var runLength: Int
    var lanes: [Lane]
  }

  struct Lane: Encodable {
    var offset: Int
    var byte: UInt8
    var isWhitespace: Bool
  }
}

struct ContainerTrace: Encodable {
  var sample: String
  var steps: [Step]
  var maximumDepth: Int
  /// Every token offset derived by the walk matched the offset of the span the parser passed, for
  /// every token that came with one.
  var offsetsVerified: Bool

  /// One token from a real parse. `depth` and `containers` are reconstructed from the container
  /// events by the documented rule -- 1 = object, 0 = array, shifted in at `depth` -- because the
  /// parser's own fields are `@usableFromInline` and therefore internal to `StreamParsingCore`.
  /// The event sequence driving them is the parser's actual output.
  struct Step: Encodable {
    var index: Int
    var event: String
    var text: String?
    /// The token's byte range in `sample`. Taken from the span the parser hands the sink where
    /// there is one, and otherwise from a whitespace-and-separator skip using the shipped
    /// scanner; `offsetsVerified` records that the two agreed everywhere both existed.
    var offset: Int
    var length: Int
    var depthBefore: Int
    var depthAfter: Int
    /// 64 characters, index 0 = depth 1, `1` for an object and `0` for an array; `.` past the top.
    var containersAfter: String
    var containersBits: [Int]
  }
}

struct NumberTrace: Encodable {
  var cases: [Case]

  struct Case: Encodable {
    var text: String
    /// The hostile prefix the kernel reads behind the token. The tests pad with junk rather than
    /// spaces because the mask-before-bias defect only shows up against bytes below `'0'`.
    var prefix: String
    var runEnd: Int
    var digitCount: Int
    var acceptedByShortInteger: Bool
    var value: UInt64?
    var steps: [SWARStep]
    var verified: Bool
  }

  struct SWARStep: Encodable {
    var label: String
    var detail: String
    /// Big-endian hex of the 64-bit word at this stage, so the UI can lay it out as eight bytes.
    var hex: String
    var bytes: [UInt8]
  }
}
