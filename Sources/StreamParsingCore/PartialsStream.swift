// MARK: - PartialsStream

public struct PartialsStream<Value: StreamParseable, Parser: StreamParser> {
  private var parser: Parser
  public private(set) var current = Value.Partial()

  public init(of valueType: Value.Type, from parser: Parser) {
    self.parser = parser
  }

  @discardableResult
  public mutating func next(_ byte: UInt8) throws -> Value.Partial {
    try self.next(CollectionOfOne(byte))
  }

  @discardableResult
  public mutating func next(_ bytes: some Sequence<UInt8>) throws -> Value.Partial {
    self.current
  }
}

extension PartialsStream: Sendable
where Value: Sendable, Value.Partial: Sendable, Parser: Sendable {}

// MARK: - StreamParseable

public protocol StreamParseable {
  associatedtype Partial: StreamPartial
}

// MARK: - StreamPartial

public protocol StreamPartial {
  init()

  mutating func reduce(action: StreamParserAction) throws
}
