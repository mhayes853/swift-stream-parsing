import Foundation

func traceHex(_ value: UInt64, width: Int = 0) -> String {
  let digits = String(value, radix: 16, uppercase: true)
  return "0x" + String(repeating: "0", count: max(0, width - digits.count)) + digits
}

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
  var structuralBlocks: StructuralBlockTrace
  var number: NumberTrace
  var whitespaceTable: TableTrace
  var numberTable: TableTrace
  var utf8: UTF8Trace
  var escapes: EscapeTrace
  var sinkCalls: SinkCallTrace
  var dispositions: DispositionTrace
  var skipRun: SkipRunTrace
  var skipBlocks: SkipBlockTrace
  var fieldMatch: FieldMatchTrace
  var frames: FrameTrace
  var streamString: StreamStringTrace
  var collections: CollectionTrace
  var views: ViewTrace
}

/// The structural run's moving 64-byte grid, recorded from the shipped C classifier and checked
/// against the real block walk.
///
/// A case is a complete parser input. Every block carries the classifier's three masks and the
/// exact token-start visits produced by clearing `starts`; the real `consumeStructuralBlocks`
/// call then has to return at the same byte (including the complemented give-up result), and a
/// full parse with the block walk enabled has to emit the same event stream as the scalar copy.
struct StructuralBlockTrace: Encodable {
  var cases: [Case]
  var verified: Bool

  struct Case: Encodable {
    var name: String
    var purpose: String
    var sample: String
    var bytes: [UInt8]
    var blocks: [Block]
    var end: Int
    var shippedEnd: Int
    var gaveUp: Bool
    var shippedGaveUp: Bool
    var eventsMatch: Bool
    var verified: Bool
  }

  struct Block: Encodable {
    var index: Int
    var offset: Int
    var bytes: [UInt8]
    var starts: [Bool]
    var quotes: [Bool]
    var backslashes: [Bool]
    var startCount: Int
    var noOuterWhitespace: Bool
    var nonASCII: Bool
    var needsScalar: Bool
    var strikeBefore: Int
    var strikeAfter: Int
    var givesUp: Bool
    var visits: [Visit]
  }

  struct Visit: Encodable {
    var offset: Int
    var byte: UInt8
    var kind: String
    var next: Int
    var maskAfter: [Bool]
    var reanchors: Bool
  }
}

/// The skipped-subtree block walk: only bracket bits survive the classifier, with quote parity
/// and odd-backslash state carried to the next block.
struct SkipBlockTrace: Encodable {
  var sample: String
  var bytes: [UInt8]
  var from: Int
  var startDepth: Int
  var blocks: [Block]
  var end: Int
  var shippedEnd: Int
  var state: String
  var shippedState: String
  var verified: Bool

  struct Block: Encodable {
    var index: Int
    var offset: Int
    var bytes: [UInt8]
    var brackets: [Bool]
    var needsScalar: Bool
    var nonASCII: Bool
    var inStringBefore: Bool
    var inStringAfter: Bool
    var endsOddBefore: Bool
    var endsOddAfter: Bool
    var depthBefore: Int
    var depthAfter: Int
    var visits: [Visit]
  }

  struct Visit: Encodable {
    var offset: Int
    var byte: UInt8
    var depthBefore: Int
    var depthAfter: Int
    var isObject: Bool
    var opens: Bool
    var emits: Bool
    var maskAfter: [Bool]
  }
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
  var replaces: String
  var sample: String
  var bytes: [UInt8]
  var tables: [Table]
  var lanes: [Lane]
  var combine: String
  var verified: Bool

  struct Table: Encodable {
    var name: String
    var indexedBy: String
    var entries: [UInt8]
    var format: String
    var bitLabels: [String]
    var note: String
  }

  struct Lane: Encodable {
    var lane: Int
    var byte: UInt8
    var indices: [Int]
    var values: [UInt8]
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
    var previous1: UInt8
    var previous2: UInt8
    var previous3: UInt8
    var indices: [Int]
    var values: [UInt8]
    var special: UInt8
    /// `(saturating(prev2 - 0x60) | saturating(prev3 - 0x70)) & 0x80`: a continuation is required
    /// after a three or four byte lead, which no pair of adjacent bytes can express.
    var mustContinue: UInt8
    var error: UInt8
    var classes: [String]
    var role: String
  }
}

/// The simple-escape table: a byte in, a byte out, zero meaning "not a simple escape".
struct EscapeTrace: Encodable {
  var entries: [Entry]
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
    var earlyOut: Bool
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
  var offsetsVerified: Bool

  /// One token from a real parse. `depth` and `containers` are reconstructed from the container
  /// events by the documented rule -- 1 = object, 0 = array, shifted in at `depth` -- because the
  /// parser's own fields are `@usableFromInline` and therefore internal to `StreamParsingCore`.
  /// The event sequence driving them is the parser's actual output.
  struct Step: Encodable {
    var index: Int
    var event: String
    var text: String?
    var offset: Int
    var length: Int
    var depthBefore: Int
    var depthAfter: Int
    var containersAfter: String
    var containersBits: [Int]
  }
}

struct NumberTrace: Encodable {
  var cases: [Case]

  struct Case: Encodable {
    var text: String
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
  var verified: Bool

  struct Call: Encodable {
    var index: Int
    var method: String
    var signature: String
    var text: String?
    var offset: Int?
    var length: Int?
    var takesSpan: Bool
    var depthAfter: Int
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
  var skippedKey: String
  var streamed: [SinkCallTrace.Call]
  var skipped: [SinkCallTrace.Call]
  var delivered: [Bool]
  var skipFrom: Int
  var skipTo: Int
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
  var shippedEnd: Int
  var verified: Bool

  struct Step: Encodable {
    var offset: Int
    var byte: UInt8
    var action: String
    var scanner: String?
    var next: Int
    var depthBefore: Int
    var depthAfter: Int
    var containers: String
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
    var strategy: String
    var threshold: Int
    var entries: [Entry]
    var slots: [Int32]
    var probes: [Probe]
  }

  struct Entry: Encodable {
    var index: Int
    var key: String
    var keyWord: String
    var wordBytes: [UInt8]
    var keyLength: Int
    var kind: String
    var offset: Int
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
    var bytesHash: String
    var steps: [Step]
    var shipped: Int32
    var mirrored: Int32
    var verified: Bool
  }

  struct Step: Encodable {
    var bucket: Int
    var entry: Int
    var wordEqual: Bool
    var lengthEqual: Bool
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
  var verified: Bool
  var result: String

  /// One schema object. Frames borrow these `unowned(unsafe)`; `id` is object identity, so two
  /// frames carrying the same id are two borrows of one object.
  struct Schema: Encodable {
    var id: Int
    var name: String
    var shape: String
    var keyRouting: String
    var fieldCount: Int
  }

  struct Member: Encodable {
    var name: String
    var offset: Int
    var size: Int
    var kind: String
    var schema: Int
  }

  struct Step: Encodable {
    var index: Int
    var call: String
    var text: String?
    var offset: Int?
    var length: Int?
    var frames: [Frame]
    var wrote: String?
  }

  struct Frame: Encodable {
    var schema: Int
    var storageOffset: Int?
    var pendingField: Int32
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
  var verified: Bool

  struct Step: Encodable {
    var chunk: String
    var chunkBytes: Int
    var inlineCount: Int
    var blocks: [Int]
    var tailCount: Int
    var tailCapacity: Int
    var utf8Count: Int
    var event: String
  }

  struct Locate: Encodable {
    var position: Int
    var block: Int
    var offset: Int
    var byte: UInt8
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
    var snapshotAfter: Int
    var steps: [ArrayStep]
  }

  struct ArrayStep: Encodable {
    var index: Int
    var value: Int
    var blocks: [Int]
    var tailCount: Int
    var tailCapacity: Int
    var pending: Int?
    var count: Int
    var sharedTail: Bool
    var event: String
  }

  struct DictionaryTrace: Encodable {
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
    var event: String
  }

  struct Lookup: Encodable {
    var key: String
    var hash: String
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
  var verified: Bool

  struct Member: Encodable {
    var name: String
    var offset: Int
    var size: Int
    var kind: String
    var value: String
    var indirect: Bool
  }
}
