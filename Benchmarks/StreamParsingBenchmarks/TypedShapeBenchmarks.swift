import Benchmark
import Foundation
import StreamParsing
import StreamParsingCore

// The typed path decomposed by shape: the same payload parsed twice, once with a counting sink
// that recognizes every token and stores nothing, and once into the declared model through
// `PartialSink`. The pair's delta is what routing and storing a value costs on that shape, with
// the lexing held identical -- which is the only way to tell a parser cost from a sink cost.
//
// These rows began as the fused-slice experiment's control halves (NEW_ARCHITECTURE.md, "The
// fused slice"). The slice is gone -- its findings shipped in the fusion series -- and what it
// leaves behind is this decomposition, which is worth keeping on its own terms: the four shapes
// isolate a homogeneous number run, a matched object member, a missed object member and a
// skipped subtree, and no real-world row separates those.

// MARK: - Synthetic shapes, one route each

// Each payload exercises one of `PartialSink`'s routes and as little else as it can, so the rows
// read as a cost per event for that route. Sizes are chosen to land near the corpus documents
// (300–700 KB) so the MB/s column sits on the same scale.
enum SinkReplayPayloads {
  // A matched key followed by an integer: `matchField`, then `applyNumber` into a field.
  static let intFields = Array(Self.makeRows(count: 8_000) { row in
    (0..<8).map { field in "\"\(Self.fieldNames[field])\":\(row &* 8 &+ field)" }.joined(separator: ",")
  }.utf8)

  // Every value is a run of doubles into `[Double]`: the bulk `appendNumbers` route, long runs.
  static let doubleArray = Array(
    "{\"values\":[\(Self.makeDoubles(count: 40_000).joined(separator: ","))]}".utf8
  )

  // A declared scalar next to an undeclared *subtree* per row: the `.skip` disposition's
  // payload. Most of the document's bytes sit inside containers the model has no field for, so
  // the delta between this row's raw and partial-sink forms is what a skipped interior costs —
  // structural scan against full streaming.
  static let nestedMiss = Array(Self.makeRows(count: 6_000) { row in
    "\"alpha\":\(row),"
      + "\"extra\":{\"a\":[\(row),\(row &+ 1),\(row &+ 2)],"
      + "\"b\":\"tail_\(row)_some_padding_text\","
      + "\"c\":{\"d\":true,\"e\":null,\"f\":\(row).5}}"
  }.utf8)

  private static let fieldNames = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel"]

  private static func makeRows(count: Int, _ body: (Int) -> String) -> String {
    "{\"rows\":[\((0..<count).map { "{\(body($0))}" }.joined(separator: ","))]}"
  }

  // Sixteen to eighteen significant digits with a fraction, which is what canada carries.
  private static func makeDoubles(count: Int) -> [String] {
    (0..<count).map { index in
      let sign = index % 3 == 0 ? "-" : ""
      let whole = 40 + index % 60
      let fraction = String(1_000_000_000_000 + (index &* 7_919) % 999_999_999_999)
      return "\(sign)\(whole).\(fraction)"
    }
  }
}

@StreamParseable
struct SinkIntRow: Equatable {
  var alpha: Int = 0
  var bravo: Int = 0
  var charlie: Int = 0
  var delta: Int = 0
  var echo: Int = 0
  var foxtrot: Int = 0
  var golf: Int = 0
  var hotel: Int = 0
}

@StreamParseable
struct SinkIntRows: Equatable {
  var rows: [SinkIntRow] = []
}

// The int rows' spine with no key that matches: every member takes the ignore route.
@StreamParseable
struct SinkMissRow: Equatable {
  var absent0: Int = 0
  var absent1: Int = 0
  var absent2: Int = 0
  var absent3: Int = 0
  var absent4: Int = 0
  var absent5: Int = 0
  var absent6: Int = 0
  var absent7: Int = 0
}

@StreamParseable
struct SinkMissRows: Equatable {
  var rows: [SinkMissRow] = []
}

// One declared field; everything else in a `nestedMiss` row is a skipped subtree.
@StreamParseable
struct SinkSkipRow: Equatable {
  var alpha: Int = 0
}

@StreamParseable
struct SinkSkipRows: Equatable {
  var rows: [SinkSkipRow] = []
}

@StreamParseable
struct SinkDoubles: Equatable {
  var values: [Double] = []
}

// MARK: - Runners

private func runTypedParse<Value: StreamParseableRoot>(
  _ payload: [UInt8], as type: Value.Type
) throws {
  let storage = UnsafeMutablePointer<Value>.allocate(capacity: 1)
  storage.initialize(to: Value.streamInitialValue())
  defer {
    storage.deinitialize(count: 1)
    storage.deallocate()
  }
  var sink = PartialSink(root: storage)
  var parser = JSONParser()
  try payload.withUnsafeBufferPointer { try parser.parse($0, into: &sink) }
  try parser.finish(into: &sink)
  precondition(sink.streamFailure == nil, "Typed parse rejected: \(sink.streamFailure!)")
  blackHole(storage.pointee)
}

private func addTypedShapePair<Value: StreamParseableRoot>(
  _ name: String, _ payload: [UInt8], as type: Value.Type, raw: Bool = true
) {
  // The raw row recognizes the same tokens and stores nothing; typed minus raw is the sink.
  if raw {
    Benchmark("Typed shape \(name) - raw counting", configuration: payloadConfiguration) {
      benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(expectParses { try runFastParser(payload, chunk: .max) })
      }
    }
  }
  Benchmark("Typed shape \(name) - typed parse", configuration: payloadConfiguration) { benchmark in
    measurePayloadThroughput(benchmark, payload: payload) {
      expectParses { try runTypedParse(payload, as: Value.self) }
    }
  }
}

// The models must build the value the rows claim before either side is worth timing. A second
// copy of `runTypedParse` used to live here only to run these; `streamBulkDiscarding` returns the
// value, so the copy is gone.
private func validateTypedShapes() {
  let doubles = expectParses {
    try streamBulkDiscarding(SinkReplayPayloads.doubleArray, as: SinkDoubles.Partial.self)
  }
  precondition(doubles.values?.count == 40_000)

  let ints = expectParses {
    try streamBulkDiscarding(SinkReplayPayloads.intFields, as: SinkIntRows.Partial.self)
  }
  precondition(ints.rows?.count == 8_000 && ints.rows?[7_999].hotel == 63_999)

  let missed = expectParses {
    try streamBulkDiscarding(SinkReplayPayloads.intFields, as: SinkMissRows.Partial.self)
  }
  precondition(missed.rows?.count == 8_000 && missed.rows?[0].absent0 == nil)

  let skipped = expectParses {
    try streamBulkDiscarding(SinkReplayPayloads.nestedMiss, as: SinkSkipRows.Partial.self)
  }
  precondition(skipped.rows?.count == 6_000 && skipped.rows?[5_999].alpha == 5_999)
}

func typedShapeBenchmarks() {
  validateTypedShapes()

  // A homogeneous run of `Double` into a `StreamArray`: the per-element append, which is the
  // series' one standing regression against the batched bulk appender it replaced.
  addTypedShapePair(
    "synthetic double array", SinkReplayPayloads.doubleArray, as: SinkDoubles.Partial.self
  )
  // Object members that all match: key scan hit early, typed store at the member's offset.
  addTypedShapePair(
    "synthetic int fields", SinkReplayPayloads.intFields, as: SinkIntRows.Partial.self
  )
  // The same payload against a model declaring none of its keys: every key scans the table to
  // the end. The int payload's raw row is already registered by the matched pair.
  addTypedShapePair(
    "synthetic int fields, no key matches", SinkReplayPayloads.intFields,
    as: SinkMissRows.Partial.self, raw: false
  )
  // Undeclared subtrees carry most of the bytes: the `.skip` disposition's payload.
  addTypedShapePair(
    "synthetic nested miss subtrees", SinkReplayPayloads.nestedMiss,
    as: SinkSkipRows.Partial.self
  )
}
