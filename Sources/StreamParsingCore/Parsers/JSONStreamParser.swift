// MARK: - JSONStreamParser

public struct JSONStreamParser<Value: StreamParseableValue>: StreamParser {
  private enum Mode {
    case neutral
    case string
    case integer
    case exponentialDouble
    case fractionalDouble
    case literal
    case keyFinding
    case keyCollecting

    var isNumeric: Bool {
      switch self {
      case .integer, .exponentialDouble, .fractionalDouble: true
      default: false
      }
    }
  }

  public let configuration: JSONStreamParserConfiguration

  private var handlers: Handlers
  private var mode = Mode.neutral
  private var string = ""
  private var isEscaping = false
  private var utf8State = UTF8State()
  private var isCollectingKey = false
  private var isAwaitingKeySeparator = false
  private var unicodeEscapeRemaining = 0
  private var unicodeEscapeValue: UInt32 = 0

  private var isNegative = false
  private var isNegativeExponent = false
  private var exponent = 0
  private var fractionalPosition = 0
  private var numberState = NumberState()

  private var stack = [StackElement]()
  private var arrayDepth = 0
  private var objectDepth = 0
  private var arrayTrailingCommaDepths = BitVector()
  private var arrayExpectingValueDepths = BitVector()
  private var arrayHasValueDepths = BitVector()
  private var objectTrailingCommaDepths = BitVector()
  private var objectValuePendingDepths = BitVector()
  private var currentStringPath: WritableKeyPath<Value, String>?
  private var currentNumberPath: WritableKeyPath<Value, JSONNumberAccumulator>?
  private var currentArrayPath: WritableKeyPath<Value, any StreamParseableArrayObject>?
  private var currentDictionaryPath: WritableKeyPath<Value, any StreamParseableDictionaryObject>?
  private var position = JSONStreamParsingPosition(line: 1, column: 1)
  private var literalState = LiteralState()

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

  public mutating func finish(reducer: inout Value) throws {
    if self.mode == .string {
      if self.unicodeEscapeRemaining > 0 {
        throw JSONStreamParsingError(
          reason: .invalidUnicodeEscape,
          position: self.position,
          context: .string
        )
      }
      throw JSONStreamParsingError(
        reason: .unterminatedString,
        position: self.position,
        context: .string
      )
    }
    if self.mode == .literal {
      throw JSONStreamParsingError(
        reason: .invalidLiteral,
        position: self.position,
        context: .literal
      )
    }
    if self.mode.isNumeric {
      try self.finalizeNumberOrThrow(at: self.position, into: &reducer)
    }
    if self.arrayDepth > 0 {
      throw JSONStreamParsingError(
        reason: .missingClosingBracket,
        position: self.position,
        context: .arrayValue
      )
    }
    if self.objectDepth > 0 {
      throw JSONStreamParsingError(
        reason: .missingClosingBrace,
        position: self.position,
        context: .objectValue
      )
    }
  }

  private mutating func parse(byte: UInt8, into reducer: inout Value) throws {
    defer { self.advancePosition(for: byte) }
    switch self.mode {
    case .literal: try self.parseLiteral(byte: byte, into: &reducer)
    case .neutral: try self.parseNeutral(byte: byte, into: &reducer)
    case .integer: try self.parseInteger(byte: byte, into: &reducer)
    case .string: try self.parseString(byte: byte, into: &reducer)
    case .exponentialDouble: try self.parseExponentialDouble(byte: byte, into: &reducer)
    case .fractionalDouble: try self.parseFractionalDouble(byte: byte, into: &reducer)
    case .keyFinding: try self.parseKeyFinding(byte: byte, into: &reducer)
    case .keyCollecting: try self.parseKeyCollecting(byte: byte, into: &reducer)
    }
  }

  private mutating func appendArrayElementIfNeeded(into reducer: inout Value) {
    guard case .array(let index) = self.stack.last else { return }
    let containerStack = Array(self.stack.dropLast())
    self.currentArrayPath = self.handlers.arrayPath(stack: containerStack)
    guard let currentArrayPath else { return }
    if let collection = reducer[keyPath: currentArrayPath] as? any Collection {
      var count = collection.count
      while count <= index {
        reducer[keyPath: currentArrayPath].appendNewElement()
        count += 1
      }
      return
    }
    reducer[keyPath: currentArrayPath].appendNewElement()
  }

  private mutating func beginValueToken() throws {
    if case .array = self.stack.last {
      if self.arrayExpectingValueDepths.contains(self.arrayDepth)
        || self.arrayTrailingCommaDepths.contains(self.arrayDepth)
      {
        self.arrayExpectingValueDepths.remove(self.arrayDepth)
        self.arrayHasValueDepths.insert(self.arrayDepth)
        self.arrayTrailingCommaDepths.remove(self.arrayDepth)
      } else if self.arrayHasValueDepths.contains(self.arrayDepth) {
        throw JSONStreamParsingError(
          reason: .missingComma,
          position: self.position,
          context: .arrayValue
        )
      }
    }
    if case .object = self.stack.last {
      let depth = self.stack.count
      if self.objectValuePendingDepths.contains(depth) {
        self.objectValuePendingDepths.remove(depth)
      }
    }
  }

  private mutating func markArrayTrailingComma() {
    guard self.arrayDepth > 0 else { return }
    self.arrayTrailingCommaDepths.insert(self.arrayDepth)
  }

  private mutating func clearArrayTrailingCommaIfNeeded() {
    guard self.arrayDepth > 0 else { return }
    self.arrayTrailingCommaDepths.remove(self.arrayDepth)
  }

  private mutating func advancePosition(for byte: UInt8) {
    if byte == 0x0A {
      self.position.line += 1
      self.position.column = 1
    } else {
      self.position.column += 1
    }
  }

  private mutating func parseNeutral(byte: UInt8, into reducer: inout Value) throws {
    switch byte {
    case .asciiQuote:
      self.clearArrayTrailingCommaIfNeeded()
      try self.beginValueToken()
      self.appendArrayElementIfNeeded(into: &reducer)
      self.currentStringPath = self.handlers.stringPath(stack: self.stack)
      self.mode = .string
      self.string = ""
      self.isEscaping = false
      self.utf8State = UTF8State()
      self.unicodeEscapeRemaining = 0
      self.unicodeEscapeValue = 0

    case .asciiComma:
      switch self.stack.last {
      case .array(let index):
        if self.arrayExpectingValueDepths.contains(self.arrayDepth) {
          throw JSONStreamParsingError(
            reason: .missingValue,
            position: self.position,
            context: .arrayValue
          )
        }
        _ = self.stack.popLast()
        self.stack.append(.array(index: index + 1))
        self.markArrayTrailingComma()
        self.arrayExpectingValueDepths.insert(self.arrayDepth)

      case .object:
        let keyDepth = self.stack.count
        if self.objectValuePendingDepths.contains(keyDepth) {
          throw JSONStreamParsingError(
            reason: .missingValue,
            position: self.position,
            context: .objectValue
          )
        }
        _ = self.stack.popLast()
        self.mode = .keyFinding
        self.string = ""
        self.isCollectingKey = false
        self.isAwaitingKeySeparator = false
        if self.objectDepth > 0 {
          self.objectTrailingCommaDepths.insert(self.objectDepth)
        }

      default:
        throw JSONStreamParsingError(
          reason: .unexpectedToken,
          position: self.position,
          context: .neutral
        )
      }

    case .asciiArrayStart:
      self.clearArrayTrailingCommaIfNeeded()
      try self.beginValueToken()
      self.appendArrayElementIfNeeded(into: &reducer)
      self.currentArrayPath = self.handlers.arrayPath(stack: self.stack)
      self.arrayDepth += 1
      self.arrayExpectingValueDepths.insert(self.arrayDepth)
      self.arrayHasValueDepths.remove(self.arrayDepth)
      self.arrayTrailingCommaDepths.remove(self.arrayDepth)
      self.stack.append(.array(index: 0))
      guard let currentArrayPath else { return }
      reducer[keyPath: currentArrayPath].reset()

    case .asciiArrayEnd:
      guard self.arrayDepth > 0, case .array = self.stack.last else {
        throw JSONStreamParsingError(
          reason: .unexpectedToken,
          position: self.position,
          context: .neutral
        )
      }
      if self.arrayTrailingCommaDepths.contains(self.arrayDepth) {
        throw JSONStreamParsingError(
          reason: .trailingComma,
          position: self.position,
          context: .arrayValue
        )
      }
      if self.arrayExpectingValueDepths.contains(self.arrayDepth)
        && self.arrayHasValueDepths.contains(self.arrayDepth)
      {
        throw JSONStreamParsingError(
          reason: .trailingComma,
          position: self.position,
          context: .arrayValue
        )
      }
      self.arrayTrailingCommaDepths.remove(self.arrayDepth)
      self.arrayExpectingValueDepths.remove(self.arrayDepth)
      self.arrayHasValueDepths.remove(self.arrayDepth)
      self.arrayDepth -= 1
      self.stack.removeLast()
      self.currentArrayPath = self.handlers.arrayPath(stack: Array(self.stack.dropLast()))

    case .asciiObjectStart:
      self.clearArrayTrailingCommaIfNeeded()
      try self.beginValueToken()
      self.appendArrayElementIfNeeded(into: &reducer)
      self.mode = .keyFinding
      self.currentDictionaryPath = self.handlers.dictionaryPath(stack: self.stack)
      self.objectDepth += 1
      guard let currentDictionaryPath else { return }
      reducer[keyPath: currentDictionaryPath].reset()

    case .asciiObjectEnd:
      guard self.objectDepth > 0 else {
        throw JSONStreamParsingError(
          reason: .unexpectedToken,
          position: self.position,
          context: .neutral
        )
      }
      if self.objectTrailingCommaDepths.contains(self.objectDepth) {
        throw JSONStreamParsingError(
          reason: .trailingComma,
          position: self.position,
          context: .objectValue
        )
      }
      if case .object = self.stack.last {
        let keyDepth = self.stack.count
        if self.objectValuePendingDepths.contains(keyDepth) {
          throw JSONStreamParsingError(
            reason: .missingValue,
            position: self.position,
            context: .objectValue
          )
        }
        self.stack.removeLast()
        self.currentDictionaryPath = self.handlers.dictionaryPath(stack: Array(self.stack.dropLast()))
      }
      self.objectTrailingCommaDepths.remove(self.objectDepth)
      self.objectDepth -= 1

    case .asciiTrueStart:
      self.clearArrayTrailingCommaIfNeeded()
      try self.beginValueToken()
      self.appendArrayElementIfNeeded(into: &reducer)
      if let boolPath = self.handlers.booleanPath(stack: self.stack) {
        reducer[keyPath: boolPath] = true
      }
      self.startLiteral(expected: jsonLiteralTrue)

    case .asciiFalseStart:
      self.clearArrayTrailingCommaIfNeeded()
      try self.beginValueToken()
      self.appendArrayElementIfNeeded(into: &reducer)
      if let boolPath = self.handlers.booleanPath(stack: self.stack) {
        reducer[keyPath: boolPath] = false
      }
      self.startLiteral(expected: jsonLiteralFalse)

    case .asciiNullStart:
      self.clearArrayTrailingCommaIfNeeded()
      try self.beginValueToken()
      self.appendArrayElementIfNeeded(into: &reducer)
      if let nullablePath = self.handlers.nullablePath(stack: self.stack) {
        reducer[keyPath: nullablePath] = nil
      }
      self.startLiteral(expected: jsonLiteralNull)

    case .asciiDash:
      self.clearArrayTrailingCommaIfNeeded()
      try self.beginValueToken()
      self.appendArrayElementIfNeeded(into: &reducer)
      self.currentNumberPath = self.handlers.numberPath(stack: self.stack)
      guard let numberPath = self.currentNumberPath else { return }
      self.mode = .integer
      self.isNegative = true
      self.isNegativeExponent = false
      self.exponent = 0
      self.fractionalPosition = 0
      self.numberState.reset()
      reducer[keyPath: numberPath].reset()

    case 0x30...0x39:
      self.clearArrayTrailingCommaIfNeeded()
      try self.beginValueToken()
      self.appendArrayElementIfNeeded(into: &reducer)
      self.currentNumberPath = self.handlers.numberPath(stack: self.stack)
      guard let numberPath = self.currentNumberPath else { return }
      self.mode = .integer
      self.isNegative = false
      self.isNegativeExponent = false
      self.exponent = 0
      self.fractionalPosition = 0
      self.numberState.reset()
      reducer[keyPath: numberPath].reset()
      try self.parseInteger(byte: byte, into: &reducer)

    default:
      if !byte.isWhitespace {
        throw JSONStreamParsingError(
          reason: .unexpectedToken,
          position: self.position,
          context: .neutral
        )
      }
    }
  }

  private mutating func parseKeyFinding(byte: UInt8, into reducer: inout Value) throws {
    switch byte {
    case .asciiQuote:
      self.mode = .keyCollecting
      self.string = ""
      self.isCollectingKey = true
      self.isAwaitingKeySeparator = false
      self.isEscaping = false
      self.utf8State = UTF8State()
      self.unicodeEscapeRemaining = 0
      self.unicodeEscapeValue = 0
      self.objectTrailingCommaDepths.remove(self.objectDepth)

    case .asciiObjectEnd:
      self.mode = .neutral
      if self.objectDepth == 0 {
        throw JSONStreamParsingError(
          reason: .unexpectedToken,
          position: self.position,
          context: .objectKey
        )
      }
      if self.objectTrailingCommaDepths.contains(self.objectDepth) {
        throw JSONStreamParsingError(
          reason: .trailingComma,
          position: self.position,
          context: .objectValue
        )
      }
      if case .object = self.stack.last {
        _ = self.stack.popLast()
      }
      self.objectTrailingCommaDepths.remove(self.objectDepth)
      self.objectDepth -= 1

    default:
      if !byte.isWhitespace {
        throw JSONStreamParsingError(
          reason: .unexpectedToken,
          position: self.position,
          context: .objectKey
        )
      }
    }
  }

  private mutating func parseKeyCollecting(byte: UInt8, into reducer: inout Value) throws {
    if self.isAwaitingKeySeparator {
      if byte == .asciiColon {
        self.stack.append(.object(key: self.string))
        self.objectValuePendingDepths.insert(self.stack.count)
        self.mode = .neutral
        self.isAwaitingKeySeparator = false
        self.isCollectingKey = false
      } else if !byte.isWhitespace {
        throw JSONStreamParsingError(
          reason: .missingColon,
          position: self.position,
          context: .objectKey
        )
      }
      return
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
        self.isCollectingKey = false
        self.isAwaitingKeySeparator = true
      }

    default:
      switch self.utf8State.consume(byte: byte) {
      case .appendByte:
        if self.isEscaping {
          var currentString = self.string
          self.appendEscapedCharacter(for: byte, into: &currentString)
          self.string = currentString
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

  private mutating func parseString(byte: UInt8, into reducer: inout Value) throws {
    if self.unicodeEscapeRemaining > 0 {
      guard let hexValue = byte.hexValue else {
        throw JSONStreamParsingError(
          reason: .invalidUnicodeEscape,
          position: self.position,
          context: .string
        )
      }
      self.unicodeEscapeValue = (self.unicodeEscapeValue << 4) | UInt32(hexValue)
      self.unicodeEscapeRemaining -= 1
      if self.unicodeEscapeRemaining == 0 {
        guard let scalar = Unicode.Scalar(self.unicodeEscapeValue) else {
          throw JSONStreamParsingError(
            reason: .invalidUnicodeEscape,
            position: self.position,
            context: .string
          )
        }
        if let currentStringPath {
          reducer[keyPath: currentStringPath].unicodeScalars.append(scalar)
        }
        self.unicodeEscapeValue = 0
      }
      return
    }

    guard let currentStringPath else {
      switch byte {
      case .asciiBackslash:
        if self.isEscaping {
          self.isEscaping = false
        } else {
          self.isEscaping = true
        }

      case .asciiQuote:
        if self.isEscaping {
          self.isEscaping = false
        } else {
          self.mode = .neutral
        }

      default:
        if self.isEscaping {
          if byte == 0x75 {
            self.unicodeEscapeRemaining = 4
            self.unicodeEscapeValue = 0
            self.isEscaping = false
            return
          }
          self.isEscaping = false
        }
        switch self.utf8State.consume(byte: byte) {
        case .appendByte:
          break
        case .appendScalar:
          break
        case .doNothing:
          break
        }
      }
      return
    }

    switch byte {
    case .asciiBackslash:
      if self.isEscaping {
        reducer[keyPath: currentStringPath].append("\\")
        self.isEscaping = false
      } else {
        self.isEscaping = true
      }

    case .asciiQuote:
      if self.isEscaping {
        reducer[keyPath: currentStringPath].append("\"")
        self.isEscaping = false
      } else {
        self.mode = .neutral
      }

    default:
      if self.isEscaping {
        if byte == 0x75 {
          self.unicodeEscapeRemaining = 4
          self.unicodeEscapeValue = 0
          self.isEscaping = false
          return
        }
      }
      switch self.utf8State.consume(byte: byte) {
      case .appendByte:
        if self.isEscaping {
          self.appendEscapedCharacter(for: byte, into: &reducer[keyPath: currentStringPath])
        } else {
          reducer[keyPath: currentStringPath].unicodeScalars.append(Unicode.Scalar(byte))
        }
      case .appendScalar(let scalar):
        reducer[keyPath: currentStringPath].unicodeScalars.append(scalar)
      case .doNothing:
        break
      }
    }
  }

  private mutating func appendEscapedCharacter(for byte: UInt8, into string: inout String) {
    switch byte {
    case .asciiLowerN: string.append("\n")
    case .asciiLowerR: string.append("\r")
    case .asciiLowerT: string.append("\t")
    case .asciiLowerB: string.append("\u{08}")
    case .asciiLowerF: string.append("\u{0C}")
    case .asciiSlash: string.append("/")
    default: string.unicodeScalars.append(Unicode.Scalar(byte))
    }
    self.isEscaping = false
  }

  private mutating func parseInteger(byte: UInt8, into reducer: inout Value) throws {
    if byte == .asciiDot {
      guard self.numberState.hasDigits else {
        throw JSONStreamParsingError(
          reason: .invalidNumber,
          position: self.position,
          context: .number
        )
      }
      self.mode = .fractionalDouble
      self.numberState.hasDot = true
    } else if byte == .asciiLowerE || byte == .asciiUpperE {
      self.mode = .exponentialDouble
      guard self.numberState.hasDigits else {
        throw JSONStreamParsingError(
          reason: .invalidNumber,
          position: self.position,
          context: .number
        )
      }
      self.numberState.hasExponent = true
      self.numberState.hasExponentDigits = false
    } else {
      guard let digit = byte.digitValue, let numberPath = self.currentNumberPath else {
        try self.finalizeNumberOrThrow(at: self.position, into: &reducer)
        return try self.parseNeutral(byte: byte, into: &reducer)
      }
      if self.numberState.hasLeadingZero && !self.numberState.hasDot && !self.numberState.hasExponent {
        throw JSONStreamParsingError(
          reason: .leadingZero,
          position: self.position,
          context: .number
        )
      }
      if !self.numberState.hasDigits {
        self.numberState.hasDigits = true
        if digit == 0 {
          self.numberState.hasLeadingZero = true
        }
      }
      reducer[keyPath: numberPath]
        .append(digit: digit, isNegative: self.isNegative, fractionalPosition: 0)
    }
  }

  private mutating func parseExponentialDouble(byte: UInt8, into reducer: inout Value) throws {
    if byte == .asciiDash {
      if self.numberState.hasExponentDigits {
        throw JSONStreamParsingError(
          reason: .invalidExponent,
          position: self.position,
          context: .number
        )
      }
      self.isNegativeExponent = true
    } else if byte == .asciiPlus {
      if self.numberState.hasExponentDigits {
        throw JSONStreamParsingError(
          reason: .invalidExponent,
          position: self.position,
          context: .number
        )
      }
      return
    } else if let digit = byte.digitValue {
      self.numberState.hasExponentDigits = true
      self.exponent.appendDigit(digit, isNegative: self.isNegativeExponent)
    } else {
      try self.finalizeNumberOrThrow(at: self.position, into: &reducer)
      try self.parseNeutral(byte: byte, into: &reducer)
    }
  }

  private mutating func parseFractionalDouble(byte: UInt8, into reducer: inout Value) throws {
    guard let digit = byte.digitValue, let currentNumberPath else {
      if byte == .asciiLowerE || byte == .asciiUpperE {
        guard self.numberState.hasFractionDigits else {
          throw JSONStreamParsingError(
            reason: .invalidNumber,
            position: self.position,
            context: .number
          )
        }
        self.mode = .exponentialDouble
        self.numberState.hasExponent = true
        self.numberState.hasExponentDigits = false
        return
      }
      try self.finalizeNumberOrThrow(at: self.position, into: &reducer)
      return try self.parseNeutral(byte: byte, into: &reducer)
    }
    self.fractionalPosition += 1
    self.numberState.hasFractionDigits = true
    reducer[keyPath: currentNumberPath]
      .append(
        digit: digit,
        isNegative: self.isNegative,
        fractionalPosition: self.fractionalPosition
      )
  }

  private mutating func parseLiteral(byte: UInt8, into reducer: inout Value) throws {
    guard self.literalState.index < self.literalState.expected.count else {
      self.mode = .neutral
      return try self.parseNeutral(byte: byte, into: &reducer)
    }
    if byte != self.literalState.expected[self.literalState.index] {
      throw JSONStreamParsingError(
        reason: .invalidLiteral,
        position: self.position,
        context: .literal
      )
    }
    self.literalState.index += 1
    if self.literalState.index == self.literalState.expected.count {
      self.mode = .neutral
    }
  }

  private mutating func startLiteral(expected: [UInt8]) {
    self.literalState.expected = expected
    self.literalState.index = 1
    self.mode = .literal
  }

  private mutating func finalizeNumberOrThrow(
    at position: JSONStreamParsingPosition,
    into reducer: inout Value
  ) throws {
    if !self.numberState.hasDigits {
      throw JSONStreamParsingError(
        reason: .invalidNumber,
        position: position,
        context: .number
      )
    }
    if self.numberState.hasDot && !self.numberState.hasFractionDigits {
      throw JSONStreamParsingError(
        reason: .invalidNumber,
        position: position,
        context: .number
      )
    }
    if self.numberState.hasExponent && !self.numberState.hasExponentDigits {
      throw JSONStreamParsingError(
        reason: .invalidExponent,
        position: position,
        context: .number
      )
    }
    if let numberPath = self.currentNumberPath {
      reducer[keyPath: numberPath].exponentiate(by: self.exponent)
    }
    self.mode = .neutral
    self.exponent = 0
    self.isNegativeExponent = false
    self.numberState.reset()
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

// MARK: - JSONStreamParsingError

public struct JSONStreamParsingPosition: Hashable, Sendable {
  public var line: Int
  public var column: Int

  public init(line: Int, column: Int) {
    self.line = line
    self.column = column
  }
}

public struct JSONStreamParsingError: Error, Hashable, Sendable {
  public enum Reason: Hashable, Sendable {
    case unexpectedToken
    case missingValue
    case missingColon
    case trailingComma
    case missingComma
    case unterminatedString
    case invalidUnicodeEscape
    case invalidLiteral
    case invalidNumber
    case leadingZero
    case invalidExponent
    case missingClosingBrace
    case missingClosingBracket
  }

  public enum Context: Hashable, Sendable {
    case neutral
    case objectKey
    case objectValue
    case arrayValue
    case string
    case number
    case literal
  }

  public var reason: Reason
  public var position: JSONStreamParsingPosition
  public var context: Context?

  public init(
    reason: Reason,
    position: JSONStreamParsingPosition,
    context: Context? = nil
  ) {
    self.reason = reason
    self.position = position
    self.context = context
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
    fileprivate private(set) var stringPath: WritableKeyPath<Value, String>?
    fileprivate private(set) var boolPath: WritableKeyPath<Value, Bool>?
    fileprivate private(set) var numberPath: WritableKeyPath<Value, JSONNumberAccumulator>?
    fileprivate private(set) var nullablePath: WritableKeyPath<Value, Void?>?
    fileprivate private(set) var arrayPath: WritableKeyPath<Value, any StreamParseableArrayObject>?
    fileprivate private(set) var dictionaryPath:
      WritableKeyPath<Value, any StreamParseableDictionaryObject>?
    fileprivate private(set) var indexPaths: IndexPaths?
    fileprivate private(set) var keyedPaths: KeyedPaths?
    fileprivate private(set) var objectHandlers = [String: ObjectHandlersState]()

    private let configuration: JSONStreamParserConfiguration

    init(configuration: JSONStreamParserConfiguration) {
      self.configuration = configuration
    }

    fileprivate func arrayPath(
      stack: [StackElement]
    ) -> WritableKeyPath<Value, any StreamParseableArrayObject>? {
      self.stackPath(
        stack: stack,
        rootPath: self.arrayPath,
        finalIndexPath: { $0.arrayPath?($1) },
        finalKeyedPath: { $0.arrayPath?($1) }
      )
    }

    fileprivate func dictionaryPath(
      stack: [StackElement]
    ) -> WritableKeyPath<Value, any StreamParseableDictionaryObject>? {
      self.stackPath(
        stack: stack,
        rootPath: self.dictionaryPath,
        finalIndexPath: { $0.dictionaryPath?($1) },
        finalKeyedPath: { $0.dictionaryPath?($1) }
      )
    }

    fileprivate func numberPath(
      stack: [StackElement]
    ) -> WritableKeyPath<Value, JSONNumberAccumulator>? {
      self.stackPath(
        stack: stack,
        rootPath: self.numberPath,
        finalIndexPath: { $0.numberPath?($1) },
        finalKeyedPath: { $0.numberPath?($1) }
      )
    }

    fileprivate func stringPath(stack: [StackElement]) -> WritableKeyPath<Value, String>? {
      self.stackPath(
        stack: stack,
        rootPath: self.stringPath,
        finalIndexPath: { $0.stringPath?($1) },
        finalKeyedPath: { $0.stringPath?($1) }
      )
    }

    fileprivate func nullablePath(stack: [StackElement]) -> WritableKeyPath<Value, Void?>? {
      self.stackPath(
        stack: stack,
        rootPath: self.nullablePath,
        finalIndexPath: { $0.nullablePath?($1) },
        finalKeyedPath: { $0.nullablePath?($1) }
      )
    }

    fileprivate func booleanPath(stack: [StackElement]) -> WritableKeyPath<Value, Bool>? {
      self.stackPath(
        stack: stack,
        rootPath: self.boolPath,
        finalIndexPath: { $0.boolPath?($1) },
        finalKeyedPath: { $0.boolPath?($1) }
      )
    }

    private func stackPath<Path>(
      stack: [StackElement],
      rootPath: WritableKeyPath<Value, Path>?,
      finalIndexPath: (IndexPaths, Int) -> AnyKeyPath?,
      finalKeyedPath: (KeyedPaths, String) -> AnyKeyPath?
    ) -> WritableKeyPath<Value, Path>? {
      guard !stack.isEmpty else { return rootPath }
      return
        self.keyPath(stack: stack, finalIndexPath: finalIndexPath, finalKeyedPath: finalKeyedPath)
        .flatMap { $0 as? WritableKeyPath<Value, Path> }
    }

    private func keyPath(
      stack: [StackElement],
      finalIndexPath: (IndexPaths, Int) -> AnyKeyPath?,
      finalKeyedPath: (KeyedPaths, String) -> AnyKeyPath?
    ) -> AnyKeyPath? {
      var path: AnyKeyPath?
      var indexPaths = self.indexPaths
      var keyedPaths = self.keyedPaths
      for element in stack.dropLast() {
        switch element {
        case .array(let index):
          guard let currentIndexPaths = indexPaths else { return nil }
          let (pathElement, nextIndexPaths, nextKeyedPaths) = currentIndexPaths.subpaths(index)
          if path == nil {
            path = pathElement
          } else {
            path = path?.appending(path: pathElement)
          }
          indexPaths = nextIndexPaths
          keyedPaths = nextKeyedPaths
        case .object(let key):
          guard let currentKeyedPaths = keyedPaths else { return nil }
          let (pathElement, nextIndexPaths, nextKeyedPaths) = currentKeyedPaths.subpaths(key)
          guard let pathElement else { return nil }
          if path == nil {
            path = pathElement
          } else {
            path = path?.appending(path: pathElement)
          }
          indexPaths = nextIndexPaths
          keyedPaths = nextKeyedPaths
        }
      }
      guard let last = stack.last else { return path }
      switch last {
      case .array(let index):
        guard let indexPaths, let pathElement = finalIndexPath(indexPaths, index) else {
          return nil
        }
        if path == nil {
          path = pathElement
        } else {
          path = path?.appending(path: pathElement)
        }
      case .object(let key):
        guard let keyedPaths, let pathElement = finalKeyedPath(keyedPaths, key) else { return nil }
        if path == nil {
          path = pathElement
        } else {
          path = path?.appending(path: pathElement)
        }
      }
      return path
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
      self.numberPath = keyPath.appending(path: \.erasedAccumulator)
    }

    public mutating func registerDoubleHandler(_ keyPath: WritableKeyPath<Value, Double>) {
      self.numberPath = keyPath.appending(path: \.erasedAccumulator)
    }

    public mutating func registerNilHandler<Nullable: StreamParseableValue>(
      _ keyPath: WritableKeyPath<Value, Nullable?>
    ) {
      self.nullablePath = keyPath.appending(path: \.nullablePath)
    }

    public mutating func registerKeyedHandler<Keyed: StreamParseableValue>(
      forKey key: String,
      _ keyPath: WritableKeyPath<Value, Keyed>
    ) {
      var keyedHandlers = JSONStreamParser<Keyed>.Handlers(configuration: self.configuration)
      Keyed.registerHandlers(in: &keyedHandlers)

      let decodedKey = self.configuration.keyDecodingStrategy.decode(key: key)

      let objectPaths = ObjectPaths(
        stringPath: keyedHandlers.stringPath.map { keyPath.appending(path: $0) },
        boolPath: keyedHandlers.boolPath.map { keyPath.appending(path: $0) },
        numberPath: keyedHandlers.numberPath.map { keyPath.appending(path: $0) },
        nullablePath: keyedHandlers.nullablePath.map { keyPath.appending(path: $0) },
        arrayPath: keyedHandlers.arrayPath.map { keyPath.appending(path: $0) },
        dictionaryPath: keyedHandlers.dictionaryPath.map { keyPath.appending(path: $0) }
      )
      self.objectHandlers[decodedKey] = ObjectHandlersState(
        paths: objectPaths,
        keyPath: keyPath,
        keyedPaths: keyedHandlers.keyedPaths,
        indexPaths: keyedHandlers.indexPaths
      )
      self.keyedPaths = KeyedPaths(objectHandlers: self.objectHandlers)
    }

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
      if let stringPath = handlers.stringPath {
        self.stringPath = path.appending(path: stringPath)
      }
      if let boolPath = handlers.boolPath {
        self.boolPath = path.appending(path: boolPath)
      }
      if let numberPath = handlers.numberPath {
        self.numberPath = path.appending(path: numberPath)
      }
      if let nullablePath = handlers.nullablePath {
        self.nullablePath = path.appending(path: nullablePath)
      }
      if let arrayPath = handlers.arrayPath {
        self.arrayPath = path.appending(path: arrayPath)
      }
      if let dictionaryPath = handlers.dictionaryPath {
        self.dictionaryPath = path.appending(path: dictionaryPath)
      }
      let prefixPath = path as AnyKeyPath
      if let indexedPaths = handlers.indexPaths {
        self.indexPaths = indexedPaths.prefixed(by: prefixPath)
      }
      if let keyedPaths = handlers.keyedPaths {
        self.keyedPaths = keyedPaths.prefixed(by: prefixPath)
      }

      guard !handlers.objectHandlers.isEmpty else { return }

      let newHandlers = handlers.objectHandlers.mapValues { handler in
        ObjectHandlersState(
          paths: ObjectPaths(
            stringPath: handler.paths.stringPath.flatMap {
              (path as AnyKeyPath).appending(path: $0)
            },
            boolPath: handler.paths.boolPath.flatMap {
              (path as AnyKeyPath).appending(path: $0)
            },
            numberPath: handler.paths.numberPath.flatMap {
              (path as AnyKeyPath).appending(path: $0)
            },
            nullablePath: handler.paths.nullablePath.flatMap {
              (path as AnyKeyPath).appending(path: $0)
            },
            arrayPath: handler.paths.arrayPath.flatMap {
              (path as AnyKeyPath).appending(path: $0)
            },
            dictionaryPath: handler.paths.dictionaryPath.flatMap {
              (path as AnyKeyPath).appending(path: $0)
            }
          ),
          keyPath: handler.keyPath.flatMap { (path as AnyKeyPath).appending(path: $0) },
          keyedPaths: handler.keyedPaths,
          indexPaths: handler.indexPaths
        )
      }
      self.objectHandlers.merge(newHandlers) { $1 }
      self.keyedPaths = KeyedPaths(objectHandlers: self.objectHandlers)
    }

    public mutating func registerArrayHandler<ArrayObject: StreamParseableArrayObject>(
      _ keyPath: WritableKeyPath<Value, ArrayObject>
    ) {
      self.arrayPath = keyPath.appending(path: \.erasedJSONPath)

      var elementHandlers = JSONStreamParser<ArrayObject.Element>
        .Handlers(configuration: self.configuration)
      ArrayObject.Element.registerHandlers(in: &elementHandlers)
      self.indexPaths = IndexPaths(handlers: elementHandlers, path: keyPath)
    }

    public mutating func registerDictionaryHandler<
      DictionaryObject: StreamParseableDictionaryObject
    >(_ keyPath: WritableKeyPath<Value, DictionaryObject>) {
      self.dictionaryPath = keyPath.appending(path: \.erasedJSONPath)

      var valueHandlers = JSONStreamParser<DictionaryObject.Value>
        .Handlers(configuration: self.configuration)
      DictionaryObject.Value.registerHandlers(in: &valueHandlers)
      self.keyedPaths = KeyedPaths(handlers: valueHandlers, path: keyPath)
    }

    @available(StreamParsing128BitIntegers, *)
    public mutating func registerInt128Handler(_ keyPath: WritableKeyPath<Value, Int128>) {
      self.numberPath = keyPath.appending(path: \.erasedAccumulator)
    }

    @available(StreamParsing128BitIntegers, *)
    public mutating func registerUInt128Handler(_ keyPath: WritableKeyPath<Value, UInt128>) {
      self.numberPath = keyPath.appending(path: \.erasedAccumulator)
    }
  }
}

// MARK: - IndexPaths

private struct IndexPaths {
  var stringPath: ((Int) -> AnyKeyPath)?
  var boolPath: ((Int) -> AnyKeyPath)?
  var numberPath: ((Int) -> AnyKeyPath)?
  var nullablePath: ((Int) -> AnyKeyPath)?
  var arrayPath: ((Int) -> AnyKeyPath)?
  var dictionaryPath: ((Int) -> AnyKeyPath)?
  var subpaths: (Int) -> (AnyKeyPath, IndexPaths?, KeyedPaths?)

  init<Value: StreamParseableValue, ArrayObject: StreamParseableArrayObject>(
    handlers: JSONStreamParser<ArrayObject.Element>.Handlers,
    path: WritableKeyPath<Value, ArrayObject>
  ) {
    if let stringPath = handlers.stringPath {
      self.stringPath = { path.appending(path: \.[$0]).appending(path: stringPath) }
    }
    if let boolPath = handlers.boolPath {
      self.boolPath = { path.appending(path: \.[$0]).appending(path: boolPath) }
    }
    if let numberPath = handlers.numberPath {
      self.numberPath = { path.appending(path: \.[$0]).appending(path: numberPath) }
    }
    if let nullablePath = handlers.nullablePath {
      self.nullablePath = { path.appending(path: \.[$0]).appending(path: nullablePath) }
    }
    if let dictionaryPath = handlers.dictionaryPath {
      self.dictionaryPath = { path.appending(path: \.[$0]).appending(path: dictionaryPath) }
    }
    if let arrayPath = handlers.arrayPath {
      self.arrayPath = { path.appending(path: \.[$0]).appending(path: arrayPath) }
    }
    self.subpaths = {
      (path.appending(path: \.[$0]), handlers.indexPaths, handlers.keyedPaths)
    }
  }

  func prefixed(by prefix: AnyKeyPath) -> IndexPaths {
    var prefixed = self
    if let stringPath = self.stringPath {
      prefixed.stringPath = { index in
        prefix.appending(path: stringPath(index)) ?? stringPath(index)
      }
    }
    if let boolPath = self.boolPath {
      prefixed.boolPath = { index in
        prefix.appending(path: boolPath(index)) ?? boolPath(index)
      }
    }
    if let numberPath = self.numberPath {
      prefixed.numberPath = { index in
        prefix.appending(path: numberPath(index)) ?? numberPath(index)
      }
    }
    if let nullablePath = self.nullablePath {
      prefixed.nullablePath = { index in
        prefix.appending(path: nullablePath(index)) ?? nullablePath(index)
      }
    }
    if let arrayPath = self.arrayPath {
      prefixed.arrayPath = { index in
        prefix.appending(path: arrayPath(index)) ?? arrayPath(index)
      }
    }
    if let dictionaryPath = self.dictionaryPath {
      prefixed.dictionaryPath = { index in
        prefix.appending(path: dictionaryPath(index)) ?? dictionaryPath(index)
      }
    }
    prefixed.subpaths = { index in
      let (pathElement, nextIndexPaths, nextKeyedPaths) = self.subpaths(index)
      return (prefix.appending(path: pathElement) ?? pathElement, nextIndexPaths, nextKeyedPaths)
    }
    return prefixed
  }
}

// MARK: - KeyedPaths

private struct KeyedPaths {
  var stringPath: ((String) -> AnyKeyPath?)?
  var boolPath: ((String) -> AnyKeyPath?)?
  var numberPath: ((String) -> AnyKeyPath?)?
  var nullablePath: ((String) -> AnyKeyPath?)?
  var arrayPath: ((String) -> AnyKeyPath?)?
  var dictionaryPath: ((String) -> AnyKeyPath?)?
  var subpaths: (String) -> (AnyKeyPath?, IndexPaths?, KeyedPaths?)

  init<Value: StreamParseableValue, DictionaryObject: StreamParseableDictionaryObject>(
    handlers: JSONStreamParser<DictionaryObject.Value>.Handlers,
    path: WritableKeyPath<Value, DictionaryObject>
  ) {
    if let stringPath = handlers.stringPath {
      self.stringPath = { path.appending(path: \.[unwrapped: $0]).appending(path: stringPath) }
    }
    if let boolPath = handlers.boolPath {
      self.boolPath = { path.appending(path: \.[unwrapped: $0]).appending(path: boolPath) }
    }
    if let numberPath = handlers.numberPath {
      self.numberPath = { path.appending(path: \.[unwrapped: $0]).appending(path: numberPath) }
    }
    if let nullablePath = handlers.nullablePath {
      self.nullablePath = { path.appending(path: \.[unwrapped: $0]).appending(path: nullablePath) }
    }
    if let dictionaryPath = handlers.dictionaryPath {
      self.dictionaryPath = {
        path.appending(path: \.[unwrapped: $0]).appending(path: dictionaryPath)
      }
    }
    if let arrayPath = handlers.arrayPath {
      self.arrayPath = { path.appending(path: \.[unwrapped: $0]).appending(path: arrayPath) }
    }
    self.subpaths = {
      (path.appending(path: \.[unwrapped: $0]), handlers.indexPaths, handlers.keyedPaths)
    }
  }

  init(objectHandlers: [String: ObjectHandlersState]) {
    self.stringPath = { objectHandlers[$0]?.paths.stringPath }
    self.numberPath = { objectHandlers[$0]?.paths.numberPath }
    self.boolPath = { objectHandlers[$0]?.paths.boolPath }
    self.arrayPath = { objectHandlers[$0]?.paths.arrayPath }
    self.dictionaryPath = { objectHandlers[$0]?.paths.dictionaryPath }
    self.nullablePath = { objectHandlers[$0]?.paths.nullablePath }
    self.subpaths = {
      (objectHandlers[$0]?.keyPath, objectHandlers[$0]?.indexPaths, objectHandlers[$0]?.keyedPaths)
    }
  }

  func prefixed(by prefix: AnyKeyPath) -> KeyedPaths {
    var prefixed = self
    if let stringPath = self.stringPath {
      prefixed.stringPath = { key in
        guard let path = stringPath(key) else { return nil }
        return prefix.appending(path: path) ?? path
      }
    }
    if let boolPath = self.boolPath {
      prefixed.boolPath = { key in
        guard let path = boolPath(key) else { return nil }
        return prefix.appending(path: path) ?? path
      }
    }
    if let numberPath = self.numberPath {
      prefixed.numberPath = { key in
        guard let path = numberPath(key) else { return nil }
        return prefix.appending(path: path) ?? path
      }
    }
    if let nullablePath = self.nullablePath {
      prefixed.nullablePath = { key in
        guard let path = nullablePath(key) else { return nil }
        return prefix.appending(path: path) ?? path
      }
    }
    if let arrayPath = self.arrayPath {
      prefixed.arrayPath = { key in
        guard let path = arrayPath(key) else { return nil }
        return prefix.appending(path: path) ?? path
      }
    }
    if let dictionaryPath = self.dictionaryPath {
      prefixed.dictionaryPath = { key in
        guard let path = dictionaryPath(key) else { return nil }
        return prefix.appending(path: path) ?? path
      }
    }
    prefixed.subpaths = { key in
      let (pathElement, nextIndexPaths, nextKeyedPaths) = self.subpaths(key)
      let appendedPath = pathElement.flatMap { prefix.appending(path: $0) ?? $0 }
      return (appendedPath, nextIndexPaths, nextKeyedPaths)
    }
    return prefixed
  }
}

// MARK: - ObjectPaths

private struct ObjectPaths {
  var stringPath: AnyKeyPath?
  var boolPath: AnyKeyPath?
  var numberPath: AnyKeyPath?
  var nullablePath: AnyKeyPath?
  var arrayPath: AnyKeyPath?
  var dictionaryPath: AnyKeyPath?
}

// MARK: - ObjectHandlersState

private struct ObjectHandlersState {
  var paths: ObjectPaths
  var keyPath: AnyKeyPath?
  var keyedPaths: KeyedPaths?
  var indexPaths: IndexPaths?
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
  fileprivate static let asciiArrayStart: UInt8 = 0x5B
  fileprivate static let asciiArrayEnd: UInt8 = 0x5D
  fileprivate static let asciiObjectStart: UInt8 = 0x7B
  fileprivate static let asciiObjectEnd: UInt8 = 0x7D
  fileprivate static let asciiColon: UInt8 = 0x3A
  fileprivate static let asciiComma: UInt8 = 0x2C
}

extension UInt8 {
  fileprivate var isLetter: Bool {
    switch self {
    case 0x41...0x5A, 0x61...0x7A: true
    default: false
    }
  }

  fileprivate var isWhitespace: Bool {
    switch self {
    case 0x20, 0x09, 0x0A, 0x0D: true
    default: false
    }
  }

  fileprivate var hexValue: UInt8? {
    switch self {
    case 0x30...0x39: self &- 0x30
    case 0x41...0x46: self &- 0x41 &+ 10
    case 0x61...0x66: self &- 0x61 &+ 10
    default: nil
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

private enum JSONNumberAccumulator {
  case int(Int)
  case int8(Int8)
  case int16(Int16)
  case int32(Int32)
  case int64(Int64)
  case int128(low: UInt64, high: Int64)
  case uint(UInt)
  case uint8(UInt8)
  case uint16(UInt16)
  case uint32(UInt32)
  case uint64(UInt64)
  case uint128(low: UInt64, high: UInt64)
  case float(Float)
  case double(Double)

  mutating func reset() {
    switch self {
    case .int: self = .int(.zero)
    case .int8: self = .int8(.zero)
    case .int16: self = .int16(.zero)
    case .int32: self = .int32(.zero)
    case .int64: self = .int64(.zero)
    case .int128: self = .int128(low: .zero, high: .zero)
    case .uint: self = .uint(.zero)
    case .uint8: self = .uint8(.zero)
    case .uint16: self = .uint16(.zero)
    case .uint32: self = .uint32(.zero)
    case .uint64: self = .uint64(.zero)
    case .uint128: self = .uint128(low: .zero, high: .zero)
    case .float: self = .float(.zero)
    case .double: self = .double(.zero)
    }
  }

  mutating func append(digit: UInt8, isNegative: Bool, fractionalPosition: Int) {
    switch self {
    case .int(var value):
      value.appendDigit(digit, isNegative: isNegative)
      self = .int(value)
    case .int8(var value):
      value.appendDigit(digit, isNegative: isNegative)
      self = .int8(value)
    case .int16(var value):
      value.appendDigit(digit, isNegative: isNegative)
      self = .int16(value)
    case .int32(var value):
      value.appendDigit(digit, isNegative: isNegative)
      self = .int32(value)
    case .int64(var value):
      value.appendDigit(digit, isNegative: isNegative)
      self = .int64(value)
    case .int128(let low, let high):
      guard #available(StreamParsing128BitIntegers , *) else { return }
      var value = Int128(_low: low, _high: high)
      value.appendDigit(digit, isNegative: isNegative)
      self = .int128(low: value._low, high: value._high)
    case .uint(var value):
      value.appendDigit(digit, isNegative: isNegative)
      self = .uint(value)
    case .uint8(var value):
      value.appendDigit(digit, isNegative: isNegative)
      self = .uint8(value)
    case .uint16(var value):
      value.appendDigit(digit, isNegative: isNegative)
      self = .uint16(value)
    case .uint32(var value):
      value.appendDigit(digit, isNegative: isNegative)
      self = .uint32(value)
    case .uint64(var value):
      value.appendDigit(digit, isNegative: isNegative)
      self = .uint64(value)
    case .uint128(let low, let high):
      guard #available(StreamParsing128BitIntegers , *) else { return }
      var value = UInt128(_low: low, _high: high)
      value.appendDigit(digit, isNegative: isNegative)
      self = .uint128(low: value._low, high: value._high)
    case .float(var value):
      value.appendDigit(digit, isNegative: isNegative, fractionalPosition: fractionalPosition)
      self = .float(value)
    case .double(var value):
      value.appendDigit(digit, isNegative: isNegative, fractionalPosition: fractionalPosition)
      self = .double(value)
    }
  }

  mutating func exponentiate(by exponent: Int) {
    switch self {
    case .float(var value):
      value.exponentiate(by: exponent)
      self = .float(value)
    case .double(var value):
      value.exponentiate(by: exponent)
      self = .double(value)
    default:
      break
    }
  }
}

extension BinaryInteger {
  fileprivate mutating func appendDigit(_ digit: UInt8, isNegative: Bool) {
    self *= 10
    if isNegative {
      self -= Self(digit)
    } else {
      self += Self(digit)
    }
  }
}

extension BinaryFloatingPoint {
  fileprivate mutating func appendDigit(_ digit: UInt8, isNegative: Bool, fractionalPosition: Int) {
    if fractionalPosition > 0 {
      let delta = Self(digit) / Self(digitPow10(fractionalPosition))
      if isNegative {
        self -= delta
      } else {
        self += delta
      }
    } else {
      self *= 10
      if isNegative {
        self -= Self(digit)
      } else {
        self += Self(digit)
      }
    }
  }

  fileprivate mutating func exponentiate(by exponent: Int) {
    self *= Self(digitPow10(exponent))
  }
}

extension Int {
  fileprivate var erasedAccumulator: JSONNumberAccumulator {
    get { .int(self) }
    set {
      guard case .int(let value) = newValue else { jsonNumberAccumulatorCaseMismatch() }
      self = value
    }
  }
}

extension Int8 {
  fileprivate var erasedAccumulator: JSONNumberAccumulator {
    get { .int8(self) }
    set {
      guard case .int8(let value) = newValue else { jsonNumberAccumulatorCaseMismatch() }
      self = value
    }
  }
}

extension Int16 {
  fileprivate var erasedAccumulator: JSONNumberAccumulator {
    get { .int16(self) }
    set {
      guard case .int16(let value) = newValue else { jsonNumberAccumulatorCaseMismatch() }
      self = value
    }
  }
}

extension Int32 {
  fileprivate var erasedAccumulator: JSONNumberAccumulator {
    get { .int32(self) }
    set {
      guard case .int32(let value) = newValue else { jsonNumberAccumulatorCaseMismatch() }
      self = value
    }
  }
}

extension Int64 {
  fileprivate var erasedAccumulator: JSONNumberAccumulator {
    get { .int64(self) }
    set {
      guard case .int64(let value) = newValue else { jsonNumberAccumulatorCaseMismatch() }
      self = value
    }
  }
}

@available(StreamParsing128BitIntegers, *)
extension Int128 {
  fileprivate var erasedAccumulator: JSONNumberAccumulator {
    get { .int128(low: self._low, high: self._high) }
    set {
      guard case .int128(let low, let high) = newValue else { jsonNumberAccumulatorCaseMismatch() }
      self = Int128(_low: low, _high: high)
    }
  }
}

extension UInt {
  fileprivate var erasedAccumulator: JSONNumberAccumulator {
    get { .uint(self) }
    set {
      guard case .uint(let value) = newValue else { jsonNumberAccumulatorCaseMismatch() }
      self = value
    }
  }
}

extension UInt8 {
  fileprivate var erasedAccumulator: JSONNumberAccumulator {
    get { .uint8(self) }
    set {
      guard case .uint8(let value) = newValue else { jsonNumberAccumulatorCaseMismatch() }
      self = value
    }
  }
}

extension UInt16 {
  fileprivate var erasedAccumulator: JSONNumberAccumulator {
    get { .uint16(self) }
    set {
      guard case .uint16(let value) = newValue else { jsonNumberAccumulatorCaseMismatch() }
      self = value
    }
  }
}

extension UInt32 {
  fileprivate var erasedAccumulator: JSONNumberAccumulator {
    get { .uint32(self) }
    set {
      guard case .uint32(let value) = newValue else { jsonNumberAccumulatorCaseMismatch() }
      self = value
    }
  }
}

extension UInt64 {
  fileprivate var erasedAccumulator: JSONNumberAccumulator {
    get { .uint64(self) }
    set {
      guard case .uint64(let value) = newValue else { jsonNumberAccumulatorCaseMismatch() }
      self = value
    }
  }
}

@available(StreamParsing128BitIntegers, *)
extension UInt128 {
  fileprivate var erasedAccumulator: JSONNumberAccumulator {
    get { .uint128(low: self._low, high: self._high) }
    set {
      guard case .uint128(let low, let high) = newValue else { jsonNumberAccumulatorCaseMismatch() }
      self = UInt128(_low: low, _high: high)
    }
  }
}

extension Float {
  fileprivate var erasedAccumulator: JSONNumberAccumulator {
    get { .float(self) }
    set {
      guard case .float(let value) = newValue else { jsonNumberAccumulatorCaseMismatch() }
      self = value
    }
  }
}

extension Double {
  fileprivate var erasedAccumulator: JSONNumberAccumulator {
    get { .double(self) }
    set {
      guard case .double(let value) = newValue else { jsonNumberAccumulatorCaseMismatch() }
      self = value
    }
  }
}

private func jsonNumberAccumulatorCaseMismatch() -> Never {
  fatalError("JSONNumberAccumulator case mismatch.")
}

// MARK: - DictionaryObject

extension StreamParseableDictionaryObject {
  fileprivate var erasedJSONPath: any StreamParseableDictionaryObject {
    get { self }
    set { self = newValue as! Self }
  }

  fileprivate subscript(unwrapped key: String) -> Value {
    get { self[key] ?? Value.initialParseableValue() }
    set { self[key] = newValue }
  }
}

// MARK: - ArrayLikeObject

extension StreamParseableArrayObject {
  fileprivate var erasedJSONPath: any StreamParseableArrayObject {
    get { self }
    set { self = newValue as! Self }
  }

  fileprivate mutating func appendNewElement() {
    self.append(contentsOf: CollectionOfOne(.initialParseableValue()))
  }
}

// MARK: - StreamParseableValue

extension StreamParseableValue {
  fileprivate var erasedJSONPath: any StreamParseableValue {
    get { self }
    set { self = newValue as! Self }
  }

  fileprivate mutating func reset() {
    self = .initialParseableValue()
  }
}

// MARK: - StackElement

private enum StackElement {
  case array(index: Int)
  case object(key: String)
}

// MARK: - NumberState

private struct NumberState {
  var hasDigits = false
  var hasLeadingZero = false
  var hasFractionDigits = false
  var hasExponent = false
  var hasExponentDigits = false
  var hasDot = false

  mutating func reset() {
    self = NumberState()
  }
}

// MARK: - LiteralState

private struct LiteralState {
  var expected = [UInt8]()
  var index = 0
}

private let jsonLiteralTrue: [UInt8] = Array("true".utf8)
private let jsonLiteralFalse: [UInt8] = Array("false".utf8)
private let jsonLiteralNull: [UInt8] = Array("null".utf8)
