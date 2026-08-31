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

// Replays every delivered batch into a directly held PartialSink: the shape a cross-boundary
// consumer has, minus the boundary.
private struct PartialReplayConsumer: StreamEventBatchConsumer, ~Copyable {
  var sink: PartialSink

  var streamFailure: StreamSinkFailure? { self.sink.streamFailure }

  mutating func events(_ batch: borrowing StreamEventBatch) -> Int {
    self.sink.events(batch)
  }
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

  @Test
  func `Grammar errors are the parser's and keep their reason`() {
    self.differential(#"{"values":[1.5,]}"#)
    self.differential(#"{"values":[01]}"#)
    self.differential(#"{"values" 1}"#)
  }
}
