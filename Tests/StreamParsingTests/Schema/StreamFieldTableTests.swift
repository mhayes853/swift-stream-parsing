import CustomDump
import Testing

import StreamParsing
@testable import StreamParsingCore

// The field table is what `PartialSink` writes through, and two of its columns are load-bearing
// in a way nothing else checks: the byte offset, taken by pointer arithmetic from a prototype
// (because a key path does not compile under Embedded Swift), and the kind, resolved by overload
// from the member's type. A wrong offset is a write into the wrong member or past the value; a
// wrong kind is a typed store of the wrong width. Both are pinned here against the answers the
// compiler gives directly.

@StreamParseable
private struct TableScalars: Equatable {
  var flag: Bool = false
  var count: Int = 0
  var small: Int8 = 0
  var wide: UInt64 = 0
  var ratio: Double = 0
  var single: Float = 0
  var name: String = ""
  var nested: TableNested = TableNested()
  var scores: [Int] = []
  var counts: [String: Int] = [:]
  @StreamParseableMember(keyNames: ["alias_a", "alias_b"])
  var aliased: Int = 0
  @StreamParseableMember(initialCapacity: 64)
  var text: String = ""
  @StreamParseableMember(initialCapacity: 16)
  var tags: [String] = []
}

@StreamParseable
private struct TableNested: Equatable {
  var value: Int = 0
}

@StreamParseable(partialMembers: .initialValue)
private struct TableInitialized: Equatable {
  var count: Int = 0
  var name: String = ""
  var nested: TableNested = TableNested()
  var scores: [Int] = []
  @StreamParseableMember(initialCapacity: 16)
  var tags: [String] = []
}

// A number type the library has no layout for: it must stay on the closures.
private struct Celsius: StreamNumberConvertible, StreamInitializable, Equatable {
  var degrees: Double
  static func streamInitialValue() -> Self { Self(degrees: 0) }
  init(degrees: Double) { self.degrees = degrees }
  init?(streamParsing bytes: Span<UInt8>, info: NumberInfo) {
    guard let value = Double(streamParsing: bytes, info: info) else { return nil }
    self.degrees = value
  }
}

extension Celsius: StreamParseable, StreamPartial {
  typealias Partial = Self
}

@StreamParseable
private struct TableCustom: Equatable {
  var temperature: Celsius = Celsius(degrees: 0)
  var count: Int = 0
}

@Suite
struct StreamFieldTableTests {
    private func entry(_ key: String, in fields: [StreamField]) -> StreamField {
      fields.first { field in
        field.keyLength == key.utf8.count
          && field.keyWord == Array(key.utf8).paddedLeadingWordForTest()
      }!
    }

    @Test
    func `Offsets match MemoryLayout`() {
      typealias P = TableScalars.Partial
      let fields = P.streamSchema.declaredFields
      expectNoDifference(Int(self.entry("flag", in: fields).offset), MemoryLayout<P>.offset(of: \.flag)!)
      expectNoDifference(Int(self.entry("count", in: fields).offset), MemoryLayout<P>.offset(of: \.count)!)
      expectNoDifference(Int(self.entry("small", in: fields).offset), MemoryLayout<P>.offset(of: \.small)!)
      expectNoDifference(Int(self.entry("wide", in: fields).offset), MemoryLayout<P>.offset(of: \.wide)!)
      expectNoDifference(Int(self.entry("ratio", in: fields).offset), MemoryLayout<P>.offset(of: \.ratio)!)
      expectNoDifference(Int(self.entry("single", in: fields).offset), MemoryLayout<P>.offset(of: \.single)!)
      expectNoDifference(Int(self.entry("name", in: fields).offset), MemoryLayout<P>.offset(of: \.name)!)
      expectNoDifference(Int(self.entry("nested", in: fields).offset), MemoryLayout<P>.offset(of: \.nested)!)
      expectNoDifference(Int(self.entry("scores", in: fields).offset), MemoryLayout<P>.offset(of: \.scores)!)
      expectNoDifference(Int(self.entry("counts", in: fields).offset), MemoryLayout<P>.offset(of: \.counts)!)
      expectNoDifference(Int(self.entry("alias_a", in: fields).offset), MemoryLayout<P>.offset(of: \.aliased)!)
      expectNoDifference(Int(self.entry("alias_b", in: fields).offset), MemoryLayout<P>.offset(of: \.aliased)!)
      expectNoDifference(Int(self.entry("text", in: fields).offset), MemoryLayout<P>.offset(of: \.text)!)
      expectNoDifference(Int(self.entry("tags", in: fields).offset), MemoryLayout<P>.offset(of: \.tags)!)

      typealias I = TableInitialized.Partial
      let initialized = I.streamSchema.declaredFields
      expectNoDifference(Int(self.entry("count", in: initialized).offset), MemoryLayout<I>.offset(of: \.count)!)
      expectNoDifference(Int(self.entry("name", in: initialized).offset), MemoryLayout<I>.offset(of: \.name)!)
    }

    @Test
    func `Kinds follow the member type`() {
      let fields = TableScalars.Partial.streamSchema.declaredFields
      expectNoDifference(self.entry("flag", in: fields).kind, .bool)
      expectNoDifference(self.entry("count", in: fields).kind, .int)
      expectNoDifference(self.entry("small", in: fields).kind, .int8)
      expectNoDifference(self.entry("wide", in: fields).kind, .uint64)
      expectNoDifference(self.entry("ratio", in: fields).kind, .double)
      expectNoDifference(self.entry("single", in: fields).kind, .float)
      expectNoDifference(self.entry("name", in: fields).kind, .streamString)
      expectNoDifference(self.entry("nested", in: fields).kind, .container)
      expectNoDifference(self.entry("scores", in: fields).kind, .container)
      expectNoDifference(self.entry("counts", in: fields).kind, .container)
      expectNoDifference(self.entry("text", in: fields).kind, .streamString)
      expectNoDifference(self.entry("text", in: fields).capacity, 64)
      // Every member of an optional-members partial is optional; none of an initialised one is.
      let allOptional = fields.allSatisfy { $0.isOptional }
      let noneOptional = TableInitialized.Partial.streamSchema.declaredFields.allSatisfy { !$0.isOptional }
      expectNoDifference(allOptional, true)
      expectNoDifference(noneOptional, true)
      expectNoDifference(self.entry("count", in: TableInitialized.Partial.streamSchema.declaredFields).kind, .int)

      let custom = TableCustom.Partial.streamSchema.declaredFields
      expectNoDifference(self.entry("temperature", in: custom).kind, .custom)
      expectNoDifference(self.entry("count", in: custom).kind, .int)
    }

    // A container entry carries the child's schema, so entering it is a frame built from the
    // entry rather than a closure call; an optional or capacity-hinted member carries a `prepare`
    // to materialise or reserve first, and a member that needs neither carries none.
    @Test
    func `Container entries carry the child schema and a prepare only when needed`() {
      let fields = TableScalars.Partial.streamSchema.declaredFields
      expectNoDifference(self.entry("nested", in: fields).schema?.shape, .object)
      expectNoDifference(self.entry("scores", in: fields).schema?.shape, .array)
      expectNoDifference(self.entry("counts", in: fields).schema?.shape, .dictionary)
      expectNoDifference(self.entry("tags", in: fields).schema?.shape, .array)
      expectNoDifference(self.entry("tags", in: fields).capacity, 16)
      expectNoDifference(self.entry("count", in: fields).schema == nil, true)
      // Optional members: every container prepares (materialises).
      expectNoDifference(self.entry("nested", in: fields).prepare != nil, true)
      expectNoDifference(self.entry("scores", in: fields).prepare != nil, true)
      expectNoDifference(self.entry("count", in: fields).prepare == nil, true)

      let initialized = TableInitialized.Partial.streamSchema.declaredFields
      expectNoDifference(self.entry("nested", in: initialized).schema?.shape, .object)
      expectNoDifference(self.entry("nested", in: initialized).prepare == nil, true)
      expectNoDifference(self.entry("scores", in: initialized).prepare == nil, true)
      // A capacity hint on a non-optional member still needs a reservation.
      expectNoDifference(self.entry("tags", in: initialized).prepare != nil, true)
      expectNoDifference(self.entry("tags", in: initialized).capacity, 16)

      let custom = TableCustom.Partial.streamSchema.declaredFields
      expectNoDifference(self.entry("temperature", in: custom).schema == nil, true)
    }

    // The sink calls an entry's `prepare` unchecked once the entry is flagged, so the flag is
    // derived from the closure when the table packs the field, never carried over from it.
    @Test
    func `Packed entries flag a prepare exactly when the field has one`() {
      for fields in [
        TableScalars.Partial.streamSchema.declaredFields,
        TableInitialized.Partial.streamSchema.declaredFields,
      ] {
        let table = StreamFieldTable(fields)
        for index in fields.indices {
          expectNoDifference(table.entries[index].hasPrepare, fields[index].prepare != nil)
          expectNoDifference(fields[index].flags.contains(.prepare), false)
        }
      }
    }

    @Test
    func `Aliased keys share an index`() {
      let fields = TableScalars.Partial.streamSchema.declaredFields
      expectNoDifference(
        self.entry("alias_a", in: fields).index, self.entry("alias_b", in: fields).index
      )
    }

    // Every kind the table writes, through the parser: the typed stores land where the compiler
    // would have put the value, optional and initialised members alike, and a custom type still
    // reaches its own conversion.
    @Test
    func `Writes land in the right members`() throws {
      let json = #"""
        {"flag":true,"count":-7,"small":-3,"wide":18446744073709551615,"ratio":2.5,
         "single":0.5,"name":"blob","nested":{"value":9},"scores":[1,2],"counts":{"a":1},
         "alias_b":42,"text":"long","tags":["a","b"]}
        """#
      var stream = PartialsStream(initialValue: TableScalars.Partial(), from: .json())
      try stream.next(Array(json.utf8))
      let value = try stream.finish()
      expectNoDifference(value.flag, true)
      expectNoDifference(value.count, -7)
      expectNoDifference(value.small, -3)
      expectNoDifference(value.wide, UInt64.max)
      expectNoDifference(value.ratio, 2.5)
      expectNoDifference(value.single, 0.5)
      expectNoDifference(value.name.map(String.init), "blob")
      expectNoDifference(value.nested?.value, 9)
      expectNoDifference(value.scores.map(Array.init), [1, 2])
      expectNoDifference(value.counts?["a"], 1)
      expectNoDifference(value.aliased, 42)
      expectNoDifference(value.text.map(String.init), "long")
      expectNoDifference(value.tags?.map(String.init), ["a", "b"])

      var initialized = PartialsStream(initialValue: TableInitialized.Partial(), from: .json())
      try initialized.next(
        Array(#"{"count":3,"name":"x","nested":{"value":4},"scores":[5],"tags":["t"]}"#.utf8)
      )
      let initializedValue = try initialized.finish()
      expectNoDifference(initializedValue.count, 3)
      expectNoDifference(String(initializedValue.name), "x")
      expectNoDifference(initializedValue.nested.value, 4)
      expectNoDifference(Array(initializedValue.scores), [5])
      expectNoDifference(initializedValue.tags.map(String.init), ["t"])

      var custom = PartialsStream(initialValue: TableCustom.Partial(), from: .json())
      try custom.next(Array(#"{"temperature":21.5,"count":1}"#.utf8))
      let customValue = try custom.finish()
      expectNoDifference(customValue.temperature?.degrees, 21.5)
      expectNoDifference(customValue.count, 1)
    }

    @Test
    func `Null clears optional members and rejects others`() throws {
      var value = TableScalars.Partial()
      try parsePartial(#"{"count":5,"name":"a","count":null,"name":null}"#, into: &value)
      expectNoDifference(value.count, nil)
      expectNoDifference(value.name, nil)

      var initialized = TableInitialized.Partial()
      #expect(throws: (any Error).self) {
        try parsePartial(#"{"count":null}"#, into: &initialized)
      }
    }

    @Test(arguments: [Int.max, 7, 1])
    func `Keys longer than a word verify their tail`(chunk: Int) throws {
      var value = TableLongKeys.Partial()
      try parsePartial(
        #"{"a_very_long_key_name_two":2,"a_very_long_key_name_one":1,"a_very_long_key_nope":3}"#,
        into: &value, chunk: chunk
      )
      expectNoDifference(value.one, 1)
      expectNoDifference(value.two, 2)
    }

    // The sink's own scan, over a table past `indexThreshold`: it stops at the first entry whose
    // first word and length match and hands a longer key's tail to a second probe, which must keep
    // probing past a tail that differs. Keys of exactly a word, and one past it, sit either side
    // of that hand-off.
    @Test(arguments: [Int.max, 7, 1])
    func `Indexed tables match long keys past a first-word collision`(chunk: Int) throws {
      #expect(TableIndexedLongKeys.Partial.streamSchema.fieldIndex != nil)
      var value = TableIndexedLongKeys.Partial()
      try parsePartial(
        #"{"a_very_long_key_name_two":2,"a_very_long_key_name_one":1,"a_very_long_key_nope":3,"#
          + #""f3":4,"exactly8":5,"exactly8x":6,"exactly9":7,"f15":8}"#,
        into: &value, chunk: chunk
      )
      expectNoDifference(value.one, 1)
      expectNoDifference(value.two, 2)
      expectNoDifference(value.f3, 4)
      expectNoDifference(value.exactly8, 5)
      expectNoDifference(value.exactly8x, 6)
      expectNoDifference(value.f15, 8)
    }

    // The tail compare reads words, the last one overlapping from the key's end, so every length
    // past a word and every byte of its tail is a separate case: a key differing only at byte `i`
    // must miss, and the span is allocated at exactly the key's length so nothing past it exists
    // to be read. Run over a scanned table and an indexed one (past `indexThreshold`).
    @Test(arguments: [false, true])
    func `Long-key tail compare checks every byte at every length`(indexed: Bool) {
      for length in 9...40 {
        let key = (0..<length).map { UInt8(ascii: "a") + UInt8($0 % 26) }
        var fields = [
          StreamField(
            key: String(decoding: key, as: UTF8.self), index: 7, kind: .int, optional: false,
            offset: 0
          )
        ]
        if indexed {
          for filler in 0..<StreamFieldTable.indexThreshold {
            fields.append(
              StreamField(key: "f\(filler)", index: Int32(filler), kind: .int, optional: false, offset: 0)
            )
          }
        }
        let table = StreamFieldTable(fields)
        func identifier(_ bytes: [UInt8]) -> Int32 {
          let exact = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: bytes.count)
          defer { exact.deallocate() }
          _ = exact.initialize(from: bytes)
          return table.fieldIdentifier(for: Span(_unsafeElements: UnsafeBufferPointer(exact)))
        }
        #expect(identifier(key) == 7, "length \(length)")
        for position in 8..<length {
          var changed = key
          changed[position] ^= 0x20
          #expect(identifier(changed) == -1, "length \(length), byte \(position)")
        }
      }
    }
}

@StreamParseable
private struct TableLongKeys: Equatable {
  @StreamParseableMember(keyNames: ["a_very_long_key_name_one"])
  var one: Int = 0
  @StreamParseableMember(keyNames: ["a_very_long_key_name_two"])
  var two: Int = 0
}

@StreamParseable
private struct TableIndexedLongKeys: Equatable {
  @StreamParseableMember(keyNames: ["a_very_long_key_name_one"])
  var one: Int = 0
  @StreamParseableMember(keyNames: ["a_very_long_key_name_two"])
  var two: Int = 0
  var exactly8: Int = 0
  var exactly8x: Int = 0
  var f0: Int = 0
  var f1: Int = 0
  var f2: Int = 0
  var f3: Int = 0
  var f4: Int = 0
  var f5: Int = 0
  var f6: Int = 0
  var f7: Int = 0
  var f8: Int = 0
  var f9: Int = 0
  var f10: Int = 0
  var f11: Int = 0
  var f12: Int = 0
  var f13: Int = 0
  var f14: Int = 0
  var f15: Int = 0
}

extension Array where Element == UInt8 {
  fileprivate func paddedLeadingWordForTest() -> UInt64 {
    var word: UInt64 = 0
    for (offset, byte) in self.prefix(8).enumerated() {
      word |= UInt64(byte) << (UInt64(offset) * 8)
    }
    return word
  }
}
