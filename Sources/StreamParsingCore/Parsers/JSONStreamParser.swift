#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#elseif canImport(Android)
  import Android
#elseif canImport(WinSDK)
  import WinSDK
#elseif canImport(WASILibc)
  import WASILibc
#endif

// MARK: - JSONStreamParser

public struct JSONStreamParser: StreamParser {
  public let configuration: JSONStreamParser.Configuration
  private var state = ParserState.idle

  public init(configuration: JSONStreamParser.Configuration = JSONStreamParser.Configuration()) {
    self.configuration = configuration
  }

  public mutating func parse(
    bytes: some Sequence<UInt8>,
    into partial: inout some StreamActionReducer
  ) throws {
    for byte in bytes {
      try self.consume(byte: byte, reducer: &partial)
    }
  }
}

extension StreamParser where Self == JSONStreamParser {
  public static var json: Self {
    JSONStreamParser()
  }

  public static func json(configuration: JSONStreamParser.Configuration) -> Self {
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

// MARK: - ParserState

extension JSONStreamParser {
  private enum ParserState {
    case idle
    case string(value: String)
    case number(NumberState)
    case literal(LiteralState)
  }
}

// MARK: - LiteralKind

extension JSONStreamParser {
  private enum LiteralKind {
    case `true`
    case `false`
    case null
  }
}

// MARK: - LiteralState

extension JSONStreamParser {
  private struct LiteralState {
    private let kind: LiteralKind
    private var letterCount = 0

    init(kind: LiteralKind) {
      self.kind = kind
    }

    var shouldEmit: Bool {
      self.letterCount == 1
    }

    var currentStreamedValue: StreamedValue {
      switch self.kind {
      case .true: .boolean(true)
      case .false: .boolean(false)
      case .null: .null
      }
    }

    mutating func consume(byte: UInt8) -> Bool {
      guard byte.isLetter else {
        return false
      }
      self.letterCount += 1
      return true
    }
  }
}

// MARK: - NumberState

extension JSONStreamParser {
  private struct NumberState {
    private var isNegative = false
    private var integerValue = 0
    private var fractionValue = 0
    private var fractionScale = 1
    private var hasDecimal = false
    private var digitCount = 0
    private var hasExponent = false
    private var exponentIsNegative = false
    private var exponentValue = 0
    private var exponentDigitCount = 0
    private var lastEmittedValue: Double?
    private var lastParsedValue: Double?
    private var lastComparedEmittedValue: Double?
    private var lastByteKind = LastByteKind.none

    var shouldEmit: Bool {
      guard let lastParsedValue = self.lastParsedValue else { return false }
      guard let lastComparedEmittedValue = self.lastComparedEmittedValue else { return true }
      return lastParsedValue != lastComparedEmittedValue
    }

    private enum LastByteKind {
      case decimalPoint
      case exponentMarker
      case exponentSign
      case digit
      case none
    }

    init(isNegative: Bool = false) {
      self.isNegative = isNegative
    }

    var currentStreamedValue: StreamedValue {
      if self.hasDecimal || self.hasExponent {
        return .double(self.doubleValue())
      }
      return .int(self.intValue())
    }

    mutating func consume(byte: UInt8) -> Bool {
      defer { self.updateEmissionState() }
      if let digit = byte.digit {
        self.appendDigit(digit)
        return true
      }
      if byte == .asciiDot {
        self.setDecimal()
        return true
      }
      if byte == .asciiLowerE || byte == .asciiUpperE {
        self.setExponent()
        return true
      }
      if self.lastByteKind == .exponentMarker && byte == .asciiDash {
        self.setExponentSign(isNegative: true)
        return true
      }
      if self.lastByteKind == .exponentMarker && byte == .asciiPlus {
        self.setExponentSign(isNegative: false)
        return true
      }
      self.lastByteKind = .none
      return false
    }

    private mutating func updateEmissionState() {
      self.lastComparedEmittedValue = self.lastEmittedValue
      self.lastParsedValue = self.doubleValue()
      if self.shouldEmit {
        self.lastEmittedValue = self.lastParsedValue
      }
    }

    private mutating func appendDigit(_ digit: Int) {
      if self.hasExponent {
        self.exponentDigitCount += 1
        self.exponentValue = (self.exponentValue * 10) + digit
      } else {
        self.digitCount += 1
        if self.hasDecimal {
          self.fractionValue = (self.fractionValue * 10) + digit
          self.fractionScale *= 10
        } else {
          self.integerValue = (self.integerValue * 10) + digit
        }
      }
      self.lastByteKind = .digit
    }

    private mutating func setDecimal() {
      self.hasDecimal = true
      self.lastByteKind = .decimalPoint
    }

    private mutating func setExponent() {
      self.hasExponent = true
      self.lastByteKind = .exponentMarker
    }

    private mutating func setExponentSign(isNegative: Bool) {
      self.exponentIsNegative = isNegative
      self.lastByteKind = .exponentSign
    }

    static func starting(with byte: UInt8) -> NumberState? {
      guard let digit = byte.digit else { return nil }
      var state = NumberState()
      state.appendDigit(digit)
      state.updateEmissionState()
      return state
    }

    private func intValue() -> Int {
      self.isNegative ? -self.integerValue : self.integerValue
    }

    private func doubleValue() -> Double {
      let sign = self.isNegative ? -1.0 : 1.0
      let fraction = self.hasDecimal ? Double(self.fractionValue) / Double(self.fractionScale) : 0.0
      let baseValue = Double(self.integerValue) + fraction
      guard self.hasExponent else { return sign * baseValue }
      let exponent = self.exponentIsNegative ? -self.exponentValue : self.exponentValue
      return sign * baseValue * pow(10.0, Double(exponent))
    }
  }
}

// MARK: - NumberConsumption

extension JSONStreamParser {
  private enum NumberConsumption {
    case digit
    case none
  }
}

// MARK: - Parsing

extension JSONStreamParser {
  private mutating func consume<R: StreamActionReducer>(
    byte: UInt8,
    reducer: inout R
  ) throws {
    switch self.state {
    case .idle:
      try self.consumeIdle(byte: byte, reducer: &reducer)
    case .string(let value):
      try self.consumeString(byte: byte, value: value, reducer: &reducer)
    case .number(let numberState):
      try self.consumeNumber(
        byte: byte,
        numberState: numberState,
        reducer: &reducer
      )
    case .literal(let literalState):
      try self.consumeLiteral(byte: byte, literalState: literalState, reducer: &reducer)
    }
  }

  private mutating func consumeIdle<R: StreamActionReducer>(
    byte: UInt8,
    reducer: inout R
  ) throws {
    switch byte {
    case .asciiQuote:
      self.state = .string(value: "")
      try self.setValue(.string(""), reducer: &reducer)
    case .asciiDash:
      self.state = .number(NumberState(isNegative: true))
    case .asciiTrue:
      var literalState = LiteralState(kind: .true)
      if literalState.consume(byte: byte) {
        try self.emitLiteralIfAble(literalState, reducer: &reducer)
      }
      self.state = .literal(literalState)
    case .asciiFalse:
      var literalState = LiteralState(kind: .false)
      if literalState.consume(byte: byte) {
        try self.emitLiteralIfAble(literalState, reducer: &reducer)
      }
      self.state = .literal(literalState)
    case .asciiNull:
      var literalState = LiteralState(kind: .null)
      _ = literalState.consume(byte: byte)
      try self.emitLiteralIfAble(literalState, reducer: &reducer)
      self.state = .literal(literalState)
    default:
      guard var numberState = NumberState.starting(with: byte) else { return }
      try self.emitNumberIfAble(&numberState, reducer: &reducer)
      self.state = .number(numberState)
    }
  }

  private mutating func consumeString<R: StreamActionReducer>(
    byte: UInt8,
    value: String,
    reducer: inout R
  ) throws {
    switch byte {
    case .asciiQuote:
      self.state = .idle
      try self.setValue(.string(value), reducer: &reducer)
    default:
      let scalar = UnicodeScalar(byte)
      var updated = value
      updated.unicodeScalars.append(scalar)
      self.state = .string(value: updated)
      try self.setValue(.string(updated), reducer: &reducer)
    }
  }

  private mutating func consumeNumber<R: StreamActionReducer>(
    byte: UInt8,
    numberState: NumberState,
    reducer: inout R
  ) throws {
    var updated = numberState
    if updated.consume(byte: byte) {
      try self.emitNumberIfAble(&updated, reducer: &reducer)
      self.state = .number(updated)
    } else {
      self.state = .idle
    }
  }

  private mutating func consumeLiteral<R: StreamActionReducer>(
    byte: UInt8,
    literalState: LiteralState,
    reducer: inout R
  ) throws {
    var updated = literalState
    if updated.consume(byte: byte) {
      try self.emitLiteralIfAble(updated, reducer: &reducer)
      self.state = .literal(updated)
    } else {
      self.state = .idle
    }
  }

  private mutating func setValue<R: StreamActionReducer>(
    _ value: StreamedValue,
    reducer: inout R
  ) throws {
    try reducer.reduce(action: .setValue(value))
  }

  private mutating func emitNumberIfAble<R: StreamActionReducer>(
    _ numberState: inout NumberState,
    reducer: inout R
  ) throws {
    guard numberState.shouldEmit else { return }
    try self.setValue(numberState.currentStreamedValue, reducer: &reducer)
  }

  private mutating func emitLiteralIfAble<R: StreamActionReducer>(
    _ literalState: LiteralState,
    reducer: inout R
  ) throws {
    guard literalState.shouldEmit else { return }
    try self.setValue(literalState.currentStreamedValue, reducer: &reducer)
  }
}

// MARK: - ASCII

extension UInt8 {
  fileprivate static let asciiQuote: UInt8 = 0x22
  fileprivate static let asciiDot: UInt8 = 0x2E
  fileprivate static let asciiDash: UInt8 = 0x2D
  fileprivate static let asciiPlus: UInt8 = 0x2B
  fileprivate static let asciiLowerE: UInt8 = 0x65
  fileprivate static let asciiUpperE: UInt8 = 0x45
  fileprivate static let asciiTrue: UInt8 = 0x74
  fileprivate static let asciiFalse: UInt8 = 0x66
  fileprivate static let asciiNull: UInt8 = 0x6E
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
