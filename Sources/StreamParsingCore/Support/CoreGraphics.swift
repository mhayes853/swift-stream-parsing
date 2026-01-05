#if canImport(CoreGraphics)
  import CoreGraphics

  extension CGFloat: StreamParseable {
    public typealias Partial = Self
  }

  extension CGFloat: StreamParseableReducer {
    public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
      handlers.registerDoubleHandler(\.streamParsingDoubleValue)
    }

    private var streamParsingDoubleValue: Double {
      get { Double(self) }
      set { self = newValue }
    }
  }
#endif
