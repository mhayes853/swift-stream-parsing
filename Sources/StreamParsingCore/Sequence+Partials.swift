extension Sequence where Element == UInt8 {
  public func partials<Value: StreamParseableValue, Parser: StreamParser<Value>>(
    initialValue: Value = .initialParseableValue(),
    from parser: Parser
  ) throws -> [Value] {
    var partials = [Value]()
    var stream = PartialsStream(initialValue: initialValue, from: parser)
    for byte in self {
      try partials.append(stream.next(byte))
    }
    return partials
  }
}

extension Sequence where Element: Sequence<UInt8> {
  public func partials<Value: StreamParseableValue, Parser: StreamParser<Value>>(
    initialValue: Value = .initialParseableValue(),
    from parser: Parser
  ) throws -> [Value] {
    var partials = [Value]()
    var stream = PartialsStream(initialValue: initialValue, from: parser)
    for bytes in self {
      try partials.append(stream.next(bytes))
    }
    return partials
  }
}
