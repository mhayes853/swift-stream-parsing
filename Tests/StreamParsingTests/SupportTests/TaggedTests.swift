#if StreamParsingTagged
  import CustomDump
  import StreamParsing
  import Tagged
  import Testing

  @Suite
  struct `StreamActionReducer+Tagged tests` {
    @Test
    func `Sets Tagged From SetValue`() throws {
      var reducer = Tagged<UserIDTag, String>(rawValue: "old")
      try reducer.reduce(action: .setValue(.string("new")))
      expectNoDifference(reducer, Tagged<UserIDTag, String>(rawValue: "new"))
    }

    @Test
    func `Reduces RawValue For Non SetValue Actions`() throws {
      var reducer = Tagged<MetadataTag, MockPartial>(rawValue: MockPartial())
      let action = StreamAction.delegateKeyed(key: "metadata", .setValue(.string("value")))
      try reducer.reduce(action: action)
      expectNoDifference(reducer.rawValue.commands, [action])
    }

    @Test
    func `Throws When SetValue Type Is Invalid`() {
      var reducer = Tagged<UserIDTag, String>(rawValue: "old")
      #expect(throws: Error.self) {
        try reducer.reduce(action: .setValue(.int(1)))
      }
    }

    @Test
    func `Converts Tagged From StreamedValue`() {
      let value = Tagged<UserIDTag, String>(streamedValue: .string("new"))
      expectNoDifference(value, Tagged<UserIDTag, String>(rawValue: "new"))
    }

    @Test
    func `Returns Nil When Tagged Init Fails From StreamedValue`() {
      let value = Tagged<LimitedTag, LimitedRawValue>(streamedValue: .string("bad"))
      expectNoDifference(value, nil)
    }
  }

  private enum UserIDTag {}
  private enum MetadataTag {}
  private enum LimitedTag {}

  private struct LimitedRawValue: Equatable, ConvertibleFromStreamedValue {
    var value: String

    init(value: String) {
      self.value = value
    }

    init?(streamedValue: StreamedValue) {
      guard case .string(let value) = streamedValue, value == "allowed" else {
        return nil
      }
      self.value = value
    }
  }
#endif
