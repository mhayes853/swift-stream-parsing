import Benchmark
import StreamParsing
import StreamParsingCore

// `StreamString` as many short values: the per-value costs (opening a member or element, the
// inline-test append, teardown) that the real-world rows bury under parsing. These were the
// `Inline string ... StreamString` rows, kept when `StreamInlineString` was removed; see
// NEW_ARCHITECTURE.md, "`StreamString` holds one reference".
private enum StringValuePayloads {
  static let count = 2_048

  // Values in the 8-16 byte range, inside `StreamString`'s 64-byte inline buffer.
  static let shortStrings = array { #""value_\#($0)""# }
  static let shortStringsDictionary = dictionary { #""value_\#($0)""# }

  // ~96 bytes each: past the inline buffer, so every value takes a heap block.
  static let mediumStrings = array { index in
    #""\#(String(repeating: "m", count: 88))_\#(index)""#
  }

  private static func array(value: (Int) -> String) -> [UInt8] {
    Array(("[" + (0..<Self.count).map(value).joined(separator: ",") + "]").utf8)
  }

  private static func dictionary(value: (Int) -> String) -> [UInt8] {
    let members = (0..<Self.count).map { #""key_\#($0)":"# + value($0) }
    return Array(("{" + members.joined(separator: ",") + "}").utf8)
  }
}

private func addStringValueRow<Value: StreamParseable>(
  _ name: String,
  payload: [UInt8],
  as type: Value.Type,
  includeByteByByte: Bool = false,
  includeSnapshot: Bool = false
) {
  Benchmark("String values \(name) - bulk", configuration: payloadConfiguration) { benchmark in
    measurePayloadThroughput(benchmark, payload: payload) {
      blackHole(expectParses { try streamBulkDiscarding(payload, as: Value.self) })
    }
  }

  if includeByteByByte {
    Benchmark("String values \(name) - byte by byte", configuration: payloadConfiguration) {
      benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(expectParses { try streamDiscarding(payload, as: Value.self) })
      }
    }
  }

  if includeSnapshot {
    Benchmark("String values \(name) - snapshot per byte", configuration: payloadConfiguration) {
      benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(expectParses { try streamSnapshotting(payload, as: Value.self) })
      }
    }
  }
}

// Three short string members per record: the field-table route.
@StreamParseable
struct StringFieldRecord: Equatable {
  var id: StreamString = StreamString()
  var name: StreamString = StreamString()
  var kind: StreamString = StreamString()
}

private let fieldRecords: [UInt8] = Array(
  ("[" + (0..<2_048).map { index in
    #"{"id":"id_\#(index)","name":"name value \#(index)","kind":"kind_\#(index % 8)"}"#
  }.joined(separator: ",") + "]").utf8
)

func stringValueBenchmarks() {
  // A model that stopped matching would turn a throughput row into a discard row, so the shapes
  // are validated once at registration, outside every measured region.
  let fields = expectParses {
    try streamBulkDiscarding(fieldRecords, as: StreamArray<StringFieldRecord.Partial>.self)
  }
  precondition(fields.count == 2_048)
  let short = expectParses {
    try streamBulkDiscarding(
      StringValuePayloads.shortStrings, as: StreamArray<StreamString>.self
    )
  }
  precondition(short.count == StringValuePayloads.count)
  precondition(short[1] == "value_1")

  addStringValueRow(
    "Fields", payload: fieldRecords, as: StreamArray<StringFieldRecord.Partial>.self,
    includeByteByByte: true, includeSnapshot: true
  )
  addStringValueRow(
    "Array short", payload: StringValuePayloads.shortStrings,
    as: StreamArray<StreamString>.self,
    includeByteByByte: true, includeSnapshot: true
  )
  addStringValueRow(
    "Dictionary short", payload: StringValuePayloads.shortStringsDictionary,
    as: StreamDictionary<StreamString>.self
  )
  addStringValueRow(
    "Array medium", payload: StringValuePayloads.mediumStrings,
    as: StreamArray<StreamString>.self, includeByteByByte: true
  )
}
