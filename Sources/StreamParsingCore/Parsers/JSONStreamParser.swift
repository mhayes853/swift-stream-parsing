// MARK: - JSONStreamParser

/// A ``StreamParser`` that parses JSON.
///
/// The parser will update its value for every byte that semantically changes the parsed value.
/// However, some sections of JSON, such as object keys, or exponentials, will not update the value
/// until the entire section has been parsed.
public struct JSONStreamParser<Value: StreamParseableValue>: StreamParser {
  private enum Mode {
    case neutral
    case string
    case integer
    case hexInteger
    case exponentialDouble
    case fractionalDouble
    case literal
    case keyFinding
    case keyCollecting
    case commentStart
    case comment

    var isNumeric: Bool {
      switch self {
      case .integer, .hexInteger, .exponentialDouble, .fractionalDouble: true
      default: false
      }
    }
  }

  /// The ``JSONStreamParserConfiguration``.
  public let configuration: JSONStreamParserConfiguration

  private var handlers: Handlers
  private var mode = Mode.neutral
  private var stringState = StringParsingState()
  private var numberParsingState = NumberParsingState()
  private var containerState = ContainerState()
  private var currentStringPath: WritableKeyPath<Value, String>?
  private var currentNumberPath: WritableKeyPath<Value, JSONNumberAccumulator>?
  private var currentArrayPath: WritableKeyPath<Value, any StreamParseableArrayObject>?
  private var currentDictionaryPath: WritableKeyPath<Value, any StreamParseableDictionaryObject>?
  private var currentTrieNode: PathTrie<Value>?
  private var trieNodeStack = [PathTrie<Value>?]()
  private var position = JSONStreamParsingPosition(line: 1, column: 1)
  private var literalState = LiteralState()
  private var commentState = CommentState()

  private var shouldThrowTrailingCommaError: Bool {
    !self.configuration.syntaxOptions.contains(.trailingCommas)
  }

  /// Creates a parser with the provided configuration.
  ///
  /// - Parameter configuration: The ``JSONStreamParserConfiguration`` to use.
  public init(configuration: JSONStreamParserConfiguration = JSONStreamParserConfiguration()) {
    self.configuration = configuration
    self.handlers = Handlers(configuration: configuration)
    self.currentTrieNode = self.handlers.pathTrie
  }

  public mutating func registerHandlers() {
    Value.registerHandlers(in: &self.handlers)
    self.currentTrieNode = self.handlers.pathTrie
    self.trieNodeStack.removeAll()
  }

  public mutating func parse(bytes: some Sequence<UInt8>, into reducer: inout Value) throws {
    for byte in bytes {
      try self.parse(byte: byte, into: &reducer)
    }
  }

  public mutating func finish(reducer: inout Value) throws {
    if self.mode == .commentStart {
      throw JSONStreamParsingError(
        reason: .unexpectedToken,
        position: self.position,
        context: .neutral
      )
    }
    if self.mode == .comment && self.commentState.kind == .block {
      throw JSONStreamParsingError(
        reason: .unexpectedToken,
        position: self.position,
        context: .neutral
      )
    }
    if self.mode == .keyCollecting && !self.stringState.isCollectingUnquotedKey {
      throw JSONStreamParsingError(
        reason: .unterminatedString,
        position: self.position,
        context: .objectKey
      )
    }
    if self.mode == .string {
      if self.stringState.unicodeEscapeRemaining > 0 {
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
    if self.containerState.arrayDepth > 0 {
      throw JSONStreamParsingError(
        reason: .missingClosingBracket,
        position: self.position,
        context: .arrayValue
      )
    }
    if self.containerState.objectDepth > 0 {
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
    case .hexInteger: try self.parseHexInteger(byte: byte, into: &reducer)
    case .string: try self.parseString(byte: byte, into: &reducer)
    case .exponentialDouble: try self.parseExponentialDouble(byte: byte, into: &reducer)
    case .fractionalDouble: try self.parseFractionalDouble(byte: byte, into: &reducer)
    case .keyFinding: try self.parseKeyFinding(byte: byte, into: &reducer)
    case .keyCollecting: try self.parseKeyCollecting(byte: byte, into: &reducer)
    case .commentStart: try self.parseCommentStart(byte: byte, into: &reducer)
    case .comment: try self.parseComment(byte: byte, into: &reducer)
    }
  }

  private mutating func appendArrayElementIfNeeded(into reducer: inout Value) {
    guard case .array = self.containerState.stack.last else { return }
    let containerDepth = self.containerState.stack.count - 1
    let containerNode = self.trieNode(forStackDepth: containerDepth)
    let (path, _) = self.handlers.arrayPath(node: containerNode)
    self.currentArrayPath = path
    guard let currentArrayPath else { return }
    reducer[keyPath: currentArrayPath].appendNewElement()
  }

  private func trieNode(forStackDepth depth: Int) -> PathTrie<Value>? {
    guard depth > 0 else { return self.handlers.pathTrie }
    let index = depth - 1
    guard index >= 0, index < self.trieNodeStack.count else { return nil }
    return self.trieNodeStack[index]
  }

  private mutating func pushArrayTrieNode() {
    let next = self.currentTrieNode?.arrayChildNode()
    self.trieNodeStack.append(next)
    self.currentTrieNode = next
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

  private func invalidTypeContext() -> JSONStreamParsingError.Context? {
    switch self.containerState.stack.last {
    case .array: .arrayValue
    case .object: .objectValue
    default: .neutral
    }
  }

  private mutating func throwInvalidTypeIfNeeded(_ isInvalidType: Bool) throws {
    guard isInvalidType else { return }
    throw JSONStreamParsingError(
      reason: .invalidType,
      position: self.position,
      context: self.invalidTypeContext()
    )
  }

  private mutating func beginValueToken() throws {
    if case .array = self.containerState.stack.last {
      if self.containerState.isArrayExpectingValueOrTrailingComma(
        at: self.containerState.arrayDepth
      ) {
        self.containerState.arrayExpectingValueDepths.remove(self.containerState.arrayDepth)
        self.containerState.arrayHasValueDepths.insert(self.containerState.arrayDepth)
        self.containerState.arrayTrailingCommaDepths.remove(self.containerState.arrayDepth)
      } else if self.containerState.arrayHasValueDepths.contains(self.containerState.arrayDepth) {
        throw JSONStreamParsingError(
          reason: .missingComma,
          position: self.position,
          context: .arrayValue
        )
      }
    }
    if case .object = self.containerState.stack.last {
      let depth = self.containerState.stack.count
      if self.containerState.objectValuePendingDepths.contains(depth) {
        self.containerState.objectValuePendingDepths.remove(depth)
      }
    }
  }

  private mutating func markArrayTrailingComma() {
    self.containerState.markArrayTrailingComma()
  }

  private mutating func clearArrayTrailingCommaIfNeeded() {
    self.containerState.clearArrayTrailingCommaIfNeeded()
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
      try self.handleNeutralDoubleQuotedStringStart(into: &reducer)
    case .asciiApostrophe:
      try self.handleNeutralSingleQuotedStringStart(into: &reducer)
    case .asciiComma:
      try self.handleNeutralComma()
    case .asciiArrayStart:
      try self.handleNeutralArrayStart(into: &reducer)
    case .asciiArrayEnd:
      try self.handleNeutralArrayEnd()
    case .asciiObjectStart:
      try self.handleNeutralObjectStart(into: &reducer)
    case .asciiObjectEnd:
      try self.handleNeutralObjectEnd()
    case .asciiTrueStart:
      try self.handleNeutralTrueStart(into: &reducer)
    case .asciiFalseStart:
      try self.handleNeutralFalseStart(into: &reducer)
    case .asciiNullStart:
      try self.handleNeutralNullStart(into: &reducer)
    case .asciiDash:
      try self.handleNeutralNegativeNumberStart(into: &reducer)
    case .asciiDot:
      try self.handleNeutralLeadingDecimalPointStart(into: &reducer)
    case .asciiPlus:
      try self.handleNeutralLeadingPlusStart(into: &reducer)
    case 0x30...0x39:
      try self.handleNeutralDigitStart(byte, into: &reducer)
    case .asciiUpperI, .asciiUpperN:
      try self.handleNeutralNonFiniteNumberStart(byte, into: &reducer)
    case .asciiSlash:
      try self.handleNeutralCommentStart()
    default:
      try self.handleNeutralWhitespaceOrError(byte)
    }
  }

  private mutating func handleNeutralDoubleQuotedStringStart(into reducer: inout Value) throws {
    self.clearArrayTrailingCommaIfNeeded()
    try self.beginValueToken()
    self.appendArrayElementIfNeeded(into: &reducer)
    let (path, isInvalidType) = self.handlers.stringPath(node: self.currentTrieNode)
    self.currentStringPath = path
    try self.throwInvalidTypeIfNeeded(isInvalidType)
    self.mode = .string
    self.stringState.startString(delimiter: .asciiQuote)
  }

  private mutating func handleNeutralSingleQuotedStringStart(into reducer: inout Value) throws {
    guard self.configuration.syntaxOptions.contains(.singleQuotedStrings) else {
      throw JSONStreamParsingError(
        reason: .unexpectedToken,
        position: self.position,
        context: .neutral
      )
    }
    self.clearArrayTrailingCommaIfNeeded()
    try self.beginValueToken()
    self.appendArrayElementIfNeeded(into: &reducer)
    let (path, isInvalidType) = self.handlers.stringPath(node: self.currentTrieNode)
    self.currentStringPath = path
    try self.throwInvalidTypeIfNeeded(isInvalidType)
    self.mode = .string
    self.stringState.startString(delimiter: .asciiApostrophe)
  }

  private mutating func handleNeutralComma() throws {
    switch self.containerState.stack.last {
    case .array(let index):
      if self.containerState.arrayExpectingValueDepths.contains(self.containerState.arrayDepth) {
        throw JSONStreamParsingError(
          reason: .missingValue,
          position: self.position,
          context: .arrayValue
        )
      }
      _ = self.containerState.stack.popLast()
      self.containerState.stack.append(.array(index: index + 1))
      self.markArrayTrailingComma()
      self.containerState.arrayExpectingValueDepths.insert(self.containerState.arrayDepth)

    case .object:
      let keyDepth = self.containerState.stack.count
      if self.containerState.objectValuePendingDepths.contains(keyDepth) {
        throw JSONStreamParsingError(
          reason: .missingValue,
          position: self.position,
          context: .objectValue
        )
      }
      _ = self.containerState.stack.popLast()
      self.popTrieNode()
      self.mode = .keyFinding
      self.stringState.resetKeyCollection()
      self.containerState.markObjectTrailingCommaIfNeeded()

    default:
      throw JSONStreamParsingError(
        reason: .unexpectedToken,
        position: self.position,
        context: .neutral
      )
    }
  }

  private mutating func handleNeutralArrayStart(into reducer: inout Value) throws {
    self.clearArrayTrailingCommaIfNeeded()
    try self.beginValueToken()
    self.appendArrayElementIfNeeded(into: &reducer)
    let (path, isInvalidType) = self.handlers.arrayPath(node: self.currentTrieNode)
    self.currentArrayPath = path
    try self.throwInvalidTypeIfNeeded(isInvalidType)
    self.containerState.startArray()
    self.pushArrayTrieNode()
    guard let currentArrayPath else { return }
    reducer[keyPath: currentArrayPath].reset()
  }

  private mutating func handleNeutralArrayEnd() throws {
    guard self.containerState.isArrayContextAtTop else {
      throw JSONStreamParsingError(
        reason: .unexpectedToken,
        position: self.position,
        context: .neutral
      )
    }
    if self.containerState.arrayTrailingCommaDepths.contains(self.containerState.arrayDepth) {
      if self.shouldThrowTrailingCommaError {
        throw JSONStreamParsingError(
          reason: .trailingComma,
          position: self.position,
          context: .arrayValue
        )
      }
    }
    if self.containerState.isArrayTrailingCommaAfterValue(at: self.containerState.arrayDepth) {
      if self.shouldThrowTrailingCommaError {
        throw JSONStreamParsingError(
          reason: .trailingComma,
          position: self.position,
          context: .arrayValue
        )
      }
    }
    self.containerState.finishArray()
    self.popTrieNode()
    let containerDepth = self.containerState.stack.count - 1
    let containerNode = self.trieNode(forStackDepth: containerDepth)
    let (path, _) = self.handlers.arrayPath(node: containerNode)
    self.currentArrayPath = path
  }

  private mutating func handleNeutralObjectStart(into reducer: inout Value) throws {
    self.clearArrayTrailingCommaIfNeeded()
    try self.beginValueToken()
    self.appendArrayElementIfNeeded(into: &reducer)
    self.mode = .keyFinding
    let (path, isInvalidType) = self.handlers.dictionaryPath(node: self.currentTrieNode)
    self.currentDictionaryPath = path
    try self.throwInvalidTypeIfNeeded(isInvalidType)
    self.containerState.startObject()
    guard let currentDictionaryPath else { return }
    reducer[keyPath: currentDictionaryPath].reset()
  }

  private mutating func handleNeutralObjectEnd() throws {
    guard self.containerState.objectDepth > 0 else {
      throw JSONStreamParsingError(
        reason: .unexpectedToken,
        position: self.position,
        context: .neutral
      )
    }
    if self.containerState.objectTrailingCommaDepths.contains(self.containerState.objectDepth) {
      if self.shouldThrowTrailingCommaError {
        throw JSONStreamParsingError(
          reason: .trailingComma,
          position: self.position,
          context: .objectValue
        )
      }
    }
    if case .object = self.containerState.stack.last {
      let keyDepth = self.containerState.stack.count
      if self.containerState.objectValuePendingDepths.contains(keyDepth) {
        throw JSONStreamParsingError(
          reason: .missingValue,
          position: self.position,
          context: .objectValue
        )
      }
      self.containerState.stack.removeLast()
      self.popTrieNode()
      let containerDepth = self.containerState.stack.count - 1
      let containerNode = self.trieNode(forStackDepth: containerDepth)
      let (path, _) = self.handlers.dictionaryPath(node: containerNode)
      self.currentDictionaryPath = path
    }
    self.containerState.finishObject()
  }

  private mutating func handleNeutralTrueStart(into reducer: inout Value) throws {
    self.clearArrayTrailingCommaIfNeeded()
    try self.beginValueToken()
    self.appendArrayElementIfNeeded(into: &reducer)
    let (boolPath, isInvalidType) = self.handlers.booleanPath(node: self.currentTrieNode)
    if let boolPath {
      reducer[keyPath: boolPath] = true
    }
    try self.throwInvalidTypeIfNeeded(isInvalidType)
    self.startLiteral(expected: jsonLiteralTrue)
  }

  private mutating func handleNeutralFalseStart(into reducer: inout Value) throws {
    self.clearArrayTrailingCommaIfNeeded()
    try self.beginValueToken()
    self.appendArrayElementIfNeeded(into: &reducer)
    let (boolPath, isInvalidType) = self.handlers.booleanPath(node: self.currentTrieNode)
    if let boolPath {
      reducer[keyPath: boolPath] = false
    }
    try self.throwInvalidTypeIfNeeded(isInvalidType)
    self.startLiteral(expected: jsonLiteralFalse)
  }

  private mutating func handleNeutralNullStart(into reducer: inout Value) throws {
    self.clearArrayTrailingCommaIfNeeded()
    try self.beginValueToken()
    self.appendArrayElementIfNeeded(into: &reducer)
    let (nullablePath, isInvalidType) = self.handlers.nullablePath(node: self.currentTrieNode)
    if let nullablePath {
      reducer[keyPath: nullablePath] = nil
    }
    try self.throwInvalidTypeIfNeeded(isInvalidType)
    self.startLiteral(expected: jsonLiteralNull)
  }

  private mutating func handleNeutralNegativeNumberStart(into reducer: inout Value) throws {
    self.clearArrayTrailingCommaIfNeeded()
    try self.beginValueToken()
    self.appendArrayElementIfNeeded(into: &reducer)
    let (path, isInvalidType) = self.handlers.numberPath(node: self.currentTrieNode)
    self.currentNumberPath = path
    try self.throwInvalidTypeIfNeeded(isInvalidType)
    self.mode = .integer
    self.numberParsingState.resetForInteger(isNegative: true)
    try self.numberParsingState.appendDigit(.asciiDash, position: self.position)
    if let numberPath = self.currentNumberPath {
      reducer[keyPath: numberPath].reset()
    }
  }

  private mutating func handleNeutralLeadingDecimalPointStart(into reducer: inout Value) throws {
    guard self.configuration.syntaxOptions.contains(.leadingDecimalPoint) else {
      throw JSONStreamParsingError(
        reason: .unexpectedToken,
        position: self.position,
        context: .neutral
      )
    }
    self.clearArrayTrailingCommaIfNeeded()
    try self.beginValueToken()
    self.appendArrayElementIfNeeded(into: &reducer)
    let (path, isInvalidType) = self.handlers.numberPath(node: self.currentTrieNode)
    self.currentNumberPath = path
    try self.throwInvalidTypeIfNeeded(isInvalidType)
    self.mode = .fractionalDouble
    try self.numberParsingState.resetForFractionalLeadingDot(position: self.position)
    if let numberPath = self.currentNumberPath {
      reducer[keyPath: numberPath].reset()
    }
  }

  private mutating func handleNeutralLeadingPlusStart(into reducer: inout Value) throws {
    guard self.configuration.syntaxOptions.contains(.leadingPlus) else {
      throw JSONStreamParsingError(
        reason: .unexpectedToken,
        position: self.position,
        context: .neutral
      )
    }
    self.clearArrayTrailingCommaIfNeeded()
    try self.beginValueToken()
    self.appendArrayElementIfNeeded(into: &reducer)
    let (path, isInvalidType) = self.handlers.numberPath(node: self.currentTrieNode)
    self.currentNumberPath = path
    try self.throwInvalidTypeIfNeeded(isInvalidType)
    self.mode = .integer
    self.numberParsingState.resetForInteger(isNegative: false)
    try self.numberParsingState.appendDigit(.asciiPlus, position: self.position)
    if let numberPath = self.currentNumberPath {
      reducer[keyPath: numberPath].reset()
    }
  }

  private mutating func handleNeutralDigitStart(_ byte: UInt8, into reducer: inout Value) throws {
    self.clearArrayTrailingCommaIfNeeded()
    try self.beginValueToken()
    self.appendArrayElementIfNeeded(into: &reducer)
    let (path, isInvalidType) = self.handlers.numberPath(node: self.currentTrieNode)
    self.currentNumberPath = path
    try self.throwInvalidTypeIfNeeded(isInvalidType)
    self.mode = .integer
    self.numberParsingState.resetForInteger(isNegative: false)
    if let numberPath = self.currentNumberPath {
      reducer[keyPath: numberPath].reset()
    }
    try self.parseInteger(byte: byte, into: &reducer)
  }

  private mutating func handleNeutralNonFiniteNumberStart(
    _ byte: UInt8,
    into reducer: inout Value
  ) throws {
    guard self.configuration.syntaxOptions.contains(.nonFiniteNumbers) else {
      throw JSONStreamParsingError(
        reason: .unexpectedToken,
        position: self.position,
        context: .neutral
      )
    }
    self.clearArrayTrailingCommaIfNeeded()
    try self.beginValueToken()
    self.appendArrayElementIfNeeded(into: &reducer)
    let (numberPath, isInvalidType) = self.handlers.numberPath(node: self.currentTrieNode)
    if let numberPath {
      switch byte {
      case .asciiUpperI:
        try self.applyNonFiniteNumber(
          .infinity,
          at: self.position,
          path: numberPath,
          into: &reducer
        )
        self.startLiteral(expected: jsonLiteralInfinity)
      case .asciiUpperN:
        try self.applyNonFiniteNumber(.nan, at: self.position, path: numberPath, into: &reducer)
        self.startLiteral(expected: jsonLiteralNaN)
      default:
        break
      }
    } else {
      try self.throwInvalidTypeIfNeeded(isInvalidType)
      switch byte {
      case .asciiUpperI:
        self.startLiteral(expected: jsonLiteralInfinity)
      case .asciiUpperN:
        self.startLiteral(expected: jsonLiteralNaN)
      default:
        break
      }
    }
  }

  private mutating func handleNeutralCommentStart() throws {
    guard self.configuration.syntaxOptions.contains(.comments) else {
      throw JSONStreamParsingError(
        reason: .unexpectedToken,
        position: self.position,
        context: .neutral
      )
    }
    self.commentState.returnMode = .neutral
    self.mode = .commentStart
  }

  private mutating func handleNeutralWhitespaceOrError(_ byte: UInt8) throws {
    if !byte.isWhitespace {
      throw JSONStreamParsingError(
        reason: .unexpectedToken,
        position: self.position,
        context: .neutral
      )
    }
  }

  private mutating func parseKeyFinding(byte: UInt8, into reducer: inout Value) throws {
    switch byte {
    case .asciiQuote:
      self.mode = .keyCollecting
      self.stringState.startKey(delimiter: .asciiQuote, initial: "", isUnquoted: false)
      self.containerState.objectTrailingCommaDepths.remove(self.containerState.objectDepth)

    case .asciiApostrophe:
      guard self.configuration.syntaxOptions.contains(.singleQuotedStrings) else {
        throw JSONStreamParsingError(
          reason: .unexpectedToken,
          position: self.position,
          context: .objectKey
        )
      }
      self.mode = .keyCollecting
      self.stringState.startKey(delimiter: .asciiApostrophe, initial: "", isUnquoted: false)
      self.containerState.objectTrailingCommaDepths.remove(self.containerState.objectDepth)

    case _ where byte.isAlphaNumeric && self.configuration.syntaxOptions.contains(.unquotedKeys):
      self.mode = .keyCollecting
      self.stringState.startKey(
        delimiter: .asciiQuote,
        initial: String(Unicode.Scalar(byte)),
        isUnquoted: true
      )
      self.containerState.objectTrailingCommaDepths.remove(self.containerState.objectDepth)

    case .asciiSlash:
      guard self.configuration.syntaxOptions.contains(.comments) else {
        throw JSONStreamParsingError(
          reason: .unexpectedToken,
          position: self.position,
          context: .objectKey
        )
      }
      self.commentState.returnMode = .keyFinding
      self.mode = .commentStart

    case .asciiObjectEnd:
      self.mode = .neutral
      if self.containerState.objectDepth == 0 {
        throw JSONStreamParsingError(
          reason: .unexpectedToken,
          position: self.position,
          context: .objectKey
        )
      }
      if self.containerState.objectTrailingCommaDepths.contains(self.containerState.objectDepth) {
        if self.shouldThrowTrailingCommaError {
          throw JSONStreamParsingError(
            reason: .trailingComma,
            position: self.position,
            context: .objectValue
          )
        }
      }
      if case .object = self.containerState.stack.last {
        _ = self.containerState.stack.popLast()
        self.popTrieNode()
      }
      self.containerState.finishObject()

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
    if self.stringState.isAwaitingKeySeparator {
      if byte == .asciiColon {
        self.containerState.stack.append(.object(key: self.stringState.buffer))
        self.pushObjectTrieNode(for: self.stringState.buffer)
        self.containerState.objectValuePendingDepths.insert(self.containerState.stack.count)
        self.mode = .neutral
        self.stringState.finishKeyCollection()
      } else if !byte.isWhitespace {
        if self.stringState.keyDelimiter == .asciiApostrophe {
          throw JSONStreamParsingError(
            reason: .unexpectedToken,
            position: self.position,
            context: .objectKey
          )
        }
        throw JSONStreamParsingError(
          reason: .missingColon,
          position: self.position,
          context: .objectKey
        )
      }
      return
    }

    if self.stringState.isCollectingUnquotedKey {
      if byte == .asciiColon {
        self.containerState.stack.append(.object(key: self.stringState.buffer))
        self.pushObjectTrieNode(for: self.stringState.buffer)
        self.containerState.objectValuePendingDepths.insert(self.containerState.stack.count)
        self.mode = .neutral
        self.stringState.finishKeyCollection()
        return
      }
      if byte.isWhitespace {
        self.stringState.isAwaitingKeySeparator = true
        return
      }
      guard byte.isAlphaNumeric else {
        throw JSONStreamParsingError(
          reason: .unexpectedToken,
          position: self.position,
          context: .objectKey
        )
      }
      self.stringState.buffer.unicodeScalars.append(Unicode.Scalar(byte))
      return
    }

    switch byte {
    case .asciiBackslash:
      if self.stringState.isEscaping {
        self.stringState.buffer.append("\\")
        self.stringState.isEscaping = false
      } else {
        self.stringState.isEscaping = true
      }

    case self.stringState.keyDelimiter:
      if self.stringState.isEscaping {
        self.stringState.buffer.unicodeScalars.append(Unicode.Scalar(byte))
        self.stringState.isEscaping = false
      } else {
        self.stringState.isCollectingKey = false
        self.stringState.isAwaitingKeySeparator = true
      }

    default:
      switch self.stringState.utf8State.consume(byte: byte) {
      case .appendByte:
        if self.stringState.isEscaping {
          var currentString = self.stringState.buffer
          self.stringState.appendEscapedCharacter(for: byte, into: &currentString)
          self.stringState.buffer = currentString
        } else {
          self.stringState.buffer.unicodeScalars.append(Unicode.Scalar(byte))
        }
      case .appendScalar(let scalar):
        self.stringState.buffer.unicodeScalars.append(scalar)
      case .doNothing:
        break
      }
    }
  }

  private mutating func parseString(byte: UInt8, into reducer: inout Value) throws {
    if self.stringState.unicodeEscapeRemaining > 0 {
      guard let hexValue = byte.hexValue else {
        throw JSONStreamParsingError(
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
          throw JSONStreamParsingError(
            reason: .invalidUnicodeEscape,
            position: self.position,
            context: .string
          )
        }
        if let currentStringPath {
          reducer[keyPath: currentStringPath].unicodeScalars.append(scalar)
        }
        self.stringState.unicodeEscapeValue = 0
      }
      return
    }

    guard let currentStringPath else {
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
      if self.stringState.isEscaping {
        reducer[keyPath: currentStringPath].append("\\")
        self.stringState.isEscaping = false
      } else {
        self.stringState.isEscaping = true
      }

    case self.stringState.stringDelimiter:
      if self.stringState.isEscaping {
        reducer[keyPath: currentStringPath].unicodeScalars.append(Unicode.Scalar(byte))
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
      }
      switch self.stringState.utf8State.consume(byte: byte) {
      case .appendByte:
        if self.stringState.isEscaping {
          self.stringState.appendEscapedCharacter(
            for: byte,
            into: &reducer[keyPath: currentStringPath]
          )
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

  private var canStartHexNumber: Bool {
    self.configuration.syntaxOptions.contains(.hexNumbers)
      && self.numberParsingState.state.hasDigits
      && self.numberParsingState.state.hasLeadingZero
      && self.numberParsingState.state.digitCount == 1
      && !self.numberParsingState.state.hasDot
      && !self.numberParsingState.state.hasExponent
  }

  private func leadingZeroErrorReason(for digit: UInt8) -> JSONStreamParsingError.Reason? {
    let state = self.numberParsingState.state
    if !state.hasLeadingZero { return nil }
    if state.hasDot { return nil }
    if state.hasExponent { return nil }
    if self.configuration.syntaxOptions.contains(.leadingZeros) { return nil }
    if self.configuration.syntaxOptions.contains(.hexNumbers) && state.digitCount == 1 && digit == 0
    {
      return .invalidNumber
    }
    return .leadingZero
  }

  private mutating func parseInteger(byte: UInt8, into reducer: inout Value) throws {
    if byte == .asciiDot {
      guard self.numberParsingState.state.hasDigits else {
        throw JSONStreamParsingError(
          reason: .invalidNumber,
          position: self.position,
          context: .number
        )
      }
      self.mode = .fractionalDouble
      self.numberParsingState.state.hasDot = true
      try self.numberParsingState.appendDigit(byte, position: self.position)
      if let numberPath = self.currentNumberPath {
        guard
          reducer[keyPath: numberPath]
            .parseDigits(
              buffer: self.numberParsingState.digitBuffer,
              isHex: false
            )
        else {
          throw JSONStreamParsingError(
            reason: .numericOverflow,
            position: self.position,
            context: .number
          )
        }
      }
    } else if byte == .asciiLowerX || byte == .asciiUpperX {
      guard self.canStartHexNumber else {
        throw JSONStreamParsingError(
          reason: .invalidNumber,
          position: self.position,
          context: .number
        )
      }
      self.mode = .hexInteger
      self.numberParsingState.state.isHex = true
      self.numberParsingState.state.hasHexDigits = false
    } else if byte == .asciiLowerE || byte == .asciiUpperE {
      self.mode = .exponentialDouble
      guard self.numberParsingState.state.hasDigits else {
        throw JSONStreamParsingError(
          reason: .invalidNumber,
          position: self.position,
          context: .number
        )
      }
      self.numberParsingState.state.hasExponent = true
      self.numberParsingState.state.hasExponentDigits = false
      try self.numberParsingState.appendDigit(byte, position: self.position)
    } else {
      guard let digit = byte.digitValue else {
        try self.finalizeNumberOrThrow(at: self.position, into: &reducer)
        return try self.parseNeutral(byte: byte, into: &reducer)
      }
      if let reason = self.leadingZeroErrorReason(for: digit) {
        throw JSONStreamParsingError(
          reason: reason,
          position: self.position,
          context: .number
        )
      }
      if !self.numberParsingState.state.hasDigits {
        self.numberParsingState.state.hasDigits = true
        if digit == 0 {
          self.numberParsingState.state.hasLeadingZero = true
        }
      }
      self.numberParsingState.state.digitCount += 1
      try self.numberParsingState.appendDigit(byte, position: self.position)
      if let numberPath = self.currentNumberPath {
        guard
          reducer[keyPath: numberPath]
            .parseDigits(
              buffer: self.numberParsingState.digitBuffer,
              isHex: false
            )
        else {
          throw JSONStreamParsingError(
            reason: .numericOverflow,
            position: self.position,
            context: .number
          )
        }
      }
    }
  }
  private mutating func parseHexInteger(byte: UInt8, into reducer: inout Value) throws {
    guard byte.hexValue != nil else {
      if !self.numberParsingState.state.hasHexDigits {
        throw JSONStreamParsingError(
          reason: .invalidNumber,
          position: self.position,
          context: .number
        )
      }
      try self.finalizeNumberOrThrow(at: self.position, into: &reducer)
      return try self.parseNeutral(byte: byte, into: &reducer)
    }
    self.numberParsingState.state.hasHexDigits = true
    try self.numberParsingState.appendDigit(byte, position: self.position)
  }
  private mutating func parseExponentialDouble(byte: UInt8, into reducer: inout Value) throws {
    if byte == .asciiDash {
      if self.numberParsingState.state.hasExponentDigits {
        throw JSONStreamParsingError(
          reason: .invalidExponent,
          position: self.position,
          context: .number
        )
      }
      self.numberParsingState.isNegativeExponent = true
      try self.numberParsingState.appendDigit(byte, position: self.position)
    } else if byte == .asciiPlus {
      if self.numberParsingState.state.hasExponentDigits {
        throw JSONStreamParsingError(
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
        throw JSONStreamParsingError(
          reason: .numericOverflow,
          position: self.position,
          context: .number
        )
      }
      self.numberParsingState.exponent = newExponent
      try self.numberParsingState.appendDigit(byte, position: self.position)
    } else {
      try self.finalizeNumberOrThrow(at: self.position, into: &reducer)
      try self.parseNeutral(byte: byte, into: &reducer)
    }
  }

  private mutating func parseFractionalDouble(byte: UInt8, into reducer: inout Value) throws {
    guard byte.digitValue != nil else {
      if byte == .asciiLowerE || byte == .asciiUpperE {
        guard self.numberParsingState.state.hasFractionDigits else {
          throw JSONStreamParsingError(
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
      try self.finalizeNumberOrThrow(at: self.position, into: &reducer)
      return try self.parseNeutral(byte: byte, into: &reducer)
    }
    if !self.numberParsingState.state.hasDigits {
      self.numberParsingState.state.hasDigits = true
    }
    self.numberParsingState.state.hasFractionDigits = true
    try self.numberParsingState.appendDigit(byte, position: self.position)
    if let numberPath = self.currentNumberPath {
      guard
        reducer[keyPath: numberPath]
          .parseDigits(
            buffer: self.numberParsingState.digitBuffer,
            isHex: false
          )
      else {
        throw JSONStreamParsingError(
          reason: .numericOverflow,
          position: self.position,
          context: .number
        )
      }
    }
  }
  private mutating func parseCommentStart(byte: UInt8, into reducer: inout Value) throws {
    switch byte {
    case .asciiSlash:
      self.commentState.begin(kind: .line)
      self.mode = .comment
    case .asciiAsterisk:
      self.commentState.begin(kind: .block)
      self.mode = .comment
    default:
      throw JSONStreamParsingError(
        reason: .unexpectedToken,
        position: self.position,
        context: .neutral
      )
    }
  }

  private mutating func parseComment(byte: UInt8, into reducer: inout Value) throws {
    switch self.commentState.kind {
    case .line:
      if byte == .asciiLineFeed || byte == .asciiCarriageReturn {
        self.mode = self.commentState.returnMode
      }
    case .block:
      if self.commentState.sawAsterisk && byte == .asciiSlash {
        self.mode = self.commentState.returnMode
        self.commentState.sawAsterisk = false
      } else {
        self.commentState.sawAsterisk = byte == .asciiAsterisk
      }
    }
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

  private mutating func applyNonFiniteNumber(
    _ value: Double,
    at position: JSONStreamParsingPosition,
    path: WritableKeyPath<Value, JSONNumberAccumulator>,
    into reducer: inout Value
  ) throws {
    var accumulator = reducer[keyPath: path]
    switch accumulator {
    case .float:
      accumulator = .float(Float(value))
    case .double:
      accumulator = .double(value)
    default:
      throw JSONStreamParsingError(
        reason: .invalidNumber,
        position: position,
        context: .number
      )
    }
    reducer[keyPath: path] = accumulator
  }

  private mutating func finalizeNumberOrThrow(
    at position: JSONStreamParsingPosition,
    into reducer: inout Value
  ) throws {
    if self.numberParsingState.state.isHex {
      if !self.numberParsingState.state.hasHexDigits {
        throw JSONStreamParsingError(
          reason: .invalidNumber,
          position: position,
          context: .number
        )
      }
      if let numberPath = self.currentNumberPath {
        guard
          reducer[keyPath: numberPath]
            .parseDigits(
              buffer: self.numberParsingState.digitBuffer,
              isHex: true
            )
        else {
          throw JSONStreamParsingError(
            reason: .numericOverflow,
            position: position,
            context: .number
          )
        }
      }
      self.mode = .neutral
      self.numberParsingState.resetAfterFinalize()
      return
    }
    if !self.numberParsingState.state.hasDigits {
      throw JSONStreamParsingError(
        reason: .invalidNumber,
        position: position,
        context: .number
      )
    }
    if self.numberParsingState.state.hasDot && !self.numberParsingState.state.hasFractionDigits {
      throw JSONStreamParsingError(
        reason: .invalidNumber,
        position: position,
        context: .number
      )
    }
    if self.numberParsingState.isMissingExponentDigits {
      throw JSONStreamParsingError(
        reason: .invalidExponent,
        position: position,
        context: .number
      )
    }
    if let numberPath = self.currentNumberPath {
      guard
        reducer[keyPath: numberPath]
          .parseDigits(
            buffer: self.numberParsingState.digitBuffer,
            isHex: self.numberParsingState.state.isHex
          )
      else {
        throw JSONStreamParsingError(
          reason: .numericOverflow,
          position: position,
          context: .number
        )
      }
    }
    self.mode = .neutral
    self.numberParsingState.resetAfterFinalize()
  }

}

extension JSONStreamParser {
  private struct StringParsingState {
    var buffer = ""
    var isEscaping = false
    var utf8State = UTF8State()
    var isCollectingKey = false
    var isAwaitingKeySeparator = false
    var isCollectingUnquotedKey = false
    var stringDelimiter: UInt8 = .asciiQuote
    var keyDelimiter: UInt8 = .asciiQuote
    var unicodeEscapeRemaining = 0
    var unicodeEscapeValue: UInt32 = 0

    mutating func startString(delimiter: UInt8) {
      self.stringDelimiter = delimiter
      self.buffer = ""
      self.resetEscapeState()
    }

    mutating func startKey(delimiter: UInt8, initial: String, isUnquoted: Bool) {
      self.keyDelimiter = delimiter
      self.buffer = initial
      self.isCollectingKey = true
      self.isCollectingUnquotedKey = isUnquoted
      self.isAwaitingKeySeparator = false
      self.resetEscapeState()
    }

    mutating func resetKeyCollection() {
      self.buffer = ""
      self.isCollectingKey = false
      self.isAwaitingKeySeparator = false
      self.isCollectingUnquotedKey = false
      self.resetEscapeState()
    }

    mutating func finishKeyCollection() {
      self.isCollectingKey = false
      self.isAwaitingKeySeparator = false
      self.isCollectingUnquotedKey = false
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
}

extension JSONStreamParser {
  private struct NumberParsingState {
    var isNegative = false
    var isNegativeExponent = false
    var exponent = 0
    var state = NumberState()
    var digitBuffer = DigitBuffer()

    var isMissingExponentDigits: Bool {
      self.state.hasExponent && !self.state.hasExponentDigits
    }

    mutating func appendDigit(_ byte: UInt8, position: JSONStreamParsingPosition) throws {
      let index = self.digitBuffer.count
      guard index < 64 else {
        throw JSONStreamParsingError(
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

    mutating func resetForInteger(isNegative: Bool) {
      self.isNegative = isNegative
      self.isNegativeExponent = false
      self.exponent = 0
      self.digitBuffer.count = 0
      self.state.reset()
    }

    mutating func resetForFractionalLeadingDot(position: JSONStreamParsingPosition) throws {
      self.resetForInteger(isNegative: false)
      self.state.hasDot = true
      try self.appendDigit(.asciiZero, position: position)
      try self.appendDigit(.asciiDot, position: position)
    }

    mutating func resetAfterFinalize() {
      self.exponent = 0
      self.isNegativeExponent = false
      self.digitBuffer.count = 0
      self.state.reset()
    }
  }
}

extension JSONStreamParser {
  private struct ContainerState {
    var stack = [StackElement]()
    var arrayDepth = 0
    var objectDepth = 0
    var arrayTrailingCommaDepths = BitVector()
    var arrayExpectingValueDepths = BitVector()
    var arrayHasValueDepths = BitVector()
    var objectTrailingCommaDepths = BitVector()
    var objectValuePendingDepths = BitVector()

    var isArrayContextAtTop: Bool {
      guard self.arrayDepth > 0 else { return false }
      if case .array = self.stack.last {
        return true
      }
      return false
    }

    mutating func startArray() {
      self.arrayDepth += 1
      self.arrayExpectingValueDepths.insert(self.arrayDepth)
      self.arrayHasValueDepths.remove(self.arrayDepth)
      self.arrayTrailingCommaDepths.remove(self.arrayDepth)
      self.stack.append(.array(index: 0))
    }

    mutating func finishArray() {
      self.arrayTrailingCommaDepths.remove(self.arrayDepth)
      self.arrayExpectingValueDepths.remove(self.arrayDepth)
      self.arrayHasValueDepths.remove(self.arrayDepth)
      self.arrayDepth -= 1
      self.stack.removeLast()
    }

    mutating func startObject() {
      self.objectDepth += 1
    }

    mutating func finishObject() {
      self.objectTrailingCommaDepths.remove(self.objectDepth)
      self.objectDepth -= 1
    }

    mutating func markArrayTrailingComma() {
      guard self.arrayDepth > 0 else { return }
      self.arrayTrailingCommaDepths.insert(self.arrayDepth)
    }

    mutating func clearArrayTrailingCommaIfNeeded() {
      guard self.arrayDepth > 0 else { return }
      self.arrayTrailingCommaDepths.remove(self.arrayDepth)
    }

    mutating func markObjectTrailingCommaIfNeeded() {
      guard self.objectDepth > 0 else { return }
      self.objectTrailingCommaDepths.insert(self.objectDepth)
    }

    func isArrayExpectingValueOrTrailingComma(at depth: Int) -> Bool {
      self.arrayExpectingValueDepths.contains(depth)
        || self.arrayTrailingCommaDepths.contains(depth)
    }

    func isArrayTrailingCommaAfterValue(at depth: Int) -> Bool {
      self.arrayExpectingValueDepths.contains(depth) && self.arrayHasValueDepths.contains(depth)
    }
  }
}

extension JSONStreamParser {
  private struct CommentState {
    var kind = CommentKind.line
    var returnMode = Mode.neutral
    var sawAsterisk = false

    mutating func begin(kind: CommentKind) {
      self.kind = kind
      self.sawAsterisk = false
    }
  }
}

extension StreamParser {
  /// Creates a ``JSONStreamParser``.
  ///
  /// - Parameter configuration: The ``JSONStreamParserConfiguration`` to use.
  public static func json<Reducer>(
    configuration: JSONStreamParserConfiguration = JSONStreamParserConfiguration()
  ) -> Self where Self == JSONStreamParser<Reducer> {
    JSONStreamParser(configuration: configuration)
  }
}

// MARK: - Configuration

/// Controls the syntax rules and key decoding used by ``JSONStreamParser``.
public struct JSONStreamParserConfiguration: Sendable {
  /// Flags that extend or relax strict JSON syntax.
  public struct SyntaxOptions: OptionSet, Sendable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
      self.rawValue = rawValue
    }

    /// Supports `//` and `/* */` comment syntax inside JSON.
    public static let comments = SyntaxOptions(rawValue: 1 << 0)

    /// Allows trailing commas in arrays and objects.
    public static let trailingCommas = SyntaxOptions(rawValue: 1 << 1)

    /// Permits unquoted object keys.
    public static let unquotedKeys = SyntaxOptions(rawValue: 1 << 2)

    /// Accepts single-quoted strings alongside double-quoted ones.
    public static let singleQuotedStrings = SyntaxOptions(rawValue: 1 << 3)

    /// Allows numbers to start with `+`.
    public static let leadingPlus = SyntaxOptions(rawValue: 1 << 4)

    /// Permits leading zeros before integers.
    public static let leadingZeros = SyntaxOptions(rawValue: 1 << 5)

    /// Parses JSON literals such as `Infinity` and `NaN`.
    public static let nonFiniteNumbers = SyntaxOptions(rawValue: 1 << 6)

    /// Allows control characters inside strings when escaped.
    public static let controlCharactersInStrings = SyntaxOptions(rawValue: 1 << 7)

    /// Accepts hexadecimal numeric literals.
    public static let hexNumbers = SyntaxOptions(rawValue: 1 << 8)

    /// Allows numbers that begin with a decimal point (e.g. `.5`).
    public static let leadingDecimalPoint = SyntaxOptions(rawValue: 1 << 9)
  }

  /// The syntax features enabled during parsing.
  public var syntaxOptions: SyntaxOptions

  /// Strategy used to translate JSON object keys to the keys registered in the handlers.
  public var keyDecodingStrategy: JSONKeyDecodingStrategy

  /// Creates a configuration.
  ///
  /// - Parameters:
  ///   - syntaxOptions: Syntax relaxations to enable while parsing.
  ///   - keyDecodingStrategy: Strategy used to transform JSON keys before handler lookup.
  public init(
    syntaxOptions: SyntaxOptions = [],
    keyDecodingStrategy: JSONKeyDecodingStrategy = JSONKeyDecodingStrategy.useDefault
  ) {
    self.syntaxOptions = syntaxOptions
    self.keyDecodingStrategy = keyDecodingStrategy
  }

}

// MARK: - JSONStreamParsingError

/// The current line and column while parsing JSON.
public struct JSONStreamParsingPosition: Hashable, Sendable {
  /// 1-based line number in the parsed stream.
  public var line: Int

  /// 1-based column number in the parsed stream.
  public var column: Int

  /// Creates a position.
  ///
  /// - Parameters:
  ///   - line: The 1-based line number in the stream.
  ///   - column: The 1-based column number in the stream.
  public init(line: Int, column: Int) {
    self.line = line
    self.column = column
  }
}

/// Represents a JSON parsing failure, its location, and context.
public struct JSONStreamParsingError: Error, Hashable, Sendable {
  public enum Reason: Hashable, Sendable {
    /// Encountered an unexpected token for the current parser mode.
    case unexpectedToken

    /// The parser found a comma without a following value.
    case missingValue

    /// An object key was not followed by a colon.
    case missingColon

    /// A trailing comma was detected where it is forbidden.
    case trailingComma

    /// A comma was missing between array or object entries.
    case missingComma

    /// A quoted string was not terminated.
    case unterminatedString

    /// A Unicode escape sequence was invalid.
    case invalidUnicodeEscape

    /// A literal (true/false/null) was malformed.
    case invalidLiteral

    /// A numeric literal could not be parsed.
    case invalidNumber

    /// A numeric literal overflowed.
    case numericOverflow

    /// A number started with an illegal leading zero.
    case leadingZero

    /// The exponent portion of a number was invalid.
    case invalidExponent

    /// A closing brace `}` was missing.
    case missingClosingBrace

    /// A closing bracket `]` was missing.
    case missingClosingBracket

    /// A value had an incompatible type.
    case invalidType
  }

  /// Optional parsing context used to describe where an error occurred.
  public enum Context: Hashable, Sendable {
    /// Neutral parsing context outside of any container.
    case neutral

    /// While decoding an object key.
    case objectKey

    /// While decoding an object value.
    case objectValue

    /// While decoding an array value.
    case arrayValue

    /// While decoding a string.
    case string

    /// While decoding a number.
    case number

    /// While decoding a JSON literal (`true`, `false`, `null`, etc.).
    case literal
  }

  /// Reason the parser failed.
  public var reason: Reason

  /// Position where the failure occurred.
  public var position: JSONStreamParsingPosition

  /// Optional context for the reason.
  public var context: Context?

  /// Initializes the error with a reason, position, and optional context.
  ///
  /// - Parameters:
  ///   - reason: Why parsing failed.
  ///   - position: Where in the stream the failure occurred.
  ///   - context: Optional contextual information about the failure.
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

/// Controls how object keys from JSON map to Swift property names.
public enum JSONKeyDecodingStrategy: Sendable {
  /// Converts snake_case JSON keys to camelCase Swift names.
  case convertFromSnakeCase

  /// Leaves keys untouched.
  case useDefault

  /// Provides a custom transformation closure.
  case custom(@Sendable (String) -> String)

  /// Applies the selected strategy to transform the provided key.
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

  enum Children {
    case none
    case array(PathTrie)
    case object(keys: [String: PathTrie], any: PathTrie?)
  }

  var paths = Paths()
  var children: Children = .none
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

  func prefixed<Root: StreamParseableValue>(
    by prefix: WritableKeyPath<Root, Value>
  ) -> PathTrie<Root> {
    let prefixedPaths = PathTrie<Root>
      .Paths(
        string: self.paths.string.map { prefix.appending(path: $0) },
        bool: self.paths.bool.map { prefix.appending(path: $0) },
        number: self.paths.number.map { prefix.appending(path: $0) },
        nullable: self.paths.nullable.map { prefix.appending(path: $0) },
        array: self.paths.array.map { prefix.appending(path: $0) },
        dictionary: self.paths.dictionary.map { prefix.appending(path: $0) }
      )
    let node = PathTrie<Root>(paths: prefixedPaths)
    switch self.children {
    case .none:
      break
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
    case .none:
      break
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

  func arrayChildNode() -> PathTrie<Value>? {
    if case .array(let child) = self.children {
      return child
    }
    return nil
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
    if case .array(let child) = self.children {
      return child
    }
    let child = PathTrie<Value>()
    self.children = .array(child)
    return child
  }

  @discardableResult
  func ensureObjectChild(for key: String) -> PathTrie<Value> {
    if case .object(var keys, let any) = self.children {
      if let child = keys[key] {
        return child
      }
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
      if let any {
        return any
      }
      let child = PathTrie<Value>()
      self.children = .object(keys: keys, any: child)
      return child
    }
    let child = PathTrie<Value>()
    self.children = .object(keys: [:], any: child)
    return child
  }
}

// MARK: - Handlers

extension JSONStreamParser {
  public struct Handlers: StreamParserHandlers {
    fileprivate var pathTrie = PathTrie<Value>()

    private let configuration: JSONStreamParserConfiguration

    fileprivate var hasAnyHandler: Bool {
      self.pathTrie.hasAnyHandler
    }

    init(configuration: JSONStreamParserConfiguration) {
      self.configuration = configuration
    }

    fileprivate func arrayPath(
      node: PathTrie<Value>?
    ) -> (WritableKeyPath<Value, any StreamParseableArrayObject>?, Bool) {
      guard let node else { return (nil, false) }
      let path = node.paths.array
      let isInvalidType = path == nil && node.hasAnyHandler
      return (path, isInvalidType)
    }

    fileprivate func dictionaryPath(
      node: PathTrie<Value>?
    ) -> (WritableKeyPath<Value, any StreamParseableDictionaryObject>?, Bool) {
      guard let node else { return (nil, false) }
      let path = node.paths.dictionary
      let isInvalidType = path == nil && node.hasAnyHandler && !node.expectsObject
      return (path, isInvalidType)
    }

    fileprivate func numberPath(
      node: PathTrie<Value>?
    ) -> (WritableKeyPath<Value, JSONNumberAccumulator>?, Bool) {
      guard let node else { return (nil, false) }
      let path = node.paths.number
      let isInvalidType = path == nil && node.hasAnyHandler
      return (path, isInvalidType)
    }

    fileprivate func stringPath(
      node: PathTrie<Value>?
    ) -> (WritableKeyPath<Value, String>?, Bool) {
      guard let node else { return (nil, false) }
      let path = node.paths.string
      let isInvalidType = path == nil && node.hasAnyHandler
      return (path, isInvalidType)
    }

    fileprivate func nullablePath(
      node: PathTrie<Value>?
    ) -> (WritableKeyPath<Value, Void?>?, Bool) {
      guard let node else { return (nil, false) }
      let path = node.paths.nullable
      let isInvalidType = path == nil && node.hasAnyHandler
      return (path, isInvalidType)
    }

    fileprivate func booleanPath(
      node: PathTrie<Value>?
    ) -> (WritableKeyPath<Value, Bool>?, Bool) {
      guard let node else { return (nil, false) }
      let path = node.paths.bool
      let isInvalidType = path == nil && node.hasAnyHandler
      return (path, isInvalidType)
    }

    public mutating func registerStringHandler(_ keyPath: WritableKeyPath<Value, String>) {
      self.pathTrie.paths.string = keyPath
    }

    public mutating func registerBoolHandler(_ keyPath: WritableKeyPath<Value, Bool>) {
      self.pathTrie.paths.bool = keyPath
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
      var keyedHandlers = JSONStreamParser<Keyed>.Handlers(configuration: self.configuration)
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
      var handlers = JSONStreamParser<Scoped>.Handlers(configuration: self.configuration)
      type.registerHandlers(in: &handlers)
      let prefixedTrie = handlers.pathTrie.prefixed(by: keyPath)
      self.pathTrie.merge(from: prefixedTrie)
    }

    public mutating func registerArrayHandler<ArrayObject: StreamParseableArrayObject>(
      _ keyPath: WritableKeyPath<Value, ArrayObject>
    ) {
      self.pathTrie.paths.array = keyPath.appending(path: \.erasedJSONPath)

      var elementHandlers = JSONStreamParser<ArrayObject.Element>
        .Handlers(configuration: self.configuration)
      ArrayObject.Element.registerHandlers(in: &elementHandlers)

      let arrayNode = self.pathTrie.ensureArrayChild()
      let elementPrefix = keyPath.appending(path: \.currentElement)
      let prefixedTrie = elementHandlers.pathTrie.prefixed(by: elementPrefix)
      arrayNode.merge(from: prefixedTrie)
    }

    public mutating func registerDictionaryHandler<
      DictionaryObject: StreamParseableDictionaryObject
    >(_ keyPath: WritableKeyPath<Value, DictionaryObject>) {
      self.pathTrie.paths.dictionary = keyPath.appending(path: \.erasedJSONPath)

      var valueHandlers = JSONStreamParser<DictionaryObject.Value>
        .Handlers(configuration: self.configuration)
      DictionaryObject.Value.registerHandlers(in: &valueHandlers)

      let anyNode = self.pathTrie.ensureAnyObjectChild()
      anyNode.dynamicKeyBuilder = { key in
        let valuePrefix = keyPath.appending(path: \.[unwrapped: key])
        return valueHandlers.pathTrie.prefixed(by: valuePrefix)
      }
    }

    @available(StreamParsing128BitIntegers, *)
    public mutating func registerInt128Handler(_ keyPath: WritableKeyPath<Value, Int128>) {
      self.pathTrie.paths.number = keyPath.appending(path: \.erasedAccumulator)
    }

    @available(StreamParsing128BitIntegers, *)
    public mutating func registerUInt128Handler(_ keyPath: WritableKeyPath<Value, UInt128>) {
      self.pathTrie.paths.number = keyPath.appending(path: \.erasedAccumulator)
    }
  }
}

extension UInt8 {
  fileprivate var isLetter: Bool {
    switch self {
    case 0x41...0x5A, 0x61...0x7A: true
    default: false
    }
  }

  fileprivate var isAlphaNumeric: Bool {
    self.isLetter || self.digitValue != nil
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

  mutating func parseDigits(
    buffer: DigitBuffer,
    isHex: Bool
  ) -> Bool {
    switch self {
    case .int:
      guard let value: Int = parseInteger(buffer: buffer, isHex: isHex, as: Int.self) else { return false }
      self = .int(value)
    case .int8:
      guard let value: Int8 = parseInteger(buffer: buffer, isHex: isHex, as: Int8.self) else { return false }
      self = .int8(value)
    case .int16:
      guard let value: Int16 = parseInteger(buffer: buffer, isHex: isHex, as: Int16.self) else { return false }
      self = .int16(value)
    case .int32:
      guard let value: Int32 = parseInteger(buffer: buffer, isHex: isHex, as: Int32.self) else { return false }
      self = .int32(value)
    case .int64:
      guard let value: Int64 = parseInteger(buffer: buffer, isHex: isHex, as: Int64.self) else { return false }
      self = .int64(value)
    case .int128:
      guard #available(StreamParsing128BitIntegers, *) else { return true }
      guard let value = parseInt128(buffer: buffer, isHex: isHex) else { return false }
      self = .int128(low: value._low, high: value._high)
    case .uint:
      guard let value: UInt = parseInteger(buffer: buffer, isHex: isHex, as: UInt.self) else { return false }
      self = .uint(value)
    case .uint8:
      guard let value: UInt8 = parseInteger(buffer: buffer, isHex: isHex, as: UInt8.self) else { return false }
      self = .uint8(value)
    case .uint16:
      guard let value: UInt16 = parseInteger(buffer: buffer, isHex: isHex, as: UInt16.self) else { return false }
      self = .uint16(value)
    case .uint32:
      guard let value: UInt32 = parseInteger(buffer: buffer, isHex: isHex, as: UInt32.self) else { return false }
      self = .uint32(value)
    case .uint64:
      guard let value: UInt64 = parseInteger(buffer: buffer, isHex: isHex, as: UInt64.self) else { return false }
      self = .uint64(value)
    case .uint128:
      guard #available(StreamParsing128BitIntegers, *) else { return true }
      guard let value = parseUInt128(buffer: buffer, isHex: isHex) else { return false }
      self = .uint128(low: value._low, high: value._high)
    case .float:
      guard let value: Float = parseFloatingPoint(buffer: buffer, as: Float.self) else { return false }
      self = .float(value)
    case .double:
      guard let value: Double = parseFloatingPoint(buffer: buffer, as: Double.self) else { return false }
      self = .double(value)
    }
    return true
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
  var digitCount = 0
  var isHex = false
  var hasHexDigits = false

  mutating func reset() {
    self = NumberState()
  }
}

// MARK: - LiteralState

private struct LiteralState {
  var expected = [UInt8]()
  var index = 0
}

private enum CommentKind {
  case line
  case block
}

private let jsonLiteralTrue: [UInt8] = Array("true".utf8)
private let jsonLiteralFalse: [UInt8] = Array("false".utf8)
private let jsonLiteralNull: [UInt8] = Array("null".utf8)
private let jsonLiteralInfinity: [UInt8] = Array("Infinity".utf8)
private let jsonLiteralNaN: [UInt8] = Array("NaN".utf8)
