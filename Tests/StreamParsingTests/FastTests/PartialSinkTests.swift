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

@Suite
struct `Partial sink tests` {
  @Test
  func `Routes scalars into matching fields`() throws {
    var user = SinkUser.Partial()
    try parsePartial(#"{"id":42,"name":"Blob","active":true}"#, into: &user)
    #expect(user.id == 42)
    #expect(user.name == "Blob")
    #expect(user.active == true)
  }

  @Test
  func `Ignores keys the destination does not have`() throws {
    var user = SinkUser.Partial()
    try parsePartial(#"{"id":1,"unknown":"x","name":"Blob"}"#, into: &user)
    #expect(user.id == 1)
    #expect(user.name == "Blob")
  }

  // An unknown key whose value is a container must not have its contents routed to the parent.
  @Test
  func `Skips containers under unknown keys`() throws {
    var user = SinkUser.Partial()
    try parsePartial(#"{"extra":{"id":999,"name":"wrong"},"id":1}"#, into: &user)
    #expect(user.id == 1)
    #expect(user.name == nil)
  }

  @Test
  func `Routes into nested objects`() throws {
    var user = SinkUser.Partial()
    try parsePartial(#"{"address":{"city":"Brooklyn","postalCode":"11201"}}"#, into: &user)
    #expect(user.address?.city == "Brooklyn")
    #expect(user.address?.postalCode == "11201")
  }

  @Test
  func `Routes into arrays of scalars`() throws {
    var user = SinkUser.Partial()
    try parsePartial(#"{"scores":[1,2,3]}"#, into: &user)
    #expect(user.scores == [1, 2, 3])
  }

  @Test
  func `Applies null literals`() throws {
    var user = SinkUser.Partial()
    user.id = 7
    try parsePartial(#"{"id":null}"#, into: &user)
    #expect(user.id == nil)
  }

  @Test
  func `Routes into dictionaries of scalars`() throws {
    var user = SinkUser.Partial()
    try parsePartial(#"{"counts":{"a":1,"b":2,"c":3}}"#, into: &user)
    #expect(user.counts?.keys == ["a", "b", "c"])
    #expect(user.counts?["b"] == 2)
  }

  @Test
  func `Routes into dictionaries of objects`() throws {
    var user = SinkUser.Partial()
    try parsePartial(
      #"{"settings":{"home":{"city":"NYC"},"work":{"city":"Brooklyn","postalCode":"11201"}}}"#,
      into: &user
    )
    #expect(user.settings?.keys == ["home", "work"])
    #expect(user.settings?["home"]?.city == "NYC")
    #expect(user.settings?["work"]?.postalCode == "11201")
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
    #expect(user.settings?["home"]?.city == "Brooklyn")
  }

  @Test
  func `Dictionaries preserve insertion order from the payload`() throws {
    var user = SinkUser.Partial()
    try parsePartial(#"{"counts":{"zebra":1,"apple":2,"mango":3}}"#, into: &user)
    #expect(user.counts?.keys == ["zebra", "apple", "mango"])
  }

  @Test
  func `Accumulates string values across chunks`() throws {
    var user = SinkUser.Partial()
    try parsePartial(#"{"name":"a longer name that will be split"}"#, into: &user, chunk: 1)
    #expect(user.name == "a longer name that will be split")
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
      #expect(chunked.id == whole.id, "chunk \(chunk)")
      #expect(chunked.name == whole.name, "chunk \(chunk)")
      #expect(chunked.active == whole.active, "chunk \(chunk)")
      #expect(chunked.address?.city == whole.address?.city, "chunk \(chunk)")
      #expect(chunked.scores == whole.scores, "chunk \(chunk)")
      #expect(chunked.counts?.keys == whole.counts?.keys, "chunk \(chunk)")
    }
  }
}

// Key words are precomputed by the macro, and a wrong one fails silently as a key that never
// matches. These exercise the boundaries where that is most likely.
@StreamParseable
struct MacroKeyWidths: Equatable {
  var a: Int = 0
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
      #"{"a":1,"exactly8":2,"nineBytes9":3,"descriptionLong":4,"descriptionShort":5}"#,
      into: &value
    )
    #expect(value.a == 1)
    #expect(value.exactly8 == 2)
    #expect(value.nineBytes9 == 3)
    #expect(value.descriptionLong == 4)
    #expect(value.descriptionShort == 5)
  }

  // Both share "descript" as their first eight bytes, so only the length distinguishes them and
  // a missing guard would route one into the other.
  @Test
  func `Distinguishes keys sharing their first eight bytes`() throws {
    var value = MacroKeyWidths.Partial()
    try parsePartial(#"{"descriptionShort":5}"#, into: &value)
    #expect(value.descriptionShort == 5)
    #expect(value.descriptionLong == nil)
  }

  @Test
  func `Rejects near misses of a known key`() throws {
    var value = MacroKeyWidths.Partial()
    try parsePartial(#"{"exactly":1,"exactly88":2,"nineBytes":3}"#, into: &value)
    #expect(value.exactly8 == nil)
    #expect(value.nineBytes9 == nil)
  }
}
