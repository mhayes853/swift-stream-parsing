// MARK: - String

extension String: StreamParseable {
  public typealias Partial = Self
}

extension String: StreamParseableReducer {
  public static func initialReduceableValue() -> Self {
    ""
  }

  public static func registerHandlers(
    in handlers: inout some StreamParserHandlers<Self>
  ) {
    handlers.registerStringHandler { $0 = $1 }
  }
}

// MARK: - Double

extension Double: StreamParseable {
  public typealias Partial = Self
}

extension Double: StreamParseableReducer {
  public static func registerHandlers(
    in handlers: inout some StreamParserHandlers<Self>
  ) {
    handlers.registerDoubleHandler { $0 = $1 }
  }
}

// MARK: - Float

extension Float: StreamParseable {
  public typealias Partial = Self
}

extension Float: StreamParseableReducer {
  public static func registerHandlers(
    in handlers: inout some StreamParserHandlers<Self>
  ) {
    handlers.registerFloatHandler { $0 = $1 }
  }
}

// MARK: - Bool

extension Bool: StreamParseable {
  public typealias Partial = Self
}

extension Bool: StreamParseableReducer {
  public static func initialReduceableValue() -> Self {
    false
  }

  public static func registerHandlers(
    in handlers: inout some StreamParserHandlers<Self>
  ) {
    handlers.registerBoolHandler { $0 = $1 }
  }
}

// MARK: - Int8

extension Int8: StreamParseable {
  public typealias Partial = Self
}

extension Int8: StreamParseableReducer {
  public static func registerHandlers(
    in handlers: inout some StreamParserHandlers<Self>
  ) {
    handlers.registerInt8Handler { $0 = $1 }
  }
}

// MARK: - Int16

extension Int16: StreamParseable {
  public typealias Partial = Self
}

extension Int16: StreamParseableReducer {
  public static func registerHandlers(
    in handlers: inout some StreamParserHandlers<Self>
  ) {
    handlers.registerInt16Handler { $0 = $1 }
  }
}
// MARK: - Int32

extension Int32: StreamParseable {
  public typealias Partial = Self
}

extension Int32: StreamParseableReducer {
  public static func registerHandlers(
    in handlers: inout some StreamParserHandlers<Self>
  ) {
    handlers.registerInt32Handler { $0 = $1 }
  }
}

// MARK: - Int64

extension Int64: StreamParseable {
  public typealias Partial = Self
}

extension Int64: StreamParseableReducer {
  public static func registerHandlers(
    in handlers: inout some StreamParserHandlers<Self>
  ) {
    handlers.registerInt64Handler { $0 = $1 }
  }
}

// MARK: - Int

extension Int: StreamParseable {
  public typealias Partial = Self
}

extension Int: StreamParseableReducer {
  public static func registerHandlers(
    in handlers: inout some StreamParserHandlers<Self>
  ) {
    handlers.registerIntHandler { $0 = $1 }
  }
}

// MARK: - UInt8

extension UInt8: StreamParseable {
  public typealias Partial = Self
}

extension UInt8: StreamParseableReducer {
  public static func registerHandlers(
    in handlers: inout some StreamParserHandlers<Self>
  ) {
    handlers.registerUInt8Handler { $0 = $1 }
  }
}

// MARK: - UInt16

extension UInt16: StreamParseable {
  public typealias Partial = Self
}

extension UInt16: StreamParseableReducer {
  public static func registerHandlers(
    in handlers: inout some StreamParserHandlers<Self>
  ) {
    handlers.registerUInt16Handler { $0 = $1 }
  }
}

// MARK: - UInt32

extension UInt32: StreamParseable {
  public typealias Partial = Self
}

extension UInt32: StreamParseableReducer {
  public static func registerHandlers(
    in handlers: inout some StreamParserHandlers<Self>
  ) {
    handlers.registerUInt32Handler { $0 = $1 }
  }
}

// MARK: - UInt64

extension UInt64: StreamParseable {
  public typealias Partial = Self
}

extension UInt64: StreamParseableReducer {
  public static func registerHandlers(
    in handlers: inout some StreamParserHandlers<Self>
  ) {
    handlers.registerUInt64Handler { $0 = $1 }
  }
}

// MARK: - UInt

extension UInt: StreamParseable {
  public typealias Partial = Self
}

extension UInt: StreamParseableReducer {
  public static func registerHandlers(
    in handlers: inout some StreamParserHandlers<Self>
  ) {
    handlers.registerUIntHandler { $0 = $1 }
  }
}

// MARK: - Int128

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
extension Int128: StreamParseable {
  public typealias Partial = Self
}

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
extension Int128: StreamParseableReducer {
  public static func registerHandlers(
    in handlers: inout some StreamParserHandlers<Self>
  ) {
    handlers.registerInt128Handler { $0 = $1 }
  }
}

// MARK: - UInt128

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
extension UInt128: StreamParseable {
  public typealias Partial = Self
}

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
extension UInt128: StreamParseableReducer {
  public static func registerHandlers(
    in handlers: inout some StreamParserHandlers<Self>
  ) {
    handlers.registerUInt128Handler { $0 = $1 }
  }
}

// MARK: - Array

extension Array: StreamParseable where Element: StreamParseable {
  public typealias Partial = [Element.Partial]
}

extension Array: StreamParseableReducer where Element: StreamParseableReducer {
  public static func initialReduceableValue() -> [Element] {
    []
  }
}

// MARK: - Dictionary

extension Dictionary: StreamParseable where Key == String, Value: StreamParseable {
  public typealias Partial = [String: Value.Partial]
}

extension Dictionary: StreamParseableReducer where Key == String, Value: StreamParseableReducer {
  public static func initialReduceableValue() -> [String: Value] {
    [:]
  }
}

// MARK: - Optional

extension Optional: StreamParseable where Wrapped: StreamParseable {
  public typealias Partial = Wrapped.Partial?
}

extension Optional: StreamParseableReducer where Wrapped: StreamParseableReducer {
  public static func initialReduceableValue() -> Wrapped? {
    Wrapped.initialReduceableValue()
  }

  public static func registerHandlers(
    in handlers: inout some StreamParserHandlers<Self>
  ) {
    handlers.registerScopedHandlers(on: Wrapped.self) { reducer, scope in
      var value = reducer ?? Wrapped.initialReduceableValue()
      scope(&value)
      reducer = value
    }
    handlers.registerNilHandler { $0 = nil }
  }
}
