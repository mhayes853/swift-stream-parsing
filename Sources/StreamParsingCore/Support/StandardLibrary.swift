// MARK: - String

extension String: StreamParseable {
  public typealias Partial = Self
}

extension String: StreamParseableValue {
  public static func initialParseableValue() -> Self {
    ""
  }

  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerStringHandler(\.self)
  }
}

// MARK: - Double

extension Double: StreamParseable {
  public typealias Partial = Self
}

extension Double: StreamParseableValue {
  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerDoubleHandler(\.self)
  }
}

// MARK: - Float

extension Float: StreamParseable {
  public typealias Partial = Self
}

extension Float: StreamParseableValue {
  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerFloatHandler(\.self)
  }
}

// MARK: - Bool

extension Bool: StreamParseable {
  public typealias Partial = Self
}

extension Bool: StreamParseableValue {
  public static func initialParseableValue() -> Self {
    false
  }

  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerBoolHandler(\.self)
  }
}

// MARK: - Int8

extension Int8: StreamParseable {
  public typealias Partial = Self
}

extension Int8: StreamParseableValue {
  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerInt8Handler(\.self)
  }
}

// MARK: - Int16

extension Int16: StreamParseable {
  public typealias Partial = Self
}

extension Int16: StreamParseableValue {
  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerInt16Handler(\.self)
  }
}
// MARK: - Int32

extension Int32: StreamParseable {
  public typealias Partial = Self
}

extension Int32: StreamParseableValue {
  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerInt32Handler(\.self)
  }
}

// MARK: - Int64

extension Int64: StreamParseable {
  public typealias Partial = Self
}

extension Int64: StreamParseableValue {
  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerInt64Handler(\.self)
  }
}

// MARK: - Int

extension Int: StreamParseable {
  public typealias Partial = Self
}

extension Int: StreamParseableValue {
  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerIntHandler(\.self)
  }
}

// MARK: - UInt8

extension UInt8: StreamParseable {
  public typealias Partial = Self
}

extension UInt8: StreamParseableValue {
  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerUInt8Handler(\.self)
  }
}

// MARK: - UInt16

extension UInt16: StreamParseable {
  public typealias Partial = Self
}

extension UInt16: StreamParseableValue {
  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerUInt16Handler(\.self)
  }
}

// MARK: - UInt32

extension UInt32: StreamParseable {
  public typealias Partial = Self
}

extension UInt32: StreamParseableValue {
  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerUInt32Handler(\.self)
  }
}

// MARK: - UInt64

extension UInt64: StreamParseable {
  public typealias Partial = Self
}

extension UInt64: StreamParseableValue {
  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerUInt64Handler(\.self)
  }
}

// MARK: - UInt

extension UInt: StreamParseable {
  public typealias Partial = Self
}

extension UInt: StreamParseableValue {
  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerUIntHandler(\.self)
  }
}

// MARK: - Int128

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
extension Int128: StreamParseable {
  public typealias Partial = Self
}

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
extension Int128: StreamParseableValue {
  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerInt128Handler(\.self)
  }
}

// MARK: - UInt128

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
extension UInt128: StreamParseable {
  public typealias Partial = Self
}

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
extension UInt128: StreamParseableValue {
  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerUInt128Handler(\.self)
  }
}

// MARK: - Array

extension Array: StreamParseable where Element: StreamParseable {
  public typealias Partial = [Element.Partial]
}

extension Array: StreamParseableValue where Element: StreamParseableValue {
  public static func initialParseableValue() -> [Element] {
    []
  }

  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerArrayHandler(\.self)
  }
}

extension Array: StreamParseableArrayObject where Element: StreamParseableValue {}

// MARK: - Dictionary

extension Dictionary: StreamParseable where Key == String, Value: StreamParseable {
  public typealias Partial = [String: Value.Partial]
}

extension Dictionary: StreamParseableValue where Key == String, Value: StreamParseableValue {
  public static func initialParseableValue() -> [String: Value] {
    [:]
  }

  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerDictionaryHandler(\.self)
  }
}

extension Dictionary: StreamParseableDictionaryObject
where Key == String, Value: StreamParseableValue {}

// MARK: - Optional

extension Optional: StreamParseable where Wrapped: StreamParseable {
  public typealias Partial = Wrapped.Partial?
}

extension Optional: StreamParseableValue where Wrapped: StreamParseableValue {
  public static func initialParseableValue() -> Wrapped? {
    Wrapped.initialParseableValue()
  }

  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerScopedHandlers(on: Wrapped.self, \.streamParsingWrappedValue)
    handlers.registerNilHandler(\.self)
  }

  private var streamParsingWrappedValue: Wrapped {
    get { self ?? Wrapped.initialParseableValue() }
    set { self = newValue }
  }
}
