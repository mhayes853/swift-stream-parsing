import CustomDump
import StreamParsing
import Testing

private enum Halving: StreamCompletedValueConversion {
  typealias Source = Int
  static func convertToValue(_ source: borrowing Source.View) -> Int { source.value * 2 }
  static func convertFromValue(_ value: Int) -> Int { value / 2 }
}

// `@StreamParseableMember` is two declarations whose arguments are all optional, rather than one
// per combination. Every combination written here has to resolve to one of them.
@StreamParseable
private struct EveryMemberAttributeForm {
  @StreamParseableMember(key: "k")
  var key: Int = 0

  @StreamParseableMember(keyNames: ["a", "b"])
  var names: Int = 0

  @StreamParseableMember(initialCapacity: 4)
  var capacity: [Int] = []

  @StreamParseableMember(partialStrings: .string)
  var string: String = ""

  @StreamParseableMember(key: "kc", initialCapacity: 4)
  var keyAndCapacity: [Int] = []

  @StreamParseableMember(keyNames: ["na", "nb"], initialCapacity: 4)
  var namesAndCapacity: [Int] = []

  @StreamParseableMember(key: "ks", partialStrings: .string)
  var keyAndString: String = ""

  @StreamParseableMember(initialCapacity: 8, partialStrings: .string)
  var capacityAndString: String = ""

  @StreamParseableMember(key: "kcs", initialCapacity: 8, partialStrings: .string)
  var everyOption: String = ""

  @StreamParseableMember(completedConversion: Halving.self)
  var converted: Int = 0

  @StreamParseableMember(key: "kv", completedConversion: Halving.self)
  var keyAndConverted: Int = 0

  @StreamParseableMember(keyNames: ["va", "vb"], completedConversion: Halving.self)
  var namesAndConverted: Int = 0

  // Two attributes may split the arguments between them.
  @StreamParseableMember(key: "split")
  @StreamParseableMember(initialCapacity: 2)
  var split: [Int] = []
}

@Suite
struct `Member attribute form tests` {
  @Test
  func `Every Combination Of Arguments Reads Its Keys`() throws {
    let json = """
      {"k":1,"b":2,"capacity":[3],"string":"s","kc":[4],"nb":[5],"ks":"t","capacityAndString":"u",\
      "kcs":"v","converted":6,"kv":7,"vb":8,"split":[9]}
      """
    var stream = PartialsStream<EveryMemberAttributeForm>(from: .json())
    try stream.next(Array(json.utf8))
    let partial = try stream.finish()

    expectNoDifference(partial.key, 1)
    expectNoDifference(partial.names, 2)
    expectNoDifference(partial.capacity.map { Array($0) }, [3])
    expectNoDifference(partial.string, "s")
    expectNoDifference(partial.keyAndCapacity.map { Array($0) }, [4])
    expectNoDifference(partial.namesAndCapacity.map { Array($0) }, [5])
    expectNoDifference(partial.keyAndString, "t")
    expectNoDifference(partial.capacityAndString, "u")
    expectNoDifference(partial.everyOption, "v")
    expectNoDifference(partial.converted?.value, 12)
    expectNoDifference(partial.keyAndConverted?.value, 14)
    expectNoDifference(partial.namesAndConverted?.value, 16)
    expectNoDifference(partial.split.map { Array($0) }, [9])
  }
}
