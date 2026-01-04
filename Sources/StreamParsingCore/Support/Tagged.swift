#if StreamParsingTagged
  import Tagged

  extension Tagged: StreamParseable where RawValue: StreamParseable {
    public typealias Partial = Tagged<Tag, RawValue.Partial>
  }

  extension Tagged: StreamParseableReducer where RawValue: StreamParseableReducer {
    public static func initialReduceableValue() -> Self {
      Tagged(rawValue: .initialReduceableValue())
    }
  }
#endif
