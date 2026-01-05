// MARK: - JSONStreamParser

public struct JSONStreamParser<Reducer: StreamParseableReducer>: StreamParser {
  public let configuration: JSONStreamParser.Configuration
  private var handlers = Handlers()

  public init(configuration: JSONStreamParser.Configuration = JSONStreamParser.Configuration()) {
    self.configuration = configuration
  }

  public mutating func parse(
    bytes: some Sequence<UInt8>,
    into reducer: inout Reducer
  ) throws {}

  public mutating func registerHandlers() {
    Reducer.registerHandlers(in: &self.handlers)
  }
}

extension StreamParser {
  public static func json<Reducer>(
    configuration: JSONStreamParser<Reducer>.Configuration =
      JSONStreamParser<Reducer>.Configuration()
  ) -> Self where Self == JSONStreamParser<Reducer> {
    JSONStreamParser(configuration: configuration)
  }
}

// MARK: - Configuration

extension JSONStreamParser {
  public struct Configuration: Sendable {
    public var completePartialValues = false
    public var allowComments = false
    public var allowTrailingCommas = false
    public var allowUnquotedKeys = false

    public init(
      completePartialValues: Bool = false,
      allowComments: Bool = false,
      allowTrailingCommas: Bool = false,
      allowUnquotedKeys: Bool = false
    ) {
      self.completePartialValues = completePartialValues
      self.allowComments = allowComments
      self.allowTrailingCommas = allowTrailingCommas
      self.allowUnquotedKeys = allowUnquotedKeys
    }
  }
}

extension JSONStreamParser {
  public struct Handlers: StreamParserHandlers {
    public init() {}

    public mutating func registerStringHandler(
      _ keyPath: WritableKeyPath<Reducer, String>
    ) {}
    public mutating func registerBoolHandler(
      _ keyPath: WritableKeyPath<Reducer, Bool>
    ) {}
    public mutating func registerIntHandler(
      _ keyPath: WritableKeyPath<Reducer, Int>
    ) {}
    public mutating func registerInt8Handler(
      _ keyPath: WritableKeyPath<Reducer, Int8>
    ) {}
    public mutating func registerInt16Handler(
      _ keyPath: WritableKeyPath<Reducer, Int16>
    ) {}
    public mutating func registerInt32Handler(
      _ keyPath: WritableKeyPath<Reducer, Int32>
    ) {}
    public mutating func registerInt64Handler(
      _ keyPath: WritableKeyPath<Reducer, Int64>
    ) {}
    public mutating func registerUIntHandler(
      _ keyPath: WritableKeyPath<Reducer, UInt>
    ) {}
    public mutating func registerUInt8Handler(
      _ keyPath: WritableKeyPath<Reducer, UInt8>
    ) {}
    public mutating func registerUInt16Handler(
      _ keyPath: WritableKeyPath<Reducer, UInt16>
    ) {}
    public mutating func registerUInt32Handler(
      _ keyPath: WritableKeyPath<Reducer, UInt32>
    ) {}
    public mutating func registerUInt64Handler(
      _ keyPath: WritableKeyPath<Reducer, UInt64>
    ) {}
    public mutating func registerFloatHandler(
      _ keyPath: WritableKeyPath<Reducer, Float>
    ) {}
    public mutating func registerDoubleHandler(
      _ keyPath: WritableKeyPath<Reducer, Double>
    ) {}
    public mutating func registerNilHandler<Value>(
      _ keyPath: WritableKeyPath<Reducer, Value?>
    ) {}

    public mutating func registerScopedHandlers<Scoped: StreamParseableReducer>(
      on type: Scoped.Type,
      _ keyPath: WritableKeyPath<Reducer, Scoped>
    ) {
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    public mutating func registerInt128Handler(
      _ keyPath: WritableKeyPath<Reducer, Int128>
    ) {}
    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    public mutating func registerUInt128Handler(
      _ keyPath: WritableKeyPath<Reducer, UInt128>
    ) {}
  }

}

// MARK: - ASCII

extension UInt8 {
  fileprivate static let asciiQuote: UInt8 = 0x22
  fileprivate static let asciiSlash: UInt8 = 0x2F
  fileprivate static let asciiDot: UInt8 = 0x2E
  fileprivate static let asciiDash: UInt8 = 0x2D
  fileprivate static let asciiPlus: UInt8 = 0x2B
  fileprivate static let asciiBackslash: UInt8 = 0x5C
  fileprivate static let asciiLowerE: UInt8 = 0x65
  fileprivate static let asciiUpperE: UInt8 = 0x45
  fileprivate static let asciiLowerB: UInt8 = 0x62
  fileprivate static let asciiLowerF: UInt8 = 0x66
  fileprivate static let asciiLowerN: UInt8 = 0x6E
  fileprivate static let asciiLowerR: UInt8 = 0x72
  fileprivate static let asciiLowerT: UInt8 = 0x74
  fileprivate static let asciiTrue: UInt8 = 0x74
  fileprivate static let asciiFalse: UInt8 = 0x66
  fileprivate static let asciiNull: UInt8 = 0x6E
  fileprivate static let utf8SingleByteMax: UInt8 = 0x7F
  fileprivate static let utf8ContinuationMin: UInt8 = 0x80
  fileprivate static let utf8ContinuationMax: UInt8 = 0xBF
  fileprivate static let utf8TwoByteMin: UInt8 = 0xC2
  fileprivate static let utf8TwoByteMax: UInt8 = 0xDF
  fileprivate static let utf8ThreeByteMin: UInt8 = 0xE0
  fileprivate static let utf8ThreeByteMax: UInt8 = 0xEF
  fileprivate static let utf8FourByteMin: UInt8 = 0xF0
  fileprivate static let utf8FourByteMax: UInt8 = 0xF4
}

// MARK: - Helpers

extension UInt8 {
  fileprivate var digit: Int? {
    switch self {
    case 0x30...0x39: Int(self - 0x30)
    default: nil
    }
  }

  fileprivate var isLetter: Bool {
    switch self {
    case 0x41...0x5A, 0x61...0x7A: true
    default: false
    }
  }
}

extension UInt32 {
  fileprivate static let utf8ContinuationMask: UInt32 = 0x3F
  fileprivate static let utf8TwoByteMask: UInt32 = 0x1F
  fileprivate static let utf8ThreeByteMask: UInt32 = 0x0F
  fileprivate static let utf8FourByteMask: UInt32 = 0x07
}
