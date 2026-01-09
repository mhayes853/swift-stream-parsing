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
      handlers.registerDoubleHandler(\.streamParsingDoubleValue)
    }

    private var streamParsingDoubleValue: Double {
      get {
        if self._length == 0 {
          return self.sign == .minus ? Double.nan : 0
        }
        var d = 0.0
        for idx in (0..<min(self._length, 8)).reversed() {
          withUnsafeBytes(of: self._mantissa) { ptr in
            let value = ptr.load(
              fromByteOffset: Int(idx) * MemoryLayout<UInt16>.stride,
              as: UInt16.self
            )
            d = d * 65536 + Double(value)
          }
        }
        if self.exponent < 0 {
          for _ in self.exponent..<0 {
            d /= 10.0
          }
        } else {
          for _ in 0..<self.exponent {
            d *= 10.0
          }
        }
        return self.sign == .minus ? -d : d
      }
      set { self = Decimal(Double(newValue)) }
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
