#if canImport(Foundation)
  import Foundation

  // MARK: - Data

  extension Data: StreamParseable {
    public typealias Partial = Self
  }

  extension Data: StreamParseableReducer {
    public static func initialReduceableValue() -> Self {
      Self()
    }

    public static func registerHandlers<Handlers: StreamParserHandlers<Self>>(
      in handlers: inout Handlers
    ) {
      handlers.registerStringHandler(\.streamParsingStringValue)
    }

    private var streamParsingStringValue: String {
      get { String(decoding: self, as: UTF8.self) }
      set { self = Data(newValue.utf8) }
    }
  }

  // MARK: - Decimal

  extension Decimal: StreamParseable {
    public typealias Partial = Self
  }

  extension Decimal: StreamParseableReducer {
    public static func initialReduceableValue() -> Self {
      Decimal(0)
    }
  }
#endif
