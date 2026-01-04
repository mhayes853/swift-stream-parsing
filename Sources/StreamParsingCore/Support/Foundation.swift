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
