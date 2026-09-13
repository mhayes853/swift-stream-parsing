import Benchmark
import Foundation
import StreamParsing
@_spi(Benchmarks) import StreamParsingCore

// The synthetic payloads and models the sink-route benchmarks share. The replay rows that used
// to live here are gone with the record/replay seam itself: the parser emits per token, there is
// no recording to replay, and the routes these payloads exercise are measured end to end by the
// rows in TypedShapeBenchmarks.

// MARK: - Synthetic shapes, one route each

// Each payload exercises one of `PartialSink`'s routes and as little else as it can, so the rows
// read as a cost per event for that route. Sizes are chosen to land near the corpus documents
// (300–700 KB) so the MB/s column sits on the same scale.
enum SinkReplayPayloads {
  // A matched key followed by an integer: `matchField`, then `applyNumber` into a field.
  static let intFields = Array(Self.makeRows(count: 8_000) { row in
    (0..<8).map { field in "\"\(Self.fieldNames[field])\":\(row &* 8 &+ field)" }.joined(separator: ",")
  }.utf8)

  // A matched key followed by a short string: `matchField`, then `applyString` into a `String`.
  static let stringFields = Array(Self.makeRows(count: 5_000) { row in
    (0..<8).map { field in "\"\(Self.fieldNames[field])\":\"value_\(row)_\(field)\"" }
      .joined(separator: ",")
  }.utf8)

  // Every value is a run of doubles into `[Double]`: the bulk `appendNumbers` route, long runs.
  static let doubleArray = Array(
    "{\"values\":[\(Self.makeDoubles(count: 40_000).joined(separator: ","))]}".utf8
  )

  // The same doubles as pairs, which is canada's shape: a frame per pair and a run of two.
  static let doublePairs: [UInt8] = {
    let doubles = Self.makeDoubles(count: 40_000)
    var pairs: [String] = []
    pairs.reserveCapacity(doubles.count / 2)
    var index = 0
    while index + 1 < doubles.count {
      pairs.append("[\(doubles[index]),\(doubles[index + 1])]")
      index += 2
    }
    return Array("{\"pairs\":[\(pairs.joined(separator: ","))]}".utf8)
  }()

  // Three containers opened and closed per scalar: `enterField`, the frame push and the pop.
  static let containerChurn = Array(Self.makeRows(count: 12_000) { row in
    "\"inner\":{\"leaf\":{\"n\":\(row)}}"
  }.utf8)

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

  // Dynamic keys into `[String: Int]`: `enterKey` and the entry, per member.
  static let dictionary = Array(
    "{\"counts\":{\((0..<20_000).map { "\"key_\($0)\":\($0)" }.joined(separator: ","))}}".utf8
  )

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

@StreamParseable
struct SinkStringRow: Equatable {
  var alpha: String = ""
  var bravo: String = ""
  var charlie: String = ""
  var delta: String = ""
  var echo: String = ""
  var foxtrot: String = ""
  var golf: String = ""
  var hotel: String = ""
}

@StreamParseable
struct SinkStringRows: Equatable {
  var rows: [SinkStringRow] = []
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

@StreamParseable
struct SinkDoublePairs: Equatable {
  var pairs: [[Double]] = []
}

@StreamParseable
struct SinkChurnLeaf: Equatable {
  var n: Int = 0
}

@StreamParseable
struct SinkChurnInner: Equatable {
  var leaf: SinkChurnLeaf = SinkChurnLeaf()
}

@StreamParseable
struct SinkChurnRow: Equatable {
  var inner: SinkChurnInner = SinkChurnInner()
}

@StreamParseable
struct SinkChurnRows: Equatable {
  var rows: [SinkChurnRow] = []
}

@StreamParseable
struct SinkCounts: Equatable {
  var counts: [String: Int] = [:]
}

private func validateSyntheticModels() {
  let ints = expectParses {
    try streamBulkDiscarding(SinkReplayPayloads.intFields, as: SinkIntRows.Partial.self)
  }
  precondition(ints.rows?.count == 8_000 && ints.rows?[7_999].hotel == 63_999)
  let strings = expectParses {
    try streamBulkDiscarding(SinkReplayPayloads.stringFields, as: SinkStringRows.Partial.self)
  }
  precondition(strings.rows?.count == 5_000 && strings.rows?[4_999].hotel == "value_4999_7")
  let doubles = expectParses {
    try streamBulkDiscarding(SinkReplayPayloads.doubleArray, as: SinkDoubles.Partial.self)
  }
  precondition(doubles.values?.count == 40_000)
  let pairs = expectParses {
    try streamBulkDiscarding(SinkReplayPayloads.doublePairs, as: SinkDoublePairs.Partial.self)
  }
  precondition(pairs.pairs?.count == 20_000 && pairs.pairs?[19_999].count == 2)
  let churn = expectParses {
    try streamBulkDiscarding(SinkReplayPayloads.containerChurn, as: SinkChurnRows.Partial.self)
  }
  precondition(churn.rows?.count == 12_000 && churn.rows?[11_999].inner?.leaf?.n == 11_999)
  let counts = expectParses {
    try streamBulkDiscarding(SinkReplayPayloads.dictionary, as: SinkCounts.Partial.self)
  }
  precondition(counts.counts?.count == 20_000)
  let skips = expectParses {
    try streamBulkDiscarding(SinkReplayPayloads.nestedMiss, as: SinkSkipRows.Partial.self)
  }
  precondition(skips.rows?.count == 6_000 && skips.rows?[5_999].alpha == 5_999)
}

func partialSinkReplayBenchmarks() {
  validateSyntheticModels()
}
