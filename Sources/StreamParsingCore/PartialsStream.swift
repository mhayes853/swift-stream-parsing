// MARK: - PartialsStream

public struct PartialsStream<Value: StreamParseable, Parser: StreamParser>
where Parser.StreamAction == Value.Partial.StreamAction {
  @usableFromInline
  var parser: Parser

  @usableFromInline
  var _current: Value.Partial

  @inlinable
  public var current: Value.Partial {
    self._current
  }

  @inlinable
  public init(initialValue: Value.Partial, from parser: Parser) {
    self.parser = parser
    self._current = initialValue
  }

  @inlinable
  @discardableResult
  public mutating func next(_ byte: UInt8) throws -> Value.Partial {
    try self.next(CollectionOfOne(byte))
  }

  @inlinable
  @discardableResult
  public mutating func next(_ bytes: some Sequence<UInt8>) throws -> Value.Partial {
    try self.parser.parse(bytes: bytes, into: &self._current)
    return self.current
  }
}

extension PartialsStream: Sendable
where Value: Sendable, Value.Partial: Sendable, Parser: Sendable {}

// MARK: - StreamParseable

public protocol StreamParseable {
  associatedtype Partial: StreamActionReducer
}
