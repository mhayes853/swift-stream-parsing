extension Sequence where Element == UInt8 {
  public func partials<Value: StreamParseableValue, Parser: StreamParser<Value>>(
    initialValue: Value,
    from parser: Parser
  ) throws -> [Value] {
    []
  }
}

extension Sequence where Element: Sequence<UInt8> {
  public func partials<Value: StreamParseableValue, Parser: StreamParser<Value>>(
    initialValue: Value,
    from parser: Parser
  ) throws -> [Value] {
    []
  }
}
