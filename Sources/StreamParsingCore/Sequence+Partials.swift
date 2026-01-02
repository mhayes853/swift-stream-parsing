// MARK: - PartialsSequence

extension Sequence where Element == UInt8 {
  public func partials<Value: StreamActionReducer, Parser: StreamParser>(
    initialValue: Value,
    from parser: Parser
  ) throws -> [Value] {
    var stream = PartialsStream(initialValue: TrackingReducer(value: initialValue), from: parser)
    var partials = [Value]()
    var previousCount = stream.current.reduceCount
    for bytes in self {
      let partial = try stream.next(bytes)
      if partial.reduceCount != previousCount {
        partials.append(partial.value)
        previousCount = partial.reduceCount
      }
    }
    return partials
  }
}

extension Sequence where Element: Sequence<UInt8> {
  public func partials<Value: StreamActionReducer, Parser: StreamParser>(
    initialValue: Value,
    from parser: Parser
  ) throws -> [Value] {
    var stream = PartialsStream(initialValue: TrackingReducer(value: initialValue), from: parser)
    var partials = [Value]()
    var previousCount = stream.current.reduceCount
    for bytes in self {
      let partial = try stream.next(bytes)
      if partial.reduceCount != previousCount {
        partials.append(partial.value)
        previousCount = partial.reduceCount
      }
    }
    return partials
  }
}
