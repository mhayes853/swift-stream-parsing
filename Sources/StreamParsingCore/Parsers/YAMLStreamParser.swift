// MARK: - YAMLStreamParser

/// A convenience typealias for ``YAMLStreamParser`` that parses a partial of a ``StreamParseable`` type.
public typealias YAMLStreamParserOf<
  Parseable: StreamParseable
> = YAMLStreamParser<Parseable.Partial>

/// A ``StreamParser`` that parses YAML.
public struct YAMLStreamParser<Value: StreamParseableValue>: StreamParser {
  private enum Mode {
    case neutral
    case string
    case keyCollecting
    case integer
    case fractionalDouble
    case exponentialDouble
    case literal
    case comment
    case arrayValue
    case lineStartDash

    var isNumeric: Bool {
      switch self {
      case .integer, .fractionalDouble, .exponentialDouble: true
      default: false
      }
    }
  }

  private enum ArrayStyle {
    case block(indent: Int)
    case flow
  }

  private enum ObjectStyle {
    case block(indent: Int)
    case flow
  }

  private struct ArrayContext {
    let path: WritableKeyPath<Value, any StreamParseableArrayObject>?
    let style: ArrayStyle
    var didAppendForCurrentElement = false
  }

  private struct ObjectContext {
    let path: WritableKeyPath<Value, any StreamParseableDictionaryObject>?
    let style: ObjectStyle
    var isExpectingKey = true
    var hasActiveKey = false
  }

  public let configuration: YAMLStreamParserConfiguration

  private var handlers: Handlers
  private var mode = Mode.neutral
  private var stringState = StringParsingState()
  private var numberParsingState = NumberParsingState()
  private var position = YAMLStreamParsingPosition(line: 1, column: 1)
  private var currentStringPath: WritableKeyPath<Value, String>?
  private var currentNumberPath: WritableKeyPath<Value, JSONNumberAccumulator>?
  private var currentBoolPath: WritableKeyPath<Value, Bool>?
  private var currentNullablePath: WritableKeyPath<Value, Void?>?
  private var currentDictionaryPath: WritableKeyPath<Value, any StreamParseableDictionaryObject>?
  private var literalState = LiteralState()
  private var currentTrieNode: PathTrie<Value>?
  private var trieNodeStack = [PathTrie<Value>?]()
  private var arrayContexts = [ArrayContext]()
  private var objectContexts = [ObjectContext]()
  private var isAtLineStart = true
  private var currentLineIndent = 0
  private var lineStartDashIndent: Int?
  private var keyParsingState = KeyParsingState()

  public init(configuration: YAMLStreamParserConfiguration = YAMLStreamParserConfiguration()) {
    self.configuration = configuration
    self.handlers = Handlers(configuration: configuration)
    self.currentTrieNode = self.handlers.pathTrie
  }

  public mutating func registerHandlers() {
    Value.registerHandlers(in: &self.handlers)
    self.currentTrieNode = self.handlers.pathTrie
    let (stringPath, _) = self.handlers.stringPath(node: self.currentTrieNode)
    self.currentStringPath = stringPath
  }

  public mutating func parse(bytes: some Sequence<UInt8>, into reducer: inout Value) throws {
    var chunkState = ByteChunkParseState()
    for byte in bytes {
      try self.parse(byte: byte, into: &reducer, chunkState: &chunkState)
    }
    try self.flushByteChunkParseState(&chunkState, into: &reducer)
  }

  public mutating func finish(reducer: inout Value) throws {
    if self.mode == .string {
      throw YAMLStreamParsingError(
        reason: .unterminatedString,
        position: self.position,
        context: .string
      )
    }
    if self.mode.isNumeric {
      var chunkState = ByteChunkParseState()
      try self.finalizeNumberOrThrow(at: self.position, into: &reducer, chunkState: &chunkState)
    }
    self.closeBlockArrayContexts(toIndent: 0)
  }

  private var currentArrayContext: ArrayContext? {
    self.arrayContexts.last
  }

  private var currentObjectContext: ObjectContext? {
    self.objectContexts.last
  }

  private mutating func replaceCurrentArrayContext(_ update: (inout ArrayContext) -> Void) {
    guard let index = self.arrayContexts.indices.last else { return }
    update(&self.arrayContexts[index])
  }

  private mutating func replaceCurrentObjectContext(_ update: (inout ObjectContext) -> Void) {
    guard let index = self.objectContexts.indices.last else { return }
    update(&self.objectContexts[index])
  }

  private mutating func pushArrayTrieNode() {
    let next = self.currentTrieNode?.ensureArrayChild()
    self.trieNodeStack.append(next)
    self.currentTrieNode = next
  }

  private mutating func popArrayTrieNode() {
    _ = self.trieNodeStack.popLast()
    self.currentTrieNode = self.trieNodeStack.last ?? self.handlers.pathTrie
  }

  private mutating func pushObjectTrieNode(for key: String) {
    let next = self.currentTrieNode?.objectChildNode(for: key)
    self.trieNodeStack.append(next)
    self.currentTrieNode = next
  }

  private mutating func popTrieNode() {
    _ = self.trieNodeStack.popLast()
    self.currentTrieNode = self.trieNodeStack.last ?? self.handlers.pathTrie
  }

  private mutating func appendArrayElementIfNeeded(into reducer: inout Value) {
    guard let currentArrayContext, !currentArrayContext.didAppendForCurrentElement else { return }
    if let path = currentArrayContext.path {
      reducer[keyPath: path].appendNewElement()
    }
    self.replaceCurrentArrayContext { $0.didAppendForCurrentElement = true }
  }

  private mutating func prepareForNextArrayElement() {
    self.replaceCurrentArrayContext { $0.didAppendForCurrentElement = false }
    self.currentNumberPath = nil
    self.currentStringPath = nil
    self.currentBoolPath = nil
    self.currentNullablePath = nil
    self.currentDictionaryPath = nil
  }

  private mutating func finishCurrentObjectValue() {
    guard let currentObjectContext, currentObjectContext.hasActiveKey else { return }
    self.popTrieNode()
    self.replaceCurrentObjectContext {
      $0.hasActiveKey = false
      $0.isExpectingKey = true
    }
  }

  private mutating func closeBlockArrayContexts(toIndent indent: Int) {
    while case .block(let currentIndent) = self.currentArrayContext?.style, currentIndent > indent {
      _ = self.arrayContexts.popLast()
      self.popArrayTrieNode()
    }
  }

  private mutating func closeBlockObjectContexts(toIndent indent: Int) {
    while case .block(let currentIndent) = self.currentObjectContext?.style, currentIndent > indent {
      self.finishCurrentObjectValue()
      _ = self.objectContexts.popLast()
    }
  }

  private mutating func prepareBlockContextsForIndent(_ indent: Int) {
    if case .block(let currentIndent) = self.currentObjectContext?.style,
      self.currentObjectContext?.hasActiveKey == true,
      indent <= currentIndent
    {
      self.finishCurrentObjectValue()
    }
    self.closeBlockArrayContexts(toIndent: indent)
    self.closeBlockObjectContexts(toIndent: indent)
  }

  private mutating func startBlockArrayItem(at indent: Int, into reducer: inout Value) {
    if case .block(let currentIndent) = self.currentArrayContext?.style, currentIndent == indent {
      self.prepareForNextArrayElement()
      return
    }

    self.appendArrayElementIfNeeded(into: &reducer)
    let (path, _) = self.handlers.arrayPath(node: self.currentTrieNode)
    if let path {
      reducer[keyPath: path].reset()
    }
    self.arrayContexts.append(ArrayContext(path: path, style: .block(indent: indent)))
    self.pushArrayTrieNode()
    self.prepareForNextArrayElement()
  }

  private mutating func startObject(style: ObjectStyle, into reducer: inout Value) {
    let (path, _) = self.handlers.dictionaryPath(node: self.currentTrieNode)
    if let path {
      reducer[keyPath: path].reset()
    }
    self.objectContexts.append(ObjectContext(path: path, style: style))
    self.currentDictionaryPath = path
  }

  private mutating func startBlockObjectIfNeeded(at indent: Int, into reducer: inout Value) {
    if case .block(let currentIndent) = self.currentObjectContext?.style, currentIndent == indent {
      return
    }
    self.startObject(style: .block(indent: indent), into: &reducer)
  }

  private mutating func activateCurrentObjectKey(_ key: String) {
    let decodedKey = self.configuration.keyDecodingStrategy.decode(key: key)
    self.pushObjectTrieNode(for: decodedKey)
    self.replaceCurrentObjectContext {
      $0.isExpectingKey = false
      $0.hasActiveKey = true
    }
  }

  private mutating func parse(byte: UInt8, into reducer: inout Value, chunkState: inout ByteChunkParseState) throws {
    defer { self.advancePosition(for: byte) }

    if self.mode == .neutral || self.mode == .arrayValue {
      if self.isAtLineStart {
        switch byte {
        case 0x20:
          self.currentLineIndent += 1
          return
        case 0x0A:
          return
        default:
          self.prepareBlockContextsForIndent(self.currentLineIndent)
          if self.currentObjectContext == nil,
            self.currentLineIndent == 0,
            self.currentTrieNode?.expectsObject == true,
            byte == .asciiQuote || self.isPlainKeyByte(byte)
          {
            self.startBlockObjectIfNeeded(at: 0, into: &reducer)
          }
          if self.currentObjectContext == nil,
            self.currentTrieNode?.expectsObject == true,
            byte == .asciiQuote || self.isPlainKeyByte(byte)
          {
            self.startBlockObjectIfNeeded(at: self.currentLineIndent, into: &reducer)
          } else if case .block(let indent) = self.currentObjectContext?.style,
            self.currentObjectContext?.hasActiveKey == true,
            self.currentLineIndent > indent,
            self.currentTrieNode?.expectsObject == true
          {
            self.startBlockObjectIfNeeded(at: self.currentLineIndent, into: &reducer)
          }
          self.isAtLineStart = false
        }
      }
    }

    switch self.mode {
    case .neutral: try self.parseNeutral(byte: byte, into: &reducer, chunkState: &chunkState)
    case .string: try self.parseString(byte: byte, into: &reducer, chunkState: &chunkState)
    case .integer: try self.parseInteger(byte: byte, into: &reducer, chunkState: &chunkState)
    case .fractionalDouble: try self.parseFractionalDouble(byte: byte, into: &reducer, chunkState: &chunkState)
    case .exponentialDouble: try self.parseExponentialDouble(byte: byte, into: &reducer, chunkState: &chunkState)
    case .literal: try self.parseLiteral(byte: byte, into: &reducer)
    case .keyCollecting: try self.parseKeyCollecting(byte: byte)
    case .comment: self.parseComment(byte: byte)
    case .arrayValue: try self.parseArrayValue(byte: byte, into: &reducer, chunkState: &chunkState)
    case .lineStartDash: try self.parseLineStartDash(byte: byte, into: &reducer, chunkState: &chunkState)
    }
  }

  private mutating func parseNeutral(byte: UInt8, into reducer: inout Value, chunkState: inout ByteChunkParseState) throws {
    if self.currentObjectContext?.isExpectingKey == true {
      switch byte {
      case .asciiObjectEnd:
        return self.finishCurrentFlowObject()
      case .asciiQuote:
        self.mode = .keyCollecting
        self.keyParsingState.startQuoted()
        return
      default:
        if self.isPlainKeyByte(byte) {
          self.mode = .keyCollecting
          self.keyParsingState.startPlain(initial: byte)
          return
        }
      }
    }

    switch byte {
    case .asciiComma:
      if case .flow = self.currentArrayContext?.style {
        try self.flushByteChunkParseState(&chunkState, into: &reducer)
        self.prepareForNextArrayElement()
        self.mode = .arrayValue
      } else if case .flow = self.currentObjectContext?.style {
        try self.flushByteChunkParseState(&chunkState, into: &reducer)
        self.finishCurrentObjectValue()
      }
    case .asciiQuote:
      try self.handleNeutralDoubleQuotedStringStart(into: &reducer, chunkState: &chunkState)
    case .asciiArrayStart:
      try self.handleNeutralArrayStart(into: &reducer)
    case .asciiArrayEnd:
      try self.handleNeutralArrayEnd(into: &reducer)
    case .asciiObjectStart:
      try self.handleNeutralObjectStart(into: &reducer)
    case .asciiObjectEnd:
      try self.handleNeutralObjectEnd()
    case .asciiDash:
      self.lineStartDashIndent = self.currentLineIndent
      self.mode = .lineStartDash
    case 0x30...0x39:
      try self.handleNeutralDigitStart(byte, into: &reducer, chunkState: &chunkState)
    case .asciiDot:
      try self.handleNeutralLeadingDecimalPointStart(into: &reducer, chunkState: &chunkState)
    case .asciiUpperI, .asciiUpperN:
      try self.handleNeutralNonFiniteNumberStart(byte, into: &reducer)
    case .asciiLowerT, .asciiLowerF:
      try self.handleNeutralLiteralStart(byte, into: &reducer)
    case .asciiLowerN:
      try self.handleNeutralNullStart(byte, into: &reducer)
    case .asciiHash:
      try self.handleNeutralCommentStart()
    default:
      break
    }
  }

  private func isPlainKeyByte(_ byte: UInt8) -> Bool {
    switch byte {
    case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F:
      true
    default:
      false
    }
  }

  private func isYAMLWhitespace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
  }

  private mutating func parseKeyCollecting(byte: UInt8) throws {
    if self.keyParsingState.isAwaitingColon {
      if byte == .asciiColon {
        self.activateCurrentObjectKey(self.keyParsingState.buffer)
        self.keyParsingState.reset()
        self.mode = .neutral
      } else if !self.isYAMLWhitespace(byte) {
        throw YAMLStreamParsingError(reason: .missingColon, position: self.position, context: .objectKey)
      }
      return
    }

    if self.keyParsingState.isQuoted {
      switch byte {
      case .asciiBackslash:
        self.keyParsingState.isEscaping.toggle()
      case self.keyParsingState.delimiter:
        if self.keyParsingState.isEscaping {
          self.keyParsingState.buffer.unicodeScalars.append(Unicode.Scalar(byte))
          self.keyParsingState.isEscaping = false
        } else {
          self.keyParsingState.isAwaitingColon = true
        }
      default:
        switch self.keyParsingState.utf8State.consume(byte: byte) {
        case .consume(let scalar):
          self.keyParsingState.buffer.unicodeScalars.append(scalar)
          self.keyParsingState.isEscaping = false
        case .doNothing:
          break
        }
      }
      return
    }

    if byte == .asciiColon {
      self.activateCurrentObjectKey(self.keyParsingState.buffer)
      self.keyParsingState.reset()
      self.mode = .neutral
    } else if self.isYAMLWhitespace(byte) {
      self.keyParsingState.isAwaitingColon = true
    } else if self.isPlainKeyByte(byte) || byte == .asciiDash {
      self.keyParsingState.buffer.unicodeScalars.append(Unicode.Scalar(byte))
    } else {
      throw YAMLStreamParsingError(reason: .unexpectedToken, position: self.position, context: .objectKey)
    }
  }

  private mutating func parseLineStartDash(
    byte: UInt8,
    into reducer: inout Value,
    chunkState: inout ByteChunkParseState
  ) throws {
    guard let lineStartDashIndent else {
      self.mode = .neutral
      return try self.parseNeutral(byte: byte, into: &reducer, chunkState: &chunkState)
    }

    if byte == 0x20 || byte == 0x0A {
      self.startBlockArrayItem(at: lineStartDashIndent, into: &reducer)
      self.mode = byte == 0x20 ? .arrayValue : .neutral
      return
    }

    self.mode = .neutral
    self.lineStartDashIndent = nil
    try self.handleNeutralNegativeNumberStart(into: &reducer, chunkState: &chunkState)
    try self.parseInteger(byte: byte, into: &reducer, chunkState: &chunkState)
  }

  private mutating func handleNeutralNegativeNumberStart(into reducer: inout Value, chunkState: inout ByteChunkParseState) throws {
    self.appendArrayElementIfNeeded(into: &reducer)
    let (path, _) = self.handlers.numberPath(node: self.currentTrieNode)
    self.currentNumberPath = path
    self.mode = .integer
    self.numberParsingState.resetForInteger(isNegative: true)
    try self.numberParsingState.appendDigit(.asciiDash, position: self.position)
    if let currentNumberPath {
      var valueNumberAccumulator = reducer[keyPath: currentNumberPath]
      valueNumberAccumulator.reset()
      chunkState.valueNumberAccumulator = valueNumberAccumulator
    }
  }

  private mutating func handleNeutralDigitStart(_ byte: UInt8, into reducer: inout Value, chunkState: inout ByteChunkParseState) throws {
    self.appendArrayElementIfNeeded(into: &reducer)
    let (path, _) = self.handlers.numberPath(node: self.currentTrieNode)
    self.currentNumberPath = path
    self.mode = .integer
    self.numberParsingState.resetForInteger(isNegative: false)
    if let currentNumberPath {
      var valueNumberAccumulator = reducer[keyPath: currentNumberPath]
      valueNumberAccumulator.reset()
      chunkState.valueNumberAccumulator = valueNumberAccumulator
    }
    try self.parseInteger(byte: byte, into: &reducer, chunkState: &chunkState)
  }

  private mutating func handleNeutralLeadingDecimalPointStart(into reducer: inout Value, chunkState: inout ByteChunkParseState) throws {
    self.appendArrayElementIfNeeded(into: &reducer)
    let (path, _) = self.handlers.numberPath(node: self.currentTrieNode)
    self.currentNumberPath = path
    self.mode = .fractionalDouble
    try self.numberParsingState.resetForFractionalLeadingDot(position: self.position)
    if let currentNumberPath {
      var valueNumberAccumulator = reducer[keyPath: currentNumberPath]
      valueNumberAccumulator.reset()
      chunkState.valueNumberAccumulator = valueNumberAccumulator
    }
  }

  private mutating func handleNeutralNonFiniteNumberStart(_ byte: UInt8, into reducer: inout Value) throws {
    if byte == .asciiUpperI {
      self.startLiteral(expected: yamlLiteralInfinity)
    } else {
      self.startLiteral(expected: yamlLiteralNaN)
    }
  }

  private mutating func handleNeutralLiteralStart(_ byte: UInt8, into reducer: inout Value) throws {
    self.appendArrayElementIfNeeded(into: &reducer)
    let (boolPath, _) = self.handlers.booleanPath(node: self.currentTrieNode)
    self.currentBoolPath = boolPath
    if byte == .asciiLowerT {
      if let boolPath {
        reducer[keyPath: boolPath] = true
      }
      self.startLiteral(expected: yamlLiteralTrue)
    } else {
      if let boolPath {
        reducer[keyPath: boolPath] = false
      }
      self.startLiteral(expected: yamlLiteralFalse)
    }
  }

  private mutating func handleNeutralNullStart(_ byte: UInt8, into reducer: inout Value) throws {
    self.appendArrayElementIfNeeded(into: &reducer)
    let (nullablePath, _) = self.handlers.nullablePath(node: self.currentTrieNode)
    self.currentNullablePath = nullablePath
    if let nullablePath {
      reducer[keyPath: nullablePath] = nil
    }
    self.startLiteral(expected: yamlLiteralNull)
  }

  private mutating func handleNeutralCommentStart() throws {
    guard self.configuration.syntaxOptions.contains(.comments) else { return }
    self.mode = .comment
  }

  private mutating func handleNeutralArrayStart(into reducer: inout Value) throws {
    let (path, _) = self.handlers.arrayPath(node: self.currentTrieNode)
    self.appendArrayElementIfNeeded(into: &reducer)
    if let path {
      reducer[keyPath: path].reset()
    }
    self.arrayContexts.append(ArrayContext(path: path, style: .flow))
    self.pushArrayTrieNode()
    self.prepareForNextArrayElement()
    self.mode = .arrayValue
  }

  private mutating func handleNeutralObjectStart(into reducer: inout Value) throws {
    self.appendArrayElementIfNeeded(into: &reducer)
    self.startObject(style: .flow, into: &reducer)
    self.mode = .neutral
  }

  private mutating func finishCurrentFlowObject() {
    guard case .flow = self.currentObjectContext?.style else { return }
    self.finishCurrentObjectValue()
    _ = self.objectContexts.popLast()
    self.currentDictionaryPath = self.currentObjectContext?.path
    self.mode = .neutral
  }

  private mutating func handleNeutralObjectEnd() throws {
    self.finishCurrentFlowObject()
  }

  private mutating func handleNeutralArrayEnd(into reducer: inout Value) throws {
    guard case .flow = self.currentArrayContext?.style else { return }
    _ = self.arrayContexts.popLast()
    self.popArrayTrieNode()
    self.mode = .neutral
  }

  private mutating func handleNeutralDoubleQuotedStringStart(into reducer: inout Value, chunkState: inout ByteChunkParseState) throws {
    self.appendArrayElementIfNeeded(into: &reducer)
    let (stringPath, _) = self.handlers.stringPath(node: self.currentTrieNode)
    self.currentStringPath = stringPath
    if let currentStringPath {
      reducer[keyPath: currentStringPath] = ""
      chunkState.valueStringBuffer = ""
    }
    self.mode = .string
    self.stringState.startString(delimiter: .asciiQuote)
  }

  private mutating func parseString(byte: UInt8, into reducer: inout Value, chunkState: inout ByteChunkParseState) throws {
    if self.stringState.unicodeEscapeRemaining > 0 {
      guard let hexValue = byte.hexValue else {
        throw YAMLStreamParsingError(
          reason: .invalidUnicodeEscape,
          position: self.position,
          context: .string
        )
      }
      self.stringState.unicodeEscapeValue = (self.stringState.unicodeEscapeValue << 4) | UInt32(hexValue)
      self.stringState.unicodeEscapeRemaining -= 1
      if self.stringState.unicodeEscapeRemaining == 0 {
        guard let scalar = Unicode.Scalar(self.stringState.unicodeEscapeValue) else {
          throw YAMLStreamParsingError(
            reason: .invalidUnicodeEscape,
            position: self.position,
            context: .string
          )
        }
        if self.currentStringPath != nil {
          var valueStringBuffer = self.ensureValueStringBuffer(in: reducer, chunkState: &chunkState)
          valueStringBuffer.unicodeScalars.append(scalar)
          chunkState.valueStringBuffer = valueStringBuffer
        }
        self.stringState.unicodeEscapeValue = 0
      }
      return
    }

    guard self.currentStringPath != nil else {
      switch byte {
      case .asciiBackslash:
        if self.stringState.isEscaping {
          self.stringState.isEscaping = false
        } else {
          self.stringState.isEscaping = true
        }
      case self.stringState.stringDelimiter:
        if self.stringState.isEscaping {
          self.stringState.isEscaping = false
        } else {
          self.mode = .neutral
        }
      default:
        if self.stringState.isEscaping {
          if byte == 0x75 {
            self.stringState.beginUnicodeEscape()
            return
          }
          self.stringState.isEscaping = false
        }
        switch self.stringState.utf8State.consume(byte: byte) {
        case .consume: break
        case .doNothing: break
        }
      }
      return
    }

    switch byte {
    case .asciiBackslash:
      if self.stringState.isEscaping {
        var valueStringBuffer = self.ensureValueStringBuffer(in: reducer, chunkState: &chunkState)
        valueStringBuffer.append("\\")
        chunkState.valueStringBuffer = valueStringBuffer
        self.stringState.isEscaping = false
      } else {
        self.stringState.isEscaping = true
      }
    case self.stringState.stringDelimiter:
      if self.stringState.isEscaping {
        var valueStringBuffer = self.ensureValueStringBuffer(in: reducer, chunkState: &chunkState)
        valueStringBuffer.unicodeScalars.append(Unicode.Scalar(byte))
        chunkState.valueStringBuffer = valueStringBuffer
        self.stringState.isEscaping = false
      } else {
        try self.flushByteChunkParseState(&chunkState, into: &reducer)
        self.mode = .neutral
      }
    default:
      if self.stringState.isEscaping {
        if byte == 0x75 {
          self.stringState.beginUnicodeEscape()
          return
        }
      }
      switch self.stringState.utf8State.consume(byte: byte) {
      case .consume(let scalar):
        var valueStringBuffer = self.ensureValueStringBuffer(in: reducer, chunkState: &chunkState)
        if self.stringState.isEscaping {
          self.stringState.appendEscapedCharacter(for: byte, into: &valueStringBuffer)
        } else {
          valueStringBuffer.unicodeScalars.append(scalar)
        }
        chunkState.valueStringBuffer = valueStringBuffer
      case .doNothing: break
      }
    }
  }

  private mutating func flushByteChunkParseState(_ chunkState: inout ByteChunkParseState, into reducer: inout Value) throws {
    if let valueStringBuffer = chunkState.valueStringBuffer, let currentStringPath {
      reducer[keyPath: currentStringPath] = valueStringBuffer
      chunkState.valueStringBuffer = nil
    }
    if let valueNumberAccumulator = chunkState.valueNumberAccumulator, let currentNumberPath {
      reducer[keyPath: currentNumberPath] = valueNumberAccumulator
      chunkState.valueNumberAccumulator = nil
    }
  }

  private func ensureValueStringBuffer(in reducer: Value, chunkState: inout ByteChunkParseState) -> String {
    if let valueStringBuffer = chunkState.valueStringBuffer {
      return valueStringBuffer
    }
    guard let currentStringPath else { return "" }
    let valueStringBuffer = reducer[keyPath: currentStringPath]
    chunkState.valueStringBuffer = valueStringBuffer
    return valueStringBuffer
  }

  private func digitValue(for byte: UInt8) -> UInt8? {
    switch byte {
    case 0x30...0x39: byte &- 0x30
    default: nil
    }
  }

  private mutating func parseInteger(byte: UInt8, into reducer: inout Value, chunkState: inout ByteChunkParseState) throws {
    if byte == .asciiDot {
      self.mode = .fractionalDouble
      self.numberParsingState.state.hasDot = true
      try self.numberParsingState.appendDigit(byte, position: self.position)
      try self.writeCurrentNumberAccumulator(in: reducer, chunkState: &chunkState, isHex: false, position: self.position)
    } else if byte == .asciiLowerE || byte == .asciiUpperE {
      self.mode = .exponentialDouble
      guard self.numberParsingState.state.hasDigits else {
        throw YAMLStreamParsingError(reason: .invalidNumber, position: self.position, context: .number)
      }
      self.numberParsingState.state.hasExponent = true
      self.numberParsingState.state.hasExponentDigits = false
      try self.numberParsingState.appendDigit(byte, position: self.position)
    } else if let digit = self.digitValue(for: byte) {
      if !self.numberParsingState.state.hasDigits {
        self.numberParsingState.state.hasDigits = true
        if digit == 0 {
          self.numberParsingState.state.hasLeadingZero = true
        }
      }
      self.numberParsingState.state.digitCount += 1
      try self.numberParsingState.appendDigit(byte, position: self.position)
      try self.writeCurrentNumberAccumulator(in: reducer, chunkState: &chunkState, isHex: false, position: self.position)
    } else {
      try self.finalizeNumberOrThrow(at: self.position, into: &reducer, chunkState: &chunkState)
      try self.parseNeutral(byte: byte, into: &reducer, chunkState: &chunkState)
    }
  }

  private mutating func parseFractionalDouble(byte: UInt8, into reducer: inout Value, chunkState: inout ByteChunkParseState) throws {
    guard self.digitValue(for: byte) != nil else {
      if byte == .asciiLowerE || byte == .asciiUpperE {
        guard self.numberParsingState.state.hasFractionDigits else {
          throw YAMLStreamParsingError(reason: .invalidNumber, position: self.position, context: .number)
        }
        self.mode = .exponentialDouble
        self.numberParsingState.state.hasExponent = true
        self.numberParsingState.state.hasExponentDigits = false
        try self.numberParsingState.appendDigit(byte, position: self.position)
        return
      }
      try self.finalizeNumberOrThrow(at: self.position, into: &reducer, chunkState: &chunkState)
      return try self.parseNeutral(byte: byte, into: &reducer, chunkState: &chunkState)
    }
    if !self.numberParsingState.state.hasDigits {
      self.numberParsingState.state.hasDigits = true
    }
    self.numberParsingState.state.hasFractionDigits = true
    try self.numberParsingState.appendDigit(byte, position: self.position)
    try self.writeCurrentNumberAccumulator(in: reducer, chunkState: &chunkState, isHex: false, position: self.position)
  }

  private mutating func parseExponentialDouble(byte: UInt8, into reducer: inout Value, chunkState: inout ByteChunkParseState) throws {
    if byte == .asciiDash {
      if self.numberParsingState.state.hasExponentDigits {
        throw YAMLStreamParsingError(reason: .invalidExponent, position: self.position, context: .number)
      }
      self.numberParsingState.isNegativeExponent = true
      try self.numberParsingState.appendDigit(byte, position: self.position)
    } else if byte == .asciiPlus {
      if self.numberParsingState.state.hasExponentDigits {
        throw YAMLStreamParsingError(reason: .invalidExponent, position: self.position, context: .number)
      }
      try self.numberParsingState.appendDigit(byte, position: self.position)
      return
    } else if let digit = self.digitValue(for: byte) {
      self.numberParsingState.state.hasExponentDigits = true
      let newExponent = self.numberParsingState.exponent * 10 + Int(digit)
      if newExponent > 999 {
        throw YAMLStreamParsingError(reason: .numericOverflow, position: self.position, context: .number)
      }
      self.numberParsingState.exponent = newExponent
      try self.numberParsingState.appendDigit(byte, position: self.position)
    } else {
      try self.finalizeNumberOrThrow(at: self.position, into: &reducer, chunkState: &chunkState)
      try self.parseNeutral(byte: byte, into: &reducer, chunkState: &chunkState)
    }
  }

  private mutating func parseLiteral(byte: UInt8, into reducer: inout Value) throws {
    guard self.literalState.index < self.literalState.expected.count else {
      self.mode = .neutral
      var chunkState = ByteChunkParseState()
      return try self.parseNeutral(byte: byte, into: &reducer, chunkState: &chunkState)
    }
    if byte != self.literalState.expected[self.literalState.index] {
      throw YAMLStreamParsingError(reason: .invalidLiteral, position: self.position, context: .literal)
    }
    self.literalState.index += 1
    if self.literalState.index == self.literalState.expected.count {
      self.mode = .neutral
    }
  }

  private mutating func parseComment(byte: UInt8) {
    if byte == 0x0A {
      self.mode = .neutral
    }
  }

  private mutating func parseArrayValue(byte: UInt8, into reducer: inout Value, chunkState: inout ByteChunkParseState) throws {
    switch byte {
    case .asciiQuote:
      try self.handleNeutralDoubleQuotedStringStart(into: &reducer, chunkState: &chunkState)
    case .asciiComma:
      try self.flushByteChunkParseState(&chunkState, into: &reducer)
      self.prepareForNextArrayElement()
    case .asciiArrayEnd:
      try self.flushByteChunkParseState(&chunkState, into: &reducer)
      try self.handleNeutralArrayEnd(into: &reducer)
    case .asciiArrayStart:
      try self.handleNeutralArrayStart(into: &reducer)
    case 0x30...0x39:
      try self.handleNeutralDigitStart(byte, into: &reducer, chunkState: &chunkState)
    case .asciiDash:
      self.lineStartDashIndent = self.currentLineIndent
      self.mode = .lineStartDash
    case .asciiLowerT, .asciiLowerF:
      try self.handleNeutralLiteralStart(byte, into: &reducer)
    case .asciiLowerN:
      try self.handleNeutralNullStart(byte, into: &reducer)
    default:
      break
    }
  }

  private mutating func writeCurrentNumberAccumulator(in reducer: Value, chunkState: inout ByteChunkParseState, isHex: Bool, position: YAMLStreamParsingPosition) throws {
    let accumulator = self.ensureValueNumberAccumulator(in: reducer, chunkState: &chunkState)
    guard var accumulator else { return }
    let didParse = accumulator.parseDigits(buffer: self.numberParsingState.digitBuffer, isHex: isHex)
    guard didParse else {
      throw YAMLStreamParsingError(reason: .numericOverflow, position: position, context: .number)
    }
    chunkState.valueNumberAccumulator = accumulator
  }

  private func ensureValueNumberAccumulator(in reducer: Value, chunkState: inout ByteChunkParseState) -> JSONNumberAccumulator? {
    if let accumulator = chunkState.valueNumberAccumulator {
      return accumulator
    }
    guard let currentNumberPath else { return nil }
    let accumulator = reducer[keyPath: currentNumberPath]
    chunkState.valueNumberAccumulator = accumulator
    return accumulator
  }

  private mutating func finalizeNumberOrThrow(at position: YAMLStreamParsingPosition, into reducer: inout Value, chunkState: inout ByteChunkParseState) throws {
    guard self.numberParsingState.state.hasDigits else {
      throw YAMLStreamParsingError(reason: .invalidNumber, position: position, context: .number)
    }
    try self.writeCurrentNumberAccumulator(in: reducer, chunkState: &chunkState, isHex: false, position: position)
    try self.flushByteChunkParseState(&chunkState, into: &reducer)
    self.mode = .neutral
    self.numberParsingState.resetAfterFinalize()
  }

  private mutating func advancePosition(for byte: UInt8) {
    if byte == 0x0A {
      self.position.line += 1
      self.position.column = 1
      self.isAtLineStart = true
      self.currentLineIndent = 0
      self.lineStartDashIndent = nil
    } else {
      self.position.column += 1
    }
  }
}

// MARK: - Handlers

extension YAMLStreamParser {
  public struct Handlers: StreamParserHandlers {
    fileprivate var pathTrie: PathTrie<Value>
    private let configuration: YAMLStreamParserConfiguration

    init(configuration: YAMLStreamParserConfiguration) {
      self.configuration = configuration
      self.pathTrie = PathTrie()
    }

    fileprivate var hasAnyHandler: Bool {
      self.pathTrie.paths.hasAnyHandler
    }

    fileprivate func numberPath(node: PathTrie<Value>?) -> (WritableKeyPath<Value, JSONNumberAccumulator>?, Bool) {
      guard let node else { return (nil, false) }
      let path = node.paths.number
      let isInvalidType = path == nil && node.paths.hasAnyHandler
      return (path, isInvalidType)
    }

    fileprivate func stringPath(node: PathTrie<Value>?) -> (WritableKeyPath<Value, String>?, Bool) {
      guard let node else { return (nil, false) }
      let path = node.paths.string
      let isInvalidType = path == nil && node.paths.hasAnyHandler
      return (path, isInvalidType)
    }

    fileprivate func booleanPath(node: PathTrie<Value>?) -> (WritableKeyPath<Value, Bool>?, Bool) {
      guard let node else { return (nil, false) }
      let path = node.paths.bool
      let isInvalidType = path == nil && node.paths.hasAnyHandler
      return (path, isInvalidType)
    }

    fileprivate func nullablePath(node: PathTrie<Value>?) -> (WritableKeyPath<Value, Void?>?, Bool) {
      guard let node else { return (nil, false) }
      let path = node.paths.nullable
      let isInvalidType = path == nil && node.paths.hasAnyHandler
      return (path, isInvalidType)
    }

    fileprivate func arrayPath(node: PathTrie<Value>?) -> (WritableKeyPath<Value, any StreamParseableArrayObject>?, Bool) {
      guard let node else { return (nil, false) }
      let path = node.paths.array
      let isInvalidType = path == nil && node.paths.hasAnyHandler
      return (path, isInvalidType)
    }

    fileprivate func dictionaryPath(node: PathTrie<Value>?) -> (WritableKeyPath<Value, any StreamParseableDictionaryObject>?, Bool) {
      guard let node else { return (nil, false) }
      let path = node.paths.dictionary
      let isInvalidType = path == nil && node.paths.hasAnyHandler && !node.expectsObject
      return (path, isInvalidType)
    }

    public mutating func registerStringHandler(_ keyPath: WritableKeyPath<Value, String>) {
      self.pathTrie.paths.string = keyPath
    }

    public mutating func registerBoolHandler(_ keyPath: WritableKeyPath<Value, Bool>) {
      self.pathTrie.paths.bool = keyPath
    }

    public mutating func registerIntHandler(_ keyPath: WritableKeyPath<Value, Int>) {
      self.pathTrie.paths.number = keyPath.appending(path: \.erasedAccumulator)
    }

    public mutating func registerInt8Handler(_ keyPath: WritableKeyPath<Value, Int8>) {
      self.pathTrie.paths.number = keyPath.appending(path: \.erasedAccumulator)
    }

    public mutating func registerInt16Handler(_ keyPath: WritableKeyPath<Value, Int16>) {
      self.pathTrie.paths.number = keyPath.appending(path: \.erasedAccumulator)
    }

    public mutating func registerInt32Handler(_ keyPath: WritableKeyPath<Value, Int32>) {
      self.pathTrie.paths.number = keyPath.appending(path: \.erasedAccumulator)
    }

    public mutating func registerInt64Handler(_ keyPath: WritableKeyPath<Value, Int64>) {
      self.pathTrie.paths.number = keyPath.appending(path: \.erasedAccumulator)
    }

    public mutating func registerUIntHandler(_ keyPath: WritableKeyPath<Value, UInt>) {
      self.pathTrie.paths.number = keyPath.appending(path: \.erasedAccumulator)
    }

    public mutating func registerUInt8Handler(_ keyPath: WritableKeyPath<Value, UInt8>) {
      self.pathTrie.paths.number = keyPath.appending(path: \.erasedAccumulator)
    }

    public mutating func registerUInt16Handler(_ keyPath: WritableKeyPath<Value, UInt16>) {
      self.pathTrie.paths.number = keyPath.appending(path: \.erasedAccumulator)
    }

    public mutating func registerUInt32Handler(_ keyPath: WritableKeyPath<Value, UInt32>) {
      self.pathTrie.paths.number = keyPath.appending(path: \.erasedAccumulator)
    }

    public mutating func registerUInt64Handler(_ keyPath: WritableKeyPath<Value, UInt64>) {
      self.pathTrie.paths.number = keyPath.appending(path: \.erasedAccumulator)
    }

    @available(StreamParsing128BitIntegers, *)
    public mutating func registerInt128Handler(_ keyPath: WritableKeyPath<Value, Int128>) {
      self.pathTrie.paths.number = keyPath.appending(path: \.erasedAccumulator)
    }

    @available(StreamParsing128BitIntegers, *)
    public mutating func registerUInt128Handler(_ keyPath: WritableKeyPath<Value, UInt128>) {
      self.pathTrie.paths.number = keyPath.appending(path: \.erasedAccumulator)
    }

    public mutating func registerFloatHandler(_ keyPath: WritableKeyPath<Value, Float>) {
      self.pathTrie.paths.number = keyPath.appending(path: \.erasedAccumulator)
    }

    public mutating func registerDoubleHandler(_ keyPath: WritableKeyPath<Value, Double>) {
      self.pathTrie.paths.number = keyPath.appending(path: \.erasedAccumulator)
    }

    public mutating func registerNilHandler<Nullable: StreamParseableValue>(
      _ keyPath: WritableKeyPath<Value, Nullable?>
    ) {
      self.pathTrie.paths.nullable = keyPath.appending(path: \.nullablePath)
    }

    public mutating func registerKeyedHandler<Keyed: StreamParseableValue>(
      forKey key: String,
      _ keyPath: WritableKeyPath<Value, Keyed>
    ) {
      var keyedHandlers = YAMLStreamParser<Keyed>.Handlers(configuration: self.configuration)
      Keyed.registerHandlers(in: &keyedHandlers)

      let decodedKey = self.configuration.keyDecodingStrategy.decode(key: key)

      let keyNode = self.pathTrie.ensureObjectChild(for: decodedKey)
      let prefixedTrie = keyedHandlers.pathTrie.prefixed(by: keyPath)
      keyNode.merge(from: prefixedTrie)
    }

    public mutating func registerScopedHandlers<Scoped: StreamParseableValue>(
      on type: Scoped.Type,
      _ keyPath: WritableKeyPath<Value, Scoped>
    ) {
      var handlers = YAMLStreamParser<Scoped>.Handlers(configuration: self.configuration)
      type.registerHandlers(in: &handlers)
      let prefixedTrie = handlers.pathTrie.prefixed(by: keyPath)
      self.pathTrie.merge(from: prefixedTrie)
    }

    public mutating func registerArrayHandler<ArrayObject: StreamParseableArrayObject>(
      _ keyPath: WritableKeyPath<Value, ArrayObject>
    ) {
      self.pathTrie.paths.array = keyPath.appending(path: \.erasedJSONPath)

      var elementHandlers = YAMLStreamParser<ArrayObject.Element>.Handlers(configuration: self.configuration)
      ArrayObject.Element.registerHandlers(in: &elementHandlers)

      let arrayNode = self.pathTrie.ensureArrayChild()
      let elementPrefix = keyPath.appending(path: \.currentElement)
      let prefixedTrie = elementHandlers.pathTrie.prefixed(by: elementPrefix)
      arrayNode.merge(from: prefixedTrie)
    }

    public mutating func registerDictionaryHandler<DictionaryObject: StreamParseableDictionaryObject>(
      _ keyPath: WritableKeyPath<Value, DictionaryObject>
    ) {
      self.pathTrie.paths.dictionary = keyPath.appending(path: \.erasedJSONPath)

      var valueHandlers = YAMLStreamParser<DictionaryObject.Value>.Handlers(configuration: self.configuration)
      DictionaryObject.Value.registerHandlers(in: &valueHandlers)

      let anyNode = self.pathTrie.ensureAnyObjectChild()
      anyNode.dynamicKeyBuilder = { key in
        let valuePrefix = keyPath.appending(path: \.[unwrapped: key])
        return valueHandlers.pathTrie.prefixed(by: valuePrefix)
      }
    }
  }
}

// MARK: - PathTrie

private final class PathTrie<Value: StreamParseableValue> {
  struct Paths {
    var string: WritableKeyPath<Value, String>?
    var bool: WritableKeyPath<Value, Bool>?
    var number: WritableKeyPath<Value, JSONNumberAccumulator>?
    var nullable: WritableKeyPath<Value, Void?>?
    var array: WritableKeyPath<Value, any StreamParseableArrayObject>?
    var dictionary: WritableKeyPath<Value, any StreamParseableDictionaryObject>?

    var hasAnyHandler: Bool {
      self.string != nil
        || self.bool != nil
        || self.number != nil
        || self.nullable != nil
        || self.array != nil
        || self.dictionary != nil
    }

    mutating func merge(from other: Paths) {
      if self.string == nil {
        self.string = other.string
      }
      if self.bool == nil {
        self.bool = other.bool
      }
      if self.number == nil {
        self.number = other.number
      }
      if self.nullable == nil {
        self.nullable = other.nullable
      }
      if self.array == nil {
        self.array = other.array
      }
      if self.dictionary == nil {
        self.dictionary = other.dictionary
      }
    }
  }

  var paths = Paths()
  var children: Children = .none

  enum Children {
    case none
    case array(PathTrie)
    case object(keys: [String: PathTrie], any: PathTrie?)
  }

  var dynamicKeyBuilder: ((String) -> PathTrie<Value>)?
  private var dynamicKeyCache: [String: PathTrie<Value>] = [:]

  init(paths: Paths = Paths(), children: Children = .none) {
    self.paths = paths
    self.children = children
  }

  var expectsObject: Bool {
    if case .object = self.children { return true }
    return false
  }

  var hasAnyHandler: Bool {
    self.paths.hasAnyHandler || self.hasChildren
  }

  private var hasChildren: Bool {
    switch self.children {
    case .none: false
    case .array, .object: true
    }
  }

  func objectChildNode(for key: String) -> PathTrie<Value>? {
    guard case .object(let keys, let any) = self.children else { return nil }
    if let child = keys[key] {
      return child
    }
    guard let any else { return nil }
    return any.nodeForDynamicKey(key)
  }

  private func nodeForDynamicKey(_ key: String) -> PathTrie<Value> {
    if let cached = self.dynamicKeyCache[key] {
      return cached
    }
    guard let builder = self.dynamicKeyBuilder else { return self }
    let node = builder(key)
    self.dynamicKeyCache[key] = node
    return node
  }

  @discardableResult
  func ensureArrayChild() -> PathTrie<Value> {
    if case .array(let child) = self.children { return child }
    let child = PathTrie<Value>()
    self.children = .array(child)
    return child
  }

  @discardableResult
  func ensureObjectChild(for key: String) -> PathTrie<Value> {
    if case .object(var keys, let any) = self.children {
      if let child = keys[key] { return child }
      let child = PathTrie<Value>()
      keys[key] = child
      self.children = .object(keys: keys, any: any)
      return child
    }
    let child = PathTrie<Value>()
    self.children = .object(keys: [key: child], any: nil)
    return child
  }

  @discardableResult
  func ensureAnyObjectChild() -> PathTrie<Value> {
    if case .object(let keys, let any) = self.children {
      if let any { return any }
      let child = PathTrie<Value>()
      self.children = .object(keys: keys, any: child)
      return child
    }
    let child = PathTrie<Value>()
    self.children = .object(keys: [:], any: child)
    return child
  }

  func prefixed<Root: StreamParseableValue>(
    by prefix: WritableKeyPath<Root, Value>
  ) -> PathTrie<Root> {
    var prefixedPaths = PathTrie<Root>.Paths()
    prefixedPaths.string = self.paths.string.map { prefix.appending(path: $0) }
    prefixedPaths.bool = self.paths.bool.map { prefix.appending(path: $0) }
    prefixedPaths.number = self.paths.number.map { prefix.appending(path: $0) }
    prefixedPaths.nullable = self.paths.nullable.map { prefix.appending(path: $0) }
    prefixedPaths.array = self.paths.array.map { prefix.appending(path: $0) }
    prefixedPaths.dictionary = self.paths.dictionary.map { prefix.appending(path: $0) }
    let node = PathTrie<Root>(paths: prefixedPaths)
    switch self.children {
    case .none: break
    case .array(let child):
      node.children = .array(child.prefixed(by: prefix))
    case .object(let keys, let any):
      var prefixedKeys = [String: PathTrie<Root>]()
      prefixedKeys.reserveCapacity(keys.count)
      for (key, child) in keys {
        prefixedKeys[key] = child.prefixed(by: prefix)
      }
      let prefixedAny = any.map { $0.prefixed(by: prefix) }
      node.children = .object(keys: prefixedKeys, any: prefixedAny)
    }
    if let builder = self.dynamicKeyBuilder {
      node.dynamicKeyBuilder = { key in
        builder(key).prefixed(by: prefix)
      }
    }
    return node
  }

  func merge(from other: PathTrie<Value>) {
    self.paths.merge(from: other.paths)
    switch other.children {
    case .none: break
    case .array(let otherChild):
      let child = self.ensureArrayChild()
      child.merge(from: otherChild)
    case .object(let keys, let any):
      for (key, otherChild) in keys {
        let child = self.ensureObjectChild(for: key)
        child.merge(from: otherChild)
      }
      if let otherAny = any {
        let anyChild = self.ensureAnyObjectChild()
        anyChild.merge(from: otherAny)
        if anyChild.dynamicKeyBuilder == nil {
          anyChild.dynamicKeyBuilder = otherAny.dynamicKeyBuilder
        }
      }
    }
    if self.dynamicKeyBuilder == nil {
      self.dynamicKeyBuilder = other.dynamicKeyBuilder
    }
  }
}

// MARK: - Configuration

public struct YAMLStreamParserConfiguration: Sendable {
  public var syntaxOptions: SyntaxOptions
  public var keyDecodingStrategy: YAMLKeyDecodingStrategy

  public init(
    syntaxOptions: SyntaxOptions = [],
    keyDecodingStrategy: YAMLKeyDecodingStrategy = .useDefault
  ) {
    self.syntaxOptions = syntaxOptions
    self.keyDecodingStrategy = keyDecodingStrategy
  }

  public struct SyntaxOptions: OptionSet, Sendable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
      self.rawValue = rawValue
    }

    public static let comments = SyntaxOptions(rawValue: 1 << 0)
  }
}

// MARK: - YAMLKeyDecodingStrategy

public enum YAMLKeyDecodingStrategy: Sendable {
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

// MARK: - YAMLStreamParsingError

public struct YAMLStreamParsingPosition: Hashable, Sendable {
  public var line: Int
  public var column: Int

  public init(line: Int, column: Int) {
    self.line = line
    self.column = column
  }
}

public struct YAMLStreamParsingError: Error, Hashable, Sendable {
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
    case numericOverflow
    case leadingZero
    case invalidExponent
    case missingClosingBrace
    case missingClosingBracket
    case invalidType
    case invalidMultiLineString
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
  public var position: YAMLStreamParsingPosition
  public var context: Context?

  public init(
    reason: Reason,
    position: YAMLStreamParsingPosition,
    context: Context? = nil
  ) {
    self.reason = reason
    self.position = position
    self.context = context
  }
}

// MARK: - StreamParser

extension StreamParser {
  public static func yaml<Reducer>(
    configuration: YAMLStreamParserConfiguration = YAMLStreamParserConfiguration()
  ) -> Self where Self == YAMLStreamParser<Reducer> {
    YAMLStreamParser(configuration: configuration)
  }
}

// MARK: - Supporting Types

extension YAMLStreamParser {
  private struct KeyParsingState {
    var buffer = ""
    var delimiter: UInt8 = .asciiQuote
    var isQuoted = false
    var isEscaping = false
    var isAwaitingColon = false
    var utf8State = UTF8State()

    mutating func startQuoted() {
      self.reset()
      self.isQuoted = true
      self.delimiter = .asciiQuote
    }

    mutating func startPlain(initial: UInt8) {
      self.reset()
      self.buffer.unicodeScalars.append(Unicode.Scalar(initial))
    }

    mutating func reset() {
      self.buffer = ""
      self.delimiter = .asciiQuote
      self.isQuoted = false
      self.isEscaping = false
      self.isAwaitingColon = false
      self.utf8State = UTF8State()
    }
  }

  private struct StringParsingState {
    var isEscaping = false
    var utf8State = UTF8State()
    var stringDelimiter: UInt8 = .asciiQuote
    var unicodeEscapeRemaining = 0
    var unicodeEscapeValue: UInt32 = 0

    mutating func startString(delimiter: UInt8) {
      self.stringDelimiter = delimiter
      self.resetEscapeState()
    }

    mutating func beginUnicodeEscape() {
      self.unicodeEscapeRemaining = 4
      self.unicodeEscapeValue = 0
      self.isEscaping = false
    }

    mutating func appendEscapedCharacter(for byte: UInt8, into string: inout String) {
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

    private mutating func resetEscapeState() {
      self.isEscaping = false
      self.utf8State = UTF8State()
      self.unicodeEscapeRemaining = 0
      self.unicodeEscapeValue = 0
    }
  }

  private struct ByteChunkParseState {
    var valueStringBuffer: String?
    var valueNumberAccumulator: JSONNumberAccumulator?
  }
}

// MARK: - UInt8+HexValue

extension UInt8 {
  fileprivate var hexValue: UInt8? {
    switch self {
    case 0x30...0x39: self &- 0x30
    case 0x41...0x46: self &- 0x41 &+ 10
    case 0x61...0x66: self &- 0x61 &+ 10
    default: nil
    }
  }
}

// MARK: - JSONNumberAccumulator stub for compilation

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

  mutating func parseDigits(buffer: DigitBuffer, isHex: Bool) -> Bool {
    switch self {
    case .int:
      guard let value: Int = parseInteger(buffer: buffer, isHex: isHex, as: Int.self) else {
        return false
      }
      self = .int(value)
    case .int8:
      guard let value: Int8 = parseInteger(buffer: buffer, isHex: isHex, as: Int8.self) else {
        return false
      }
      self = .int8(value)
    case .int16:
      guard let value: Int16 = parseInteger(buffer: buffer, isHex: isHex, as: Int16.self) else {
        return false
      }
      self = .int16(value)
    case .int32:
      guard let value: Int32 = parseInteger(buffer: buffer, isHex: isHex, as: Int32.self) else {
        return false
      }
      self = .int32(value)
    case .int64:
      guard let value: Int64 = parseInteger(buffer: buffer, isHex: isHex, as: Int64.self) else {
        return false
      }
      self = .int64(value)
    case .int128:
      guard #available(StreamParsing128BitIntegers, *) else { return true }
      guard let value = parseInt128(buffer: buffer, isHex: isHex) else { return false }
      self = .int128(low: value._low, high: value._high)
    case .uint:
      guard let value: UInt = parseInteger(buffer: buffer, isHex: isHex, as: UInt.self) else {
        return false
      }
      self = .uint(value)
    case .uint8:
      guard let value: UInt8 = parseInteger(buffer: buffer, isHex: isHex, as: UInt8.self) else {
        return false
      }
      self = .uint8(value)
    case .uint16:
      guard let value: UInt16 = parseInteger(buffer: buffer, isHex: isHex, as: UInt16.self) else {
        return false
      }
      self = .uint16(value)
    case .uint32:
      guard let value: UInt32 = parseInteger(buffer: buffer, isHex: isHex, as: UInt32.self) else {
        return false
      }
      self = .uint32(value)
    case .uint64:
      guard let value: UInt64 = parseInteger(buffer: buffer, isHex: isHex, as: UInt64.self) else {
        return false
      }
      self = .uint64(value)
    case .uint128:
      guard #available(StreamParsing128BitIntegers, *) else { return true }
      guard let value = parseUInt128(buffer: buffer, isHex: isHex) else { return false }
      self = .uint128(low: value._low, high: value._high)
    case .float:
      guard let value: Float = parseFloatingPoint(buffer: buffer, as: Float.self) else {
        return false
      }
      self = .float(value)
    case .double:
      guard let value: Double = parseFloatingPoint(buffer: buffer, as: Double.self) else {
        return false
      }
      self = .double(value)
    }
    return true
  }
}

// MARK: - StreamParseableValue extensions for arrays/objects

extension StreamParseableValue {
  fileprivate var erasedJSONPath: any StreamParseableValue {
    get { self }
    set { self = newValue as! Self }
  }
}

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

extension StreamParseableArrayObject {
  fileprivate var erasedJSONPath: any StreamParseableArrayObject {
    get { self }
    set { self = newValue as! Self }
  }

  fileprivate var currentElement: Element {
    get {
      let index = self.count - 1
      return self[index]
    }
    set {
      let index = self.count - 1
      self[index] = newValue
    }
  }

  fileprivate mutating func appendNewElement() {
    self.append(contentsOf: CollectionOfOne(.initialParseableValue()))
  }
}

extension Int {
  fileprivate var erasedAccumulator: JSONNumberAccumulator {
    get { .int(self) }
    set {
      guard case .int(let value) = newValue else { return }
      self = value
    }
  }
}

extension Int8 {
  fileprivate var erasedAccumulator: JSONNumberAccumulator {
    get { .int8(self) }
    set {
      guard case .int8(let value) = newValue else { return }
      self = value
    }
  }
}

extension Int16 {
  fileprivate var erasedAccumulator: JSONNumberAccumulator {
    get { .int16(self) }
    set {
      guard case .int16(let value) = newValue else { return }
      self = value
    }
  }
}

extension Int32 {
  fileprivate var erasedAccumulator: JSONNumberAccumulator {
    get { .int32(self) }
    set {
      guard case .int32(let value) = newValue else { return }
      self = value
    }
  }
}

extension Int64 {
  fileprivate var erasedAccumulator: JSONNumberAccumulator {
    get { .int64(self) }
    set {
      guard case .int64(let value) = newValue else { return }
      self = value
    }
  }
}

extension UInt {
  fileprivate var erasedAccumulator: JSONNumberAccumulator {
    get { .uint(self) }
    set {
      guard case .uint(let value) = newValue else { return }
      self = value
    }
  }
}

extension UInt8 {
  fileprivate var erasedAccumulator: JSONNumberAccumulator {
    get { .uint8(self) }
    set {
      guard case .uint8(let value) = newValue else { return }
      self = value
    }
  }
}

extension UInt16 {
  fileprivate var erasedAccumulator: JSONNumberAccumulator {
    get { .uint16(self) }
    set {
      guard case .uint16(let value) = newValue else { return }
      self = value
    }
  }
}

extension UInt32 {
  fileprivate var erasedAccumulator: JSONNumberAccumulator {
    get { .uint32(self) }
    set {
      guard case .uint32(let value) = newValue else { return }
      self = value
    }
  }
}

extension UInt64 {
  fileprivate var erasedAccumulator: JSONNumberAccumulator {
    get { .uint64(self) }
    set {
      guard case .uint64(let value) = newValue else { return }
      self = value
    }
  }
}

@available(StreamParsing128BitIntegers, *)
extension Int128 {
  fileprivate var erasedAccumulator: JSONNumberAccumulator {
    get { .int128(low: self._low, high: self._high) }
    set {
      guard case .int128(let low, let high) = newValue else { return }
      self = Int128(_low: low, _high: high)
    }
  }
}

@available(StreamParsing128BitIntegers, *)
extension UInt128 {
  fileprivate var erasedAccumulator: JSONNumberAccumulator {
    get { .uint128(low: self._low, high: self._high) }
    set {
      guard case .uint128(let low, let high) = newValue else { return }
      self = UInt128(_low: low, _high: high)
    }
  }
}

extension Float {
  fileprivate var erasedAccumulator: JSONNumberAccumulator {
    get { .float(self) }
    set {
      guard case .float(let value) = newValue else { return }
      self = value
    }
  }
}

extension Double {
  fileprivate var erasedAccumulator: JSONNumberAccumulator {
    get { .double(self) }
    set {
      guard case .double(let value) = newValue else { return }
      self = value
    }
  }
}

extension StreamParseableValue {
  fileprivate mutating func reset() {
    self = .initialParseableValue()
  }
}

// MARK: - NumberParsingState

extension YAMLStreamParser {
  private struct NumberParsingState {
    var isNegative = false
    var isNegativeExponent = false
    var exponent = 0
    var state = NumberState()
    var digitBuffer: DigitBuffer = DigitBuffer()

    mutating func resetForInteger(isNegative: Bool) {
      self.isNegative = isNegative
      self.isNegativeExponent = false
      self.exponent = 0
      self.digitBuffer.count = 0
      self.state.reset()
    }

    mutating func resetForFractionalLeadingDot(position: YAMLStreamParsingPosition) throws {
      self.resetForInteger(isNegative: false)
      self.state.hasDot = true
      try self.appendDigit(.asciiZero, position: position)
      try self.appendDigit(.asciiDot, position: position)
    }

    mutating func appendDigit(_ byte: UInt8, position: YAMLStreamParsingPosition) throws {
      let index = self.digitBuffer.count
      guard index < 64 else {
        throw YAMLStreamParsingError(
          reason: .numericOverflow,
          position: position,
          context: .number
        )
      }
      withUnsafeMutableBytes(of: &self.digitBuffer.storage) { ptr in
        ptr.storeBytes(of: byte, toByteOffset: index, as: UInt8.self)
      }
      self.digitBuffer.count += 1
    }

    mutating func resetAfterFinalize() {
      self.exponent = 0
      self.isNegativeExponent = false
      self.digitBuffer.count = 0
      self.state.reset()
    }
  }

  private struct NumberState {
    var hasDigits = false
    var hasLeadingZero = false
    var hasFractionDigits = false
    var hasExponent = false
    var hasExponentDigits = false
    var hasDot = false
    var isHex = false
    var digitCount = 0

    mutating func reset() {
      self.hasDigits = false
      self.hasLeadingZero = false
      self.hasFractionDigits = false
      self.hasExponent = false
      self.hasExponentDigits = false
      self.hasDot = false
      self.isHex = false
      self.digitCount = 0
    }
  }
}

// MARK: - LiteralState

extension YAMLStreamParser {
  private struct LiteralState {
    var expected = [UInt8]()
    var index = 0
  }

  private mutating func startLiteral(expected: [UInt8]) {
    self.literalState.expected = expected
    self.literalState.index = 1
    self.mode = .literal
  }
}

// MARK: - YAML Literals

private let yamlLiteralTrue: [UInt8] = Array("true".utf8)
private let yamlLiteralFalse: [UInt8] = Array("false".utf8)
private let yamlLiteralNull: [UInt8] = Array("null".utf8)
private let yamlLiteralInfinity: [UInt8] = Array("Infinity".utf8)
private let yamlLiteralNaN: [UInt8] = Array("NaN".utf8)
