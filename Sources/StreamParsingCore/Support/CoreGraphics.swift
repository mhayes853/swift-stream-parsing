#if StreamParsingCoreGraphics && canImport(CoreGraphics)
  import CoreGraphics

  // MARK: - Conversion protocols

  // CGFloat is not LosslessStringConvertible, so it cannot pick up the shared floating point
  // conversion and goes through Double, which is what the registration based path did too.
  extension CGFloat: StreamNumberConvertible, StreamInitializable, StreamParseableRoot {
    public static func streamInitialValue() -> Self { 0 }

    public init?(streamParsing bytes: Span<UInt8>, info: NumberInfo) {
      guard let value = Double(streamParsing: bytes, info: info) else { return nil }
      self = CGFloat(value)
    }
  }

  // MARK: - Legacy handler registration

  extension CGFloat: StreamParseable {
    public typealias Partial = Self
  }

  extension CGFloat: StreamParseableValue {
    public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
      handlers.registerDoubleHandler(\.streamParsingDoubleValue)
    }

    private var streamParsingDoubleValue: Double {
      get { Double(self) }
      set { self = newValue }
    }
  }
#endif
