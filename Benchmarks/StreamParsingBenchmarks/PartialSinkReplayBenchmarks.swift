import Benchmark
import Foundation
import StreamParsing
@_spi(Benchmarks) import StreamParsingCore

// The sink in isolation: the batches one parse delivered, recorded once and replayed into a sink
// with no parser in the loop.
//
// Every `Real ... discarding` row is the parser and `PartialSink` added together, and the two
// cannot be separated by subtracting rows, because the parser's own cost changes with the sink
// it is specialized for. These rows hold the parser at zero: the recorder captures exactly the
// `StreamEventBatch`es a bulk parse handed over — the same records, the same batch boundaries,
// the same bytes — and the measured region is the sink consuming them again.
//
//   null sink       a sink that takes every batch and does nothing: the harness floor, batch
//                   construction and the loop
//   counting sink   `FastCountingSink`, so `Real <x> - bulk` minus this row is the parser alone
//   partial sink    `PartialSink` routing every record into the corpus's model
//   one batch       the same, with the whole recording delivered as a single batch: what the
//                   parser's batch seams cost the sink (`deliverEvents` entry, run resolution
//                   restarted at each boundary)
//
// Batch boundaries are kept because `PartialSink.events` has fast paths that only see records in
// the same batch — a key followed by its scalar, a run of numbers into an array — so re-batching
// would measure a sink the parser never drives. `.parserBuffer` records point at scratch the
// parser reuses, so their bytes are copied out at recording time; `.input` records are re-based
// from the chunk to the payload.
//
// Payload MB/s is the recording's source bytes, so a row composes with the `Real` rows: at the
// same corpus, 1/typed − 1/raw is what this row should read. Events M/s is the per-event view,
// which is the one that compares across corpora.

// MARK: - Metrics

let eventsPerSecond = BenchmarkMetric.custom(
  "Events M/s",
  polarity: .prefersLarger,
  useScalingFactor: false
)

var replayConfiguration: Benchmark.Configuration {
  var configuration = payloadConfiguration
  configuration.metrics.append(eventsPerSecond)
  return configuration
}

func measureReplayThroughput(
  _ benchmark: Benchmark,
  payload: [UInt8],
  eventCount: Int,
  work: () -> Void
) {
  let start = DispatchTime.now().uptimeNanoseconds
  for _ in benchmark.scaledIterations {
    work()
  }
  // A 64 KB recording through the null sink can finish inside one clock tick, and dividing
  // by zero here converts to `Int` as infinity and traps.
  let elapsed = Swift.max(DispatchTime.now().uptimeNanoseconds - start, 1)
  let iterations = Double(benchmark.scaledIterations.count)
  let bytes = Double(payload.count) * iterations
  let megabytesPerSecond = bytes / Double(elapsed) * 1_000_000_000 / 1_000_000
  benchmark.measurement(payloadMegabytesPerSecond, Int(megabytesPerSecond))
  let events = Double(eventCount) * iterations
  let eventsPerMicrosecond = events / Double(elapsed) * 1_000
  benchmark.measurement(eventsPerSecond, Int(eventsPerMicrosecond))
}

// MARK: - Recording

// One parse's batches, kept after the parser is gone.
final class RecordedEvents {
  let payload: [UInt8]
  private(set) var records: [StreamEventRecord] = []
  private(set) var infos: [NumberInfo] = []
  // Bytes of every `.parserBuffer` record, in delivery order. Starts with one byte so the
  // replay always has a base address to hand over, even when nothing was ever buffered.
  private(set) var buffer: [UInt8] = [0]
  // The batches as delivered, as ranges into `records`.
  private(set) var batches: [Range<Int>] = []

  var eventCount: Int { self.records.count }

  private init(payload: [UInt8]) {
    self.payload = payload
  }

  // Records the batches the parser delivers for `payload`, fed in `chunk` sized pieces.
  static func record(_ payload: [UInt8], chunk: Int = .max) -> RecordedEvents {
    let recorded = RecordedEvents(payload: payload)
    var parser = JSONParser(bufferCapacity: 4_096)
    var sink = RecordingSink(recorded: recorded)
    expectParses {
      try payload.withUnsafeBufferPointer { buffer in
        var offset = 0
        while offset < buffer.count {
          let count = min(chunk, buffer.count - offset)
          let slice = UnsafeBufferPointer(start: buffer.baseAddress! + offset, count: count)
          sink.chunkOffset = offset
          try parser.parse(slice, into: &sink)
          offset += count
        }
        // `finish` flushes what the last chunk left pending; an input-sourced record it delivers
        // is relative to that chunk's base, which `chunkOffset` still holds.
        try parser.finish(into: &sink)
      }
    }
    return recorded
  }

  fileprivate func append(_ batch: borrowing StreamEventBatch, chunkOffset: Int) {
    let start = self.records.count
    let records = batch.records
    for index in 0..<batch.count {
      var record = records[index]
      switch record.source {
      case .input:
        record.start = UInt32(truncatingIfNeeded: Int(record.start) &+ chunkOffset)
      case .parserBuffer:
        let bytes = batch.bytes(of: index)
        record.start = UInt32(truncatingIfNeeded: self.buffer.count)
        bytes.withUnsafeBufferPointer { self.buffer.append(contentsOf: $0) }
      case .inline:
        break
      }
      self.records.append(record)
      self.infos.append(batch.info(of: index))
    }
    self.batches.append(start..<self.records.count)
  }
}

private struct RecordingSink: StreamParseSink {
  let recorded: RecordedEvents
  var chunkOffset = 0
  var streamFailure: StreamSinkFailure? { nil }

  mutating func events(_ batch: borrowing StreamEventBatch) -> Int {
    self.recorded.append(batch, chunkOffset: self.chunkOffset)
    return batch.count
  }

  // A batch-transport sink: the parser reaches it through `events` only, so the per-token
  // requirements are dead weight it satisfies and never runs.
  mutating func beginObject() {}
  mutating func endObject() {}
  mutating func beginArray() {}
  mutating func endArray() {}
  mutating func key(_ bytes: Span<UInt8>) {}
  mutating func stringBegin() {}
  mutating func stringChunk(_ bytes: Span<UInt8>) {}
  mutating func stringEnd() {}
  mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) {}
  mutating func boolean(_ value: Bool) {}
  mutating func null() {}
}

// MARK: - Replay

enum ReplayBatching {
  case asDelivered
  case oneBatch
}

// Hands the recording to the sink and returns how many records it took. The four buffers are
// pinned once for the whole replay; the loop is a batch construction and one `events` call per
// recorded batch, which is what the parser's `deliverEvents` does.
@inline(never)
func replay<Sink: StreamParseSink & ~Copyable>(
  _ recorded: RecordedEvents,
  _ batching: ReplayBatching,
  into sink: inout Sink
) -> Int {
  recorded.records.withUnsafeBufferPointer { records in
    recorded.infos.withUnsafeBufferPointer { infos in
      recorded.payload.withUnsafeBufferPointer { payload in
        recorded.buffer.withUnsafeBufferPointer { buffer in
          let recordBase = records.baseAddress!
          let infoBase = infos.baseAddress!
          let bytesBase = payload.baseAddress!
          let bufferBase = buffer.baseAddress!
          switch batching {
          case .oneBatch:
            let batch = StreamEventBatch(
              replaying: recordBase, infoBase: infoBase, count: records.count,
              bytesBase: bytesBase, bufferBase: bufferBase
            )
            return sink.events(batch)
          case .asDelivered:
            var taken = 0
            for range in recorded.batches {
              let batch = StreamEventBatch(
                replaying: recordBase + range.lowerBound, infoBase: infoBase + range.lowerBound,
                count: range.count, bytesBase: bytesBase, bufferBase: bufferBase
              )
              let took = sink.events(batch)
              taken &+= took
              if took < range.count { return taken }
            }
            return taken
          }
        }
      }
    }
  }
}

// Takes every batch and reads nothing. Overrides `events` rather than inheriting the default:
// the default unrolls the batch into per-token calls, which is a cost, and this row is the
// floor those costs are read against. Unoptimized by force so the call survives: inlined, the
// batch construction folds into the sum of the ranges and the row measures nothing at all.
// What it measures otherwise is ~2 ns per batch — a Twitter recording is ~125 batches and reads
// 0.6 µs — so the floor is below anything a sink row can resolve, and the sink rows are read as
// absolute rather than against it.
private struct NullReplaySink: StreamParseSink {
  var streamFailure: StreamSinkFailure? { nil }

  @_optimize(none)
  mutating func events(_ batch: borrowing StreamEventBatch) -> Int { batch.count }

  mutating func beginObject() {}
  mutating func endObject() {}
  mutating func beginArray() {}
  mutating func endArray() {}
  mutating func key(_ bytes: Span<UInt8>) {}
  mutating func stringBegin() {}
  mutating func stringChunk(_ bytes: Span<UInt8>) {}
  mutating func stringEnd() {}
  mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) {}
  mutating func boolean(_ value: Bool) {}
  mutating func null() {}
}

func runReplayNullSink(_ recorded: RecordedEvents, _ batching: ReplayBatching) -> Int {
  var sink = NullReplaySink()
  return replay(recorded, batching, into: &sink)
}

func runReplayCountingSink(_ recorded: RecordedEvents, _ batching: ReplayBatching) -> UInt64 {
  var sink = FastCountingSink()
  let taken = replay(recorded, batching, into: &sink)
  precondition(taken == recorded.eventCount)
  return sink.checksum
}

// The same root storage `runLayerPartialSink` builds, fed from the recording instead of a parse.
func runReplayPartialSink<Value: StreamParseableRoot>(
  _ recorded: RecordedEvents,
  _ batching: ReplayBatching,
  as type: Value.Type
) {
  let storage = UnsafeMutablePointer<Value>.allocate(capacity: 1)
  storage.initialize(to: Value.streamInitialValue())
  defer {
    storage.deinitialize(count: 1)
    storage.deallocate()
  }
  var sink = PartialSink(root: storage)
  let taken = replay(recorded, batching, into: &sink)
  // A rejection is recorded, not thrown, and a sink that stops early reads as a fast row.
  precondition(
    sink.streamFailure == nil && taken == recorded.eventCount,
    "Partial sink rejected the recording: \(String(describing: sink.streamFailure))"
  )
  blackHole(storage.pointee)
}

// MARK: - Registration

private func addReplayRows<Value: StreamParseableRoot>(
  _ name: String,
  _ recorded: RecordedEvents,
  as type: Value.Type,
  floors: Bool = true
) {
  let payload = recorded.payload
  let events = recorded.eventCount

  if floors {
    Benchmark("Sink \(name) - null sink replay", configuration: replayConfiguration) { benchmark in
      measureReplayThroughput(benchmark, payload: payload, eventCount: events) {
        blackHole(runReplayNullSink(recorded, .asDelivered))
      }
    }

    Benchmark("Sink \(name) - counting sink replay", configuration: replayConfiguration) {
      benchmark in
      measureReplayThroughput(benchmark, payload: payload, eventCount: events) {
        blackHole(runReplayCountingSink(recorded, .asDelivered))
      }
    }
  }

  Benchmark("Sink \(name) - partial sink replay", configuration: replayConfiguration) {
    benchmark in
    measureReplayThroughput(benchmark, payload: payload, eventCount: events) {
      runReplayPartialSink(recorded, .asDelivered, as: Value.self)
    }
  }

  Benchmark("Sink \(name) - partial sink replay, one batch", configuration: replayConfiguration) {
    benchmark in
    measureReplayThroughput(benchmark, payload: payload, eventCount: events) {
      runReplayPartialSink(recorded, .oneBatch, as: Value.self)
    }
  }
}

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
}

func partialSinkReplayBenchmarks() {
  validateSyntheticModels()
  // The replay rows are retired: they measured the sink behind the record/replay seam, and the
  // parser no longer records — `RecordedEvents.record` would capture nothing, because `events`
  // is never called by the parser. The fused rows in FusedParseBenchmarks measure the same
  // payloads end to end; the recording machinery above goes with `events()` itself.

}
