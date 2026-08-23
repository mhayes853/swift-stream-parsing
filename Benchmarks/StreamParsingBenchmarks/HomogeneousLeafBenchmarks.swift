import Benchmark
import StreamParsingCore

// Homogeneous containers are the one place the destination schema knows the type of every value
// before a token arrives. Keep arrays and dictionaries side by side here: both route through the
// same scalar schema, while only the operation that opens stable storage differs.

private enum HomogeneousLeafPayloads {
  static let count = 2_048

  static let doublesArray = array { index in
    index.isMultiple(of: 2) ? "\(index).125" : "-\(index).875"
  }
  static let doublesDictionary = dictionary { index in
    index.isMultiple(of: 2) ? "\(index).125" : "-\(index).875"
  }
  static let integersArray = array { index in
    index.isMultiple(of: 2) ? "\(index)" : "-\(index)"
  }

  static let booleansArray = array { $0.isMultiple(of: 3) ? "true" : "false" }
  static let booleansDictionary = dictionary { $0.isMultiple(of: 3) ? "true" : "false" }

  static let stringsArray = array { "\"value_\($0)\"" }
  static let stringsDictionary = dictionary { "\"value_\($0)\"" }

  static let optionalNumbersArray = array { index in
    index.isMultiple(of: 4) ? "null" : "\(index)"
  }
  static let optionalNumbersDictionary = dictionary { index in
    index.isMultiple(of: 4) ? "null" : "\(index)"
  }

  private static func array(value: (Int) -> String) -> [UInt8] {
    Array(("[" + (0..<Self.count).map(value).joined(separator: ",") + "]").utf8)
  }

  private static func dictionary(value: (Int) -> String) -> [UInt8] {
    let members = (0..<Self.count).map { index in
      "\"key_\(index)\":" + value(index)
    }
    return Array(("{" + members.joined(separator: ",") + "}").utf8)
  }
}

private func addHomogeneousLeafRow<Value: StreamParseableRoot>(
  _ name: String,
  payload: [UInt8],
  as type: Value.Type
) {
  Benchmark("Leaf \(name) - bulk", configuration: payloadConfiguration) { benchmark in
    measurePayloadThroughput(benchmark, payload: payload) {
      blackHole(expectParses { try streamBulkDiscarding(payload, as: Value.self) })
    }
  }
}

func homogeneousLeafBenchmarks() {
  let doublesArray = expectParses {
    try streamBulkDiscarding(
      HomogeneousLeafPayloads.doublesArray,
      as: StreamArray<Double>.self
    )
  }
  precondition(doublesArray.count == HomogeneousLeafPayloads.count)

  let doublesDictionary = expectParses {
    try streamBulkDiscarding(
      HomogeneousLeafPayloads.doublesDictionary,
      as: StreamDictionary<Double>.self
    )
  }
  precondition(doublesDictionary.count == HomogeneousLeafPayloads.count)

  let integersArray = expectParses {
    try streamBulkDiscarding(
      HomogeneousLeafPayloads.integersArray,
      as: StreamArray<Int>.self
    )
  }
  precondition(integersArray.count == HomogeneousLeafPayloads.count)

  let stringsArray = expectParses {
    try streamBulkDiscarding(
      HomogeneousLeafPayloads.stringsArray,
      as: StreamArray<StreamString>.self
    )
  }
  precondition(stringsArray.count == HomogeneousLeafPayloads.count)

  let optionalDictionary = expectParses {
    try streamBulkDiscarding(
      HomogeneousLeafPayloads.optionalNumbersDictionary,
      as: StreamDictionary<Int?>.self
    )
  }
  precondition(optionalDictionary.count == HomogeneousLeafPayloads.count)
  precondition(optionalDictionary["key_0"]! == nil)
  precondition(optionalDictionary["key_1"] == 1)

  addHomogeneousLeafRow(
    "Array Double", payload: HomogeneousLeafPayloads.doublesArray,
    as: StreamArray<Double>.self
  )
  addHomogeneousLeafRow(
    "Dictionary Double", payload: HomogeneousLeafPayloads.doublesDictionary,
    as: StreamDictionary<Double>.self
  )
  addHomogeneousLeafRow(
    "Array Int", payload: HomogeneousLeafPayloads.integersArray,
    as: StreamArray<Int>.self
  )
  addHomogeneousLeafRow(
    "Array Bool", payload: HomogeneousLeafPayloads.booleansArray,
    as: StreamArray<Bool>.self
  )
  addHomogeneousLeafRow(
    "Dictionary Bool", payload: HomogeneousLeafPayloads.booleansDictionary,
    as: StreamDictionary<Bool>.self
  )
  addHomogeneousLeafRow(
    "Array String", payload: HomogeneousLeafPayloads.stringsArray,
    as: StreamArray<StreamString>.self
  )
  addHomogeneousLeafRow(
    "Dictionary String", payload: HomogeneousLeafPayloads.stringsDictionary,
    as: StreamDictionary<StreamString>.self
  )
  addHomogeneousLeafRow(
    "Array Optional Int", payload: HomogeneousLeafPayloads.optionalNumbersArray,
    as: StreamArray<Int?>.self
  )
  addHomogeneousLeafRow(
    "Dictionary Optional Int", payload: HomogeneousLeafPayloads.optionalNumbersDictionary,
    as: StreamDictionary<Int?>.self
  )
}
