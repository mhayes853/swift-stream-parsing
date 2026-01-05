#if canImport(Foundation)
  import Foundation

  // MARK: - Data

  extension Data: StreamParseable {
    public typealias Partial = Self
  }

  extension Data: StreamParseableValue {
    public static func initialParseableValue() -> Self {
      Self()
    }

    public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
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

  extension Decimal: StreamParseableValue {
    public static func initialParseableValue() -> Self {
      Decimal(0)
    }

    public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
      handlers.registerIntHandler(\.streamParsingIntValue)
      handlers.registerInt8Handler(\.streamParsingInt8Value)
      handlers.registerInt16Handler(\.streamParsingInt16Value)
      handlers.registerInt32Handler(\.streamParsingInt32Value)
      handlers.registerInt64Handler(\.streamParsingInt64Value)
      handlers.registerUIntHandler(\.streamParsingUIntValue)
      handlers.registerUInt8Handler(\.streamParsingUInt8Value)
      handlers.registerUInt16Handler(\.streamParsingUInt16Value)
      handlers.registerUInt32Handler(\.streamParsingUInt32Value)
      handlers.registerUInt64Handler(\.streamParsingUInt64Value)
      handlers.registerFloatHandler(\.streamParsingFloatValue)
      handlers.registerDoubleHandler(\.streamParsingDoubleValue)
      if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) {
        handlers.registerInt128Handler(\.streamParsingInt128Value)
        handlers.registerUInt128Handler(\.streamParsingUInt128Value)
      }
    }

    private var streamParsingIntValue: Int {
      get { self.decimalNumber.intValue }
      set { self = Decimal(newValue) }
    }

    private var streamParsingInt8Value: Int8 {
      get { self.decimalNumber.int8Value }
      set { self = Decimal(newValue) }
    }

    private var streamParsingInt16Value: Int16 {
      get { self.decimalNumber.int16Value }
      set { self = Decimal(newValue) }
    }

    private var streamParsingInt32Value: Int32 {
      get { self.decimalNumber.int32Value }
      set { self = Decimal(newValue) }
    }

    private var streamParsingInt64Value: Int64 {
      get { self.decimalNumber.int64Value }
      set { self = Decimal(newValue) }
    }

    private var streamParsingUIntValue: UInt {
      get { self.decimalNumber.uintValue }
      set { self = Decimal(newValue) }
    }

    private var streamParsingUInt8Value: UInt8 {
      get { self.decimalNumber.uint8Value }
      set { self = Decimal(newValue) }
    }

    private var streamParsingUInt16Value: UInt16 {
      get { self.decimalNumber.uint16Value }
      set { self = Decimal(newValue) }
    }

    private var streamParsingUInt32Value: UInt32 {
      get { self.decimalNumber.uint32Value }
      set { self = Decimal(newValue) }
    }

    private var streamParsingUInt64Value: UInt64 {
      get { self.decimalNumber.uint64Value }
      set { self = Decimal(newValue) }
    }

    private var streamParsingFloatValue: Float {
      get { self.decimalNumber.floatValue }
      set { self = Decimal(Double(newValue)) }
    }

    private var streamParsingDoubleValue: Double {
      get { self.decimalNumber.doubleValue }
      set { self = Decimal(Double(newValue)) }
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    private var streamParsingInt128Value: Int128 {
      get { Int128(self.decimalNumber.int64Value) }
      set { self = Decimal(string: String(newValue)) ?? .zero }
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    private var streamParsingUInt128Value: UInt128 {
      get { UInt128(self.decimalNumber.uint64Value) }
      set { self = Decimal(string: String(newValue)) ?? .zero }
    }

    private var decimalNumber: NSDecimalNumber {
      NSDecimalNumber(decimal: self)
    }
  }

  // MARK: - PersonNameComponents

  extension PersonNameComponents: StreamParseable, StreamParseableValue {
    public typealias Partial = Self

    public static func initialParseableValue() -> Self {
      Self()
    }

    public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
      handlers.registerKeyedHandler(forKey: "familyName", \.familyName)
      handlers.registerKeyedHandler(forKey: "givenName", \.givenName)
      handlers.registerKeyedHandler(forKey: "middleName", \.middleName)
      handlers.registerKeyedHandler(forKey: "namePrefix", \.namePrefix)
      handlers.registerKeyedHandler(forKey: "nameSuffix", \.nameSuffix)
      handlers.registerKeyedHandler(forKey: "nickname", \.nickname)
      handlers.registerKeyedHandler(forKey: "phoneticRepresentation", \.phoneticRepresentation)
    }
  }
#endif
