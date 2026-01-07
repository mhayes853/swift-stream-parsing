// MARK: - JSONStreamParser

public struct JSONStreamParser<Value: StreamParseableValue>: StreamParser {
  private enum Mode {
    case neutral
    case string
    case number
    case literal
  }

  public let configuration: JSONStreamParserConfiguration

  private var handlers: Handlers
  private var mode = Mode.neutral
  private var string = ""
  private var isEscaping = false
  private var utf8State = UTF8State()

  private var isNegative = false

  public init(configuration: JSONStreamParserConfiguration = JSONStreamParserConfiguration()) {
    self.configuration = configuration
    self.handlers = Handlers(configuration: configuration)
  }

  public mutating func registerHandlers() {
    Value.registerHandlers(in: &self.handlers)
  }

  public mutating func parse(bytes: some Sequence<UInt8>, into reducer: inout Value) throws {
    for byte in bytes {
      try self.parse(byte: byte, into: &reducer)
    }
  }

  private mutating func parse(byte: UInt8, into reducer: inout Value) throws {
    switch self.mode {
    case .literal: break
    case .neutral: try self.parseNeutral(byte: byte, into: &reducer)
    case .number: try self.parseNumber(byte: byte, into: &reducer)
    case .string: try self.parseString(byte: byte, into: &reducer)
    }
  }

  private mutating func parseNeutral(byte: UInt8, into reducer: inout Value) throws {
    switch byte {
    case .asciiQuote:
      self.mode = .string
      self.string = ""
    case .asciiTrueStart:
      self.mode = .literal
      if let boolPath = self.handlers.boolPath {
        reducer[keyPath: boolPath] = true
      }
    case .asciiFalseStart:
      self.mode = .literal
      if let boolPath = self.handlers.boolPath {
        reducer[keyPath: boolPath] = false
      }
    case .asciiNullStart:
      self.mode = .literal
      if let nullablePath = self.handlers.nullablePath {
        reducer[keyPath: nullablePath] = nil
      }
    case .asciiDash:
      self.mode = .number
      self.isNegative = true
      if let numberPath = self.handlers.numberPath {
        reducer[keyPath: numberPath].reset()
      }
    case 0x30...0x39:
      self.mode = .number
      self.isNegative = false
      if let numberPath = self.handlers.numberPath {
        reducer[keyPath: numberPath].reset()
      }
      try self.parseNumber(byte: byte, into: &reducer)
    default:
      break
    }
  }

  private mutating func parseString(byte: UInt8, into reducer: inout Value) throws {
    defer {
      if let stringPath = self.handlers.stringPath {
        reducer[keyPath: stringPath] = self.string
      }
    }

    switch byte {
    case .asciiBackslash:
      if self.isEscaping {
        self.string.append("\\")
        self.isEscaping = false
      } else {
        self.isEscaping = true
      }

    case .asciiQuote:
      if self.isEscaping {
        self.string.append("\"")
        self.isEscaping = false
      } else {
        self.mode = .neutral
      }

    default:
      switch self.utf8State.consume(byte: byte) {
      case .appendByte:
        if self.isEscaping {
          self.appendEscapedCharacter(for: byte)
        } else {
          self.string.unicodeScalars.append(Unicode.Scalar(byte))
        }
      case .appendScalar(let scalar):
        self.string.unicodeScalars.append(scalar)
      case .doNothing:
        break
      }
    }
  }

  private mutating func appendEscapedCharacter(for byte: UInt8) {
    switch byte {
    case .asciiLowerN: self.string.append("\n")
    case .asciiLowerR: self.string.append("\r")
    case .asciiLowerT: self.string.append("\t")
    case .asciiLowerB: self.string.append("\u{08}")
    case .asciiLowerF: self.string.append("\u{0C}")
    case .asciiSlash: self.string.append("/")
    default: self.string.unicodeScalars.append(Unicode.Scalar(byte))
    }
    self.isEscaping = false
  }

  private mutating func parseNumber(byte: UInt8, into reducer: inout Value) throws {
    guard let digit = byte.digitValue, let numberPath = self.handlers.numberPath else {
      self.mode = .neutral
      return
    }
    reducer[keyPath: numberPath].append(digit: digit)
    if self.isNegative {
      reducer[keyPath: numberPath].negateIfPositive()
    }
  }
}

extension StreamParser {
  public static func json<Reducer>(
    configuration: JSONStreamParserConfiguration = JSONStreamParserConfiguration()
  ) -> Self where Self == JSONStreamParser<Reducer> {
    JSONStreamParser(configuration: configuration)
  }
}

// MARK: - Configuration

public struct JSONStreamParserConfiguration: Sendable {
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
    var stringPath: WritableKeyPath<Value, String>?
    var boolPath: WritableKeyPath<Value, Bool>?
    fileprivate var numberPath: WritableKeyPath<Value, any JSONNumberAccumulator>?
    var floatPath: WritableKeyPath<Value, Float>?
    var doublePath: WritableKeyPath<Value, Double>?
    var nullablePath: WritableKeyPath<Value, Void?>?
    var int128Path: WritableKeyPath<Value, any Sendable>?
    var uint128Path: WritableKeyPath<Value, any Sendable>?
    private let configuration: JSONStreamParserConfiguration

    init(configuration: JSONStreamParserConfiguration) {
      self.configuration = configuration
    }

    public mutating func registerStringHandler(_ keyPath: WritableKeyPath<Value, String>) {
      self.stringPath = keyPath
    }

    public mutating func registerBoolHandler(_ keyPath: WritableKeyPath<Value, Bool>) {
      self.boolPath = keyPath
    }

    public mutating func registerUIntHandler(_ keyPath: WritableKeyPath<Value, UInt>) {
      self.numberPath = keyPath.appending(path: \.erasedAccumulator)
    }

    public mutating func registerUInt8Handler(_ keyPath: WritableKeyPath<Value, UInt8>) {
      self.numberPath = keyPath.appending(path: \.erasedAccumulator)
    }

    public mutating func registerUInt16Handler(_ keyPath: WritableKeyPath<Value, UInt16>) {
      self.numberPath = keyPath.appending(path: \.erasedAccumulator)
    }

    public mutating func registerUInt32Handler(_ keyPath: WritableKeyPath<Value, UInt32>) {
      self.numberPath = keyPath.appending(path: \.erasedAccumulator)
    }

    public mutating func registerUInt64Handler(_ keyPath: WritableKeyPath<Value, UInt64>) {
      self.numberPath = keyPath.appending(path: \.erasedAccumulator)
    }

    public mutating func registerIntHandler(_ keyPath: WritableKeyPath<Value, Int>) {
      self.numberPath = keyPath.appending(path: \.erasedAccumulator)
    }

    public mutating func registerInt8Handler(_ keyPath: WritableKeyPath<Value, Int8>) {
      self.numberPath = keyPath.appending(path: \.erasedAccumulator)
    }

    public mutating func registerInt16Handler(_ keyPath: WritableKeyPath<Value, Int16>) {
      self.numberPath = keyPath.appending(path: \.erasedAccumulator)
    }

    public mutating func registerInt32Handler(_ keyPath: WritableKeyPath<Value, Int32>) {
      self.numberPath = keyPath.appending(path: \.erasedAccumulator)
    }

    public mutating func registerInt64Handler(_ keyPath: WritableKeyPath<Value, Int64>) {
      self.numberPath = keyPath.appending(path: \.erasedAccumulator)
    }

    public mutating func registerFloatHandler(_ keyPath: WritableKeyPath<Value, Float>) {
      self.floatPath = keyPath
    }

    public mutating func registerDoubleHandler(_ keyPath: WritableKeyPath<Value, Double>) {
      self.doublePath = keyPath
    }

    public mutating func registerNilHandler<Nullable: StreamParseableValue>(
      _ keyPath: WritableKeyPath<Value, Nullable?>
    ) {
      self.nullablePath = keyPath.appending(path: \.nullablePath)
    }

    public mutating func registerKeyedHandler<Keyed: StreamParseableValue>(
      forKey key: String,
      _ keyPath: WritableKeyPath<Value, Keyed>
    ) {}

    public mutating func registerScopedHandlers<Scoped: StreamParseableValue>(
      on type: Scoped.Type,
      _ keyPath: WritableKeyPath<Value, Scoped>
    ) {
      var handlers = JSONStreamParser<Scoped>.Handlers(configuration: self.configuration)
      type.registerHandlers(in: &handlers)
      self.merge(with: handlers, using: keyPath)
    }

    private mutating func merge<Scoped: StreamParseableValue>(
      with handlers: JSONStreamParser<Scoped>.Handlers,
      using path: WritableKeyPath<Value, Scoped>
    ) {
      if let boolPath = handlers.boolPath {
        self.boolPath = path.appending(path: boolPath)
      }
      if let numberPath = handlers.numberPath {
        self.numberPath = path.appending(path: numberPath)
      }
      if let floatPath = handlers.floatPath {
        self.floatPath = path.appending(path: floatPath)
      }
      if let doublePath = handlers.doublePath {
        self.doublePath = path.appending(path: doublePath)
      }
      if let nullablePath = handlers.nullablePath {
        self.nullablePath = path.appending(path: nullablePath)
      }
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
    public mutating func registerInt128Handler(_ keyPath: WritableKeyPath<Value, Int128>) {
      self.numberPath = keyPath.appending(path: \.erasedAccumulator)
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    public mutating func registerUInt128Handler(_ keyPath: WritableKeyPath<Value, UInt128>) {
      self.numberPath = keyPath.appending(path: \.erasedAccumulator)
    }
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
  fileprivate static let asciiTrueStart: UInt8 = 0x74
  fileprivate static let asciiFalseStart: UInt8 = 0x66
  fileprivate static let asciiNullStart: UInt8 = 0x6E
}

extension UInt8 {
  fileprivate var isLetter: Bool {
    switch self {
    case 0x41...0x5A, 0x61...0x7A: true
    default: false
    }
  }
}

// MARK: - UTF8

private struct UTF8State {
  private var buffer: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
  private var index = 0
  private var maxSize = UInt8(0)

  init() {}

  enum ConsumeAction {
    case doNothing
    case appendByte
    case appendScalar(Unicode.Scalar)
  }

  mutating func consume(byte: UInt8) -> ConsumeAction {
    self.maxSize = self.maxSize > 0 ? self.maxSize : self.maxSize(for: byte)
    withUnsafeMutableBytes(of: &self.buffer) { buffer in
      buffer[self.index] = byte
      self.index += 1
    }
    guard self.index == self.maxSize else { return .doNothing }
    defer { self = UTF8State() }
    return self.unicodeScalar.map { .appendScalar($0) } ?? .appendByte
  }

  private var unicodeScalar: UnicodeScalar? {
    switch self.maxSize {
    case 2:
      let b0 = UInt32(self.buffer.0)
      let b1 = UInt32(self.buffer.1)
      return Unicode.Scalar(((b0 & 0x1F) << 6) | (b1 & 0x3F))
    case 3:
      let b0 = UInt32(self.buffer.0)
      let b1 = UInt32(self.buffer.1)
      let b2 = UInt32(self.buffer.2)
      return Unicode.Scalar(((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F))
    case 4:
      let b0 = UInt32(self.buffer.0)
      let b1 = UInt32(self.buffer.1)
      let b2 = UInt32(self.buffer.2)
      let b3 = UInt32(self.buffer.3)
      let scalar = ((b0 & 0x07) << 18) | ((b1 & 0x3F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F)
      return Unicode.Scalar(scalar)
    default:
      return nil
    }
  }

  private func maxSize(for byte: UInt8) -> UInt8 {
    switch byte {
    case 0xC2...0xDF: 2
    case 0xE0...0xEF: 3
    case 0xF0...0xF4: 4
    default: 1
    }
  }
}

// MARK: - Digit

extension UInt8 {
  fileprivate var digitValue: UInt8? {
    switch self {
    case 0x30...0x39: self &- 0x30
    default: nil
    }
  }
}

// MARK: - JSONNumberAccumulator

private protocol JSONNumberAccumulator {
  mutating func reset()
  mutating func append(digit: UInt8)
  mutating func negateIfPositive()
}

extension JSONNumberAccumulator {
  mutating func negateIfPositive() {}
}

extension JSONNumberAccumulator where Self: Numeric {
  mutating func reset() {
    self = .zero
  }
}

extension JSONNumberAccumulator where Self: BinaryInteger & Comparable {
  mutating func append(digit: UInt8) {
    self *= 10
    if self < .zero {
      self -= Self(digit)
    } else {
      self += Self(digit)
    }
  }
}

extension JSONNumberAccumulator where Self: SignedNumeric & Comparable {
  mutating func negateIfPositive() {
    if self > .zero {
      self = -self
    }
  }
}

extension Int: JSONNumberAccumulator {}
extension Int8: JSONNumberAccumulator {}
extension Int16: JSONNumberAccumulator {}
extension Int32: JSONNumberAccumulator {}
extension Int64: JSONNumberAccumulator {}

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
extension Int128: JSONNumberAccumulator {}

extension UInt: JSONNumberAccumulator {}
extension UInt8: JSONNumberAccumulator {}
extension UInt16: JSONNumberAccumulator {}
extension UInt32: JSONNumberAccumulator {}
extension UInt64: JSONNumberAccumulator {}

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
extension UInt128: JSONNumberAccumulator {}

extension JSONNumberAccumulator where Self: BinaryInteger {
  fileprivate var erasedAccumulator: any JSONNumberAccumulator {
    get { self }
    set { self = newValue as! Self }
  }
}
