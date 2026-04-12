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
    case blockScalarHeader
    case blockScalar
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
    var sawTrailingComma = false
  }

  private struct ObjectContext {
    let path: WritableKeyPath<Value, any StreamParseableDictionaryObject>?
    let style: ObjectStyle
    var isExpectingKey = true
    var hasActiveKey = false
    var hasStartedValueForActiveKey = false
    var sawTrailingComma = false
  }

  private enum BlockScalarKind {
    case literal
    case folded
  }

  public let configuration: YAMLStreamParserConfiguration

  private var handlers: Handlers
  private var mode = Mode.neutral
  private var stringState = StringParsingState()
  private var numberParsingState = NumberParsingState()
  private var position = YAMLStreamParsingPosition(line: 1, column: 1)
  private var currentStringPath: WritableKeyPath<Value, String>?
  private var currentNumberPath: WritableKeyPath<Value, NumberAccumulator>?
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
  private var blockScalarState = BlockScalarState()

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
    chunkState.flush(into: &reducer, stringPath: self.currentStringPath, numberPath: self.currentNumberPath)
  }

  public mutating func finish(reducer: inout Value) throws {
    if self.mode == .blockScalarHeader {
      throw YAMLStreamParsingError(
        reason: .invalidMultiLineString,
        position: self.position,
        context: .string
      )
    }
    if self.mode == .blockScalar {
      var chunkState = ByteChunkParseState()
      try self.finishBlockScalar(into: &reducer, chunkState: &chunkState)
    }
    if self.mode == .string {
      throw YAMLStreamParsingError(
        reason: .unterminatedString,
        position: self.position,
        context: .string
      )
    }
    if self.mode == .literal {
      throw YAMLStreamParsingError(
        reason: .invalidLiteral,
        position: self.position,
        context: .literal
      )
    }
    if self.mode == .keyCollecting {
      throw YAMLStreamParsingError(
        reason: .missingColon,
        position: self.position,
        context: .objectKey
      )
    }
    if self.mode.isNumeric {
      if self.numberParsingState.state.hasExponent
        && !self.numberParsingState.state.hasExponentDigits
      {
        throw YAMLStreamParsingError(
          reason: .invalidExponent,
          position: self.position,
          context: .number
        )
      }
      if self.numberParsingState.state.hasDot && !self.numberParsingState.state.hasFractionDigits {
        throw YAMLStreamParsingError(
          reason: .invalidNumber,
          position: self.position,
          context: .number
        )
      }
      var chunkState = ByteChunkParseState()
      try self.finalizeNumberOrThrow(at: self.position, into: &reducer, chunkState: &chunkState)
    }
    try self.prepareBlockContextsForIndent(0)
    self.closeBlockArrayContexts(toIndent: 0)
    if case .flow = self.currentArrayContext?.style {
      if self.currentArrayContext?.sawTrailingComma == true {
        throw YAMLStreamParsingError(
          reason: .trailingComma,
          position: self.position,
          context: .arrayValue
        )
      }
      throw YAMLStreamParsingError(
        reason: .missingClosingBracket,
        position: self.position,
        context: .arrayValue
      )
    }
    if case .flow = self.currentObjectContext?.style {
      if self.currentObjectContext?.sawTrailingComma == true {
        throw YAMLStreamParsingError(
          reason: .trailingComma,
          position: self.position,
          context: .objectValue
        )
      }
      throw YAMLStreamParsingError(
        reason: .missingClosingBrace,
        position: self.position,
        context: .objectValue
      )
    }
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

  private func invalidTypeContext() -> YAMLStreamParsingError.Context? {
    if self.currentArrayContext != nil {
      return .arrayValue
    }
    if self.currentObjectContext?.hasActiveKey == true {
      return .objectValue
    }
    return .neutral
  }

  private func throwInvalidTypeIfNeeded(_ isInvalidType: Bool) throws {
    guard isInvalidType else { return }
    throw YAMLStreamParsingError(
      reason: .invalidType,
      position: self.position,
      context: self.invalidTypeContext()
    )
  }

  private mutating func appendArrayElementIfNeeded(into reducer: inout Value) {
    guard let currentArrayContext, !currentArrayContext.didAppendForCurrentElement else { return }
    if let path = currentArrayContext.path {
      reducer[keyPath: path].appendNewElement()
    }
    self.replaceCurrentArrayContext { $0.didAppendForCurrentElement = true }
  }

  private mutating func prepareForValueStart() throws {
    if case .flow = self.currentArrayContext?.style {
      if self.currentArrayContext?.didAppendForCurrentElement == true {
        throw YAMLStreamParsingError(
          reason: .missingComma,
          position: self.position,
          context: .arrayValue
        )
      }
      self.replaceCurrentArrayContext { $0.sawTrailingComma = false }
    }
    if self.currentObjectContext?.hasActiveKey == true {
      self.replaceCurrentObjectContext {
        $0.sawTrailingComma = false
        $0.hasStartedValueForActiveKey = true
      }
    }
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
      $0.hasStartedValueForActiveKey = false
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
    while case .block(let currentIndent) = self.currentObjectContext?.style, currentIndent > indent
    {
      self.finishCurrentObjectValue()
      _ = self.objectContexts.popLast()
    }
  }

  private mutating func prepareBlockContextsForIndent(_ indent: Int) throws {
    if case .block(let currentIndent) = self.currentObjectContext?.style,
      self.currentObjectContext?.hasActiveKey == true,
      indent <= currentIndent
    {
      if self.currentObjectContext?.hasStartedValueForActiveKey == true {
        self.finishCurrentObjectValue()
      } else {
        throw YAMLStreamParsingError(
          reason: .missingValue,
          position: self.position,
          context: .objectValue
        )
      }
    }
    self.closeBlockArrayContexts(toIndent: indent)
    self.closeBlockObjectContexts(toIndent: indent)
  }

  private mutating func startBlockArrayItem(at indent: Int, into reducer: inout Value) throws {
    if case .block(let currentIndent) = self.currentArrayContext?.style, currentIndent == indent {
      self.prepareForNextArrayElement()
      return
    }

    if self.currentObjectContext?.hasActiveKey == true {
      self.replaceCurrentObjectContext { $0.hasStartedValueForActiveKey = true }
    }
    self.appendArrayElementIfNeeded(into: &reducer)
    let (path, isInvalidType) = self.handlers.arrayPath(node: self.currentTrieNode)
    try self.throwInvalidTypeIfNeeded(isInvalidType)
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

  private mutating func startBlockObjectIfNeeded(at indent: Int, into reducer: inout Value) throws {
    if case .block(let currentIndent) = self.currentObjectContext?.style, currentIndent == indent {
      return
    }
    if self.currentObjectContext?.hasActiveKey == true {
      self.replaceCurrentObjectContext { $0.hasStartedValueForActiveKey = true }
    }
    self.startObject(style: .block(indent: indent), into: &reducer)
  }

  private mutating func activateCurrentObjectKey(_ key: String) {
    let decodedKey = self.configuration.keyDecodingStrategy.decode(key: key)
    self.pushObjectTrieNode(for: decodedKey)
    self.replaceCurrentObjectContext {
      $0.isExpectingKey = false
      $0.hasActiveKey = true
      $0.hasStartedValueForActiveKey = false
    }
  }

  private mutating func parse(
    byte: UInt8,
    into reducer: inout Value,
    chunkState: inout ByteChunkParseState
  ) throws {
    try self.parseCurrentByte(byte: byte, into: &reducer, chunkState: &chunkState)
    self.advancePosition(for: byte)
  }

  private mutating func parseCurrentByte(
    byte: UInt8,
    into reducer: inout Value,
    chunkState: inout ByteChunkParseState
  ) throws {
    if self.mode == .neutral || self.mode == .arrayValue {
      if try self.handleLineStartIfNeeded(byte: byte, into: &reducer) {
        return
      }
    }

    switch self.mode {
    case .neutral: try self.parseNeutral(byte: byte, into: &reducer, chunkState: &chunkState)
    case .string: try self.parseString(byte: byte, into: &reducer, chunkState: &chunkState)
    case .blockScalarHeader: try self.parseBlockScalarHeader(byte: byte)
    case .blockScalar:
      try self.parseBlockScalar(byte: byte, into: &reducer, chunkState: &chunkState)
    case .integer: try self.parseInteger(byte: byte, into: &reducer, chunkState: &chunkState)
    case .fractionalDouble:
      try self.parseFractionalDouble(byte: byte, into: &reducer, chunkState: &chunkState)
    case .exponentialDouble:
      try self.parseExponentialDouble(byte: byte, into: &reducer, chunkState: &chunkState)
    case .literal: try self.parseLiteral(byte: byte, into: &reducer)
    case .keyCollecting: try self.parseKeyCollecting(byte: byte)
    case .comment: self.parseComment(byte: byte)
    case .arrayValue: try self.parseArrayValue(byte: byte, into: &reducer, chunkState: &chunkState)
    case .lineStartDash:
      try self.parseLineStartDash(byte: byte, into: &reducer, chunkState: &chunkState)
    }
  }

  private mutating func handleLineStartIfNeeded(byte: UInt8, into reducer: inout Value) throws
    -> Bool
  {
    guard self.isAtLineStart else { return false }
    switch byte {
    case .asciiSpace:
      self.currentLineIndent += 1
      return true
    case .asciiLineFeed:
      return true
    default:
      try self.prepareBlockContextsForIndent(self.currentLineIndent)
      if self.currentObjectContext == nil,
        self.currentLineIndent == 0,
        self.currentTrieNode?.expectsObject == true,
        byte == .asciiQuote || self.isPlainKeyByte(byte)
      {
        try self.startBlockObjectIfNeeded(at: 0, into: &reducer)
      }
      if self.currentObjectContext == nil,
        self.currentTrieNode?.expectsObject == true,
        byte == .asciiQuote || self.isPlainKeyByte(byte)
      {
        try self.startBlockObjectIfNeeded(at: self.currentLineIndent, into: &reducer)
      } else if case .block(let indent) = self.currentObjectContext?.style,
        self.currentObjectContext?.hasActiveKey == true,
        self.currentLineIndent > indent,
        self.currentTrieNode?.expectsObject == true
      {
        try self.startBlockObjectIfNeeded(at: self.currentLineIndent, into: &reducer)
      }
      self.isAtLineStart = false
      return false
    }
  }

  private mutating func parseNeutral(
    byte: UInt8,
    into reducer: inout Value,
    chunkState: inout ByteChunkParseState
  ) throws {
    if self.currentObjectContext?.isExpectingKey == true {
      switch byte {
      case .asciiObjectEnd:
        if self.currentObjectContext?.sawTrailingComma == true {
          throw YAMLStreamParsingError(
            reason: .trailingComma,
            position: self.position,
            context: .objectValue
          )
        }
        return self.finishCurrentFlowObject()
      case .asciiQuote:
        self.replaceCurrentObjectContext { $0.sawTrailingComma = false }
        self.mode = .keyCollecting
        self.keyParsingState.startQuoted()
        return
      default:
        if self.isPlainKeyByte(byte) {
          self.replaceCurrentObjectContext { $0.sawTrailingComma = false }
          self.mode = .keyCollecting
          self.keyParsingState.startPlain(initial: byte)
          return
        }
      }
    }

    switch byte {
    case .asciiComma:
      if case .flow = self.currentArrayContext?.style {
        chunkState.flush(into: &reducer, stringPath: self.currentStringPath, numberPath: self.currentNumberPath)
        self.prepareForNextArrayElement()
        self.replaceCurrentArrayContext { $0.sawTrailingComma = true }
        self.mode = .arrayValue
      } else if case .flow = self.currentObjectContext?.style {
        chunkState.flush(into: &reducer, stringPath: self.currentStringPath, numberPath: self.currentNumberPath)
        self.finishCurrentObjectValue()
        self.replaceCurrentObjectContext { $0.sawTrailingComma = true }
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
    case .asciiZero ... .asciiNine:
      try self.handleNeutralDigitStart(byte, into: &reducer, chunkState: &chunkState)
    case .asciiDot:
      try self.handleNeutralLeadingDecimalPointStart(into: &reducer, chunkState: &chunkState)
    case .asciiUpperI, .asciiUpperN:
      try self.handleNeutralNonFiniteNumberStart(byte, into: &reducer)
    case .asciiLowerT, .asciiLowerF:
      try self.handleNeutralLiteralStart(byte, into: &reducer)
    case .asciiLowerN:
      try self.handleNeutralNullStart(byte, into: &reducer)
    case .asciiPipe, .asciiGreaterThan:
      try self.handleNeutralBlockScalarStart(byte, into: &reducer, chunkState: &chunkState)
    case .asciiHash:
      try self.handleNeutralCommentStart()
    default:
      break
    }
  }

  private func isPlainKeyByte(_ byte: UInt8) -> Bool {
    switch byte {
    case .asciiZero ... .asciiNine, .asciiUpperA ... .asciiUpperZ, .asciiLowerA ... .asciiLowerZ,
      .asciiUnderscore:
      true
    default:
      false
    }
  }

  private func isYAMLWhitespace(_ byte: UInt8) -> Bool {
    byte == .asciiSpace || byte == .asciiLineFeed || byte == .asciiCarriageReturn
      || byte == .asciiTab
  }

  private mutating func parseKeyCollecting(byte: UInt8) throws {
    if self.keyParsingState.isAwaitingColon {
      if byte == .asciiColon {
        self.activateCurrentObjectKey(self.keyParsingState.buffer)
        self.keyParsingState.reset()
        self.mode = .neutral
      } else if !self.isYAMLWhitespace(byte) {
        if self.currentObjectContext?.hasActiveKey == true {
          throw YAMLStreamParsingError(
            reason: .missingValue,
            position: self.position,
            context: .objectValue
          )
        }
        throw YAMLStreamParsingError(
          reason: .missingColon,
          position: self.position,
          context: .objectKey
        )
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
      throw YAMLStreamParsingError(
        reason: .unexpectedToken,
        position: self.position,
        context: .objectKey
      )
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

    if byte == .asciiSpace || byte == .asciiLineFeed {
      try self.startBlockArrayItem(at: lineStartDashIndent, into: &reducer)
      self.mode = byte == .asciiSpace ? .arrayValue : .neutral
      return
    }

    self.mode = .neutral
    self.lineStartDashIndent = nil
    try self.handleNeutralNegativeNumberStart(into: &reducer, chunkState: &chunkState)
    try self.parseInteger(byte: byte, into: &reducer, chunkState: &chunkState)
  }

  private mutating func handleNeutralNegativeNumberStart(
    into reducer: inout Value,
    chunkState: inout ByteChunkParseState
  ) throws {
    try self.prepareForValueStart()
    self.appendArrayElementIfNeeded(into: &reducer)
    let (path, isInvalidType) = self.handlers.numberPath(node: self.currentTrieNode)
    try self.throwInvalidTypeIfNeeded(isInvalidType)
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

  private mutating func handleNeutralDigitStart(
    _ byte: UInt8,
    into reducer: inout Value,
    chunkState: inout ByteChunkParseState
  ) throws {
    try self.prepareForValueStart()
    self.appendArrayElementIfNeeded(into: &reducer)
    let (path, isInvalidType) = self.handlers.numberPath(node: self.currentTrieNode)
    try self.throwInvalidTypeIfNeeded(isInvalidType)
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

  private mutating func handleNeutralLeadingDecimalPointStart(
    into reducer: inout Value,
    chunkState: inout ByteChunkParseState
  ) throws {
    try self.prepareForValueStart()
    self.appendArrayElementIfNeeded(into: &reducer)
    let (path, isInvalidType) = self.handlers.numberPath(node: self.currentTrieNode)
    try self.throwInvalidTypeIfNeeded(isInvalidType)
    self.currentNumberPath = path
    self.mode = .fractionalDouble
    try self.numberParsingState.resetForFractionalLeadingDot(position: self.position)
    if let currentNumberPath {
      var valueNumberAccumulator = reducer[keyPath: currentNumberPath]
      valueNumberAccumulator.reset()
      chunkState.valueNumberAccumulator = valueNumberAccumulator
    }
  }

  private mutating func handleNeutralNonFiniteNumberStart(_ byte: UInt8, into reducer: inout Value)
    throws
  {
    try self.prepareForValueStart()
    let (_, isInvalidType) = self.handlers.numberPath(node: self.currentTrieNode)
    try self.throwInvalidTypeIfNeeded(isInvalidType)
    if byte == .asciiUpperI {
      self.startLiteral(expected: yamlLiteralInfinity)
    } else {
      self.startLiteral(expected: yamlLiteralNaN)
    }
  }

  private mutating func handleNeutralLiteralStart(_ byte: UInt8, into reducer: inout Value) throws {
    try self.prepareForValueStart()
    self.appendArrayElementIfNeeded(into: &reducer)
    let (boolPath, isInvalidType) = self.handlers.booleanPath(node: self.currentTrieNode)
    try self.throwInvalidTypeIfNeeded(isInvalidType)
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
    try self.prepareForValueStart()
    self.appendArrayElementIfNeeded(into: &reducer)
    let (nullablePath, isInvalidType) = self.handlers.nullablePath(node: self.currentTrieNode)
    try self.throwInvalidTypeIfNeeded(isInvalidType)
    self.currentNullablePath = nullablePath
    if let nullablePath {
      reducer[keyPath: nullablePath] = nil
    }
    self.startLiteral(expected: yamlLiteralNull)
  }

  private mutating func handleNeutralCommentStart() throws {
    self.mode = .comment
  }

  private mutating func handleNeutralArrayStart(into reducer: inout Value) throws {
    try self.prepareForValueStart()
    let (path, isInvalidType) = self.handlers.arrayPath(node: self.currentTrieNode)
    try self.throwInvalidTypeIfNeeded(isInvalidType)
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
    try self.prepareForValueStart()
    let (_, isInvalidType) = self.handlers.dictionaryPath(node: self.currentTrieNode)
    try self.throwInvalidTypeIfNeeded(isInvalidType)
    self.appendArrayElementIfNeeded(into: &reducer)
    self.startObject(style: .flow, into: &reducer)
    self.mode = .neutral
  }

  private mutating func handleNeutralBlockScalarStart(
    _ byte: UInt8,
    into reducer: inout Value,
    chunkState: inout ByteChunkParseState
  ) throws {
    try self.prepareForValueStart()
    self.appendArrayElementIfNeeded(into: &reducer)
    let (stringPath, isInvalidType) = self.handlers.stringPath(node: self.currentTrieNode)
    try self.throwInvalidTypeIfNeeded(isInvalidType)
    self.currentStringPath = stringPath
    if let currentStringPath {
      reducer[keyPath: currentStringPath] = ""
      chunkState.valueStringBuffer = ""
    }
    let kind = byte == .asciiPipe ? BlockScalarKind.literal : BlockScalarKind.folded
    self.blockScalarState.start(kind: kind, parentIndent: self.currentLineIndent)
    self.mode = .blockScalarHeader
  }

  private mutating func parseBlockScalarHeader(byte: UInt8) throws {
    if byte == .asciiSpace || byte == .asciiCarriageReturn {
      return
    }
    guard byte == .asciiLineFeed else {
      throw YAMLStreamParsingError(
        reason: .invalidMultiLineString,
        position: self.position,
        context: .string
      )
    }
    self.mode = .blockScalar
  }

  private mutating func parseBlockScalar(
    byte: UInt8,
    into reducer: inout Value,
    chunkState: inout ByteChunkParseState
  ) throws {
    if self.blockScalarState.isAtLineStart {
      if byte == .asciiSpace {
        self.blockScalarState.currentLineIndent += 1
        return
      }
      if byte == .asciiLineFeed {
        self.blockScalarState.finishCurrentLine()
        return
      }
      if self.blockScalarState.contentIndent == nil {
        guard self.blockScalarState.currentLineIndent > self.blockScalarState.parentIndent else {
          throw YAMLStreamParsingError(
            reason: .invalidMultiLineString,
            position: self.position,
            context: .string
          )
        }
        self.blockScalarState.contentIndent = self.blockScalarState.currentLineIndent
      } else if self.blockScalarState.currentLineIndent < self.blockScalarState.contentIndent ?? 0 {
        self.currentLineIndent = self.blockScalarState.currentLineIndent
        try self.finishBlockScalar(into: &reducer, chunkState: &chunkState)
        return try self.parseCurrentByte(byte: byte, into: &reducer, chunkState: &chunkState)
      }
      self.blockScalarState.beginContentByte()
    }

    if byte == .asciiLineFeed {
      self.blockScalarState.finishCurrentLine()
      return
    }
    self.blockScalarState.append(byte: byte)
  }

  private mutating func finishBlockScalar(
    into reducer: inout Value,
    chunkState: inout ByteChunkParseState
  ) throws {
    if self.mode == .blockScalar {
      if !self.blockScalarState.isAtLineStart || self.blockScalarState.currentLineIndent > 0 {
        self.blockScalarState.finishCurrentLine()
      }
    }
    guard self.blockScalarState.hasContent else {
      throw YAMLStreamParsingError(
        reason: .invalidMultiLineString,
        position: self.position,
        context: .string
      )
    }
    if let currentStringPath {
      reducer[keyPath: currentStringPath] = self.blockScalarState.buffer
      chunkState.valueStringBuffer = nil
    }
    self.mode = .neutral
    self.blockScalarState = BlockScalarState()
  }

  private mutating func finishCurrentFlowObject() {
    guard case .flow = self.currentObjectContext?.style else { return }
    self.finishCurrentObjectValue()
    _ = self.objectContexts.popLast()
    self.currentDictionaryPath = self.currentObjectContext?.path
    self.mode = .neutral
  }

  private mutating func handleNeutralObjectEnd() throws {
    guard case .flow = self.currentObjectContext?.style else {
      throw YAMLStreamParsingError(
        reason: .unexpectedToken,
        position: self.position,
        context: .neutral
      )
    }
    let sawTrailingComma = self.currentObjectContext?.sawTrailingComma == true
    let isMissingValue =
      self.currentObjectContext?.hasActiveKey == true
      && self.currentObjectContext?.hasStartedValueForActiveKey == false
    self.finishCurrentFlowObject()
    if isMissingValue {
      throw YAMLStreamParsingError(
        reason: .missingValue,
        position: self.position,
        context: .objectValue
      )
    }
    if sawTrailingComma {
      throw YAMLStreamParsingError(
        reason: .trailingComma,
        position: self.position,
        context: .objectValue
      )
    }
  }

  private mutating func handleNeutralArrayEnd(into reducer: inout Value) throws {
    guard case .flow = self.currentArrayContext?.style else {
      throw YAMLStreamParsingError(
        reason: .unexpectedToken,
        position: self.position,
        context: .neutral
      )
    }
    let sawTrailingComma = self.currentArrayContext?.sawTrailingComma == true
    let didAppendElement = self.currentArrayContext?.didAppendForCurrentElement == true
    _ = self.arrayContexts.popLast()
    self.popArrayTrieNode()
    self.mode = .neutral
    if !didAppendElement && sawTrailingComma {
      throw YAMLStreamParsingError(
        reason: .trailingComma,
        position: self.position,
        context: .arrayValue
      )
    }
  }

  private mutating func handleNeutralDoubleQuotedStringStart(
    into reducer: inout Value,
    chunkState: inout ByteChunkParseState
  ) throws {
    try self.prepareForValueStart()
    self.appendArrayElementIfNeeded(into: &reducer)
    let (stringPath, isInvalidType) = self.handlers.stringPath(node: self.currentTrieNode)
    try self.throwInvalidTypeIfNeeded(isInvalidType)
    self.currentStringPath = stringPath
    if let currentStringPath {
      reducer[keyPath: currentStringPath] = ""
      chunkState.valueStringBuffer = ""
    }
    self.mode = .string
    self.stringState.startString(delimiter: .asciiQuote)
  }

  private mutating func parseString(
    byte: UInt8,
    into reducer: inout Value,
    chunkState: inout ByteChunkParseState
  ) throws {
    if self.stringState.unicodeEscapeRemaining > 0 {
      guard let hexValue = byte.hexValue else {
        throw YAMLStreamParsingError(
          reason: .invalidUnicodeEscape,
          position: self.position,
          context: .string
        )
      }
      self.stringState.unicodeEscapeValue =
        (self.stringState.unicodeEscapeValue << 4) | UInt32(hexValue)
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
          var valueStringBuffer = chunkState.ensureValueStringBuffer(in: reducer, path: self.currentStringPath)
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
          if byte == .asciiLowerU {
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
        var valueStringBuffer = chunkState.ensureValueStringBuffer(in: reducer, path: self.currentStringPath)
        valueStringBuffer.append("\\")
        chunkState.valueStringBuffer = valueStringBuffer
        self.stringState.isEscaping = false
      } else {
        self.stringState.isEscaping = true
      }
    case self.stringState.stringDelimiter:
      if self.stringState.isEscaping {
        var valueStringBuffer = chunkState.ensureValueStringBuffer(in: reducer, path: self.currentStringPath)
        valueStringBuffer.unicodeScalars.append(Unicode.Scalar(byte))
        chunkState.valueStringBuffer = valueStringBuffer
        self.stringState.isEscaping = false
      } else {
        chunkState.flush(into: &reducer, stringPath: self.currentStringPath, numberPath: self.currentNumberPath)
        self.mode = .neutral
      }
    default:
      if self.stringState.isEscaping {
        if byte == .asciiLowerU {
          self.stringState.beginUnicodeEscape()
          return
        }
      }
      switch self.stringState.utf8State.consume(byte: byte) {
      case .consume(let scalar):
        var valueStringBuffer = chunkState.ensureValueStringBuffer(in: reducer, path: self.currentStringPath)
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

  private mutating func parseInteger(
    byte: UInt8,
    into reducer: inout Value,
    chunkState: inout ByteChunkParseState
  ) throws {
    if byte == .asciiDot {
      self.mode = .fractionalDouble
      self.numberParsingState.state.hasDot = true
      try self.numberParsingState.appendDigit(byte, position: self.position)
      try self.writeCurrentNumberAccumulator(
        in: reducer,
        chunkState: &chunkState,
        isHex: false,
        position: self.position
      )
    } else if byte == .asciiLowerE || byte == .asciiUpperE {
      self.mode = .exponentialDouble
      guard self.numberParsingState.state.hasDigits else {
        throw YAMLStreamParsingError(
          reason: .invalidNumber,
          position: self.position,
          context: .number
        )
      }
      self.numberParsingState.state.hasExponent = true
      self.numberParsingState.state.hasExponentDigits = false
      try self.numberParsingState.appendDigit(byte, position: self.position)
    } else if let digit = byte.digitValue {
      if !self.numberParsingState.state.hasDigits {
        self.numberParsingState.state.hasDigits = true
        if digit == 0 {
          self.numberParsingState.state.hasLeadingZero = true
        }
      } else if self.numberParsingState.state.hasLeadingZero {
        throw YAMLStreamParsingError(
          reason: .leadingZero,
          position: self.position,
          context: .number
        )
      }
      self.numberParsingState.state.digitCount += 1
      try self.numberParsingState.appendDigit(byte, position: self.position)
      try self.writeCurrentNumberAccumulator(
        in: reducer,
        chunkState: &chunkState,
        isHex: false,
        position: self.position
      )
    } else {
      try self.finalizeNumberOrThrow(at: self.position, into: &reducer, chunkState: &chunkState)
      try self.parseNeutral(byte: byte, into: &reducer, chunkState: &chunkState)
    }
  }

  private mutating func parseFractionalDouble(
    byte: UInt8,
    into reducer: inout Value,
    chunkState: inout ByteChunkParseState
  ) throws {
    guard byte.digitValue != nil else {
      if byte == .asciiLowerE || byte == .asciiUpperE {
        guard self.numberParsingState.state.hasFractionDigits else {
          throw YAMLStreamParsingError(
            reason: .invalidNumber,
            position: self.position,
            context: .number
          )
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
    try self.writeCurrentNumberAccumulator(
      in: reducer,
      chunkState: &chunkState,
      isHex: false,
      position: self.position
    )
  }

  private mutating func parseExponentialDouble(
    byte: UInt8,
    into reducer: inout Value,
    chunkState: inout ByteChunkParseState
  ) throws {
    if byte == .asciiDash {
      if self.numberParsingState.state.hasExponentDigits {
        throw YAMLStreamParsingError(
          reason: .invalidExponent,
          position: self.position,
          context: .number
        )
      }
      self.numberParsingState.isNegativeExponent = true
      try self.numberParsingState.appendDigit(byte, position: self.position)
    } else if byte == .asciiPlus {
      if self.numberParsingState.state.hasExponentDigits {
        throw YAMLStreamParsingError(
          reason: .invalidExponent,
          position: self.position,
          context: .number
        )
      }
      try self.numberParsingState.appendDigit(byte, position: self.position)
      return
    } else if let digit = byte.digitValue {
      self.numberParsingState.state.hasExponentDigits = true
      let newExponent = self.numberParsingState.exponent * 10 + Int(digit)
      if newExponent > 999 {
        throw YAMLStreamParsingError(
          reason: .numericOverflow,
          position: self.position,
          context: .number
        )
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
      throw YAMLStreamParsingError(
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

  private mutating func parseComment(byte: UInt8) {
    if byte == .asciiLineFeed {
      self.mode = .neutral
    }
  }

  private mutating func parseArrayValue(
    byte: UInt8,
    into reducer: inout Value,
    chunkState: inout ByteChunkParseState
  ) throws {
    switch byte {
    case .asciiQuote:
      try self.handleNeutralDoubleQuotedStringStart(into: &reducer, chunkState: &chunkState)
    case .asciiComma:
      chunkState.flush(into: &reducer, stringPath: self.currentStringPath, numberPath: self.currentNumberPath)
      self.prepareForNextArrayElement()
      self.replaceCurrentArrayContext { $0.sawTrailingComma = true }
    case .asciiArrayEnd:
      chunkState.flush(into: &reducer, stringPath: self.currentStringPath, numberPath: self.currentNumberPath)
      try self.handleNeutralArrayEnd(into: &reducer)
    case .asciiArrayStart:
      try self.handleNeutralArrayStart(into: &reducer)
    case .asciiZero ... .asciiNine:
      try self.handleNeutralDigitStart(byte, into: &reducer, chunkState: &chunkState)
    case .asciiDash:
      self.lineStartDashIndent = self.currentLineIndent
      self.mode = .lineStartDash
    case .asciiLowerT, .asciiLowerF:
      try self.handleNeutralLiteralStart(byte, into: &reducer)
    case .asciiLowerN:
      try self.handleNeutralNullStart(byte, into: &reducer)
    case .asciiPipe, .asciiGreaterThan:
      try self.handleNeutralBlockScalarStart(byte, into: &reducer, chunkState: &chunkState)
    default:
      if self.isYAMLWhitespace(byte) {
        break
      }
      if case .flow = self.currentArrayContext?.style {
        throw YAMLStreamParsingError(
          reason: .missingComma,
          position: self.position,
          context: .arrayValue
        )
      }
      break
    }
  }

  private mutating func writeCurrentNumberAccumulator(
    in reducer: Value,
    chunkState: inout ByteChunkParseState,
    isHex: Bool,
    position: YAMLStreamParsingPosition
  ) throws {
    let accumulator = chunkState.ensureValueNumberAccumulator(in: reducer, path: self.currentNumberPath)
    guard var accumulator else { return }
    let didParse = accumulator.parseDigits(
      buffer: self.numberParsingState.digitBuffer,
      isHex: isHex
    )
    guard didParse else {
      throw YAMLStreamParsingError(reason: .numericOverflow, position: position, context: .number)
    }
    chunkState.valueNumberAccumulator = accumulator
  }

  private mutating func finalizeNumberOrThrow(
    at position: YAMLStreamParsingPosition,
    into reducer: inout Value,
    chunkState: inout ByteChunkParseState
  ) throws {
    guard self.numberParsingState.state.hasDigits else {
      throw YAMLStreamParsingError(reason: .invalidNumber, position: position, context: .number)
    }
    try self.writeCurrentNumberAccumulator(
      in: reducer,
      chunkState: &chunkState,
      isHex: false,
      position: position
    )
    chunkState.flush(into: &reducer, stringPath: self.currentStringPath, numberPath: self.currentNumberPath)
    self.mode = .neutral
    self.numberParsingState.resetAfterFinalize()
  }

  private mutating func advancePosition(for byte: UInt8) {
    if byte == .asciiLineFeed {
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

    fileprivate func numberPath(node: PathTrie<Value>?) -> (
      WritableKeyPath<Value, NumberAccumulator>?, Bool
    ) {
      guard let node else { return (nil, false) }
      return node.path(\.number) { $0.paths.hasAnyHandler }
    }

    fileprivate func stringPath(node: PathTrie<Value>?) -> (WritableKeyPath<Value, String>?, Bool) {
      guard let node else { return (nil, false) }
      return node.path(\.string) { $0.paths.hasAnyHandler }
    }

    fileprivate func booleanPath(node: PathTrie<Value>?) -> (WritableKeyPath<Value, Bool>?, Bool) {
      guard let node else { return (nil, false) }
      return node.path(\.bool) { $0.paths.hasAnyHandler }
    }

    fileprivate func nullablePath(node: PathTrie<Value>?) -> (WritableKeyPath<Value, Void?>?, Bool)
    {
      guard let node else { return (nil, false) }
      return node.path(\.nullable) { $0.paths.hasAnyHandler }
    }

    fileprivate func arrayPath(node: PathTrie<Value>?) -> (
      WritableKeyPath<Value, any StreamParseableArrayObject>?, Bool
    ) {
      guard let node else { return (nil, false) }
      return node.path(\.array) { $0.paths.hasAnyHandler }
    }

    fileprivate func dictionaryPath(node: PathTrie<Value>?) -> (
      WritableKeyPath<Value, any StreamParseableDictionaryObject>?, Bool
    ) {
      guard let node else { return (nil, false) }
      return node.path(\.dictionary) { $0.paths.hasAnyHandler && !$0.expectsObject }
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

      self.pathTrie.mergeKeyedHandlerTrie(
        decodedKey: self.configuration.keyDecodingStrategy.decode(key: key),
        keyPath: keyPath,
        nestedTrie: keyedHandlers.pathTrie
      )
    }

    public mutating func registerScopedHandlers<Scoped: StreamParseableValue>(
      on type: Scoped.Type,
      _ keyPath: WritableKeyPath<Value, Scoped>
    ) {
      var handlers = YAMLStreamParser<Scoped>.Handlers(configuration: self.configuration)
      type.registerHandlers(in: &handlers)
      self.pathTrie.mergeScopedHandlerTrie(keyPath: keyPath, nestedTrie: handlers.pathTrie)
    }

    public mutating func registerArrayHandler<ArrayObject: StreamParseableArrayObject>(
      _ keyPath: WritableKeyPath<Value, ArrayObject>
    ) {
      var elementHandlers = YAMLStreamParser<ArrayObject.Element>
        .Handlers(configuration: self.configuration)
      ArrayObject.Element.registerHandlers(in: &elementHandlers)

      self.pathTrie.registerArrayHandlerTrie(
        keyPath: keyPath,
        elementTrie: elementHandlers.pathTrie
      )
    }

    public mutating func registerDictionaryHandler<
      DictionaryObject: StreamParseableDictionaryObject
    >(
      _ keyPath: WritableKeyPath<Value, DictionaryObject>
    ) {
      var valueHandlers = YAMLStreamParser<DictionaryObject.Value>
        .Handlers(configuration: self.configuration)
      DictionaryObject.Value.registerHandlers(in: &valueHandlers)

      self.pathTrie.registerDictionaryHandlerTrie(
        keyPath: keyPath,
        valueTrie: valueHandlers.pathTrie
      )
    }
  }
}

// MARK: - Configuration

public struct YAMLStreamParserConfiguration: Sendable {
  public var keyDecodingStrategy: YAMLKeyDecodingStrategy

  public init(
    keyDecodingStrategy: YAMLKeyDecodingStrategy = .useDefault
  ) {
    self.keyDecodingStrategy = keyDecodingStrategy
  }
}

// MARK: - YAMLKeyDecodingStrategy

public enum YAMLKeyDecodingStrategy: Sendable {
  case convertFromSnakeCase
  case useDefault
  case custom(@Sendable (String) -> String)

  public func decode(key: String) -> String {
    switch self {
    case .convertFromSnakeCase: decodeKeyFromSnakeCase(key)
    case .useDefault: key
    case .custom(let decode): decode(key)
    }
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

  private typealias ByteChunkParseState = ParserByteChunkState<Value>

  private struct BlockScalarState {
    var kind = BlockScalarKind.literal
    var parentIndent = 0
    var contentIndent: Int?
    var currentLineIndent = 0
    var currentLine = ""
    var buffer = ""
    var isAtLineStart = true
    var hasContent = false
    var previousLineWasBlank = false
    var utf8State = UTF8State()

    mutating func start(kind: BlockScalarKind, parentIndent: Int) {
      self.kind = kind
      self.parentIndent = parentIndent
      self.contentIndent = nil
      self.currentLineIndent = 0
      self.currentLine = ""
      self.buffer = ""
      self.isAtLineStart = true
      self.hasContent = false
      self.previousLineWasBlank = false
      self.utf8State = UTF8State()
    }

    mutating func beginContentByte() {
      guard let contentIndent else { return }
      if self.currentLineIndent > contentIndent {
        self.currentLine = String(repeating: " ", count: self.currentLineIndent - contentIndent)
      }
      self.isAtLineStart = false
    }

    mutating func append(byte: UInt8) {
      switch self.utf8State.consume(byte: byte) {
      case .consume(let scalar):
        self.currentLine.unicodeScalars.append(scalar)
      case .doNothing:
        break
      }
    }

    mutating func finishCurrentLine() {
      let isBlankLine = self.currentLine.isEmpty
      if self.hasContent {
        switch self.kind {
        case .literal:
          self.buffer.append("\n")
        case .folded:
          if self.previousLineWasBlank || isBlankLine {
            self.buffer.append("\n")
          } else {
            self.buffer.append(" ")
          }
        }
      }
      self.buffer.append(self.currentLine)
      self.hasContent = true
      self.previousLineWasBlank = isBlankLine
      self.currentLine = ""
      self.currentLineIndent = 0
      self.isAtLineStart = true
      self.utf8State.reset()
    }
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

}

extension YAMLStreamParser {
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
