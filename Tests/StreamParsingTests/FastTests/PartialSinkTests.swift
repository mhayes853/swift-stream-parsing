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

@Suite
struct `Partial sink tests` {
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

  // Null still clears them, which is the one shape that worked before and has to keep working.
  // Container members are left out because a null has never reached one: the macro emits no
  // `applyNull` case for an array or dictionary field, so `{"scores":null}` is a type mismatch
  // whether or not the source declared it optional.
  @Test(arguments: [Int.max, 7, 1])
  func `Nulls clear members the source declared optional`(chunk: Int) throws {
    var value = SinkOptionalMembers.Partial(
      count: 1, name: "Blob", flag: true, address: SinkAddress.Partial(city: "NYC")
    )
    try parsePartial(
      #"{"count":null,"name":null,"flag":null,"address":null}"#,
      into: &value,
      chunk: chunk
    )
    expectNoDifference(value, SinkOptionalMembers.Partial())
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
