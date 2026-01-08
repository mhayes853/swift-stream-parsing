// MARK: - PartialsStream

public struct PartialsStream<Value: StreamParseableValue, Parser: StreamParser<Value>> {
  @usableFromInline
  var parser: Parser

  @usableFromInline
  var _current: Value

  @usableFromInline
  var hasFinished = false

  @inlinable
  public var current: Value {
    self._current
  }

  @inlinable
  public init(initialValue: Value = .initialParseableValue(), from parser: Parser) {
    var parser = parser
    parser.registerHandlers()
    self.parser = parser
    self._current = initialValue
  }

  @inlinable
  @discardableResult
  public mutating func next(_ byte: UInt8) throws -> Value {
    try self.next(CollectionOfOne(byte))
  }

  @inlinable
  @discardableResult
  public mutating func next(_ bytes: some Sequence<UInt8>) throws -> Value {
    try self.parser.parse(bytes: bytes, into: &self._current)
    return self.current
  }

  @inlinable
  @discardableResult
  public mutating func finish() throws -> Value {
    guard !self.hasFinished else { throw StreamParsingError.parserFinished }
    self.hasFinished = true
    try self.parser.finish(reducer: &self._current)
    return self.current
  }
}

extension PartialsStream: Sendable
where Value: Sendable, Parser: Sendable {}
