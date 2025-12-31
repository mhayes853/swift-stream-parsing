// MARK: - PartialsStream

public struct PartialsStream<Value: StreamActionReducer, Parser: StreamParser>
where Parser.StreamAction == Value.StreamAction {
  @usableFromInline
  var parser: Parser

  @usableFromInline
  var _current: Value

  @inlinable
  public var current: Value {
    self._current
  }

  @inlinable
  public init(initialValue: Value, from parser: Parser) {
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
}

extension PartialsStream: Sendable
where Value: Sendable, Parser: Sendable {}
