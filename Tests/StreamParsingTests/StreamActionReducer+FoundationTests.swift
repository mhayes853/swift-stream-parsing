#if canImport(Foundation)
  import Foundation
  import StreamParsing
  import Testing

  @Suite
  struct `StreamActionReducer+Foundation tests` {
    @Test
    func `Sets Data From UTF8 String`() throws {
      try expectSetValue(
        initial: Data(),
        expected: Data("hello".utf8),
        streamedValue: .string("hello")
      )
    }

    @Test
    func `Sets Decimal From Double`() throws {
      try expectSetValue(
        initial: Decimal(),
        expected: Decimal(12.5),
        streamedValue: .double(12.5)
      )
    }

    @Test
    func `Sets Decimal From Float`() throws {
      try expectSetValue(
        initial: Decimal(),
        expected: Decimal(Double(3.5)),
        streamedValue: .float(3.5)
      )
    }

    @Test
    func `Sets Decimal From Int32`() throws {
      try expectSetValue(
        initial: Decimal(),
        expected: Decimal(32),
        streamedValue: .int32(32)
      )
    }

    @Test
    func `Sets Decimal From UInt64`() throws {
      try expectSetValue(
        initial: Decimal(),
        expected: Decimal(64),
        streamedValue: .uint64(64)
      )
    }

    @Test
    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    func `Sets Decimal From Int128`() throws {
      let value: Int128 = 256
      try expectSetValue(
        initial: Decimal(),
        expected: Decimal(string: String(value))!,
        streamedValue: .int128(value)
      )
    }

    @Test
    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    func `Sets Decimal From UInt128`() throws {
      let value: UInt128 = 512
      try expectSetValue(
        initial: Decimal(),
        expected: Decimal(string: String(value))!,
        streamedValue: .uint128(value)
      )
    }

    @Test
    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    func `Sets Decimal From Large Int128`() throws {
      let value = Int128(Int64.max) + 1
      try expectSetValue(
        initial: Decimal(),
        expected: Decimal(string: String(value))!,
        streamedValue: .int128(value)
      )
    }

    @Test
    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    func `Sets Decimal From Large UInt128`() throws {
      let value = UInt128(UInt64.max) + 1
      try expectSetValue(
        initial: Decimal(),
        expected: Decimal(string: String(value))!,
        streamedValue: .uint128(value)
      )
    }

    @Test
    func `Throws For Non SetValue Data Action`() {
      expectThrowsOnNonSetValue(initial: Data())
    }

    @Test
    func `Throws For Non SetValue Decimal Action`() {
      expectThrowsOnNonSetValue(initial: Decimal())
    }
  }
#endif
