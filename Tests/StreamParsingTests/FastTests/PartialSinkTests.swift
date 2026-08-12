import Testing

import StreamParsing
import StreamParsingCore

// Hand written in the shape the macro will generate, so the routing design is exercised before
// the macro has to produce it.

struct SinkAddress: StreamParseableObject, Equatable {
  var city: String?
  var postalCode: String?

  static func streamInitialValue() -> Self { Self() }

  static let streamSchema = StreamSchema(
    shape: .object,
    matchField: { key in
      switch key.paddedLeadingWord() {
      case 0x0000_0000_7974_6963: return 0  // "city"
      case 0x6F43_6C61_7473_6F70: return key.count == 10 ? 1 : -1  // "postalCode"
      default: return -1
      }
    },
    applyString: { storage, field, bytes in
      let p = storage.assumingMemoryBound(to: Self.self)
      switch field {
      case 0: streamApply(&p.pointee.city, utf8: bytes)
      case 1: streamApply(&p.pointee.postalCode, utf8: bytes)
      default: break
      }
    },
    applyNull: { storage, field in
      let p = storage.assumingMemoryBound(to: Self.self)
      switch field {
      case 0: p.pointee.city = nil
      case 1: p.pointee.postalCode = nil
      default: break
      }
    }
  )
}

struct SinkUser: StreamParseableObject, Equatable {
  var id: Int?
  var name: String?
  var active: Bool?
  var address: SinkAddress?
  var scores: [Int]?
  var settings: StreamDictionary<SinkAddress>?
  var counts: StreamDictionary<Int>?

  static func streamInitialValue() -> Self { Self() }

  static let streamSchema = StreamSchema(
    shape: .object,
    matchField: { key in
      switch key.paddedLeadingWord() {
      case 0x0000_0000_0000_6469: return 0  // "id"
      case 0x0000_0000_656D_616E: return 1  // "name"
      case 0x0000_6576_6974_6361: return 2  // "active"
      case 0x0073_7365_7264_6461: return 3  // "address"
      case 0x0000_7365_726F_6373: return 4  // "scores"
      case 0x7367_6E69_7474_6573: return 5  // "settings"
      case 0x0000_7374_6E75_6F63: return 6  // "counts"
      default: return -1
      }
    },
    applyString: { storage, field, bytes in
      let p = storage.assumingMemoryBound(to: Self.self)
      if field == 1 { streamApply(&p.pointee.name, utf8: bytes) }
    },
    applyNumber: { storage, field, bytes, info in
      let p = storage.assumingMemoryBound(to: Self.self)
      if field == 0 { streamApply(&p.pointee.id, bytes: bytes, info: info) }
    },
    applyBoolean: { storage, field, value in
      let p = storage.assumingMemoryBound(to: Self.self)
      if field == 2 { streamApply(&p.pointee.active, boolean: value) }
    },
    applyNull: { storage, field in
      let p = storage.assumingMemoryBound(to: Self.self)
      switch field {
      case 0: p.pointee.id = nil
      case 1: p.pointee.name = nil
      case 2: p.pointee.active = nil
      default: break
      }
    },
    enterField: { storage, field in
      let p = storage.assumingMemoryBound(to: Self.self)
      switch field {
      case 3: return _streamEnterField(&p.pointee.address)
      case 4: return _streamEnterArrayField(&p.pointee.scores, element: _streamSchema(for: Int.self))
      case 5:
        return _streamEnterDictionaryField(
          &p.pointee.settings, value: _streamSchema(for: SinkAddress.self)
        )
      case 6:
        return _streamEnterDictionaryField(
          &p.pointee.counts, value: _streamSchema(for: Int.self)
        )
      default: return nil
      }
    }
  )
}

private func parse<Root: StreamParseableObject>(
  _ json: String, into value: inout Root, chunk: Int = .max
) throws {
  try withUnsafeMutablePointer(to: &value) { pointer in
    var parser = JSONParser()
    var sink = PartialSink(root: pointer)
    let bytes = Array(json.utf8)
    try bytes.withUnsafeBufferPointer { input in
      var i = 0
      while i < input.count {
        let count = min(chunk, input.count - i)
        try parser.parse(
          UnsafeBufferPointer(start: input.baseAddress! + i, count: count), into: &sink
        )
        i += count
      }
    }
    try parser.finish(into: &sink)
  }
}

@Suite
struct `Partial sink tests` {
  @Test
  func `Routes scalars into matching fields`() throws {
    var user = SinkUser()
    try parse(#"{"id":42,"name":"Blob","active":true}"#, into: &user)
    #expect(user.id == 42)
    #expect(user.name == "Blob")
    #expect(user.active == true)
  }

  @Test
  func `Ignores keys the destination does not have`() throws {
    var user = SinkUser()
    try parse(#"{"id":1,"unknown":"x","name":"Blob"}"#, into: &user)
    #expect(user.id == 1)
    #expect(user.name == "Blob")
  }

  // An unknown key whose value is a container must not have its contents routed to the parent.
  @Test
  func `Skips containers under unknown keys`() throws {
    var user = SinkUser()
    try parse(#"{"extra":{"id":999,"name":"wrong"},"id":1}"#, into: &user)
    #expect(user.id == 1)
    #expect(user.name == nil)
  }

  @Test
  func `Routes into nested objects`() throws {
    var user = SinkUser()
    try parse(#"{"address":{"city":"Brooklyn","postalCode":"11201"}}"#, into: &user)
    #expect(user.address?.city == "Brooklyn")
    #expect(user.address?.postalCode == "11201")
  }

  @Test
  func `Routes into arrays of scalars`() throws {
    var user = SinkUser()
    try parse(#"{"scores":[1,2,3]}"#, into: &user)
    #expect(user.scores == [1, 2, 3])
  }

  @Test
  func `Applies null literals`() throws {
    var user = SinkUser()
    user.id = 7
    try parse(#"{"id":null}"#, into: &user)
    #expect(user.id == nil)
  }

  @Test
  func `Produces the same value at every chunk size`() throws {
    let json = #"{"id":42,"name":"Blob Jr","active":false,"address":{"city":"NYC"},"scores":[10,20]}"#
    var whole = SinkUser()
    try parse(json, into: &whole)

    for chunk in [1, 2, 3, 7] {
      var chunked = SinkUser()
      try parse(json, into: &chunked, chunk: chunk)
      #expect(chunked == whole, "chunk \(chunk)")
    }
  }

  @Test
  func `Routes into dictionaries of scalars`() throws {
    var user = SinkUser()
    try parse(#"{"counts":{"a":1,"b":2,"c":3}}"#, into: &user)
    #expect(user.counts?.keys == ["a", "b", "c"])
    #expect(user.counts?["b"] == 2)
  }

  @Test
  func `Routes into dictionaries of objects`() throws {
    var user = SinkUser()
    try parse(
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
    let bytes = Array(json.utf8)
    let prefix = json.prefix(bytes.count - 3)  // stops mid-city, before the object closes

    var user = SinkUser()
    try withUnsafeMutablePointer(to: &user) { pointer in
      var parser = JSONParser()
      var sink = PartialSink(root: pointer)
      try Array(prefix.utf8).withUnsafeBufferPointer {
        try parser.parse($0, into: &sink)
      }
    }
    #expect(user.settings?["home"]?.city == "Brooklyn")
  }

  @Test
  func `Dictionaries preserve insertion order from the payload`() throws {
    var user = SinkUser()
    try parse(#"{"counts":{"zebra":1,"apple":2,"mango":3}}"#, into: &user)
    #expect(user.counts?.keys == ["zebra", "apple", "mango"])
  }

  @Test
  func `Accumulates string values across chunks`() throws {
    var user = SinkUser()
    try parse(#"{"name":"a longer name that will be split"}"#, into: &user, chunk: 1)
    #expect(user.name == "a longer name that will be split")
  }
}

// MARK: - Macro generated

@StreamParseable
struct MacroAddress: Equatable {
  var city: String = ""
  var postalCode: String = ""
}

@StreamParseable
struct MacroUser: Equatable {
  var id: Int = 0
  var name: String = ""
  var active: Bool = false
  var address: MacroAddress = MacroAddress()
  var scores: [Int] = []
  var settings: [String: MacroAddress] = [:]
}

@Suite
struct `Macro generated schema tests` {
  @Test
  func `Routes scalars into macro generated partials`() throws {
    var user = MacroUser.Partial()
    try parse(#"{"id":42,"name":"Blob","active":true}"#, into: &user)
    #expect(user.id == 42)
    #expect(user.name == "Blob")
    #expect(user.active == true)
  }

  @Test
  func `Routes nested objects, arrays and dictionaries`() throws {
    var user = MacroUser.Partial()
    try parse(
      #"{"address":{"city":"NYC"},"scores":[1,2,3],"settings":{"home":{"city":"Brooklyn"}}}"#,
      into: &user
    )
    #expect(user.address?.city == "NYC")
    #expect(user.scores == [1, 2, 3])
    #expect(user.settings?["home"]?.city == "Brooklyn")
  }

  @Test
  func `Produces the same value at every chunk size`() throws {
    let json = #"{"id":7,"name":"Blob Jr","address":{"city":"NYC","postalCode":"10001"},"scores":[10,20]}"#
    var whole = MacroUser.Partial()
    try parse(json, into: &whole)

    for chunk in [1, 2, 5] {
      var chunked = MacroUser.Partial()
      try parse(json, into: &chunked, chunk: chunk)
      #expect(chunked.id == whole.id, "chunk \(chunk)")
      #expect(chunked.name == whole.name, "chunk \(chunk)")
      #expect(chunked.address?.city == whole.address?.city, "chunk \(chunk)")
      #expect(chunked.scores == whole.scores, "chunk \(chunk)")
    }
  }

  // The macro precomputes key words, which is the part I got wrong four times by hand.
  @Test
  func `Ignores keys the generated matcher does not know`() throws {
    var user = MacroUser.Partial()
    try parse(#"{"unknown":1,"id":9,"nam":2,"names":3}"#, into: &user)
    #expect(user.id == 9)
    #expect(user.name == nil)
  }
}
