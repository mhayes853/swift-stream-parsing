import Benchmark
import StreamParsing
import StreamParsingCore

// Repeated small arrays, rather than one large fixed array: this is the case where inline storage
// removes one allocation per occurrence without turning the containing value into an enormous
// object that is expensive to copy.
private enum FixedArrayPayloads {
  static let recordCount = 512
  static let width = 4

  static let strings = nestedArray { record, element in
    #""s_\#(record)_\#(element)""#
  }
  static let booleans = nestedArray { record, element in
    (record &+ element).isMultiple(of: 3) ? "true" : "false"
  }
  static let numbers = nestedArray { record, element in
    "\(record).\(element + 1)25"
  }
  static let objects = nestedArray { record, element in
    #"{"id":\#(record * width + element),"name":"o_\#(record)_\#(element)","active":\#((record + element).isMultiple(of: 2))}"#
  }

  static let composite = Array(
    ("[" + (0..<recordCount).map { record in
      let strings = elements { element in #""s_\#(record)_\#(element)""# }
      let booleans = elements { element in
        (record &+ element).isMultiple(of: 3) ? "true" : "false"
      }
      let numbers = elements { element in "\(record).\(element + 1)25" }
      let objects = elements { element in
        #"{"id":\#(record * width + element),"name":"o_\#(record)_\#(element)","active":\#((record + element).isMultiple(of: 2))}"#
      }
      return #"{"strings":\#(strings),"booleans":\#(booleans),"numbers":\#(numbers),"objects":\#(objects)}"#
    }.joined(separator: ",") + "]").utf8
  )

  private static func nestedArray(_ value: (Int, Int) -> String) -> [UInt8] {
    Array(
      ("[" + (0..<recordCount).map { record in
        elements { value(record, $0) }
      }.joined(separator: ",") + "]").utf8
    )
  }

  private static func elements(_ value: (Int) -> String) -> String {
    "[" + (0..<width).map(value).joined(separator: ",") + "]"
  }
}

@available(macOS 26.0, *)
@StreamParseable
private struct FixedArrayBenchmarkObject {
  var id: Int = 0
  var name: String = ""
  var active: Bool = false
}

@available(macOS 26.0, *)
@StreamParseable
private struct DynamicArrayBenchmarkRecord {
  var strings: [String] = []
  var booleans: [Bool] = []
  var numbers: [Double] = []
  var objects: [FixedArrayBenchmarkObject] = []
}

@available(macOS 26.0, *)
@StreamParseable
private struct InlineArrayBenchmarkRecord {
  var strings: InlineArray<4, String> = InlineArray(repeating: "")
  var booleans: InlineArray<4, Bool> = InlineArray(repeating: false)
  var numbers: InlineArray<4, Double> = InlineArray(repeating: 0)
  var objects: InlineArray<4, FixedArrayBenchmarkObject> = InlineArray {
    _ in FixedArrayBenchmarkObject()
  }
}

@available(macOS 26.0, *)
private func addFixedArrayRow<Value: StreamParseableRoot>(
  _ name: String,
  payload: [UInt8],
  as type: Value.Type,
  chunk: Int = .max
) {
  Benchmark("Fixed array \(name)", configuration: payloadConfiguration) { benchmark in
    measurePayloadThroughput(benchmark, payload: payload) {
      blackHole(
        expectParses {
          try streamDiscardingChunks(payload, chunk: chunk, as: Value.self)
        }
      )
    }
  }
}

@available(macOS 26.0, *)
func inlineArrayBenchmarks() {
  typealias Object = FixedArrayBenchmarkObject.Partial

  let fixedStrings = expectParses {
    try streamBulkDiscarding(
      FixedArrayPayloads.strings,
      as: StreamArray<InlineArray<4, StreamString>>.self
    )
  }
  precondition(fixedStrings.count == FixedArrayPayloads.recordCount)
  precondition(fixedStrings[0][3] == "s_0_3")

  let fixedComposite = expectParses {
    try streamBulkDiscarding(
      FixedArrayPayloads.composite,
      as: StreamArray<InlineArrayBenchmarkRecord.Partial>.self
    )
  }
  precondition(fixedComposite.count == FixedArrayPayloads.recordCount)
  precondition(fixedComposite[0].numbers?[3] == 0.425)
  precondition(fixedComposite[0].objects?[3].id == 3)

  addFixedArrayRow(
    "strings - dynamic", payload: FixedArrayPayloads.strings,
    as: StreamArray<StreamArray<StreamString>>.self
  )
  addFixedArrayRow(
    "strings - inline", payload: FixedArrayPayloads.strings,
    as: StreamArray<InlineArray<4, StreamString>>.self
  )
  addFixedArrayRow(
    "booleans - dynamic", payload: FixedArrayPayloads.booleans,
    as: StreamArray<StreamArray<Bool>>.self
  )
  addFixedArrayRow(
    "booleans - inline", payload: FixedArrayPayloads.booleans,
    as: StreamArray<InlineArray<4, Bool>>.self
  )
  addFixedArrayRow(
    "numbers - dynamic", payload: FixedArrayPayloads.numbers,
    as: StreamArray<StreamArray<Double>>.self
  )
  addFixedArrayRow(
    "numbers - inline", payload: FixedArrayPayloads.numbers,
    as: StreamArray<InlineArray<4, Double>>.self
  )
  addFixedArrayRow(
    "objects - dynamic", payload: FixedArrayPayloads.objects,
    as: StreamArray<StreamArray<Object>>.self
  )
  addFixedArrayRow(
    "objects - inline", payload: FixedArrayPayloads.objects,
    as: StreamArray<InlineArray<4, Object>>.self
  )
  addFixedArrayRow(
    "composite - dynamic", payload: FixedArrayPayloads.composite,
    as: StreamArray<DynamicArrayBenchmarkRecord.Partial>.self
  )
  addFixedArrayRow(
    "composite - inline", payload: FixedArrayPayloads.composite,
    as: StreamArray<InlineArrayBenchmarkRecord.Partial>.self
  )
  addFixedArrayRow(
    "composite 64B - dynamic", payload: FixedArrayPayloads.composite,
    as: StreamArray<DynamicArrayBenchmarkRecord.Partial>.self,
    chunk: 64
  )
  addFixedArrayRow(
    "composite 64B - inline", payload: FixedArrayPayloads.composite,
    as: StreamArray<InlineArrayBenchmarkRecord.Partial>.self,
    chunk: 64
  )
}
