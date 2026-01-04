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
      _ handler: @escaping (inout Reducer, String) -> Void
    ) {}
    public mutating func registerBoolHandler(
      _ handler: @escaping (inout Reducer, Bool) -> Void
    ) {}
    public mutating func registerIntHandler(
      _ handler: @escaping (inout Reducer, Int) -> Void
    ) {}
    public mutating func registerInt8Handler(
      _ handler: @escaping (inout Reducer, Int8) -> Void
    ) {}
    public mutating func registerInt16Handler(
      _ handler: @escaping (inout Reducer, Int16) -> Void
    ) {}
    public mutating func registerInt32Handler(
      _ handler: @escaping (inout Reducer, Int32) -> Void
    ) {}
    public mutating func registerInt64Handler(
      _ handler: @escaping (inout Reducer, Int64) -> Void
    ) {}
    public mutating func registerUIntHandler(
      _ handler: @escaping (inout Reducer, UInt) -> Void
    ) {}
    public mutating func registerUInt8Handler(
      _ handler: @escaping (inout Reducer, UInt8) -> Void
    ) {}
    public mutating func registerUInt16Handler(
      _ handler: @escaping (inout Reducer, UInt16) -> Void
    ) {}
    public mutating func registerUInt32Handler(
      _ handler: @escaping (inout Reducer, UInt32) -> Void
    ) {}
    public mutating func registerUInt64Handler(
      _ handler: @escaping (inout Reducer, UInt64) -> Void
    ) {}
    public mutating func registerFloatHandler(
      _ handler: @escaping (inout Reducer, Float) -> Void
    ) {}
    public mutating func registerDoubleHandler(
      _ handler: @escaping (inout Reducer, Double) -> Void
    ) {}
    public mutating func registerNilHandler(
      _ handler: @escaping (inout Reducer) -> Void
    ) {}

    public mutating func registerScopedHandlers<Scoped: StreamParseableReducer>(
      on type: Scoped.Type,
      _ body: (inout Reducer, (inout Scoped) -> Void) -> Void
    ) {
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    public mutating func registerInt128Handler(
      _ handler: @escaping (inout Reducer, Int128) -> Void
    ) {}
    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    public mutating func registerUInt128Handler(
      _ handler: @escaping (inout Reducer, UInt128) -> Void
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
