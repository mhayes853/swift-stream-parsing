import StreamParsingCore

// A test sink written per event. The parser's one requirement is `events(_:)`; this unrolls a
// batch into the call-per-event form the tests are written in, stopping at the first failure
// the way the default did when it was the protocol's.
protocol EventSink: StreamParseSink {
  mutating func beginObject()
  mutating func endObject()
  mutating func beginArray()
  mutating func endArray()
  mutating func key(_ bytes: Span<UInt8>)
  mutating func stringBegin()
  mutating func stringChunk(_ bytes: Span<UInt8>)
  mutating func stringEnd()
  mutating func number(_ bytes: Span<UInt8>, info: NumberInfo)
  mutating func boolean(_ value: Bool)
  mutating func null()
}

extension EventSink {
  mutating func events(_ batch: borrowing StreamEventBatch) -> Int {
    unrollEvents(batch, into: &self)
  }
}

func unrollEvents<S: EventSink>(_ batch: borrowing StreamEventBatch, into sink: inout S) -> Int {
  let records = batch.records
  var index = 0
  while index < batch.count {
    let record = records[index]
    switch record.kind {
    case .beginObject: sink.beginObject()
    case .endObject: sink.endObject()
    case .beginArray: sink.beginArray()
    case .endArray: sink.endArray()
    case .key: sink.key(batch.bytes(of: index))
    case .stringBegin: sink.stringBegin()
    case .stringChunk: sink.stringChunk(batch.bytes(of: index))
    case .stringEnd: sink.stringEnd()
    case .number: sink.number(batch.bytes(of: index), info: batch.info(of: index))
    case .boolean: sink.boolean(record.booleanValue)
    case .null: sink.null()
    case .string:
      sink.stringBegin()
      if sink.streamFailure != nil { return index }
      if record.length > 0 { sink.stringChunk(batch.bytes(of: index)) }
      sink.stringEnd()
    }
    if sink.streamFailure != nil { return index }
    index &+= 1
  }
  return index
}
