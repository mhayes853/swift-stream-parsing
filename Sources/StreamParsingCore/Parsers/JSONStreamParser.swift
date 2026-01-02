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
    case literal(LiteralKind)
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

// MARK: - NumberState

extension JSONStreamParser {
  private struct NumberState {
    private var isNegative = false
    private var integerValue = 0
    private var fractionValue = 0
    private var fractionScale = 1
    private var hasDecimal = false
    private var digitCount = 0
    private var lastWasDecimalPoint = false

    init(isNegative: Bool = false) {
      self.isNegative = isNegative
    }

    var shouldEmit: Bool {
      !self.lastWasDecimalPoint && self.digitCount > 0
    }

    var currentStreamedValue: StreamedValue {
      if self.hasDecimal {
        return .double(self.doubleValue())
      }
      return .int(self.intValue())
    }

    mutating func appendDigit(_ digit: Int) {
      self.digitCount += 1
      self.lastWasDecimalPoint = false
      if self.hasDecimal {
        self.fractionValue = (self.fractionValue * 10) + digit
        self.fractionScale *= 10
      } else {
        self.integerValue = (self.integerValue * 10) + digit
      }
    }

    mutating func consume(byte: UInt8) -> Bool {
      if let digit = byte.digit {
        self.appendDigit(digit)
        return true
      }
      if byte == .asciiDot, self.hasDecimal == false {
        self.setDecimal()
        return true
      }
      self.lastWasDecimalPoint = false
      return false
    }

    private mutating func setDecimal() {
      self.hasDecimal = true
      self.lastWasDecimalPoint = true
    }

    static func starting(with byte: UInt8) -> NumberState? {
      guard let digit = byte.digit else { return nil }
      var state = NumberState()
      state.appendDigit(digit)
      return state
    }

    private func intValue() -> Int {
      self.isNegative ? -self.integerValue : self.integerValue
    }

    private func doubleValue() -> Double {
      let sign = self.isNegative ? -1.0 : 1.0
      let fraction = self.hasDecimal ? Double(self.fractionValue) / Double(self.fractionScale) : 0.0
      return sign * (Double(self.integerValue) + fraction)
    }

    private static func digit(from byte: UInt8) -> Int? {
      switch byte {
      case 0x30...0x39: Int(byte - 0x30)
      default: nil
      }
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
    case .literal(let literal):
      try self.consumeLiteral(byte: byte, literal: literal, reducer: &reducer)
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
      self.state = .literal(.true)
      try self.setValue(.boolean(true), reducer: &reducer)
    case .asciiFalse:
      self.state = .literal(.false)
      try self.setValue(.boolean(false), reducer: &reducer)
    case .asciiNull:
      self.state = .literal(.null)
      try self.setValue(.null, reducer: &reducer)
    default:
      guard let numberState = NumberState.starting(with: byte) else { return }
      self.state = .number(numberState)
      try self.emitNumberIfAble(numberState, reducer: &reducer)
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
      self.state = .number(updated)
      try self.emitNumberIfAble(updated, reducer: &reducer)
    } else {
      self.state = .idle
    }
  }

  private mutating func consumeLiteral<R: StreamActionReducer>(
    byte: UInt8,
    literal: LiteralKind,
    reducer: inout R
  ) throws {
    guard self.isLetter(byte) else {
      self.state = .idle
      return
    }
    self.state = .literal(literal)
    switch literal {
    case .true:
      try self.setValue(.boolean(true), reducer: &reducer)
    case .false:
      try self.setValue(.boolean(false), reducer: &reducer)
    case .null:
      try self.setValue(.null, reducer: &reducer)
    }
  }

  private mutating func setValue<R: StreamActionReducer>(
    _ value: StreamedValue,
    reducer: inout R
  ) throws {
    try reducer.reduce(action: .setValue(value))
  }

  private mutating func emitNumberIfAble<R: StreamActionReducer>(
    _ numberState: NumberState,
    reducer: inout R
  ) throws {
    guard numberState.shouldEmit else { return }
    try self.setValue(numberState.currentStreamedValue, reducer: &reducer)
  }

  private func isLetter(_ byte: UInt8) -> Bool {
    switch byte {
    case 0x41...0x5A, 0x61...0x7A: true
    default: false
    }
  }

}

// MARK: - ASCII

extension UInt8 {
  fileprivate static let asciiQuote: UInt8 = 0x22
  fileprivate static let asciiDot: UInt8 = 0x2E
  fileprivate static let asciiDash: UInt8 = 0x2D
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
}
