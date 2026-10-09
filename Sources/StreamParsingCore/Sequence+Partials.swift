extension Sequence where Element == UInt8 {
  /// Incrementally parses bytes as a value.
  ///
  /// ```swift
  /// let partials = try bytes.partials(of: MyModel.self, from: .json())
  /// print(partials.last)
  /// ```
  ///
  /// A partial type is itself parseable, so `MyModel.Partial.self` works too.
  ///
  /// - Parameters:
  ///   - type: The value type to collect partials for.
  ///   - format: The format describing the parser that produces the value states.
  /// - Returns: The partials observed after each byte and at completion.
  public func partials<Parseable: StreamParseable>(
    of type: Parseable.Type,
    from format: JSONStreamFormat
  ) throws -> [Parseable.Partial] {
    try self.collectPartials(from: PartialsStream<Parseable>(from: format))
  }

  /// Incrementally parses bytes as a value.
  ///
  /// - Parameters:
  ///   - initialValue: The partial to begin parsing from.
  ///   - format: The format describing the parser that feeds the bytes.
  /// - Returns: The partials observed after each byte and at completion.
  public func partials<Value: StreamParseable>(
    initialValue: Value,
    from format: JSONStreamFormat
  ) throws -> [Value] where Value.Partial == Value {
    try self.collectPartials(from: PartialsStream(initialValue: initialValue, from: format))
  }

  private func collectPartials<Value: StreamParseable>(
    from stream: consuming PartialsStream<Value>
  ) throws -> [Value.Partial] {
    var partials = [Value.Partial]()
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
  /// - Returns: The partials observed after each collection and at completion.
  public func partials<Parseable: StreamParseable>(
    of type: Parseable.Type,
    from format: JSONStreamFormat
  ) throws -> [Parseable.Partial] {
    try self.collectPartials(from: PartialsStream<Parseable>(from: format))
  }

  /// Incrementally parses chunks of bytes as a value.
  ///
  /// - Parameters:
  ///   - initialValue: The partial to resume parsing from.
  ///   - format: The format describing the parser that consumes each collection.
  /// - Returns: The partials observed after each collection and at completion.
  public func partials<Value: StreamParseable>(
    initialValue: Value,
    from format: JSONStreamFormat
  ) throws -> [Value] where Value.Partial == Value {
    try self.collectPartials(from: PartialsStream(initialValue: initialValue, from: format))
  }

  private func collectPartials<Value: StreamParseable>(
    from stream: consuming PartialsStream<Value>
  ) throws -> [Value.Partial] {
    var partials = [Value.Partial]()
    for bytes in self {
      try stream.next(bytes)
      partials.append(stream.current)
    }
    try partials.append(stream.finish())
    return partials
  }
}
