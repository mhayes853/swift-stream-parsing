// MARK: - JSONStreamParser

public struct JSONStreamParser<Value: StreamParseableValue>: StreamParser {
  public let configuration: JSONStreamParser.Configuration
  private var handlers = Handlers()

  public init(configuration: JSONStreamParser.Configuration = JSONStreamParser.Configuration()) {
    self.configuration = configuration
  }

  public mutating func parse(bytes: some Sequence<UInt8>, into reducer: inout Value) throws {}

  public mutating func registerHandlers() {
    Value.registerHandlers(in: &self.handlers)
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
    public var keyDecodingStrategy = JSONKeyDecodingStrategy.useDefault

    public init(
      completePartialValues: Bool = false,
      allowComments: Bool = false,
      allowTrailingCommas: Bool = false,
      allowUnquotedKeys: Bool = false,
      keyDecodingStrategy: JSONKeyDecodingStrategy = JSONKeyDecodingStrategy.useDefault
    ) {
      self.completePartialValues = completePartialValues
      self.allowComments = allowComments
      self.allowTrailingCommas = allowTrailingCommas
      self.allowUnquotedKeys = allowUnquotedKeys
      self.keyDecodingStrategy = keyDecodingStrategy
    }
  }
}

// MARK: - JSONKeyDecodingStrategy

public enum JSONKeyDecodingStrategy: Sendable {
  case convertFromSnakeCase
  case useDefault
  case custom(@Sendable (String) -> String)

  public func decode(key: String) -> String {
    switch self {
    case .convertFromSnakeCase: Self.convertFromSnakeCase(key: key)
    case .useDefault: key
    case .custom(let decode): decode(key)
    }
  }

  private static func convertFromSnakeCase(key: String) -> String {
    guard !key.isEmpty else { return key }
    guard let firstNonUnderscore = key.firstIndex(where: { $0 != "_" }) else { return key }

    var lastNonUnderscore = key.index(before: key.endIndex)
    while lastNonUnderscore > firstNonUnderscore && key[lastNonUnderscore] == "_" {
      key.formIndex(before: &lastNonUnderscore)
    }

    let keyRange = firstNonUnderscore...lastNonUnderscore
    let leadingUnderscoreRange = key.startIndex..<firstNonUnderscore
    let trailingUnderscoreRange = key.index(after: lastNonUnderscore)..<key.endIndex

    let components = key[keyRange].split(separator: "_")
    let joinedString: String
    if components.count == 1 {
      joinedString = String(key[keyRange])
    } else {
      joinedString = ([components[0].lowercased()] + components[1...].map(\.capitalized)).joined()
    }

    let result: String
    if leadingUnderscoreRange.isEmpty && trailingUnderscoreRange.isEmpty {
      result = joinedString
    } else if !leadingUnderscoreRange.isEmpty && !trailingUnderscoreRange.isEmpty {
      result =
        String(key[leadingUnderscoreRange]) + joinedString + String(key[trailingUnderscoreRange])
    } else if !leadingUnderscoreRange.isEmpty {
      result = String(key[leadingUnderscoreRange]) + joinedString
    } else {
      result = joinedString + String(key[trailingUnderscoreRange])
    }
    return result
  }
}

// MARK: - Handlers

extension JSONStreamParser {
  public struct Handlers: StreamParserHandlers {
    public init() {}

    public mutating func registerStringHandler(
      _ keyPath: WritableKeyPath<Value, String>
    ) {}
    public mutating func registerBoolHandler(
      _ keyPath: WritableKeyPath<Value, Bool>
    ) {}
    public mutating func registerIntHandler(
      _ keyPath: WritableKeyPath<Value, Int>
    ) {}
    public mutating func registerInt8Handler(
      _ keyPath: WritableKeyPath<Value, Int8>
    ) {}
    public mutating func registerInt16Handler(
      _ keyPath: WritableKeyPath<Value, Int16>
    ) {}
    public mutating func registerInt32Handler(
      _ keyPath: WritableKeyPath<Value, Int32>
    ) {}
    public mutating func registerInt64Handler(
      _ keyPath: WritableKeyPath<Value, Int64>
    ) {}
    public mutating func registerUIntHandler(
      _ keyPath: WritableKeyPath<Value, UInt>
    ) {}
    public mutating func registerUInt8Handler(
      _ keyPath: WritableKeyPath<Value, UInt8>
    ) {}
    public mutating func registerUInt16Handler(
      _ keyPath: WritableKeyPath<Value, UInt16>
    ) {}
    public mutating func registerUInt32Handler(
      _ keyPath: WritableKeyPath<Value, UInt32>
    ) {}
    public mutating func registerUInt64Handler(
      _ keyPath: WritableKeyPath<Value, UInt64>
    ) {}
    public mutating func registerFloatHandler(
      _ keyPath: WritableKeyPath<Value, Float>
    ) {}
    public mutating func registerDoubleHandler(
      _ keyPath: WritableKeyPath<Value, Double>
    ) {}
    public mutating func registerNilHandler<Nullable>(
      _ keyPath: WritableKeyPath<Value, Nullable?>
    ) {}

    public mutating func registerKeyedHandler<Keyed: StreamParseableValue>(
      forKey key: String,
      _ keyPath: WritableKeyPath<Value, Keyed>
    ) {}

    public mutating func registerScopedHandlers<Scoped: StreamParseableValue>(
      on type: Scoped.Type,
      _ keyPath: WritableKeyPath<Value, Scoped>
    ) {
    }

    public mutating func registerArrayHandler(
      _ keyPath: WritableKeyPath<Value, some StreamParseableArrayObject>
    ) {
    }

    public mutating func registerDictionaryHandler(
      _ keyPath: WritableKeyPath<Value, some StreamParseableDictionaryObject>
    ) {
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    public mutating func registerInt128Handler(
      _ keyPath: WritableKeyPath<Value, Int128>
    ) {}

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    public mutating func registerUInt128Handler(
      _ keyPath: WritableKeyPath<Value, UInt128>
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
