extension Sequence where Element == UInt8 {
  /// Incrementally parses bytes as a value.
  ///
  /// ```swift
  /// @StreamParseable
  /// struct MyModel {
  ///   // ...
  /// }
  ///
  /// let partials = try bytes.partials(of: MyModel.self, from: .json())
  /// print(partials.last)
  /// ```
  ///
  /// - Parameters:
  ///   - type: The value type to collect partials for.
  ///   - format: The format describing the parser that produces the value states.
  /// - Returns: The values observed after each byte and at completion.
  public func partials<Value: StreamParseable>(
    of type: Value.Type,
    from format: JSONStreamFormat
  ) throws -> [Value.Partial] {
    try self.partials(initialValue: Value.Partial.streamInitialValue(), from: format)
  }

  /// Incrementally parses bytes as a value.
  ///
  /// ```swift
  /// let partials = try bytes.partials(of: MyModel.Partial.self, from: .json())
  /// print(partials.last)
  /// ```
  ///
  /// - Parameters:
  ///   - type: The value type to collect partials for.
  ///   - format: The format describing the parser that produces the value states.
  /// - Returns: The values observed after each byte and at completion.
  public func partials<Value: StreamParseableRoot>(
    of type: Value.Type,
    from format: JSONStreamFormat
  ) throws -> [Value] {
    try self.partials(initialValue: Value.streamInitialValue(), from: format)
  }

  /// Incrementally parses bytes as a value.
  ///
  /// - Parameters:
  ///   - initialValue: The value state to begin parsing from.
  ///   - format: The format describing the parser that feeds the bytes.
  /// - Returns: The values observed after each byte and at completion.
  public func partials<Value: StreamParseableRoot>(
    initialValue: Value,
    from format: JSONStreamFormat
  ) throws -> [Value] {
    var partials = [Value]()
    var stream = PartialsStream(initialValue: initialValue, from: format)
    for byte in self {
      try stream.next(byte)
      partials.append(stream.current)
    }
    try partials.append(stream.finish())
    return partials
  }
}

extension Sequence where Element: Sequence<UInt8> {
  /// Incrementally parses chunks of bytes as a value.
  ///
  /// ```swift
  /// let partials = try batches.partials(of: MyModel.self, from: .json())
  /// ```
  ///
  /// - Parameters:
  ///   - type: The value type to collect partials for.
  ///   - format: The format describing the parser that produces the value states.
  /// - Returns: The values observed after each collection and at completion.
  public func partials<Value: StreamParseable>(
    of type: Value.Type,
    from format: JSONStreamFormat
  ) throws -> [Value.Partial] {
    try self.partials(initialValue: Value.Partial.streamInitialValue(), from: format)
  }

  /// Incrementally parses chunks of bytes as a value.
  ///
  /// - Parameters:
  ///   - type: The value type being parsed.
  ///   - format: The format describing the parser that consumes the nested sequences.
  /// - Returns: The value states observed after each collection and at completion.
  public func partials<Value: StreamParseableRoot>(
    of type: Value.Type,
    from format: JSONStreamFormat
  ) throws -> [Value] {
    try self.partials(initialValue: Value.streamInitialValue(), from: format)
  }

  /// Incrementally parses chunks of bytes as a value.
  ///
  /// - Parameters:
  ///   - initialValue: The value state to resume parsing from.
  ///   - format: The format describing the parser that consumes each collection.
  /// - Returns: The value states observed after each collection and at completion.
  public func partials<Value: StreamParseableRoot>(
    initialValue: Value,
    from format: JSONStreamFormat
  ) throws -> [Value] {
    var partials = [Value]()
    var stream = PartialsStream(initialValue: initialValue, from: format)
    for bytes in self {
      try stream.next(bytes)
      partials.append(stream.current)
    }
    try partials.append(stream.finish())
    return partials
  }
}
