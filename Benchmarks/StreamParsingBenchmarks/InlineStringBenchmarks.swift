import Benchmark
import StreamParsing
import StreamParsingCore

// `StreamInlineString` against the `StreamString` it is an alternative to, on the same payloads.
//
// Two axes matter and they pull in opposite directions, so both are here rather than a single
// summary row:
//
//   - **Append.** The inline append is a compare and a memcpy through the layout-erased route,
//     with no uniqueness check and no branch between representations. It should win, and by more
//     as chunks get smaller, which is why the byte-by-byte rows exist.
//   - **Copy.** A snapshot of an inline value copies `capacity` bytes; a snapshot of a
//     `StreamString` copies two references. The `snapshot per byte` rows are where that shows up,
//     and they are the reason the capacity sweep runs to 512: the crossover is the number this
//     type's usable range depends on.
private enum InlineStringPayloads {
  static let count = 2_048

  // Values in the 8-16 byte range: what a bounded field actually holds, and small enough that
  // every capacity under test accepts them.
  static let shortStrings = array { #""value_\#($0)""# }
  static let shortStringsDictionary = dictionary { #""value_\#($0)""# }

  // ~96 bytes each: past `StreamString`'s 64-byte inline buffer, so that type takes a heap block
  // per value here and this type still does not.
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

private func addInlineStringRow<Value: StreamParseableRoot>(
  _ name: String,
  payload: [UInt8],
  as type: Value.Type,
  includeByteByByte: Bool = false,
  includeSnapshot: Bool = false
) {
  Benchmark("Inline string \(name) - bulk", configuration: payloadConfiguration) { benchmark in
    measurePayloadThroughput(benchmark, payload: payload) {
      blackHole(expectParses { try streamBulkDiscarding(payload, as: Value.self) })
    }
  }

  if includeByteByByte {
    Benchmark("Inline string \(name) - byte by byte", configuration: payloadConfiguration) {
      benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(expectParses { try streamDiscarding(payload, as: Value.self) })
      }
    }
  }

  if includeSnapshot {
    Benchmark("Inline string \(name) - snapshot per byte", configuration: payloadConfiguration) {
      benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(expectParses { try streamSnapshotting(payload, as: Value.self) })
      }
    }
  }
}

// The position an inline string is actually meant for: a bounded field of a generated partial.
// The container rows above put it where `StreamString` has a closed sink route and it does not,
// which measures the route gap rather than the storage.
@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
@StreamParseable
struct InlineFieldRecord: Equatable {
  var id: StreamInlineString<16> = StreamInlineString<16>()
  var name: StreamInlineString<32> = StreamInlineString<32>()
  var kind: StreamInlineString<16> = StreamInlineString<16>()
}

@StreamParseable
struct DynamicFieldRecord: Equatable {
  var id: StreamString = StreamString()
  var name: StreamString = StreamString()
  var kind: StreamString = StreamString()
}

private let fieldRecords: [UInt8] = Array(
  ("[" + (0..<2_048).map { index in
    #"{"id":"id_\#(index)","name":"name value \#(index)","kind":"kind_\#(index % 8)"}"#
  }.joined(separator: ",") + "]").utf8
)

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
func inlineStringFieldBenchmarks() {
  let inlineFields = expectParses {
    try streamBulkDiscarding(fieldRecords, as: StreamArray<InlineFieldRecord.Partial>.self)
  }
  precondition(inlineFields.count == 2_048)
  let dynamicFields = expectParses {
    try streamBulkDiscarding(fieldRecords, as: StreamArray<DynamicFieldRecord.Partial>.self)
  }
  precondition(dynamicFields.count == 2_048)

  addInlineStringRow(
    "Fields inline", payload: fieldRecords,
    as: StreamArray<InlineFieldRecord.Partial>.self,
    includeByteByByte: true, includeSnapshot: true
  )
  addInlineStringRow(
    "Fields StreamString", payload: fieldRecords,
    as: StreamArray<DynamicFieldRecord.Partial>.self,
    includeByteByByte: true, includeSnapshot: true
  )
}

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
func inlineStringBenchmarks() {
  inlineStringFieldBenchmarks()
  // A model that stopped matching would turn a throughput row into a discard row, so the shapes
  // are validated once at registration, outside every measured region.
  let inline32 = expectParses {
    try streamBulkDiscarding(
      InlineStringPayloads.shortStrings, as: StreamArray<StreamInlineString<32>>.self
    )
  }
  precondition(inline32.count == InlineStringPayloads.count)
  precondition(inline32[1] == "value_1")

  let dynamic = expectParses {
    try streamBulkDiscarding(
      InlineStringPayloads.shortStrings, as: StreamArray<StreamString>.self
    )
  }
  precondition(dynamic.count == InlineStringPayloads.count)

  let inlineDictionary = expectParses {
    try streamBulkDiscarding(
      InlineStringPayloads.shortStringsDictionary,
      as: StreamDictionary<StreamInlineString<32>>.self
    )
  }
  precondition(inlineDictionary.count == InlineStringPayloads.count)

  let medium = expectParses {
    try streamBulkDiscarding(
      InlineStringPayloads.mediumStrings, as: StreamArray<StreamInlineString<128>>.self
    )
  }
  precondition(medium.count == InlineStringPayloads.count)

  // The pair the whole design rests on: same payload, same container, one capacity each.
  addInlineStringRow(
    "Array 32 short", payload: InlineStringPayloads.shortStrings,
    as: StreamArray<StreamInlineString<32>>.self,
    includeByteByByte: true, includeSnapshot: true
  )
  addInlineStringRow(
    "Array StreamString short", payload: InlineStringPayloads.shortStrings,
    as: StreamArray<StreamString>.self,
    includeByteByByte: true, includeSnapshot: true
  )

  // The capacity sweep: appends cost the same at every capacity, copies do not.
  addInlineStringRow(
    "Array 64 short", payload: InlineStringPayloads.shortStrings,
    as: StreamArray<StreamInlineString<64>>.self, includeSnapshot: true
  )
  addInlineStringRow(
    "Array 128 short", payload: InlineStringPayloads.shortStrings,
    as: StreamArray<StreamInlineString<128>>.self, includeSnapshot: true
  )
  addInlineStringRow(
    "Array 512 short", payload: InlineStringPayloads.shortStrings,
    as: StreamArray<StreamInlineString<512>>.self, includeSnapshot: true
  )

  addInlineStringRow(
    "Dictionary 32 short", payload: InlineStringPayloads.shortStringsDictionary,
    as: StreamDictionary<StreamInlineString<32>>.self
  )
  addInlineStringRow(
    "Dictionary StreamString short", payload: InlineStringPayloads.shortStringsDictionary,
    as: StreamDictionary<StreamString>.self
  )

  // Past `StreamString`'s inline buffer, where that type allocates per value and this one does
  // not: the case the malloc columns are for.
  addInlineStringRow(
    "Array 128 medium", payload: InlineStringPayloads.mediumStrings,
    as: StreamArray<StreamInlineString<128>>.self, includeByteByByte: true
  )
  addInlineStringRow(
    "Array StreamString medium", payload: InlineStringPayloads.mediumStrings,
    as: StreamArray<StreamString>.self, includeByteByByte: true
  )
}
