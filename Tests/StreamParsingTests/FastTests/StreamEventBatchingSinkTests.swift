import CustomDump
import Testing

import StreamParsing
import StreamParsingCore

// The batching adapter against the direct path on the same documents. The adapter is the old
// internal transport relocated behind the protocol, so a PartialSink fed through it must build
// the same value and record the same failure reason as one fed directly — batch boundaries,
// chunk boundaries and copied bytes included. Offsets are exempt by contract: a deferred event
// is refused up to a batch later than a direct one.

@StreamParseable
private struct BatchedRow: Equatable {
  var count: Int = 0
  var ratio: Double = 0
  var label: String = ""
  var live: Bool = false
  var maybe: Int? = nil
}

@StreamParseable
private struct BatchedRows: Equatable {
  var rows: [BatchedRow] = []
  var values: [Double] = []
}

private struct SizeRecordingConsumer: StreamEventBatchConsumer {
  var sizes: [Int] = []
  var streamFailure: StreamSinkFailure? { nil }

  mutating func events(_ batch: borrowing StreamEventBatch) -> Int {
    self.sizes.append(batch.count)
    return batch.count
  }
}

// Replays every delivered batch into a directly held PartialSink: the shape a cross-boundary
// consumer has, minus the boundary.
private struct PartialReplayConsumer: StreamEventBatchConsumer, ~Copyable {
  var sink: PartialSink

  var streamFailure: StreamSinkFailure? { self.sink.streamFailure }

  mutating func events(_ batch: borrowing StreamEventBatch) -> Int {
    batch.replay(into: &self.sink)
  }
}

// A self-recursive object: `child` re-enters the same storage through the same schema, so a
// document of nested `child` keys pushes an unbounded number of *real* frames onto the sink.
// That is the only way to reach the sink's own depth overflow -- `JSONParser` rejects the depth
// one container earlier -- and it is exactly the shape the overflow has to get right.
// At file scope so `enterField` can name the schema it is part of; a `static let` referencing
// itself inside its own initializer cannot be type checked.
private let depthNodeSchema = StreamSchema(
  shape: .object,
  matchField: { key in
    let bytes = key.withUnsafeBufferPointer { Array($0) }
    if bytes == Array("name".utf8) { return 0 }
    if bytes == Array("child".utf8) { return 1 }
    return -1
  },
  applyString: { storage, field, bytes in
    guard field == 0 else { return .unsupported }
    return storage.assumingMemoryBound(to: DepthNode.self).pointee.name.streamAppend(utf8: bytes)
  },
  enterField: { storage, field in
    guard field == 1 else { return nil }
    return StreamFrame(storage: storage, schema: depthNodeSchema)
  }
)

private struct DepthNode: StreamInitializable, StreamParseableObject {
  var name = StreamString()

  static func streamInitialValue() -> Self { Self() }

  static var streamSchema: StreamSchema { depthNodeSchema }
}

@Suite
struct StreamEventBatchingSinkTests {
  // Partials are not Equatable; the comparison is over plain copies of every field the
  // documents touch.
  private struct RowSnapshot: Equatable {
    var count: Int?
    var ratio: Double?
    var label: StreamString?
    var live: Bool?
    var maybe: Int?
  }

  private struct Outcome: Equatable {
    var rows: [RowSnapshot]?
    var values: [Double]?
    var failureReason: StreamSinkFailure.Reason?
    var parserError: JSONParsingError.Reason?
  }

  private static func snapshot(_ value: BatchedRows.Partial, into outcome: inout Outcome) {
    outcome.values = value.values.map(Array.init)
    outcome.rows = value.rows.map { rows in
      (0..<rows.count).map { index in
        RowSnapshot(
          count: rows[index].count,
          ratio: rows[index].ratio,
          label: rows[index].label,
          live: rows[index].live,
          maybe: rows[index].maybe ?? nil
        )
      }
    }
  }

  private func parseDirect(_ payload: [UInt8], chunk: Int) -> Outcome {
    var value = BatchedRows.Partial.streamInitialValue()
    var outcome = Outcome()
    withUnsafeMutablePointer(to: &value) { pointer in
      var parser = JSONParser()
      var sink = PartialSink(root: pointer)
      do {
        try payload.withUnsafeBufferPointer { input in
          var index = 0
          while index < input.count {
            let end = min(index + chunk, input.count)
            try parser.parse(
              UnsafeBufferPointer(rebasing: input[index..<end]), into: &sink
            )
            index = end
          }
        }
        try parser.finish(into: &sink)
      } catch let error as JSONParsingError {
        outcome.parserError = error.reason
      } catch {}
      outcome.failureReason = sink.streamFailure?.reason
    }
    Self.snapshot(value, into: &outcome)
    return outcome
  }

  private func parseBatched(_ payload: [UInt8], chunk: Int) -> Outcome {
    var value = BatchedRows.Partial.streamInitialValue()
    var outcome = Outcome()
    withUnsafeMutablePointer(to: &value) { pointer in
      var parser = JSONParser()
      var sink = StreamEventBatchingSink(
        consumer: PartialReplayConsumer(sink: PartialSink(root: pointer))
      )
      do {
        try payload.withUnsafeBufferPointer { input in
          var index = 0
          while index < input.count {
            let end = min(index + chunk, input.count)
            try parser.parse(
              UnsafeBufferPointer(rebasing: input[index..<end]), into: &sink
            )
            // The parser does not call `commit` yet (that is the fusion stage); the driver
            // stands in for it at every point borrowed memory goes away.
            sink.commit()
            index = end
          }
        }
        try parser.finish(into: &sink)
      } catch let error as JSONParsingError {
        outcome.parserError = error.reason
      } catch {}
      // Committed on the error path too: the recorded transport delivers events *before* it
      // throws, so the sink's state reflects everything ahead of the error. The fused loop owes
      // the same ordering — commit before propagating — and the driver stands in for it here.
      sink.commit()
      outcome.failureReason = sink.streamFailure?.reason
    }
    Self.snapshot(value, into: &outcome)
    return outcome
  }

  private func differential(_ json: String, chunks: [Int] = [Int.max, 7]) {
    let payload = Array(json.utf8)
    for chunk in chunks {
      let direct = self.parseDirect(payload, chunk: chunk)
      let batched = self.parseBatched(payload, chunk: chunk)
      expectNoDifference(batched.rows, direct.rows, "chunk \(chunk)")
      expectNoDifference(batched.values, direct.values, "chunk \(chunk)")
      expectNoDifference(batched.failureReason, direct.failureReason, "chunk \(chunk)")
      // A sink rejection surfaces late on the batched side and may convert a mid-parse throw
      // into a post-commit failure, so the parser error is only pinned when no sink failure is
      // involved.
      if direct.failureReason == nil {
        expectNoDifference(batched.parserError, direct.parserError, "chunk \(chunk)")
      }
    }
  }

  @Test
  func `Values survive the adapter, whole and chunked`() {
    self.differential(
      #"""
      {"rows":[
        {"count":42,"ratio":-0.5,"label":"a","live":true,"maybe":7},
        {"count":9,"ratio":1.5e3,"label":"héllo ✓","live":false,"maybe":null,"unknown":[1,2]}
      ],"values":[1.5,-2.25,3e-2]}
      """#
    )
  }

  @Test
  func `Flushes at capacity mid-parse`() {
    // Well past one batch of events, so values cross flush boundaries mid-document.
    let doubles = (0..<600).map { "\($0).5" }.joined(separator: ",")
    self.differential(#"{"values":[\#(doubles)]}"#)
  }

  @Test
  func `Escaped and cut strings arrive intact through the copy`() {
    self.differential(#"{"rows":[{"label":"a\nbéc and a long tail to cut"}]}"#, chunks: [3])
  }

  @Test
  func `A rejection surfaces with the direct path's reason`() {
    self.differential(#"{"rows":[{"count":"not a number"}]}"#)
    self.differential(#"{"values":[1.5,{"deep":1},2.5]}"#)
  }

  // The 256 cadence, relocated from the parser's recorder: a long numeric run reaches the
  // consumer as full batches, with the remainder delivered by the commit at end of input.
  @Test
  func `Long numeric runs fill the adapter's batches`() throws {
    let bytes = Array(("[" + (0..<1000).map { "\($0)" }.joined(separator: ",") + "]").utf8)
    var sink = StreamEventBatchingSink(consumer: SizeRecordingConsumer())
    var parser = JSONParser()
    try bytes.withUnsafeBufferPointer { try parser.parse($0, into: &sink) }
    try parser.finish(into: &sink)
    // beginArray + 1000 numbers + endArray = 1002 events. The batch capacity is a tuning choice,
    // so this pins the invariant rather than the exact cadence: every event arrives, as equal
    // full batches followed by the commit's remainder at end of input.
    let sizes = sink.consumer.sizes
    expectNoDifference(sizes.reduce(0, +), 1002)
    #expect(sizes.count > 1 && sizes.count < 10)
    #expect(sizes.dropLast().allSatisfy { $0 == sizes.first })
    #expect((sizes.last ?? 0) <= (sizes.first ?? 0))
  }

  // Past the sink's frame capacity there is no slot for a real frame, and the entry points that
  // route a key or a scalar have no depth test -- that test would sit on the hot path. The
  // overflow therefore has to push the ignored frame, or the over-deep subtree's keys are matched
  // against whatever frame is still on top and written into it.
  //
  // Both drivers are run. The batching adapter is the deferred-rejection case: its `replay` stops
  // at the first record that records a failure, so the over-deep interior is *dropped* on the way
  // in and the parent is safe for a second reason. The direct feed is the case the routing has to
  // carry on its own -- any driver that keeps feeding after a recorded failure, which the sink's
  // contract permits -- and it is what actually exercises the overflow frame.
  @Test
  func `A subtree past the depth cap does not write into the frame below it`() {
    // 200 nested `child` objects: well past the frames the sink has room for, and past a batch,
    // so the batched run also crosses a flush boundary inside the over-deep subtree.
    let depth = 200
    let json = Array(
      (String(repeating: #"{"child":"#, count: depth)
        + #"{"name":"leaked"}"#
        + String(repeating: "}", count: depth)).utf8
    )

    let batched = Self.withDepthNode { storage in
      var sink = StreamEventBatchingSink(
        consumer: PartialReplayConsumer(sink: PartialSink(root: storage))
      )
      json.withUnsafeBufferPointer { Self.feed($0, into: &sink) }
      return sink.streamFailure?.reason
    }
    expectNoDifference(batched.failure, .depthExceeded)
    expectNoDifference(batched.name, "")

    let direct = Self.withDepthNode { storage in
      var sink = PartialSink(root: storage)
      json.withUnsafeBufferPointer { Self.feed($0, into: &sink) }
      return sink.streamFailure?.reason
    }
    expectNoDifference(direct.failure, .depthExceeded)
    expectNoDifference(direct.name, "")
  }

  private static func withDepthNode(
    _ body: (UnsafeMutablePointer<DepthNode>) -> StreamSinkFailure.Reason?
  ) -> (failure: StreamSinkFailure.Reason?, name: String) {
    let storage = UnsafeMutablePointer<DepthNode>.allocate(capacity: 1)
    storage.initialize(to: DepthNode.streamInitialValue())
    defer {
      storage.deinitialize(count: 1)
      storage.deallocate()
    }
    let failure = body(storage)
    return (failure, String(storage.pointee.name))
  }

  // The sink is fed directly rather than through `JSONParser`: the parser rejects the depth one
  // container before the sink can overflow, so its cap would hide the case under test. Only the
  // token shapes this one document contains are recognised, and `streamFailure` is deliberately
  // not polled -- that is the driver shape this is about.
  private static func feed<Sink: StreamParseSink & ~Copyable>(
    _ json: UnsafeBufferPointer<UInt8>, into sink: inout Sink
  ) {
    let quote = UInt8(ascii: "\"")
    var index = 0
    while index < json.count {
      switch json[index] {
      case UInt8(ascii: "{"):
        _ = sink.beginObject()
        index += 1
      case UInt8(ascii: "}"):
        sink.endObject()
        index += 1
      case quote:
        var end = index + 1
        while json[end] != quote { end += 1 }
        let body = UnsafeBufferPointer(
          start: json.baseAddress! + index + 1, count: end - index - 1
        )
        if end + 1 < json.count, json[end + 1] == UInt8(ascii: ":") {
          sink.key(Span(_unsafeElements: body))
        } else {
          sink.string(Span(_unsafeElements: body))
        }
        index = end + 1
      default:
        index += 1
      }
    }
    sink.commit()
  }

  @Test
  func `Grammar errors are the parser's and keep their reason`() {
    self.differential(#"{"values":[1.5,]}"#)
    self.differential(#"{"values":[01]}"#)
    self.differential(#"{"values" 1}"#)
  }
}
