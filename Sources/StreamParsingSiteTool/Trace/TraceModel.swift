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

  /// One token from a real parse. `depth` and `containers` are reconstructed from the container
  /// events by the documented rule -- 1 = object, 0 = array, shifted in at `depth` -- because the
  /// parser's own fields are `@usableFromInline` and therefore internal to `StreamParsingCore`.
  /// The event sequence driving them is the parser's actual output.
  struct Step: Encodable {
    var index: Int
    var event: String
    var text: String?
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
