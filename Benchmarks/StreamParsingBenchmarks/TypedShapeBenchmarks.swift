import Benchmark
import Foundation
import StreamParsing
@_spi(Benchmarks) import StreamParsingCore

// The typed path decomposed by shape: the same payload parsed twice, once with a counting sink
// that recognizes every token and stores nothing, and once into the declared model through
// `PartialSink`. The pair's delta is what routing and storing a value costs on that shape, with
// the lexing held identical -- which is the only way to tell a parser cost from a sink cost.
//
// Same payloads as the replay rows in PartialSinkReplayBenchmarks.swift, so the two tables
// compose: the sink alone there, the sink behind the real parser here.
//
// These rows began as the fused-slice experiment's control halves (NEW_ARCHITECTURE.md, "The
// fused slice"). The slice is gone -- its findings shipped in the fusion series -- and what it
// leaves behind is this decomposition, which is worth keeping on its own terms: the four shapes
// isolate a homogeneous number run, a matched object member, a missed object member and a
// skipped subtree, and no real-world row separates those.

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

// The models must build the value the rows claim before either side is worth timing.
private func validateTypedShapes() {
  var doubles = SinkDoubles.Partial.streamInitialValue()
  expectParses { try parseInto(&doubles, SinkReplayPayloads.doubleArray) }
  precondition(doubles.values?.count == 40_000)

  var ints = SinkIntRows.Partial.streamInitialValue()
  expectParses { try parseInto(&ints, SinkReplayPayloads.intFields) }
  precondition(ints.rows?.count == 8_000 && ints.rows?[7_999].hotel == 63_999)

  var missed = SinkMissRows.Partial.streamInitialValue()
  expectParses { try parseInto(&missed, SinkReplayPayloads.intFields) }
  precondition(missed.rows?.count == 8_000 && missed.rows?[0].absent0 == nil)

  var skipped = SinkSkipRows.Partial.streamInitialValue()
  expectParses { try parseInto(&skipped, SinkReplayPayloads.nestedMiss) }
  precondition(skipped.rows?.count == 6_000 && skipped.rows?[5_999].alpha == 5_999)
}

private func parseInto<Value: StreamParseableRoot>(
  _ value: inout Value, _ payload: [UInt8]
) throws {
  try withUnsafeMutablePointer(to: &value) { pointer in
    var parser = JSONParser()
    var sink = PartialSink(root: pointer)
    try payload.withUnsafeBufferPointer { try parser.parse($0, into: &sink) }
    try parser.finish(into: &sink)
    precondition(sink.streamFailure == nil)
  }
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
