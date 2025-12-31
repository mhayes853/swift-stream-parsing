// MARK: - PartialsSequence

extension Sequence where Element == UInt8 {
  public func partials<Value: StreamActionReducer, Parser: StreamParser>(
    initialValue: Value,
    from parser: Parser
  ) throws -> [Value] {
    var stream = PartialsStream(initialValue: initialValue, from: parser)
    var partials = [Value]()
    partials.reserveCapacity(self.underestimatedCount)
    for bytes in self {
      partials.append(try stream.next(bytes))
    }
    return partials
  }
}

extension Sequence where Element: Sequence<UInt8> {
  public func partials<Value: StreamActionReducer, Parser: StreamParser>(
    initialValue: Value,
    from parser: Parser
  ) throws -> [Value] {
    var stream = PartialsStream(initialValue: initialValue, from: parser)
    var partials = [Value]()
    partials.reserveCapacity(self.underestimatedCount)
    for bytes in self {
      partials.append(try stream.next(bytes))
    }
    return partials
  }
}
