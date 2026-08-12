#if StreamParsingFoundation && canImport(Foundation)
  import Foundation
  import Testing

  import StreamParsing
  import StreamParsingCore

  @StreamParseable
  struct FoundationValues: Equatable {
    var blob: Data = Data()
    var amount: Decimal = 0
    var name: PersonNameComponents = PersonNameComponents()
  }

  @Suite
  struct `Foundation conversion tests` {
    // MARK: - Data

    @Test(arguments: [Int.max, 7, 1])
    func `Data accumulates string content`(chunk: Int) throws {
      var value = FoundationValues.Partial()
      try parsePartial(#"{"blob":"hello world"}"#, into: &value, chunk: chunk)
      #expect(value.blob == Data("hello world".utf8))
    }

    // The registration based path rebuilt a String from the whole accumulated value on every
    // write, so a payload this size was quadratic. Correctness is what is asserted here; the
    // cost is what changed.
    @Test
    func `Data accumulates a long payload byte by byte`() throws {
      let payload = String(repeating: "QUJDREVGR0hJSg", count: 512)
      var value = FoundationValues.Partial()
      try parsePartial(#"{"blob":"\#(payload)"}"#, into: &value, chunk: 1)
      #expect(value.blob == Data(payload.utf8))
    }

    @Test
    func `Data preserves multi byte UTF-8 and escapes`() throws {
      var value = FoundationValues.Partial()
      try parsePartial(#"{"blob":"Aé€😀\n\t"}"#, into: &value)
      #expect(value.blob == Data("Aé€😀\n\t".utf8))
    }

    // MARK: - Decimal

    // Decimal is built from the magnitude and decimal exponent the parser already accumulated,
    // so these are exact. Going through Double, as the registration based path did, loses every
    // one of them.
    @Test(
      arguments: [
        "0.1", "1.005", "3.14", "2.675", "0.07", "-0.1",
        "123456789012345678.9", "18263.29836292", "0.000001", "-987654321.123456789"
      ]
    )
    func `Decimal converts exactly`(literal: String) throws {
      var value = FoundationValues.Partial()
      try parsePartial(#"{"amount":\#(literal)}"#, into: &value)
      #expect(value.amount == Decimal(string: literal))
    }

    @Test
    func `Decimal through Double would have lost these`() throws {
      var value = FoundationValues.Partial()
      try parsePartial(#"{"amount":1.005}"#, into: &value)
      #expect(value.amount == Decimal(string: "1.005"))
      #expect(value.amount != Decimal(1.005))
    }

    @Test(arguments: ["1.5e3", "1.5E3", "15e-1", "-2e2", "0e0"])
    func `Decimal converts exponent forms`(literal: String) throws {
      var value = FoundationValues.Partial()
      try parsePartial(#"{"amount":\#(literal)}"#, into: &value)
      #expect(value.amount == Decimal(string: literal))
    }

    // Wider than the accumulator's UInt64 magnitude, so this reaches the string fallback.
    @Test
    func `Decimal falls back for magnitudes the accumulator cannot hold`() throws {
      let literal = "123456789012345678901234567890"
      var value = FoundationValues.Partial()
      try parsePartial(#"{"amount":\#(literal)}"#, into: &value)
      #expect(value.amount == Decimal(string: literal))
    }

    @Test(arguments: [Int.max, 7, 1])
    func `Decimal is chunk size independent`(chunk: Int) throws {
      var value = FoundationValues.Partial()
      try parsePartial(#"{"amount":-98765.4321}"#, into: &value, chunk: chunk)
      #expect(value.amount == Decimal(string: "-98765.4321"))
    }

    // MARK: - PersonNameComponents

    @Test(arguments: [Int.max, 7, 1])
    func `PersonNameComponents routes every key`(chunk: Int) throws {
      var value = FoundationValues.Partial()
      try parsePartial(
        """
        {"name":{"namePrefix":"Dr","givenName":"Blob","middleName":"Q",\
        "familyName":"Johnson","nameSuffix":"Jr","nickname":"Blobby"}}
        """,
        into: &value,
        chunk: chunk
      )
      let name = try #require(value.name)
      #expect(name.namePrefix == "Dr")
      #expect(name.givenName == "Blob")
      #expect(name.middleName == "Q")
      #expect(name.familyName == "Johnson")
      #expect(name.nameSuffix == "Jr")
      #expect(name.nickname == "Blobby")
    }

    // PersonNameComponents is a single bridged handle with no stored properties, so there is no
    // address for a frame to point at and a nested object under this key is skipped. Recorded
    // rather than left to be discovered, because the surrounding keys keep working.
    @Test
    func `PersonNameComponents skips a nested phonetic representation`() throws {
      var value = FoundationValues.Partial()
      try parsePartial(
        """
        {"name":{"givenName":"Blob","phoneticRepresentation":{"givenName":"blahb"},\
        "familyName":"Johnson"}}
        """,
        into: &value
      )
      let name = try #require(value.name)
      #expect(name.givenName == "Blob")
      #expect(name.familyName == "Johnson")
      #expect(name.phoneticRepresentation == nil)
    }

    @Test
    func `PersonNameComponents ignores keys it does not have`() throws {
      var value = FoundationValues.Partial()
      try parsePartial(
        #"{"name":{"unknown":"x","givenName":"Blob","nicknames":"y","given":"z"}}"#,
        into: &value
      )
      let name = try #require(value.name)
      #expect(name.givenName == "Blob")
      #expect(name.nickname == nil)
      #expect(name.familyName == nil)
    }

    @Test
    func `PersonNameComponents clears a member on null`() throws {
      var value = FoundationValues.Partial()
      try parsePartial(
        #"{"name":{"givenName":"Blob","familyName":null}}"#,
        into: &value
      )
      let name = try #require(value.name)
      #expect(name.givenName == "Blob")
      #expect(name.familyName == nil)
    }

    // The key words in the schema are written by hand, which is exactly what produced four wrong
    // literals out of nine before the macro took the job over. Each one is checked against the
    // key it claims to encode, and against a near miss that must not match.
    @Test(
      arguments: [
        ("familyName", Int32(0)), ("givenName", Int32(1)), ("middleName", Int32(2)),
        ("namePrefix", Int32(3)), ("nameSuffix", Int32(4)), ("nickname", Int32(5)),
        ("phoneticRepresentation", Int32(6))
      ]
    )
    func `Hand written key words encode the keys they claim`(key: String, field: Int32) {
      #expect(Self.matchField(key) == field)
      #expect(Self.matchField(key + "s") == -1)
      #expect(Self.matchField(String(key.dropLast())) == -1)
      #expect(Self.matchField(key.uppercased()) == -1)
    }

    private static func matchField(_ key: String) -> Int32 {
      let bytes = Array(key.utf8)
      return bytes.withUnsafeBufferPointer {
        PersonNameComponents.streamSchema.matchField(Span(_unsafeElements: $0))
      }
    }
  }
#endif
