#if StreamParsingTagged
  import Tagged

  extension Tagged: StreamParseable where RawValue: StreamParseable {
    public typealias Partial = Tagged<Tag, RawValue.Partial>
  }

  extension Tagged: StreamActionReducer where RawValue: StreamActionReducer {
    public mutating func reduce(action: StreamAction) throws {
      try self.rawValue.reduce(action: action)
    }
  }

  extension Tagged: StreamParseableReducer where RawValue: StreamParseableReducer {
    public static func initialReduceableValue() -> Self {
      Tagged(rawValue: .initialReduceableValue())
    }
  }

  extension Tagged: ConvertibleFromStreamedValue where RawValue: ConvertibleFromStreamedValue {
    public init?(streamedValue: StreamedValue) {
      guard let rawValue = RawValue(streamedValue: streamedValue) else { return nil }
      self.init(rawValue: rawValue)
    }
  }
#endif
