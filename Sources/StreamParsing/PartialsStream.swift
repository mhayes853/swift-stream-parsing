public struct PartialsStream<Value: StreamParseable, Parser: StreamParser> {
  private var parser: Parser
  public private(set) var current = Value.Partial()

  public init(of valueType: Value.Type, from parser: Parser) {
    self.parser = parser
  }

  @discardableResult
  public mutating func next(_ byte: UInt8) -> Value.Partial? {
    nil
  }

  @discardableResult
  public mutating func next(_ bytes: some Sequence<UInt8>) -> Value.Partial? {
    nil
  }
}

extension PartialsStream: Sendable
where Value: Sendable, Value.Partial: Sendable, Parser: Sendable {}
