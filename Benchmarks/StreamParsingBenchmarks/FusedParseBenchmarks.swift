import Benchmark
import Foundation
import StreamParsing
@_spi(Benchmarks) import StreamParsingCore

// The parser -> sink fusion slice, priced end to end: the same payload parsed into the same
// model twice, once through the recorded path (`parse` -> event scratch -> `events`) and once
// through the fused loop (FusedParseExperiment.swift), which runs the same lexing kernels and
// calls the sink's routing at the lex points. The pair's delta is the record/replay seam on that
// route -- the number the fusion discussion needs before any protocol change.
//
// Same payloads as the replay rows, so the three tables compose: `Real`-style recorded E2E here,
// the sink alone in PartialSinkReplayBenchmarks, and the fused E2E as the third point.

private func runRecordedParse<Value: StreamParseableRoot>(
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
  precondition(sink.streamFailure == nil, "Recorded parse rejected: \(sink.streamFailure!)")
  blackHole(storage.pointee)
}

private func runFusedParse<Value: StreamParseableRoot>(
  _ payload: [UInt8], as type: Value.Type
) throws {
  let storage = UnsafeMutablePointer<Value>.allocate(capacity: 1)
  storage.initialize(to: Value.streamInitialValue())
  defer {
    storage.deinitialize(count: 1)
    storage.deallocate()
  }
  var sink = makeFusedSliceSink(
    root: UnsafeMutableRawPointer(storage), schema: Value.streamSchema
  )
  var parser = JSONParser()
  try payload.withUnsafeBufferPointer { try parser.parseFusedDocument($0, into: &sink) }
  precondition(sink.streamFailure == nil, "Fused parse rejected: \(sink.streamFailure!)")
  blackHole(storage.pointee)
}

private func addFusedPair<Value: StreamParseableRoot>(
  _ name: String, _ payload: [UInt8], as type: Value.Type, raw: Bool = true
) {
  // The raw row is the decomposition's third point: recorded minus raw is the sink through the
  // seam, fused minus raw is the sink without it.
  if raw {
    Benchmark("Fused \(name) - raw counting", configuration: payloadConfiguration) { benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(expectParses { try runFastParser(payload, chunk: .max) })
      }
    }
  }
  Benchmark("Fused \(name) - recorded parse", configuration: payloadConfiguration) { benchmark in
    measurePayloadThroughput(benchmark, payload: payload) {
      expectParses { try runRecordedParse(payload, as: Value.self) }
    }
  }
  Benchmark("Fused \(name) - fused parse", configuration: payloadConfiguration) { benchmark in
    measurePayloadThroughput(benchmark, payload: payload) {
      expectParses { try runFusedParse(payload, as: Value.self) }
    }
  }
}

// The two paths must build the same value before either is worth timing.
private func validateFusedSlice() {
  var recorded = SinkDoubles.Partial.streamInitialValue()
  var fused = SinkDoubles.Partial.streamInitialValue()
  expectParses { try parseInto(&recorded, SinkReplayPayloads.doubleArray, fused: false) }
  expectParses { try parseInto(&fused, SinkReplayPayloads.doubleArray, fused: true) }
  precondition(fused.values?.count == 40_000 && recorded.values?.count == 40_000)
  precondition(fused.values?[0] == recorded.values?[0])
  precondition(fused.values?[39_999] == recorded.values?[39_999])

  var recordedInts = SinkIntRows.Partial.streamInitialValue()
  var fusedInts = SinkIntRows.Partial.streamInitialValue()
  expectParses { try parseInto(&recordedInts, SinkReplayPayloads.intFields, fused: false) }
  expectParses { try parseInto(&fusedInts, SinkReplayPayloads.intFields, fused: true) }
  precondition(fusedInts.rows?.count == 8_000 && recordedInts.rows?.count == 8_000)
  precondition(fusedInts.rows?[7_999].hotel == 63_999)
  precondition(fusedInts.rows?[7_999].hotel == recordedInts.rows?[7_999].hotel)

  var missed = SinkMissRows.Partial.streamInitialValue()
  expectParses { try parseInto(&missed, SinkReplayPayloads.intFields, fused: true) }
  precondition(missed.rows?.count == 8_000 && missed.rows?[0].absent0 == nil)

  // The skipped-subtree payload builds the same value whether the deliverer honors the skip
  // (the production path) or streams the interior anyway (the slice discards dispositions).
  var skipHonored = SinkSkipRows.Partial.streamInitialValue()
  var skipStreamed = SinkSkipRows.Partial.streamInitialValue()
  expectParses { try parseInto(&skipHonored, SinkReplayPayloads.nestedMiss, fused: false) }
  expectParses { try parseInto(&skipStreamed, SinkReplayPayloads.nestedMiss, fused: true) }
  precondition(skipHonored.rows?.count == 6_000 && skipStreamed.rows?.count == 6_000)
  precondition(skipHonored.rows?[5_999].alpha == 5_999 && skipStreamed.rows?[5_999].alpha == 5_999)
}

private func parseInto<Value: StreamParseableRoot>(
  _ value: inout Value, _ payload: [UInt8], fused: Bool
) throws {
  try withUnsafeMutablePointer(to: &value) { pointer in
    var parser = JSONParser()
    if fused {
      var sink = makeFusedSliceSink(
        root: UnsafeMutableRawPointer(pointer), schema: Value.streamSchema
      )
      try payload.withUnsafeBufferPointer { try parser.parseFusedDocument($0, into: &sink) }
      precondition(sink.streamFailure == nil)
    } else {
      var sink = PartialSink(root: pointer)
      try payload.withUnsafeBufferPointer { try parser.parse($0, into: &sink) }
      try parser.finish(into: &sink)
      precondition(sink.streamFailure == nil)
    }
  }
}

func fusedParseBenchmarks() {
  validateFusedSlice()

  addFusedPair("synthetic double array", SinkReplayPayloads.doubleArray, as: SinkDoubles.Partial.self)
  addFusedPair("synthetic int fields", SinkReplayPayloads.intFields, as: SinkIntRows.Partial.self)
  // The int payload's raw row is already registered by the matched pair.
  addFusedPair(
    "synthetic int fields, no key matches", SinkReplayPayloads.intFields,
    as: SinkMissRows.Partial.self, raw: false
  )
  // The `.skip` disposition's payload: undeclared subtrees carry most of the bytes. The
  // "recorded parse" row (the production per-token path) honors the skip; the slice row does
  // not (it discards dispositions), so the pair's delta prices the skip itself on top of the
  // same lexing.
  addFusedPair(
    "synthetic nested miss subtrees", SinkReplayPayloads.nestedMiss,
    as: SinkSkipRows.Partial.self
  )
}
