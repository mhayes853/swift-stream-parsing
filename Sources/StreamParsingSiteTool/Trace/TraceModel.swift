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
  /// The sink boundary onwards. See the note above `SinkCallTrace`.
  var sinkCalls: SinkCallTrace
  var dispositions: DispositionTrace
  var skipRun: SkipRunTrace
  var fieldMatch: FieldMatchTrace
  var frames: FrameTrace
  var streamString: StreamStringTrace
  var collections: CollectionTrace
  var views: ViewTrace
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

// MARK: - The sink boundary and everything past it
//
// From `sink-protocol` on, the subject is not a vector kernel but a *protocol boundary*: calls
// arriving in an order, a frame stack rising and falling, storage growing a block at a time. None
// of it is mirrored. `@testable import StreamParsingCore` reaches the same internals the tests
// read, so these recorders hand a real parse a real sink and read the real fields back out --
// `PartialSink.frames`, `StreamString.blocks`, `StreamFieldTable.entries`. Where a number here
// could have been written down instead (the inline capacity, the index threshold, the block
// schedule), it is read off the shipped type, so a constant edited in the parser moves the
// animation with it.

/// The parser's output surface, recorded by handing a real parse a sink that keeps every call.
///
/// Nothing is reconstructed: these are the methods the parser called, in the order it called
/// them, each with the span it passed. A span that does not point into the parsed buffer -- a
/// string the parser had to unescape into scratch -- reports no offset rather than a wrong one,
/// which is the boundary's own rule showing through.
struct SinkCallTrace: Encodable {
  var sample: String
  var bytes: [UInt8]
  var calls: [Call]
  /// Every span that pointed into the input covered exactly the bytes its text claims.
  var verified: Bool

  struct Call: Encodable {
    var index: Int
    /// The method as the protocol declares it.
    var method: String
    var signature: String
    var text: String?
    /// Where the span sits in the parsed buffer, or nil when the call carries no span or carries
    /// one into scratch storage.
    var offset: Int?
    var length: Int?
    var takesSpan: Bool
    var depthAfter: Int
    /// `structure`, `key`, `whole`, `chunked`.
    var group: String
  }
}

/// The same document delivered twice: once to a sink that streams every subtree, once to a sink
/// that answers `.skip` at one container.
///
/// Both runs are real parses of the same bytes. `delivered` says, for each call the streaming run
/// received, whether the skipping run received it too -- which is how the animation can show the
/// interior simply not arriving while the matching close still does.
struct DispositionTrace: Encodable {
  var sample: String
  var bytes: [UInt8]
  /// The key whose container the skipping sink refuses.
  var skippedKey: String
  var streamed: [SinkCallTrace.Call]
  var skipped: [SinkCallTrace.Call]
  /// Parallel to `streamed`.
  var delivered: [Bool]
  /// The subtree's byte range, open bracket through close.
  var skipFrom: Int
  var skipTo: Int
  /// The skipping run is a subsequence of the streaming one and the matching close still arrived.
  var verified: Bool
}

/// The skip scanner's walk over one subtree.
///
/// `consumeSkipRun`'s intermediates are not observable from outside it, so the walk here is
/// mirrored with the same `package` scanners the shipped loop calls -- `streamWhitespaceEndByte`,
/// `streamStringRun`, `streamNumberRunEnd` -- and then the shipped function is run over the same
/// bytes from the same state. `verified` is the two agreeing on where the cursor came to rest.
struct SkipRunTrace: Encodable {
  var sample: String
  var bytes: [UInt8]
  var from: Int
  var startDepth: Int
  var steps: [Step]
  var end: Int
  /// `consumeSkipRun`'s own answer over the same bytes.
  var shippedEnd: Int
  var verified: Bool

  struct Step: Encodable {
    var offset: Int
    var byte: UInt8
    /// `open`, `close`, `string`, `separator`, `number`, `literal`, `done`.
    var action: String
    /// The scanner that resolved this step, where one did.
    var scanner: String?
    /// Where the cursor lands after this step.
    var next: Int
    var depthBefore: Int
    var depthAfter: Int
    /// One character per live depth, `1` for an object and `0` for an array.
    var containers: String
    /// Whether this step delivered the matching close to the sink.
    var emits: Bool
  }
}

/// Keys resolved against real field tables.
///
/// The tables are `StreamFieldTable`s built by real `StreamSchema`s, and the entries, the slot
/// table and the threshold between the two strategies are read off them. Every probe's answer is
/// checked against the shipped matcher -- `streamMatchField` for a scanned table,
/// `streamMatchFieldIndexed` for an indexed one -- run over the same entries.
struct FieldMatchTrace: Encodable {
  var tables: [Table]
  var verified: Bool

  struct Table: Encodable {
    var name: String
    /// `scan` at or below the threshold, `indexed` above it.
    var strategy: String
    /// `StreamFieldTable.indexThreshold`, read off the type.
    var threshold: Int
    var entries: [Entry]
    /// The open-addressed slot table, -1 where empty. Empty for a scanned table.
    var slots: [Int32]
    var probes: [Probe]
  }

  struct Entry: Encodable {
    var index: Int
    var key: String
    /// The key's first eight bytes as one little-endian word, zero padded: what the match compares.
    var keyWord: String
    /// Those eight bytes in load order, so the animation can lay the word out as bytes.
    var wordBytes: [UInt8]
    var keyLength: Int
    var kind: String
    var offset: Int
    /// `streamFieldHash(word:length:)` of this entry, and the bucket it landed in.
    var hash: String
    var bucket: Int
  }

  struct Probe: Encodable {
    var key: String
    var bytes: [UInt8]
    var word: String
    var wordBytes: [UInt8]
    var length: Int
    var hash: String
    /// `streamHashBytes` over the whole key: the byte-wise hash a dictionary key takes instead.
    var bytesHash: String
    var steps: [Step]
    /// What the shipped matcher answered.
    var shipped: Int32
    var mirrored: Int32
    var verified: Bool
  }

  struct Step: Encodable {
    /// The slot table bucket for an indexed probe, -1 for a scan.
    var bucket: Int
    var entry: Int
    var wordEqual: Bool
    var lengthEqual: Bool
    /// Keys longer than a word verify their tail against the packed key bytes on a first-word hit.
    var tailChecked: Bool
    var tailEqual: Bool
    var hit: Bool
  }
}

/// The frame stack of a real `PartialSink`, read off the sink after every call the parser makes.
///
/// The recording sink forwards each method to a `PartialSink` and then reads `frames` and
/// `frameCount` straight out of it, so the stack drawn is the stack the sink kept. `result` is the
/// value the parse produced, which is what makes the whole thing checkable.
struct FrameTrace: Encodable {
  var sample: String
  var bytes: [UInt8]
  var rootSize: Int
  var schemas: [Schema]
  var members: [Member]
  var steps: [Step]
  /// The destination holds what the document said it should.
  var verified: Bool
  var result: String

  /// One schema object. Frames borrow these `unowned(unsafe)`; `id` is object identity, so two
  /// frames carrying the same id are two borrows of one object.
  struct Schema: Encodable {
    var id: Int
    var name: String
    var shape: String
    /// `match`, `dictionary`, `ignore` or `table`: the one byte a key is routed through.
    var keyRouting: String
    var fieldCount: Int
  }

  struct Member: Encodable {
    var name: String
    var offset: Int
    var size: Int
    var kind: String
    /// Which schema declares it.
    var schema: Int
  }

  struct Step: Encodable {
    var index: Int
    var call: String
    var text: String?
    var offset: Int?
    var length: Int?
    var frames: [Frame]
    /// The member this call wrote, where it wrote one.
    var wrote: String?
  }

  struct Frame: Encodable {
    var schema: Int
    /// Byte offset of the frame's storage inside the root value, or nil when it points elsewhere.
    var storageOffset: Int?
    var pendingField: Int32
    /// The member `pendingField` names, when the frame's schema has a table.
    var field: String?
  }
}

/// A real `StreamString` fed real chunks, with its physical storage read back after each one.
///
/// `inlineCapacity`, the block schedule and the cap are read off the shipped type rather than
/// written down here, and `locate` calls the shipped `sealedPosition(of:)`.
struct StreamStringTrace: Encodable {
  var inlineCapacity: Int
  var firstBlockCapacity: Int
  var maximumBlockCapacity: Int
  var steps: [Step]
  var locate: [Locate]
  /// Every byte came back out of the shipped reader in the order it went in.
  var verified: Bool

  struct Step: Encodable {
    var chunk: String
    var chunkBytes: Int
    var inlineCount: Int
    /// The sealed blocks' capacities, in order.
    var blocks: [Int]
    var tailCount: Int
    var tailCapacity: Int
    var utf8Count: Int
    /// `inline`, `promote`, `append` or `seal`.
    var event: String
  }

  /// A byte's address, from the shipped closed-form locate.
  struct Locate: Encodable {
    var position: Int
    var block: Int
    var offset: Int
    var byte: UInt8
    /// `inline`, `sealed` or `tail`.
    var region: String
  }
}

/// Real `StreamArray` and `StreamDictionary` values, filled the way the parser fills them.
struct CollectionTrace: Encodable {
  var array: ArrayTrace
  var dictionary: DictionaryTrace
  var verified: Bool

  struct ArrayTrace: Encodable {
    var blockCapacity: Int
    var initialTailCapacity: Int
    var steps: [ArrayStep]
  }

  struct ArrayStep: Encodable {
    var index: Int
    var value: Int
    var blocks: [Int]
    var tailCount: Int
    var tailCapacity: Int
    /// The open element, which lives outside the storage until it commits.
    var pending: Int?
    var count: Int
    /// `open`, `commit` or `seal`.
    var event: String
  }

  struct DictionaryTrace: Encodable {
    /// `StreamDictionary.indexThreshold`, read off the type.
    var indexThreshold: Int
    var steps: [DictStep]
    var slots: [Int32]
    var lookups: [Lookup]
  }

  struct DictStep: Encodable {
    var key: String
    var hash: String
    var entryCount: Int
    var storedValueCount: Int
    var tableCount: Int
    var pendingSlot: Int32
    /// `open`, `commit` or `index`.
    var event: String
  }

  struct Lookup: Encodable {
    var key: String
    var hash: String
    /// The probe chain through the slot table, or the scanned entry positions when there is none.
    var buckets: [Int]
    var slot: Int32
    var found: Bool
  }
}

/// Reading a value that is still being parsed: one member out of it, or the whole thing.
///
/// The offsets are the schema's own field offsets and the sizes are `MemoryLayout`'s, both taken
/// from the same parse the `frames` trace records.
struct ViewTrace: Encodable {
  var typeName: String
  var size: Int
  var stride: Int
  var members: [Member]
  /// The view and the snapshot report the same values.
  var verified: Bool

  struct Member: Encodable {
    var name: String
    var offset: Int
    var size: Int
    var kind: String
    var value: String
    /// Whether reading this member has to copy storage the value only points at.
    var indirect: Bool
  }
}
