#if StreamParsingTagged
  import Tagged

  extension Tagged: StreamParseable where RawValue: StreamParseable {
    public typealias Partial = Tagged<Tag, RawValue.Partial>
  }

  extension Tagged: StreamParseableValue where RawValue: StreamParseableValue {
    public static func initialParseableValue() -> Self {
      Tagged(rawValue: .initialParseableValue())
    }

    public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
      handlers.registerScopedHandlers(on: RawValue.self, \.rawValue)
    }
  }
#endif
