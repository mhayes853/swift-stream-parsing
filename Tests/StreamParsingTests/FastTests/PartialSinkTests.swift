import CustomDump
import Testing

import StreamParsing
import StreamParsingCore

@StreamParseable
struct SinkAddress: Equatable {
  var city: String = ""
  var postalCode: String = ""
}

@StreamParseable
struct SinkUser: Equatable {
  var id: Int = 0
  var name: String = ""
  var active: Bool = false
  var address: SinkAddress = SinkAddress()
  var scores: [Int] = []
  var settings: [String: SinkAddress] = [:]
  var counts: [String: Int] = [:]
}

@StreamParseable
struct SinkCapacityMembers: Equatable {
  @StreamParseableMember(initialCapacity: 64)
  var scores: [Int] = []

  @StreamParseableMember(key: "counts_by_name", initialCapacity: 32)
  var counts: [String: Int] = [:]

  @StreamParseableMember(key: "generic_scores", initialCapacity: 4)
  var genericScores: Array<Int> = []

  @StreamParseableMember(key: "direct_counts", initialCapacity: 4)
  var directCounts: StreamDictionary<Int> = [:]
}

typealias SinkCapacityArrayAlias = [Int]
typealias SinkCapacityDictionaryAlias = [String: Int]
typealias SinkCapacityStringAlias = String

@StreamParseable
struct SinkCapacityLiteralAndQualificationMembers: Equatable {
  @StreamParseableMember(initialCapacity: 0x40)
  var hexadecimal: [Int] = []

  @StreamParseableMember(initialCapacity: 0o100)
  var octal: Swift.Optional<Swift.Array<Int>> = []

  @StreamParseableMember(initialCapacity: 0b100_0000)
  var binary: StreamParsingCore.StreamArray<Int> = []

  @StreamParseableMember(key: "no_hint", initialCapacity: nil)
  var noHint: [Int] = []

  @StreamParseableMember(initialCapacity: 3_600)
  var aliasedArray: SinkCapacityArrayAlias = []

  @StreamParseableMember(initialCapacity: 32)
  var aliasedDictionary: SinkCapacityDictionaryAlias = [:]
}

@StreamParseable
struct SinkCapacityStringMembers: Equatable {
  @StreamParseableMember(initialCapacity: 1_024)
  var text: String = ""

  @StreamParseableMember(key: "aliased_text", initialCapacity: 0x400)
  var aliasedText: SinkCapacityStringAlias = ""

  @StreamParseableMember(initialCapacity: 128)
  var optionalText: String?
}

@StreamParseable(partialMembers: .streamInitialValue)
struct SinkInitializedCapacityString: Equatable {
  @StreamParseableMember(initialCapacity: 1_024)
  var text: String = ""
}

// Optional in the source declaration, which is a different axis from the partial members mode:
// the mode decides whether a *non*-optional property becomes optional in the `Partial`, and a
// property that is already optional is already there. Storing both — the member as `Int??` while
// every schema emitted for it described `Int` — meant no `streamApply` overload matched, so a
// scalar was rejected as a type mismatch and a container silently dropped its contents. Only
// `null` worked, because a double optional is still `StreamNullable`.
@StreamParseable
struct SinkOptionalMembers: Equatable {
  var count: Int?
  var name: String?
  var flag: Optional<Bool>
  var address: SinkAddress?
  var scores: [Int]?
  var counts: [String: Int]?
}

extension SinkAddress.Partial: Equatable {}
extension SinkOptionalMembers.Partial: Equatable {}

// Optional in the *element* or *value* position, which is a different axis again from an optional
// member. The storage is `StreamArray<StreamString?>`, whose `streamInitialValue()` is `nil`, and
// the element schema used to be built from the wrapped type — so the first token written to an
// element wrote through the `.none` representation and took the process with it. All three of
// these segfaulted.
@StreamParseable(partialMembers: .streamInitialValue)
struct SinkInitializedContainers: Equatable {
  var scores: [Int] = []
}

@StreamParseable
struct SinkOptionalElements: Equatable {
  var tags: [String?]
  var counts: [Int?]
  var rows: [SinkAddress?]
  var meta: [String: String?]
  var lookup: [String: SinkAddress?]
}

extension SinkOptionalElements.Partial: Equatable {}

typealias SinkAliasedOptionals = [String?]

// The same type, spelled four ways. `fieldShape` reads syntax, so only the sugared forms reach the
// macro's optional builders; the rest resolve through `_streamContainerSchema` and the type. They
// have to agree, and before `streamElementSchema` they did not: the sugared ones ran at
// 32 ns/element and the others at 77, through `Optional`'s materialising wrapper. A typealias
// cannot be fixed in the macro at all — it has no type information to resolve one with.
@StreamParseable
struct SinkOptionalSpellings: Equatable {
  var sugared: [Int?]
  var generic: Array<Int?>
  var aliased: SinkAliasedOptionals
  var nested: [[Int?]]
  var genericDictionary: Dictionary<String, Int?>
}

@Suite
struct `Partial sink tests` {
  @Test
  func `Capacity Hints Materialize Containers Lazily`() throws {
    var absent = SinkCapacityMembers.Partial()
    try parsePartial("{}", into: &absent)
    expectNoDifference(absent.scores, nil)
    expectNoDifference(absent.counts, nil)
    expectNoDifference(absent.genericScores, nil)
    expectNoDifference(absent.directCounts, nil)

    var empty = SinkCapacityMembers.Partial()
    try parsePartial(
      #"{"scores":[],"counts_by_name":{},"generic_scores":[],"direct_counts":{}}"#,
      into: &empty
    )
    expectNoDifference(empty.scores, [])
    expectNoDifference(empty.counts?.count, 0)
    expectNoDifference(empty.genericScores, [])
    expectNoDifference(empty.directCounts?.count, 0)
  }

  @Test
  func `Capacity Hints Do Not Limit Container Growth`() throws {
    var value = SinkCapacityMembers.Partial()
    try parsePartial(
      #"{"scores":[1,2,3],"counts_by_name":{"one":1,"two":2},"generic_scores":[4,5],"direct_counts":{"three":3}}"#,
      into: &value
    )
    expectNoDifference(value.scores, [1, 2, 3])
    expectNoDifference(value.counts?["one"], 1)
    expectNoDifference(value.counts?["two"], 2)
    expectNoDifference(value.genericScores, [4, 5])
    expectNoDifference(value.directCounts?["three"], 3)
  }

  @Test
  func `Capacity Hints Accept Swift Integer Literals And Qualified Containers`() throws {
    var value = SinkCapacityLiteralAndQualificationMembers.Partial()
    try parsePartial(
      #"{"hexadecimal":[1],"octal":[2],"binary":[3],"no_hint":[4],"aliasedArray":[5,6],"aliasedDictionary":{"seven":7}}"#,
      into: &value
    )

    expectNoDifference(value.hexadecimal, [1])
    expectNoDifference(value.octal, [2])
    expectNoDifference(value.binary, [3])
    expectNoDifference(value.noHint, [4])
    expectNoDifference(value.aliasedArray, [5, 6])
    expectNoDifference(value.aliasedDictionary?["seven"], 7)
  }

  @Test
  func `Capacity Hints Apply To String Storage And Aliases`() throws {
    var value = SinkCapacityStringMembers.Partial()
    try parsePartial(
      #"{"text":"first","text":" second","aliased_text":"alias","optionalText":"optional"}"#,
      into: &value
    )

    expectNoDifference(value.text, "first second")
    expectNoDifference(value.aliasedText, "alias")
    expectNoDifference(value.optionalText, "optional")

    var initialized = SinkInitializedCapacityString.Partial()
    try parsePartial(#"{"text":"initialized"}"#, into: &initialized)
    expectNoDifference(initialized.text, "initialized")
  }

  @Test
  func `Routes scalars into matching fields`() throws {
    var user = SinkUser.Partial()
    try parsePartial(#"{"id":42,"name":"Blob","active":true}"#, into: &user)
    expectNoDifference(user.id, 42)
    expectNoDifference(user.name, "Blob")
    expectNoDifference(user.active, true)
  }

  @Test
  func `Ignores keys the destination does not have`() throws {
    var user = SinkUser.Partial()
    try parsePartial(#"{"id":1,"unknown":"x","name":"Blob"}"#, into: &user)
    expectNoDifference(user.id, 1)
    expectNoDifference(user.name, "Blob")
  }

  // An unknown key whose value is a container must not have its contents routed to the parent.
  @Test
  func `Skips containers under unknown keys`() throws {
    var user = SinkUser.Partial()
    try parsePartial(#"{"extra":{"id":999,"name":"wrong"},"id":1}"#, into: &user)
    expectNoDifference(user.id, 1)
    expectNoDifference(user.name, nil)
  }

  @Test
  func `Routes into nested objects`() throws {
    var user = SinkUser.Partial()
    try parsePartial(#"{"address":{"city":"Brooklyn","postalCode":"11201"}}"#, into: &user)
    expectNoDifference(user.address?.city, "Brooklyn")
    expectNoDifference(user.address?.postalCode, "11201")
  }

  @Test
  func `Routes into arrays of scalars`() throws {
    var user = SinkUser.Partial()
    try parsePartial(#"{"scores":[1,2,3]}"#, into: &user)
    expectNoDifference(user.scores, [1, 2, 3])
  }

  @Test
  func `Applies null literals`() throws {
    var user = SinkUser.Partial()
    user.id = 7
    try parsePartial(#"{"id":null}"#, into: &user)
    expectNoDifference(user.id, nil)
  }

  // MARK: - Optional element and value types

  @Test(arguments: [Int.max, 7, 1])
  func `Every spelling of an optional container agrees`(chunk: Int) throws {
    var value = SinkOptionalSpellings.Partial()
    try parsePartial(
      #"""
      {"sugared":[1,null],"generic":[1,null],"aliased":["a",null],
       "nested":[[1,null]],"genericDictionary":{"j":1,"k":null}}
      """#,
      into: &value,
      chunk: chunk
    )
    expectNoDifference(value.sugared, [1, nil])
    expectNoDifference(value.generic, [1, nil])
    expectNoDifference(value.aliased, ["a", nil])
    expectNoDifference(value.nested, [[1, nil]])
    expectNoDifference(value.genericDictionary?["j"], 1)
    expectNoDifference(value.genericDictionary?["k"] ?? nil, nil)
  }

  // The root position resolves through the same requirement, which the macro never sees at all.
  @Test(arguments: [Int.max, 7, 1])
  func `Optional elements parse as a root`(chunk: Int) throws {
    var array = StreamArray<Int?>()
    try parsePartial("[1,null,3]", into: &array, chunk: chunk)
    expectNoDifference(array, [1, nil, 3])

    var dictionary = StreamDictionary<StreamString?>()
    try parsePartial(#"{"a":"x","b":null}"#, into: &dictionary, chunk: chunk)
    expectNoDifference(dictionary["a"] ?? nil, "x")
    expectNoDifference(dictionary["b"] ?? nil, nil)

    // Composed by the library rather than by the macro, so the inner element schema is resolved
    // through `Element.streamElementSchema` twice over.
    var nested = StreamArray<StreamArray<Int?>>()
    try parsePartial("[[1,null]]", into: &nested, chunk: chunk)
    expectNoDifference(nested, [[1, nil]])
  }

  @Test(arguments: [Int.max, 7, 1])
  func `Homogeneous leaf roots preserve repeated and optional values`(chunk: Int) throws {
    var doubles = StreamArray<Double>()
    try parsePartial("[1.25,0,-2.5]", into: &doubles, chunk: chunk)
    expectNoDifference(doubles, [1.25, 0, -2.5])

    var integers = StreamArray<Int>()
    try parsePartial("[1,0,-2]", into: &integers, chunk: chunk)
    expectNoDifference(integers, [1, 0, -2])

    var booleans = StreamArray<Bool>()
    try parsePartial("[true,false,true]", into: &booleans, chunk: chunk)
    expectNoDifference(booleans, [true, false, true])

    var optionalBooleans = StreamArray<Bool?>()
    try parsePartial("[true,null,false]", into: &optionalBooleans, chunk: chunk)
    expectNoDifference(optionalBooleans, [true, nil, false])

    var booleanDictionary = StreamDictionary<Bool>()
    try parsePartial(#"{"a":false,"a":true,"b":false}"#, into: &booleanDictionary, chunk: chunk)
    expectNoDifference(booleanDictionary["a"], true)
    expectNoDifference(booleanDictionary["b"], false)

    var optionalBooleanDictionary = StreamDictionary<Bool?>()
    try parsePartial(
      #"{"a":null,"a":true,"b":false,"b":null}"#,
      into: &optionalBooleanDictionary,
      chunk: chunk
    )
    expectNoDifference(optionalBooleanDictionary["a"] ?? nil, true)
    expectNoDifference(optionalBooleanDictionary["b"] ?? nil, nil)

    var strings = StreamDictionary<StreamString>()
    try parsePartial(#"{"s":"a","s":"b"}"#, into: &strings, chunk: chunk)
    expectNoDifference(strings["s"], StreamString("ab"))

    var optionalStrings = StreamDictionary<StreamString?>()
    try parsePartial(
      #"{"s":null,"s":"a","s":"b"}"#,
      into: &optionalStrings,
      chunk: chunk
    )
    expectNoDifference(optionalStrings["s"] ?? nil, StreamString("ab"))
  }

  @Test(arguments: [Int.max, 7, 1])
  func `Routes into containers of optionals`(chunk: Int) throws {
    var value = SinkOptionalElements.Partial()
    try parsePartial(
      #"""
      {"tags":["a","b"],"counts":[1,2],"rows":[{"city":"NYC"}],
       "meta":{"k":"v"},"lookup":{"home":{"city":"Brooklyn"}}}
      """#,
      into: &value,
      chunk: chunk
    )
    expectNoDifference(value.tags, ["a", "b"])
    expectNoDifference(value.counts, [1, 2])
    expectNoDifference(value.rows?.first??.city, "NYC")
    expectNoDifference(value.meta?["k"], "v")
    expectNoDifference(value.lookup?["home"]??.city, "Brooklyn")
  }

  // A null naming the element clears it, which is the whole point of an optional element and the
  // one thing opening the slot materialised could have cost. It does not, because the element
  // schema keeps an `applyNull` that answers `StreamSchema.wholeValueField`.
  @Test(arguments: [Int.max, 7, 1])
  func `Nulls clear individual elements and values`(chunk: Int) throws {
    var value = SinkOptionalElements.Partial()
    try parsePartial(
      #"""
      {"tags":["a",null,"c"],"counts":[null,2],"rows":[null,{"city":"NYC"}],
       "meta":{"j":null,"k":"v"},"lookup":{"home":null}}
      """#,
      into: &value,
      chunk: chunk
    )
    expectNoDifference(value.tags, ["a", nil, "c"])
    expectNoDifference(value.counts, [nil, 2])
    expectNoDifference(value.rows?.count, 2)
    expectNoDifference(value.rows?.first ?? nil, nil)
    expectNoDifference(value.meta?["j"] ?? nil, nil)
    expectNoDifference(value.meta?["k"], "v")
    expectNoDifference(value.lookup?["home"] ?? nil, nil)
  }

  // A null inside an optional object element names that field, not the element — the distinction
  // `StreamSchema.wholeValueField` exists for, exercised here through the macro's own emission
  // rather than through a hand built schema.
  @Test(arguments: [Int.max, 7, 1])
  func `A null inside an optional element names its field`(chunk: Int) throws {
    var value = SinkOptionalElements.Partial()
    try parsePartial(
      #"{"rows":[{"city":"NYC","postalCode":null}]}"#, into: &value, chunk: chunk
    )
    expectNoDifference(value.rows?.first??.city, "NYC")
    expectNoDifference(value.rows?.first??.postalCode, nil)
  }

  // MARK: - Optional source declarations

  @Test(arguments: [Int.max, 7, 1])
  func `Routes into members the source declared optional`(chunk: Int) throws {
    var value = SinkOptionalMembers.Partial()
    try parsePartial(
      #"""
      {"count":42,"name":"Blob","flag":true,"address":{"city":"NYC"},"scores":[1,2],"counts":{"a":1}}
      """#,
      into: &value,
      chunk: chunk
    )
    expectNoDifference(value.count, 42)
    expectNoDifference(value.name, "Blob")
    expectNoDifference(value.flag, true)
    expectNoDifference(value.address?.city, "NYC")
    expectNoDifference(value.scores, [1, 2])
    expectNoDifference(value.counts?["a"], 1)
  }

  // Null still clears them, containers included. A container field used to reach no `applyNull`
  // case at all — the macro emitted one only for scalars and nested objects — so `{"scores":null}`
  // was a type mismatch however the member was declared.
  @Test(arguments: [Int.max, 7, 1])
  func `Nulls clear members the source declared optional`(chunk: Int) throws {
    var value = SinkOptionalMembers.Partial(
      count: 1,
      name: "Blob",
      flag: true,
      address: SinkAddress.Partial(city: "NYC"),
      scores: [1],
      counts: ["a": 1]
    )
    try parsePartial(
      #"{"count":null,"name":null,"flag":null,"address":null,"scores":null,"counts":null}"#,
      into: &value,
      chunk: chunk
    )
    expectNoDifference(value, SinkOptionalMembers.Partial())
  }

  // In the default mode every member is optional, so a null clears a container declared
  // non-optional in the source too. Under `.streamInitialValue` the member really is
  // non-optional, and there the same helper resolves to the disfavoured overload and the null is
  // the mismatch it should be.
  @Test(arguments: [Int.max, 7, 1])
  func `A null into a non-nullable container is rejected`(chunk: Int) {
    var optionalMembers = SinkUser.Partial()
    #expect(throws: Never.self) {
      try parsePartial(#"{"scores":null}"#, into: &optionalMembers, chunk: chunk)
    }
    expectNoDifference(optionalMembers.scores, nil)

    var initializedMembers = SinkInitializedContainers.Partial()
    #expect(throws: JSONParsingError.self) {
      try parsePartial(#"{"scores":null}"#, into: &initializedMembers, chunk: chunk)
    }
  }

  // The bridge back, which did not compile for an optional dictionary member: the generated
  // `streamPartialValue` reached for `mapValues` on the optional itself.
  @Test
  func `A value round trips through its partial`() {
    let value = SinkOptionalMembers(
      count: 1,
      name: "Blob",
      flag: false,
      address: SinkAddress(city: "NYC", postalCode: "11201"),
      scores: [3],
      counts: ["a": 4]
    )
    let partial = value.streamPartialValue
    expectNoDifference(partial.count, 1)
    expectNoDifference(partial.name, "Blob")
    expectNoDifference(partial.address?.city, "NYC")
    expectNoDifference(partial.scores, [3])
    expectNoDifference(partial.counts?["a"], 4)

    let empty = SinkOptionalMembers(flag: nil).streamPartialValue
    expectNoDifference(empty.counts, nil)
    expectNoDifference(empty.scores, nil)
  }

  @Test
  func `Routes into dictionaries of scalars`() throws {
    var user = SinkUser.Partial()
    try parsePartial(#"{"counts":{"a":1,"b":2,"c":3}}"#, into: &user)
    expectNoDifference(user.counts?.keys, ["a", "b", "c"])
    expectNoDifference(user.counts?["b"], 2)
  }

  @Test
  func `Routes into dictionaries of objects`() throws {
    var user = SinkUser.Partial()
    try parsePartial(
      #"{"settings":{"home":{"city":"NYC"},"work":{"city":"Brooklyn","postalCode":"11201"}}}"#,
      into: &user
    )
    expectNoDifference(user.settings?.keys, ["home", "work"])
    expectNoDifference(user.settings?["home"]?.city, "NYC")
    expectNoDifference(user.settings?["work"]?.postalCode, "11201")
  }

  // The point of the append-only storage: a nested value inside a dictionary updates as it
  // streams rather than appearing only once it closes.
  @Test
  func `Dictionary values update as they stream`() throws {
    let json = #"{"settings":{"home":{"city":"Brooklyn"}}}"#
    let prefix = String(json.prefix(json.utf8.count - 3))

    var user = SinkUser.Partial()
    try withUnsafeMutablePointer(to: &user) { pointer in
      var parser = JSONParser()
      var sink = PartialSink(root: pointer)
      try Array(prefix.utf8).withUnsafeBufferPointer { try parser.parse($0, into: &sink) }
    }
    expectNoDifference(user.settings?["home"]?.city, "Brooklyn")
  }

  @Test
  func `Dictionaries preserve insertion order from the payload`() throws {
    var user = SinkUser.Partial()
    try parsePartial(#"{"counts":{"zebra":1,"apple":2,"mango":3}}"#, into: &user)
    expectNoDifference(user.counts?.keys, ["zebra", "apple", "mango"])
  }

  @Test
  func `Accumulates string values across chunks`() throws {
    var user = SinkUser.Partial()
    try parsePartial(#"{"name":"a longer name that will be split"}"#, into: &user, chunk: 1)
    expectNoDifference(user.name, "a longer name that will be split")
  }

  @Test
  func `Produces the same value at every chunk size`() throws {
    let json =
      #"{"id":42,"name":"Blob Jr","active":false,"address":{"city":"NYC"},"scores":[10,20],"counts":{"a":1}}"#
    var whole = SinkUser.Partial()
    try parsePartial(json, into: &whole)

    for chunk in [1, 2, 3, 7] {
      var chunked = SinkUser.Partial()
      try parsePartial(json, into: &chunked, chunk: chunk)
      expectNoDifference(chunked.id, whole.id, "chunk \(chunk)")
      expectNoDifference(chunked.name, whole.name, "chunk \(chunk)")
      expectNoDifference(chunked.active, whole.active, "chunk \(chunk)")
      expectNoDifference(chunked.address?.city, whole.address?.city, "chunk \(chunk)")
      expectNoDifference(chunked.scores, whole.scores, "chunk \(chunk)")
      expectNoDifference(chunked.counts?.keys, whole.counts?.keys, "chunk \(chunk)")
    }
  }
}

// Key words are precomputed by the macro, and a wrong one fails silently as a key that never
// matches. These exercise the boundaries where that is most likely.
@StreamParseable
struct MacroKeyWidths: Equatable {
  var a: Int = 0
  var abcdefghX: Int = 0
  var abcdefghijklmnopX: Int = 0
  var exactly8: Int = 0
  var nineBytes9: Int = 0
  var descriptionLong: Int = 0
  var descriptionShort: Int = 0
}

@Suite
struct `Macro key matching tests` {
  @Test
  func `Matches keys at and beyond the word width`() throws {
    var value = MacroKeyWidths.Partial()
    try parsePartial(
      #"""
      {
        "a": 1,
        "abcdefghX": 2,
        "abcdefghijklmnopX": 3,
        "exactly8": 4,
        "nineBytes9": 5,
        "descriptionLong": 6,
        "descriptionShort": 7
      }
      """#,
      into: &value
    )
    expectNoDifference(value.a, 1)
    expectNoDifference(value.abcdefghX, 2)
    expectNoDifference(value.abcdefghijklmnopX, 3)
    expectNoDifference(value.exactly8, 4)
    expectNoDifference(value.nineBytes9, 5)
    expectNoDifference(value.descriptionLong, 6)
    expectNoDifference(value.descriptionShort, 7)
  }

  // Both share "descript" as their first eight bytes, so only the length distinguishes them and
  // a missing guard would route one into the other.
  @Test
  func `Distinguishes keys sharing their first eight bytes`() throws {
    var value = MacroKeyWidths.Partial()
    try parsePartial(#"{"descriptionShort":5}"#, into: &value)
    expectNoDifference(value.descriptionShort, 5)
    expectNoDifference(value.descriptionLong, nil)
  }

  @Test
  func `Rejects near misses of a known key`() throws {
    var value = MacroKeyWidths.Partial()
    try parsePartial(
      #"""
      {
        "a\u0000": 1,
        "abcdefghY": 2,
        "abcdefghijklmnopY": 3,
        "exactly": 4,
        "exactly88": 5,
        "nineBytes": 6
      }
      """#,
      into: &value
    )
    expectNoDifference(value.a, nil)
    expectNoDifference(value.abcdefghX, nil)
    expectNoDifference(value.abcdefghijklmnopX, nil)
    expectNoDifference(value.exactly8, nil)
    expectNoDifference(value.nineBytes9, nil)
  }
}
