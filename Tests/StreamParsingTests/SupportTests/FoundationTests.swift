#if canImport(Foundation)
  import CustomDump
  import Foundation
  import StreamParsing
  import Testing

  @Suite
  struct `Foundation tests` {
    @Test
    func `Data Reducer Applies Parsed String Through PartialsStream`() throws {
      let expected = Data("hello".utf8)
      let parser = MockParser<Data>(actions: [0x00: .string("hello")])
      var stream = PartialsStream(initialValue: Data(), from: parser)

      let result = try stream.next(0x00)

      expectNoDifference(result, expected)
      expectNoDifference(stream.current, expected)
    }

    @Test
    func `Decimal Reducer Applies Parsed Integer Through PartialsStream`() throws {
      let expected = Decimal(42)
      let parser = MockParser<Decimal>(actions: [0x01: .int(42)])
      var stream = PartialsStream(initialValue: Decimal(), from: parser)

      let result = try stream.next(0x01)

      expectNoDifference(result, expected)
      expectNoDifference(stream.current, expected)
    }

    @Test
    func `Decimal Reducer Applies Parsed Unsigned Integer Through PartialsStream`() throws {
      let value: UInt = 123
      let expected = Decimal(value)
      let parser = MockParser<Decimal>(actions: [0x02: .uint(value)])
      var stream = PartialsStream(initialValue: Decimal(), from: parser)

      let result = try stream.next(0x02)

      expectNoDifference(result, expected)
      expectNoDifference(stream.current, expected)
    }

    @Test
    func `Decimal Reducer Applies Parsed Double Through PartialsStream`() throws {
      let value = 3.14
      let expected = Decimal(value)
      let parser = MockParser<Decimal>(actions: [0x03: .double(value)])
      var stream = PartialsStream(initialValue: Decimal(), from: parser)

      let result = try stream.next(0x03)

      expectNoDifference(result, expected)
      expectNoDifference(stream.current, expected)
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    @Test
    func `Decimal Reducer Applies Parsed Int128 Through PartialsStream`() throws {
      let value = Int128(Int64.max) + 1
      let expected = Decimal(string: String(value))
      let parser = MockParser<Decimal>(actions: [0x04: .int128(value)])
      var stream = PartialsStream(initialValue: Decimal(), from: parser)

      let result = try stream.next(0x04)

      expectNoDifference(result, expected)
      expectNoDifference(stream.current, expected)
    }
  }
#endif
