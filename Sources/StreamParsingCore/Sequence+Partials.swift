extension Sequence where Element == UInt8 {
  /// Parses every byte, returning the value state after each input and the final state.
  ///
  /// ```swift
  /// let partials = try bytes.partials(of: MyModel.Partial.self, from: .json())
  /// print(partials.last)
  /// ```
  ///
  /// - Parameters:
  ///   - type: The value type to collect partials for.
  ///   - parser: The parser that produces the value states.
  /// - Returns: An array of value states observed after each input and at completion.
  public func partials<Value: StreamParseableValue, Parser: StreamParser<Value>>(
    of type: Value.Type,
    from parser: Parser
  ) throws -> [Value] {
    try self.partials(initialValue: type.initialParseableValue(), from: parser)
  }

  /// Parses bytes starting from the caller-provided value state.
  ///
  /// - Parameters:
  ///   - initialValue: The value state to begin parsing from.
  ///   - parser: The parser that feeds the bytes.
  /// - Returns: All intermediate and final value states.
  public func partials<Value: StreamParseableValue, Parser: StreamParser<Value>>(
    initialValue: Value,
    from parser: Parser
  ) throws -> [Value] {
    var partials = [Value]()
    var stream = PartialsStream(initialValue: initialValue, from: parser)
    for byte in self {
      try partials.append(stream.next(byte))
    }
    try partials.append(stream.finish())
    return partials
  }
}

extension Sequence where Element: Sequence<UInt8> {
  /// Parses each nested byte collection and returns the partial value states produced.
  ///
  /// ```swift
  /// let partials = try batches.partials(of: MyModel.Partial.self, from: .json())
  /// ```
  ///
  /// - Parameters:
  ///   - type: The value type being parsed.
  ///   - parser: The parser that consumes the nested sequences.
  /// - Returns: An array with the value states observed for each batch.
  public func partials<Value: StreamParseableValue, Parser: StreamParser<Value>>(
    of type: Value.Type,
    from parser: Parser
  ) throws -> [Value] {
    try self.partials(initialValue: type.initialParseableValue(), from: parser)
  }

  /// Parses each collection from the call-site value state.
  ///
  /// - Parameters:
  ///   - initialValue: The value state to resume parsing from.
  ///   - parser: The parser that consumes each collection.
  /// - Returns: The value states observed after each collection and at completion.
  public func partials<Value: StreamParseableValue, Parser: StreamParser<Value>>(
    initialValue: Value,
    from parser: Parser
  ) throws -> [Value] {
    var partials = [Value]()
    var stream = PartialsStream(initialValue: initialValue, from: parser)
    for bytes in self {
      try partials.append(stream.next(bytes))
    }
    try partials.append(stream.finish())
    return partials
  }
}
