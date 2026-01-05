#if StreamParsingTagged
  import Tagged

  extension Tagged: StreamParseable where RawValue: StreamParseable {
    public typealias Partial = Tagged<Tag, RawValue.Partial>
  }

  extension Tagged: StreamParseableReducer where RawValue: StreamParseableReducer {
    public static func initialReduceableValue() -> Self {
      Tagged(rawValue: .initialReduceableValue())
    }

    public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
      handlers.registerScopedHandlers(on: RawValue.self, \.rawValue)
    }
  }
#endif
