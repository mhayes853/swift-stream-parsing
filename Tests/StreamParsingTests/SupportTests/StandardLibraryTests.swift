import CustomDump
import StreamParsing
import Testing

@Suite
struct `StreamActionReducer+StandardLibrary tests` {
  @Test
  func `Throws For Non SetValue Convertible Reducer Action`() {
    let reducer = DefaultConvertibleReducer(value: "old")
    expectThrowsOnNonSetValue(initial: reducer)
  }

  @Test
  func `Sets Convertible Reducer From SetValue`() throws {
    var reducer = DefaultConvertibleReducer(value: "old")
    try reducer.reduce(action: .setValue(.string("new")))
    expectNoDifference(reducer, DefaultConvertibleReducer(value: "new"))
  }

  @Test
  func `Initializes Reducer From InitialValue`() {
    let value = String.initialValue()
    expectNoDifference(value, "")
  }

  @Test
  func `Initializes Boolean Reducer From InitialValue`() {
    let value = Bool.initialValue()
    expectNoDifference(value, false)
  }

  @Test
  func `Sets String From SetValue`() throws {
    try expectSetValue(initial: "", expected: "hello", streamedValue: .string("hello"))
  }

  @Test
  func `Sets Double From SetValue`() throws {
    try expectSetValue(initial: 0.0, expected: 12.5, streamedValue: .double(12.5))
  }

  @Test
  func `Sets Float From SetValue`() throws {
    try expectSetValue(initial: Float(0), expected: Float(3.5), streamedValue: .float(3.5))
  }

  @Test
  func `Converts Between Double And Float`() throws {
    try expectSetValue(initial: Float(0), expected: Float(3.5), streamedValue: .double(3.5))
    try expectSetValue(initial: 0.0, expected: 3.5, streamedValue: .float(3.5))
  }

  @Test
  func `Throws When Double To Float Overflows`() {
    expectThrowsOnSetValue(
      initial: Float(0),
      streamedValue: .double(Double.greatestFiniteMagnitude)
    )
  }

  @Test
  func `Sets Boolean From SetValue`() throws {
    try expectSetValue(initial: false, expected: true, streamedValue: .boolean(true))
  }

  @Test
  func `Sets Int8 From SetValue`() throws {
    try expectSetValue(initial: Int8(0), expected: Int8(8), streamedValue: .int8(8))
  }

  @Test
  func `Sets Int16 From SetValue`() throws {
    try expectSetValue(initial: Int16(0), expected: Int16(16), streamedValue: .int16(16))
  }

  @Test
  func `Sets Int32 From SetValue`() throws {
    try expectSetValue(initial: Int32(0), expected: Int32(32), streamedValue: .int32(32))
  }

  @Test
  func `Sets Int64 From SetValue`() throws {
    try expectSetValue(initial: Int64(0), expected: Int64(64), streamedValue: .int64(64))
  }

  @Test
  func `Sets Int From SetValue`() throws {
    try expectSetValue(initial: 0, expected: 128, streamedValue: .int(128))
  }

  @Test
  func `Sets UInt8 From SetValue`() throws {
    try expectSetValue(initial: UInt8(0), expected: UInt8(8), streamedValue: .uint8(8))
  }

  @Test
  func `Sets UInt16 From SetValue`() throws {
    try expectSetValue(initial: UInt16(0), expected: UInt16(16), streamedValue: .uint16(16))
  }

  @Test
  func `Sets UInt32 From SetValue`() throws {
    try expectSetValue(initial: UInt32(0), expected: UInt32(32), streamedValue: .uint32(32))
  }

  @Test
  func `Sets UInt64 From SetValue`() throws {
    try expectSetValue(initial: UInt64(0), expected: UInt64(64), streamedValue: .uint64(64))
  }

  @Test
  func `Sets UInt From SetValue`() throws {
    try expectSetValue(initial: UInt(0), expected: UInt(128), streamedValue: .uint(128))
  }

  @Test
  func `Reduces Array Element For DelegateUnkeyed`() throws {
    var reducer = [Int]()
    try reducer.reduce(action: .appendArrayElement)
    try reducer.reduce(action: .appendArrayElement)
    try reducer.reduce(action: .delegateUnkeyed(index: 1, .setValue(.int(9))))
    expectNoDifference(reducer, [0, 9])
  }

  @Test
  func `Reduces Dictionary Value For DelegateKeyed`() throws {
    var reducer = [String: Int]()
    let actions: [StreamAction] = [
      .delegateKeyed(key: "first", .createObjectValue),
      .delegateKeyed(key: "first", .setValue(.int(1))),
      .delegateKeyed(key: "second", .createObjectValue),
      .delegateKeyed(key: "second", .setValue(.int(2)))
    ]

    for action in actions {
      try reducer.reduce(action: action)
    }

    expectNoDifference(reducer, ["first": 1, "second": 2])
  }

  @Test
  func `Converts Between Signed Integers`() throws {
    try expectSetValue(initial: Int32(0), expected: Int32(32), streamedValue: .int64(32))
    try expectSetValue(initial: Int64(0), expected: Int64(8), streamedValue: .int8(8))
  }

  @Test
  func `Converts Between Unsigned Integers`() throws {
    try expectSetValue(initial: UInt32(0), expected: UInt32(32), streamedValue: .uint64(32))
    try expectSetValue(initial: UInt64(0), expected: UInt64(8), streamedValue: .uint8(8))
  }

  @Test
  func `Converts Unsigned To Signed When In Range`() throws {
    try expectSetValue(initial: Int16(0), expected: Int16(8), streamedValue: .uint8(8))
    try expectSetValue(initial: Int64(0), expected: Int64(32), streamedValue: .uint32(32))
  }

  @Test
  func `Converts Signed To Unsigned When Nonnegative`() throws {
    try expectSetValue(initial: UInt16(0), expected: UInt16(8), streamedValue: .int8(8))
    try expectSetValue(initial: UInt64(0), expected: UInt64(32), streamedValue: .int32(32))
  }

  @Test
  func `Throws When Signed To Unsigned Is Negative`() {
    expectThrowsOnSetValue(initial: UInt8(0), streamedValue: .int8(-1))
  }

  @Test
  func `Throws When Unsigned To Signed Overflows`() {
    expectThrowsOnSetValue(initial: Int8(0), streamedValue: .uint8(200))
  }

  @Test
  func `Throws When Signed Overflow`() {
    expectThrowsOnSetValue(initial: Int8(0), streamedValue: .int16(256))
  }

  @Test
  func `Throws When Unsigned Overflow`() {
    expectThrowsOnSetValue(initial: UInt8(0), streamedValue: .uint16(256))
  }

  @Test
  func `Converts Optional From Null StreamedValue`() {
    let value = String?(streamedValue: .null)
    expectNoDifference(value, .some(nil))
  }

  @Test
  func `Converts Optional From Invalid StreamedValue`() {
    let value = String?(streamedValue: .int(10))
    expectNoDifference(value, nil)
  }

  @Test
  func `Converts Optional From Wrapped StreamedValue`() {
    let value = String?(streamedValue: .string("hello"))
    expectNoDifference(value, "hello")
  }

  @Test
  @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
  func `Sets Int128 From SetValue`() throws {
    let initial: Int128 = 0
    let expected: Int128 = 256
    try expectSetValue(initial: initial, expected: expected, streamedValue: .int128(expected))
  }

  @Test
  @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
  func `Sets UInt128 From SetValue`() throws {
    let initial: UInt128 = 0
    let expected: UInt128 = 512
    try expectSetValue(initial: initial, expected: expected, streamedValue: .uint128(expected))
  }

  @Test
  func `Sets RawRepresentable From SetValue`() throws {
    var reducer = TestRawRepresentable(rawValue: "old")
    try reducer.reduce(action: .setValue(.string("new")))
    expectNoDifference(reducer, TestRawRepresentable(rawValue: "new"))
  }

  @Test
  func `Reduces RawValue For Non SetValue Actions`() throws {
    var reducer = PartialRawRepresentable(rawValue: MockPartial())
    let action = StreamAction.delegateKeyed(key: "metadata", .setValue("value"))
    try reducer.reduce(action: action)
    expectNoDifference(reducer.rawValue.commands, [action])
  }

  @Test
  func `Throws When SetValue Type Is Invalid`() {
    var reducer = TestRawRepresentable(rawValue: "old")
    #expect(throws: Error.self) {
      try reducer.reduce(action: .setValue(.int(1)))
    }
  }

  @Test
  func `Throws When RawValue Init Fails`() {
    var reducer = LimitedRawRepresentable(rawValue: "allowed")!
    #expect(throws: Error.self) {
      try reducer.reduce(action: .setValue(.string("bad")))
    }
  }

  @Test
  func `Converts RawRepresentable From StreamedValue`() {
    let value = TestRawRepresentable(streamedValue: .string("new"))
    expectNoDifference(value, TestRawRepresentable(rawValue: "new"))
  }

  @Test
  func `Returns Nil When RawRepresentable Init Fails From StreamedValue`() {
    let value = LimitedRawRepresentable(streamedValue: .string("bad"))
    expectNoDifference(value, nil)
  }
}

private struct DefaultConvertibleReducer: StreamActionReducer, ConvertibleFromStreamedValue,
  Equatable
{
  var value: String

  init(value: String) {
    self.value = value
  }

  init?(streamedValue: StreamedValue) {
    guard case .string(let value) = streamedValue else { return nil }
    self.value = value
  }
}

private struct TestRawRepresentable: RawRepresentable, Equatable {
  var rawValue: String

  init(rawValue: String) {
    self.rawValue = rawValue
  }
}

private struct LimitedRawRepresentable: RawRepresentable, Equatable {
  var rawValue: String

  init?(rawValue: String) {
    guard rawValue == "allowed" else {
      return nil
    }
    self.rawValue = rawValue
  }
}

private struct PartialRawRepresentable: RawRepresentable {
  var rawValue: MockPartial

  init(rawValue: MockPartial) {
    self.rawValue = rawValue
  }
}
