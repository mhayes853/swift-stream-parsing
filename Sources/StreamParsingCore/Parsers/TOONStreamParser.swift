// MARK: - TOONStreamParser

/// A convenience typealias for ``TOONStreamParser`` that parses a partial of a ``StreamParseable`` type.
public typealias TOONStreamParserOf<
  Parseable: StreamParseable
> = TOONStreamParser<Parseable.Partial>

/// A ``StreamParser`` that parses TOON.
public struct TOONStreamParser<Value: StreamParseableValue>: StreamParser {
  private enum Mode {
    case idle
    case document
    case object
    case array
    case arrayItem
    case syntheticObjectItem
  }

  public let configuration: TOONStreamParserConfiguration

  private var handlers: Handlers
  private var buffer = [UInt8]()
  private var initialReducer: Value?
  private var reducer = Value.initialParseableValue()
  private var lines = [TOONLine]()
  private var index = 0
  private var strict = false
  private var mode = Mode.idle
  private var modeStack = [Mode]()
  private var objectModeStack = [(indent: Int, node: PathTrie<Value>?)]()
  private var currentObjectIndent: Int?
  private var currentObjectNode: PathTrie<Value>?
  private var currentArrayHeader: ArrayHeader?
  private var currentArrayInlineValue: String?
  private var currentArrayIndent: Int?
  private var currentArrayNode: PathTrie<Value>?
  private var currentArrayItemLine: TOONLine?
  private var currentArrayItemNode: PathTrie<Value>?
  private var currentSyntheticContent: String?
  private var currentSyntheticLine: TOONLine?
  private var currentSyntheticNode: PathTrie<Value>?

  public init(configuration: TOONStreamParserConfiguration = TOONStreamParserConfiguration()) {
    self.configuration = configuration
    self.handlers = Handlers(configuration: configuration)
  }

  public mutating func registerHandlers() {
    Value.registerHandlers(in: &self.handlers)
  }

  public mutating func parse(bytes: some Sequence<UInt8>, into reducer: inout Value) throws {
    let appendedBytes = Array(bytes)
    self.buffer.append(contentsOf: appendedBytes)
    if self.initialReducer == nil {
      self.initialReducer = reducer
    }
    guard self.shouldParseIncrementally(appendedBytes) else {
      return
    }
    try self.parseBufferedText(
      decodedIncrementalTOONText(self.buffer),
      strict: false,
      into: &reducer
    )
  }

  public mutating func finish(reducer: inout Value) throws {
    let text =
      String(bytes: self.buffer, encoding: .utf8)
      ?? String(decoding: self.buffer, as: UTF8.self)
    if self.initialReducer == nil {
      self.initialReducer = reducer
    }
    try self.parseBufferedText(text, strict: true, into: &reducer)
  }

  private func shouldParseIncrementally(_ appendedBytes: [UInt8]) -> Bool {
    guard !appendedBytes.isEmpty else { return false }
    if self.buffer.count <= 8 * 1024 {
      return true
    }
    if appendedBytes.count > 1 {
      return true
    }
    return appendedBytes.contains(10) || appendedBytes.contains(13)
  }

  private mutating func parseBufferedText(
    _ text: String,
    strict: Bool,
    into reducer: inout Value
  ) throws {
    self.lines = self.makeLines(from: text)
    self.index = 0
    self.strict = strict
    self.reducer = self.initialReducer ?? reducer
    self.mode = .document
    self.modeStack.removeAll()
    self.objectModeStack.removeAll()
    self.currentObjectIndent = nil
    self.currentObjectNode = nil
    self.currentArrayHeader = nil
    self.currentArrayInlineValue = nil
    self.currentArrayIndent = nil
    self.currentArrayNode = nil
    self.currentArrayItemLine = nil
    self.currentArrayItemNode = nil
    self.currentSyntheticContent = nil
    self.currentSyntheticLine = nil
    self.currentSyntheticNode = nil
    try self.runModes()
    reducer = self.reducer
  }

  private mutating func runModes() throws {
    while let mode = self.nextMode() {
      switch mode {
      case .idle:
        return
      case .document:
        try self.parseDocumentMode()
      case .object:
        try self.parseObjectMode()
      case .array:
        try self.parseArrayMode()
      case .arrayItem:
        try self.parseArrayItemMode()
      case .syntheticObjectItem:
        try self.parseSyntheticObjectItemMode()
      }
    }
  }

  private mutating func nextMode() -> Mode? {
    if self.mode != .idle {
      return self.mode
    }
    guard let nextMode = self.modeStack.popLast() else { return nil }
    if nextMode == .object, let resumeState = self.objectModeStack.popLast() {
      self.currentObjectIndent = resumeState.indent
      self.currentObjectNode = resumeState.node
    }
    self.mode = nextMode
    return nextMode
  }

  private mutating func makeLines(from text: String) -> [TOONLine] {
    let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
    return parts.enumerated()
      .map { index, rawPart in
        var raw = String(rawPart)
        if raw.hasSuffix("\r") {
          raw.removeLast()
        }
        if raw.isEmpty {
          return TOONLine(number: index + 1, indent: 0, content: "", raw: raw)
        }
        let indent = raw.prefix { $0 == " " }.count
        let content = String(raw.dropFirst(indent))
        return TOONLine(number: index + 1, indent: indent, content: content, raw: raw)
      }
  }
}

// MARK: - StreamParser

extension StreamParser {
  public static func toon<Reducer>(
    configuration: TOONStreamParserConfiguration = TOONStreamParserConfiguration()
  ) -> Self where Self == TOONStreamParser<Reducer> {
    TOONStreamParser(configuration: configuration)
  }
}

// MARK: - Configuration

public struct TOONStreamParserConfiguration: Sendable {
  public var keyDecodingStrategy: TOONKeyDecodingStrategy
  public var pathExpansionStrategy: TOONPathExpansionStrategy
  public var indentWidth: Int

  public init(
    keyDecodingStrategy: TOONKeyDecodingStrategy = .useDefault,
    pathExpansionStrategy: TOONPathExpansionStrategy = .useLiteralKeys,
    indentWidth: Int = 2
  ) {
    self.keyDecodingStrategy = keyDecodingStrategy
    self.pathExpansionStrategy = pathExpansionStrategy
    self.indentWidth = indentWidth
  }
}

public enum TOONKeyDecodingStrategy: Sendable {
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

public enum TOONPathExpansionStrategy: Sendable {
  case useLiteralKeys
  case expandSafe
}

// MARK: - Error

public struct TOONStreamParsingPosition: Hashable, Sendable {
  public var line: Int
  public var column: Int

  public init(line: Int, column: Int) {
    self.line = line
    self.column = column
  }
}

public struct TOONStreamParsingError: Error, Hashable, Sendable {
  public enum Reason: Hashable, Sendable {
    case unexpectedToken
    case missingValue
    case missingColon
    case unterminatedString
    case invalidEscape
    case invalidLiteral
    case invalidNumber
    case numericOverflow
    case invalidIndentation
    case invalidArrayHeader
    case invalidArrayItem
    case arrayLengthMismatch
    case tabularWidthMismatch
    case invalidType
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
  public var position: TOONStreamParsingPosition
  public var context: Context?

  public init(
    reason: Reason,
    position: TOONStreamParsingPosition,
    context: Context? = nil
  ) {
    self.reason = reason
    self.position = position
    self.context = context
  }
}

// MARK: - Handlers

extension TOONStreamParser {
  public struct Handlers: StreamParserHandlers {
    fileprivate var pathTrie = PathTrie<Value>()

    private let configuration: TOONStreamParserConfiguration

    init(configuration: TOONStreamParserConfiguration) {
      self.configuration = configuration
    }

    fileprivate func arrayPath(
      node: PathTrie<Value>?
    ) -> (WritableKeyPath<Value, any StreamParseableArrayObject>?, Bool) {
      guard let node else { return (nil, false) }
      return node.path(\.array)
    }

    fileprivate func dictionaryPath(
      node: PathTrie<Value>?
    ) -> (WritableKeyPath<Value, any StreamParseableDictionaryObject>?, Bool) {
      guard let node else { return (nil, false) }
      return node.path(\.dictionary) { $0.hasAnyHandler && !$0.expectsObject }
    }

    fileprivate func numberPath(
      node: PathTrie<Value>?
    ) -> (WritableKeyPath<Value, NumberAccumulator>?, Bool) {
      guard let node else { return (nil, false) }
      return node.path(\.number)
    }

    fileprivate func stringPath(
      node: PathTrie<Value>?
    ) -> (WritableKeyPath<Value, String>?, Bool) {
      guard let node else { return (nil, false) }
      return node.path(\.string)
    }

    fileprivate func nullablePath(
      node: PathTrie<Value>?
    ) -> (WritableKeyPath<Value, Void?>?, Bool) {
      guard let node else { return (nil, false) }
      return node.path(\.nullable)
    }

    fileprivate func booleanPath(
      node: PathTrie<Value>?
    ) -> (WritableKeyPath<Value, Bool>?, Bool) {
      guard let node else { return (nil, false) }
      return node.path(\.bool)
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
      var keyedHandlers = TOONStreamParser<Keyed>.Handlers(configuration: self.configuration)
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
      var handlers = TOONStreamParser<Scoped>.Handlers(configuration: self.configuration)
      type.registerHandlers(in: &handlers)
      self.pathTrie.mergeScopedHandlerTrie(keyPath: keyPath, nestedTrie: handlers.pathTrie)
    }

    public mutating func registerArrayHandler<ArrayObject: StreamParseableArrayObject>(
      _ keyPath: WritableKeyPath<Value, ArrayObject>
    ) {
      var elementHandlers = TOONStreamParser<ArrayObject.Element>
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
      var valueHandlers = TOONStreamParser<DictionaryObject.Value>
        .Handlers(configuration: self.configuration)
      DictionaryObject.Value.registerHandlers(in: &valueHandlers)
      self.pathTrie.registerDictionaryHandlerTrie(
        keyPath: keyPath,
        valueTrie: valueHandlers.pathTrie
      )
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

// MARK: - Helpers

private struct TOONLine {
  let number: Int
  let indent: Int
  let content: String
  let raw: String

  var isBlank: Bool {
    self.content.trimmingCharacters(in: .whitespaces).isEmpty
  }
}

private struct ArrayHeader {
  let key: String?
  let count: Int
  let delimiter: Character
  let fields: [String]?
}

private enum ScalarToken {
  case string(String)
  case bool(Bool)
  case null
  case number(String)
}

extension TOONStreamParser {
  private mutating func parseDocumentMode() throws {
    self.skipBlankLines()
    guard self.index < self.lines.count else {
      self.mode = .idle
      return
    }

    let line = self.lines[self.index]
    if self.shouldParseAsRootPrimitive() && self.rootCanParsePrimitive {
      let position = self.position(for: self.lines[self.index], column: 1)
      if self.strict {
        try self.assignScalar(
          from: self.lines[self.index].content.trimmingCharacters(in: .whitespaces),
          to: self.handlers.pathTrie,
          position: position
        )
      } else {
        try? self.assignScalar(
          from: self.lines[self.index].content.trimmingCharacters(in: .whitespaces),
          to: self.handlers.pathTrie,
          position: position
        )
      }
      self.mode = .idle
      return
    }

    let (rootLHS, rootRHS) = try self.splitField(line)
    if let header = try self.parseArrayHeader(from: rootLHS), header.key == nil {
      self.index += 1
      self.currentArrayHeader = header
      self.currentArrayInlineValue = rootRHS
      self.currentArrayIndent = line.indent
      self.currentArrayNode = self.handlers.pathTrie
      self.mode = .array
      return
    }

    self.currentObjectIndent = line.indent
    self.currentObjectNode = self.handlers.pathTrie
    self.mode = .object
  }

  private mutating func parseObjectMode() throws {
    guard let expectedIndent = self.currentObjectIndent else {
      self.mode = .idle
      return
    }
    let node = self.currentObjectNode
    self.skipBlankLines()
    guard self.index < self.lines.count else {
      self.mode = .idle
      return
    }
    let line = self.lines[self.index]
    guard line.indent >= expectedIndent else {
      self.mode = .idle
      return
    }
    if line.indent != expectedIndent {
      if self.strict {
        throw self.error(.invalidIndentation, at: line, column: 1)
      }
      self.mode = .idle
      return
    }
    if line.content.hasPrefix("- ") {
      self.mode = .idle
      return
    }

    let (lhs, rhs) = try self.splitField(line)
    if let header = try self.parseArrayHeader(from: lhs), let key = header.key {
      let (fieldNode, _) = self.resolveChildNodeInfo(for: key, from: node)
      self.index += 1
      self.objectModeStack.append((expectedIndent, node))
      self.modeStack.append(.object)
      self.currentArrayHeader = ArrayHeader(
        key: key,
        count: header.count,
        delimiter: header.delimiter,
        fields: header.fields
      )
      self.currentArrayInlineValue = rhs
      self.currentArrayIndent = line.indent
      self.currentArrayNode = fieldNode
      self.mode = .array
      return
    }

    let key = try self.parseKey(lhs, line: line)
    let (fieldNode, isDynamicField) = self.resolveChildNodeInfo(for: key, from: node)
    self.index += 1
    if let rhs {
      try self.assignScalar(
        from: rhs,
        to: fieldNode,
        position: self.position(for: line, column: lhs.count + 2)
      )
      self.currentObjectIndent = expectedIndent
      self.currentObjectNode = node
      self.mode = .object
      return
    }

    let childIndent = line.indent + self.configuration.indentWidth
    let nextLine = self.peekNextNonBlankLine()
    guard let nextLine, nextLine.indent >= childIndent else {
      if self.strict
        && self.shouldRequireExplicitValue(for: fieldNode, isDynamicField: isDynamicField)
      {
        throw self.error(.missingValue, at: line, column: line.content.count, context: .objectValue)
      }
      self.currentObjectIndent = expectedIndent
      self.currentObjectNode = node
      self.mode = .object
      return
    }
    self.objectModeStack.append((expectedIndent, node))
    self.modeStack.append(.object)
    self.currentObjectIndent = childIndent
    self.currentObjectNode = fieldNode
    self.mode = .object
  }

  private mutating func parseArrayMode() throws {
    guard let header = self.currentArrayHeader,
      let indent = self.currentArrayIndent
    else {
      self.mode = .idle
      return
    }
    let inlineValue = self.currentArrayInlineValue
    let node = self.currentArrayNode
    try self.parseArray(header: header, inlineValue: inlineValue, atIndent: indent, node: node)
    self.mode = .idle
  }

  private mutating func parseArrayItemMode() throws {
    guard let line = self.currentArrayItemLine else {
      self.mode = .idle
      return
    }
    let node = self.currentArrayItemNode
    try self.parseArrayItem(line, node: node)
    self.mode = .idle
  }

  private mutating func parseSyntheticObjectItemMode() throws {
    guard let content = self.currentSyntheticContent,
      let line = self.currentSyntheticLine
    else {
      self.mode = .idle
      return
    }
    let node = self.currentSyntheticNode
    try self.parseSyntheticObjectItem(content, line: line, node: node)
    self.mode = .idle
  }

  private mutating func parseObjectBlock(
    expectedIndent: Int,
    node: PathTrie<Value>?
  ) throws {
    while self.index < self.lines.count {
      self.skipBlankLines()
      guard self.index < self.lines.count else { return }
      let line = self.lines[self.index]
      guard line.indent >= expectedIndent else { return }
      if line.indent != expectedIndent {
        if self.strict {
          throw self.error(.invalidIndentation, at: line, column: 1)
        }
        return
      }
      if line.content.hasPrefix("- ") {
        return
      }
      try self.parseFieldLine(line, node: node)
    }
  }

  private mutating func parseFieldLine(
    _ line: TOONLine,
    node: PathTrie<Value>?
  ) throws {
    let (lhs, rhs) = try self.splitField(line)
    if let header = try self.parseArrayHeader(from: lhs), let key = header.key {
      let (fieldNode, _) = self.resolveChildNodeInfo(for: key, from: node)
      self.index += 1
      try self.parseArray(
        header: ArrayHeader(
          key: key,
          count: header.count,
          delimiter: header.delimiter,
          fields: header.fields
        ),
        inlineValue: rhs,
        atIndent: line.indent,
        node: fieldNode
      )
      return
    }

    let key = try self.parseKey(lhs, line: line)
    let (fieldNode, isDynamicField) = self.resolveChildNodeInfo(for: key, from: node)
    self.index += 1
    if let rhs {
      try self.assignScalar(
        from: rhs,
        to: fieldNode,
        position: self.position(for: line, column: lhs.count + 2)
      )
      return
    }

    let childIndent = line.indent + self.configuration.indentWidth
    let nextLine = self.peekNextNonBlankLine()
    guard let nextLine, nextLine.indent >= childIndent else {
      if self.strict
        && self.shouldRequireExplicitValue(for: fieldNode, isDynamicField: isDynamicField)
      {
        throw self.error(.missingValue, at: line, column: line.content.count, context: .objectValue)
      }
      return
    }
    try self.parseObjectBlock(expectedIndent: childIndent, node: fieldNode)
  }

  private mutating func parseArray(
    header: ArrayHeader,
    inlineValue: String? = nil,
    atIndent indent: Int,
    node: PathTrie<Value>?
  ) throws {
    let (path, isInvalidType) = self.handlers.arrayPath(node: node)
    if isInvalidType {
      throw self.error(.invalidType, at: self.currentLine, column: 1, context: .arrayValue)
    }
    if let path {
      self.reducer[keyPath: path].reset()
    }

    if let inlineValue {
      let values = try self.splitPrimitiveValues(inlineValue, delimiter: header.delimiter)
      if self.strict && values.count != header.count {
        throw self.error(
          .arrayLengthMismatch,
          at: self.currentLine,
          column: 1,
          context: .arrayValue
        )
      }
      for value in values.prefix(header.count) {
        self.appendArrayElement(at: path)
        try self.assignScalar(
          from: value,
          to: node?.arrayChildNode(),
          position: self.position(for: self.currentLine, column: 1)
        )
      }
      return
    }

    if header.count == 0 {
      return
    }

    let childIndent = indent + self.configuration.indentWidth
    var parsedCount = 0
    if let fields = header.fields {
      while self.index < self.lines.count {
        self.skipBlankLines()
        guard self.index < self.lines.count else { break }
        let line = self.lines[self.index]
        guard line.indent >= childIndent else { break }
        if line.indent != childIndent {
          if self.strict {
            throw self.error(.invalidIndentation, at: line, column: 1)
          }
          break
        }
        let values = try self.splitPrimitiveValues(line.content, delimiter: header.delimiter)
        if self.strict && values.count != fields.count {
          throw self.error(.tabularWidthMismatch, at: line, column: 1, context: .arrayValue)
        }
        self.appendArrayElement(at: path)
        let elementNode = node?.arrayChildNode()
        for (field, value) in zip(fields, values) {
          let fieldNode = self.resolveChildNode(for: field, from: elementNode)
          try self.assignScalar(
            from: value,
            to: fieldNode,
            position: self.position(for: line, column: 1)
          )
        }
        parsedCount += 1
        self.index += 1
      }
    } else {
      while self.index < self.lines.count {
        self.skipBlankLines()
        guard self.index < self.lines.count else { break }
        let line = self.lines[self.index]
        guard line.indent >= childIndent else { break }
        if line.indent != childIndent || !line.content.hasPrefix("- ") {
          if self.strict {
            throw self.error(.invalidArrayItem, at: line, column: 1, context: .arrayValue)
          }
          break
        }
        self.appendArrayElement(at: path)
        self.currentArrayItemLine = line
        self.currentArrayItemNode = node?.arrayChildNode()
        self.mode = .arrayItem
        try self.runModes()
        parsedCount += 1
      }
    }

    if self.strict && parsedCount != header.count {
      throw self.error(.arrayLengthMismatch, at: self.currentLine, column: 1, context: .arrayValue)
    }
  }

  private mutating func parseArrayItem(
    _ line: TOONLine,
    node: PathTrie<Value>?
  ) throws {
    let content = String(line.content.dropFirst(2))
    self.index += 1
    let synthetic = TOONLine(
      number: line.number,
      indent: line.indent,
      content: content,
      raw: content
    )
    let (lhs, rhs) = try self.splitField(synthetic)
    if let header = try self.parseArrayHeader(from: lhs), header.key == nil {
      try self.parseArray(header: header, inlineValue: rhs, atIndent: line.indent, node: node)
      return
    }
    if content.contains(":") {
      try self.parseSyntheticObjectItem(content, line: line, node: node)
      return
    }
    try self.assignScalar(
      from: content,
      to: node,
      position: self.position(for: line, column: 3)
    )
  }

  private mutating func parseSyntheticObjectItem(
    _ content: String,
    line: TOONLine,
    node: PathTrie<Value>?
  ) throws {
    let synthetic = TOONLine(
      number: line.number,
      indent: line.indent + self.configuration.indentWidth,
      content: content,
      raw: content
    )
    try self.parseFieldLine(synthetic, node: node)
    let extraIndent = synthetic.indent + self.configuration.indentWidth
    try self.parseObjectBlock(expectedIndent: extraIndent, node: node)
  }

  private func resolveChildNode(
    for key: String,
    from node: PathTrie<Value>?
  ) -> PathTrie<Value>? {
    self.resolveChildNodeInfo(for: key, from: node).0
  }

  private func resolveChildNodeInfo(
    for key: String,
    from node: PathTrie<Value>?
  ) -> (PathTrie<Value>?, Bool) {
    guard let node else { return (nil, false) }
    let segments = self.keySegments(for: key)
    var current: PathTrie<Value>? = node
    var usedDynamicChild = false
    for segment in segments {
      if case .object(let keys, let any) = current?.children,
        keys[segment] == nil,
        any != nil
      {
        usedDynamicChild = true
      }
      guard let next = current?.objectChildNode(for: segment) else {
        return (nil, usedDynamicChild)
      }
      current = next
    }
    return (current, usedDynamicChild)
  }

  private func keySegments(for key: String) -> [String] {
    switch self.configuration.pathExpansionStrategy {
    case .useLiteralKeys:
      return [self.configuration.keyDecodingStrategy.decode(key: key)]
    case .expandSafe:
      let rawSegments = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
      let areSafe = !rawSegments.isEmpty && rawSegments.allSatisfy(isSafePathSegment)
      guard areSafe else {
        return [self.configuration.keyDecodingStrategy.decode(key: key)]
      }
      return rawSegments.map { self.configuration.keyDecodingStrategy.decode(key: $0) }
    }
  }

  private mutating func assignScalar(
    from token: String,
    to node: PathTrie<Value>?,
    position: TOONStreamParsingPosition
  ) throws {
    guard let scalar = try self.parseScalarToken(token, position: position) else { return }
    switch scalar {
    case .string(let value):
      let (path, isInvalidType) = self.handlers.stringPath(node: node)
      if isInvalidType {
        if !self.strict { return }
        let isQuotedToken = token.trimmingCharacters(in: .whitespaces).first == "\""
        throw TOONStreamParsingError(
          reason: isQuotedToken ? .invalidType : self.invalidScalarReason(for: value, node: node),
          position: position,
          context: self.invalidScalarContext(for: node)
        )
      }
      if let path {
        self.reducer[keyPath: path] = value
      }
    case .bool(let value):
      let (path, isInvalidType) = self.handlers.booleanPath(node: node)
      if isInvalidType {
        if !self.strict { return }
        throw TOONStreamParsingError(reason: .invalidType, position: position, context: .literal)
      }
      if let path {
        self.reducer[keyPath: path] = value
      }
    case .null:
      let (path, isInvalidType) = self.handlers.nullablePath(node: node)
      if isInvalidType {
        if !self.strict { return }
        throw TOONStreamParsingError(reason: .invalidType, position: position, context: .literal)
      }
      if let path {
        self.reducer[keyPath: path] = nil
      }
    case .number(let token):
      let (path, isInvalidType) = self.handlers.numberPath(node: node)
      if isInvalidType {
        if !self.strict { return }
        throw TOONStreamParsingError(reason: .invalidType, position: position, context: .number)
      }
      guard let path else { return }
      var accumulator = self.reducer[keyPath: path]
      accumulator.reset()
      let buffer = try digitBuffer(from: token, position: position)
      guard accumulator.parseDigits(buffer: buffer, isHex: false) else {
        throw TOONStreamParsingError(reason: .numericOverflow, position: position, context: .number)
      }
      self.reducer[keyPath: path] = accumulator
    }
  }

  private func parseScalarToken(
    _ token: String,
    position: TOONStreamParsingPosition
  ) throws -> ScalarToken? {
    let trimmed = token.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else {
      if self.strict {
        throw TOONStreamParsingError(
          reason: .missingValue,
          position: position,
          context: .objectValue
        )
      }
      return nil
    }
    if trimmed.first == "\"" {
      return .string(try self.parseQuotedString(trimmed, position: position))
    }
    switch trimmed {
    case "true": return .bool(true)
    case "false": return .bool(false)
    case "null": return .null
    default: break
    }
    if let number = self.recoverNumberToken(trimmed) {
      return .number(number)
    }
    if !self.strict, looksLikeTOONNumberPrefix(trimmed) {
      return nil
    }
    return .string(trimmed)
  }

  private func parseQuotedString(
    _ token: String,
    position: TOONStreamParsingPosition
  ) throws -> String {
    var result = ""
    var isEscaping = false
    var sawClosingQuote = false
    for character in token.dropFirst() {
      if isEscaping {
        switch character {
        case "\\": result.append("\\")
        case "\"": result.append("\"")
        case "n": result.append("\n")
        case "r": result.append("\r")
        case "t": result.append("\t")
        default:
          if self.strict {
            throw TOONStreamParsingError(
              reason: .invalidEscape,
              position: position,
              context: .string
            )
          }
          return result
        }
        isEscaping = false
        continue
      }
      if character == "\\" {
        isEscaping = true
        continue
      }
      if character == "\"" {
        sawClosingQuote = true
        break
      }
      result.append(character)
    }
    if self.strict && (!sawClosingQuote || isEscaping) {
      throw TOONStreamParsingError(
        reason: .unterminatedString,
        position: position,
        context: .string
      )
    }
    return result
  }

  private func recoverNumberToken(_ token: String) -> String? {
    if !self.strict,
      let exponentIndex = token.firstIndex(where: { $0 == "e" || $0 == "E" }),
      token[token.index(after: exponentIndex)...].first == "+"
        || token[token.index(after: exponentIndex)...].first == "-"
    {
      return String(token[..<exponentIndex])
    }
    var candidate = token
    while !candidate.isEmpty {
      if isValidTOONNumber(candidate) {
        return candidate
      }
      guard !self.strict else { return nil }
      candidate.removeLast()
    }
    return nil
  }

  private func splitField(_ line: TOONLine) throws -> (String, String?) {
    guard let colonIndex = line.content.firstTopLevelColonIndex else {
      if self.strict {
        throw self.error(.missingColon, at: line, column: 1, context: .objectKey)
      }
      return (line.content, nil)
    }
    let lhs = String(line.content[..<colonIndex]).trimmingCharacters(in: .whitespaces)
    let rhsStart = line.content.index(after: colonIndex)
    let rawRHS = String(line.content[rhsStart...])
    let trimmedRHS = rawRHS.hasPrefix(" ") ? String(rawRHS.dropFirst()) : rawRHS
    return (lhs, trimmedRHS.isEmpty ? nil : trimmedRHS)
  }

  private func parseKey(_ token: String, line: TOONLine) throws -> String {
    let trimmed = token.trimmingCharacters(in: .whitespaces)
    if trimmed.first == "\"" {
      return try self.parseQuotedString(trimmed, position: self.position(for: line, column: 1))
    }
    return trimmed
  }

  private func parseArrayHeader(from token: String) throws -> ArrayHeader? {
    let trimmed = token.trimmingCharacters(in: .whitespaces)
    guard let openBracket = trimmed.lastIndex(of: "["),
      let closeBracket = trimmed[openBracket...].firstIndex(of: "]")
    else { return nil }

    let keyPrefix = String(trimmed[..<openBracket])
    let bracketBody = String(trimmed[trimmed.index(after: openBracket)..<closeBracket])
    let suffix = String(trimmed[trimmed.index(after: closeBracket)...])
    guard !bracketBody.isEmpty else { return nil }

    let digits = bracketBody.prefix { $0.isNumber }
    guard let count = Int(digits) else {
      if self.strict {
        throw self.error(.invalidArrayHeader, at: self.currentLine, column: 1)
      }
      return nil
    }
    let delimiter: Character = bracketBody.dropFirst(digits.count).first ?? ","
    var fields: [String]?
    if !suffix.isEmpty {
      guard suffix.first == "{", let closeBrace = suffix.firstIndex(of: "}") else {
        if suffix != ":", self.strict {
          throw self.error(.invalidArrayHeader, at: self.currentLine, column: 1)
        }
        return ArrayHeader(
          key: keyPrefix.isEmpty ? nil : keyPrefix,
          count: count,
          delimiter: delimiter,
          fields: nil
        )
      }
      let fieldBody = String(suffix[suffix.index(after: suffix.startIndex)..<closeBrace])
      fields = self.splitFieldNames(fieldBody, delimiter: delimiter)
    }

    return ArrayHeader(
      key: keyPrefix.isEmpty ? nil : keyPrefix,
      count: count,
      delimiter: delimiter,
      fields: fields
    )
  }

  private func splitFieldNames(_ body: String, delimiter: Character) -> [String] {
    body.split(separator: delimiter).map { String($0) }
  }

  private func splitPrimitiveValues(_ body: String, delimiter: Character) throws -> [String] {
    var values = [String]()
    var current = ""
    var isQuoted = false
    var isEscaping = false
    for character in body {
      if isQuoted {
        current.append(character)
        if isEscaping {
          isEscaping = false
        } else if character == "\\" {
          isEscaping = true
        } else if character == "\"" {
          isQuoted = false
        }
        continue
      }
      if character == "\"" {
        isQuoted = true
        current.append(character)
        continue
      }
      if character == delimiter {
        values.append(current)
        current = ""
        continue
      }
      current.append(character)
    }
    if !current.isEmpty || body.last == delimiter {
      values.append(current)
    }
    return values.map { $0.trimmingCharacters(in: .whitespaces) }
  }

  private mutating func appendArrayElement(
    at path: WritableKeyPath<Value, any StreamParseableArrayObject>?
  ) {
    guard let path else { return }
    self.reducer[keyPath: path].appendNewElement()
  }

  private mutating func skipBlankLines() {
    while self.index < self.lines.count, self.lines[self.index].isBlank {
      self.index += 1
    }
  }

  private func peekNextNonBlankLine() -> TOONLine? {
    var nextIndex = self.index
    while nextIndex < self.lines.count {
      let line = self.lines[nextIndex]
      if !line.isBlank {
        return line
      }
      nextIndex += 1
    }
    return nil
  }

  private func shouldParseAsRootPrimitive() -> Bool {
    let nonBlank = self.lines.filter { !$0.isBlank }
    guard nonBlank.count == 1, let line = nonBlank.first else { return false }
    if line.content.firstTopLevelColonIndex != nil {
      return false
    }
    return true
  }

  private var rootCanParsePrimitive: Bool {
    let node = self.handlers.pathTrie
    let hasPrimitivePath =
      node.paths.string != nil
      || node.paths.bool != nil
      || node.paths.number != nil
      || node.paths.nullable != nil
    let hasContainerPath =
      node.paths.array != nil
      || node.paths.dictionary != nil
      || node.expectsObject
      || node.arrayChildNode() != nil
    return hasPrimitivePath && !hasContainerPath
  }

  private func shouldRequireExplicitValue(
    for node: PathTrie<Value>?,
    isDynamicField: Bool
  ) -> Bool {
    guard let node else { return false }
    if node.paths.array != nil || node.paths.dictionary != nil || node.expectsObject {
      return false
    }
    if node.paths.bool != nil || node.paths.nullable != nil {
      return false
    }
    if isDynamicField {
      return node.paths.number != nil || node.paths.string != nil
    }
    return node.paths.number != nil
  }

  private func invalidScalarReason(
    for token: String,
    node: PathTrie<Value>?
  ) -> TOONStreamParsingError.Reason {
    guard let node else { return .invalidType }
    if node.paths.bool != nil || node.paths.nullable != nil {
      if looksLikeTOONLiteralPrefix(token) {
        return .invalidLiteral
      }
    }
    if node.paths.number != nil {
      if looksLikeTOONNumberPrefix(token) || token == "-" || token.hasSuffix(".") {
        return .invalidNumber
      }
    }
    return .invalidType
  }

  private func invalidScalarContext(
    for node: PathTrie<Value>?
  ) -> TOONStreamParsingError.Context {
    guard let node else { return .neutral }
    if node.paths.number != nil {
      return .number
    }
    if node.paths.bool != nil || node.paths.nullable != nil {
      return .literal
    }
    return .string
  }

  private var currentLine: TOONLine {
    if self.index < self.lines.count {
      return self.lines[self.index]
    }
    return self.lines.last ?? TOONLine(number: 1, indent: 0, content: "", raw: "")
  }

  private func position(for line: TOONLine, column: Int) -> TOONStreamParsingPosition {
    TOONStreamParsingPosition(line: line.number, column: column)
  }

  private func error(
    _ reason: TOONStreamParsingError.Reason,
    at line: TOONLine,
    column: Int,
    context: TOONStreamParsingError.Context? = .neutral
  ) -> TOONStreamParsingError {
    TOONStreamParsingError(
      reason: reason,
      position: self.position(for: line, column: column),
      context: context
    )
  }
}

private func digitBuffer(
  from token: String,
  position: TOONStreamParsingPosition
) throws -> DigitBuffer {
  let bytes = Array(token.utf8)
  guard bytes.count <= 64 else {
    throw TOONStreamParsingError(reason: .numericOverflow, position: position, context: .number)
  }
  var buffer = DigitBuffer()
  buffer.count = bytes.count
  for (index, byte) in bytes.enumerated() {
    withUnsafeMutableBytes(of: &buffer.storage) { storage in
      storage.storeBytes(of: byte, toByteOffset: index, as: UInt8.self)
    }
  }
  return buffer
}

private func decodedIncrementalTOONText(_ bytes: [UInt8]) -> String {
  if let text = String(bytes: bytes, encoding: .utf8) {
    return text
  }
  guard !bytes.isEmpty else { return "" }
  let minimumEndIndex = max(0, bytes.count - 4)
  var endIndex = bytes.count - 1
  while endIndex >= minimumEndIndex {
    if let text = String(bytes: bytes[..<endIndex], encoding: .utf8) {
      return text
    }
    endIndex -= 1
  }
  return ""
}

private func isSafePathSegment(_ value: String) -> Bool {
  guard let first = value.first else { return false }
  guard first == "_" || first.isLetter else { return false }
  return value.dropFirst().allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
}

private func looksLikeTOONLiteralPrefix(_ token: String) -> Bool {
  ["true", "false", "null"].contains { $0.hasPrefix(token) || token.hasPrefix($0) }
}

private func isValidTOONNumber(_ token: String) -> Bool {
  guard !token.isEmpty else { return false }
  var index = token.startIndex
  if token[index] == "-" {
    index = token.index(after: index)
    guard index < token.endIndex else { return false }
  }
  let integerStart = index
  while index < token.endIndex, token[index].isNumber {
    index = token.index(after: index)
  }
  let integerPart = String(token[integerStart..<index])
  guard !integerPart.isEmpty else { return false }
  if integerPart.count > 1, integerPart.first == "0" {
    return false
  }
  if index < token.endIndex, token[index] == "." {
    index = token.index(after: index)
    let fractionStart = index
    while index < token.endIndex, token[index].isNumber {
      index = token.index(after: index)
    }
    guard fractionStart < index else { return false }
  }
  if index < token.endIndex, token[index] == "e" || token[index] == "E" {
    index = token.index(after: index)
    if index < token.endIndex, token[index] == "+" || token[index] == "-" {
      index = token.index(after: index)
    }
    let exponentStart = index
    while index < token.endIndex, token[index].isNumber {
      index = token.index(after: index)
    }
    guard exponentStart < index else { return false }
  }
  return index == token.endIndex
}

private func looksLikeTOONNumberPrefix(_ token: String) -> Bool {
  guard let first = token.first else { return false }
  guard first == "-" || first.isNumber else { return false }
  return token.allSatisfy {
    $0.isNumber || $0 == "-" || $0 == "." || $0 == "e" || $0 == "E" || $0 == "+"
  }
}

extension String {
  fileprivate var firstTopLevelColonIndex: Index? {
    var quotedDelimiter: Character?
    var bracketDepth = 0
    var braceDepth = 0
    var isEscaping = false
    var index = self.startIndex
    while index < self.endIndex {
      let character = self[index]
      if let activeQuote = quotedDelimiter {
        if isEscaping {
          isEscaping = false
        } else if character == "\\" {
          isEscaping = true
        } else if character == activeQuote {
          quotedDelimiter = nil
        }
      } else {
        switch character {
        case "\"": quotedDelimiter = "\""
        case "[": bracketDepth += 1
        case "]": bracketDepth = max(0, bracketDepth - 1)
        case "{": braceDepth += 1
        case "}": braceDepth = max(0, braceDepth - 1)
        case ":" where bracketDepth == 0 && braceDepth == 0:
          return index
        default: break
        }
      }
      index = self.index(after: index)
    }
    return nil
  }
}
