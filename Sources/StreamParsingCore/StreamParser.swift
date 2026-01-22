// MARK: - StreamParser

/// Consumes bytes and applies them to a parsed value.
public protocol StreamParser<Value> {
  /// The value type that the parser emits and updates.
  associatedtype Value: StreamParseableValue

  /// The handler set used to map parsed values into `Value`.
  associatedtype Handlers: StreamParserHandlers<Value>

  /// Parses the supplied bytes and updates `value`.
  mutating func parse(bytes: some Sequence<UInt8>, into reducer: inout Value) throws

  /// Finalizes parsing, validating that the stream ended in an acceptable state.
  mutating func finish(reducer: inout Value) throws

  /// Registers handler mappings for the associated value.
  mutating func registerHandlers()
}

// MARK: - StreamParserHandlers

/// Allows callers to register how values map to writable key paths on the parsed value.
public protocol StreamParserHandlers<Value> {
  /// The value that the handlers are populated from.
  associatedtype Value: StreamParseableValue

  /// Handles string values and writes them through the supplied key path.
  mutating func registerStringHandler(
    _ keyPath: WritableKeyPath<Value, String>
  )

  /// Handles boolean values.
  mutating func registerBoolHandler(
    _ keyPath: WritableKeyPath<Value, Bool>
  )

  /// Handles signed integer values.
  mutating func registerIntHandler(
    _ keyPath: WritableKeyPath<Value, Int>
  )

  /// Handles signed 8-bit integer values.
  mutating func registerInt8Handler(
    _ keyPath: WritableKeyPath<Value, Int8>
  )

  /// Handles signed 16-bit integer values.
  mutating func registerInt16Handler(
    _ keyPath: WritableKeyPath<Value, Int16>
  )

  /// Handles signed 32-bit integer values.
  mutating func registerInt32Handler(
    _ keyPath: WritableKeyPath<Value, Int32>
  )

  /// Handles signed 64-bit integer values.
  mutating func registerInt64Handler(
    _ keyPath: WritableKeyPath<Value, Int64>
  )

  /// Handles 128-bit signed integer values.
  @available(StreamParsing128BitIntegers, *)
  mutating func registerInt128Handler(
    _ keyPath: WritableKeyPath<Value, Int128>
  )

  /// Handles unsigned integer values.
  mutating func registerUIntHandler(
    _ keyPath: WritableKeyPath<Value, UInt>
  )

  /// Handles unsigned 8-bit integer values.
  mutating func registerUInt8Handler(
    _ keyPath: WritableKeyPath<Value, UInt8>
  )

  /// Handles unsigned 16-bit integer values.
  mutating func registerUInt16Handler(
    _ keyPath: WritableKeyPath<Value, UInt16>
  )

  /// Handles unsigned 32-bit integer values.
  mutating func registerUInt32Handler(
    _ keyPath: WritableKeyPath<Value, UInt32>
  )

  /// Handles unsigned 64-bit integer values.
  mutating func registerUInt64Handler(
    _ keyPath: WritableKeyPath<Value, UInt64>
  )

  /// Handles 128-bit unsigned integer values.
  @available(StreamParsing128BitIntegers, *)
  mutating func registerUInt128Handler(
    _ keyPath: WritableKeyPath<Value, UInt128>
  )

  /// Handles floating-point values parsed as `Float`.
  mutating func registerFloatHandler(
    _ keyPath: WritableKeyPath<Value, Float>
  )

  /// Handles floating-point values parsed as `Double`.
  mutating func registerDoubleHandler(
    _ keyPath: WritableKeyPath<Value, Double>
  )

  /// Handles `null` literals when the value stores optional properties.
  mutating func registerNilHandler<Nullable: StreamParseableValue>(
    _ keyPath: WritableKeyPath<Value, Nullable?>
  )

  /// Registers a sub-object that appears under a specific key name.
  mutating func registerKeyedHandler<Keyed: StreamParseableValue>(
    forKey key: String,
    _ keyPath: WritableKeyPath<Value, Keyed>
  )

  /// Registers a scoped value that is stored at another key path while sharing the same handlers.
  mutating func registerScopedHandlers<Scoped: StreamParseableValue>(
    on type: Scoped.Type,
    _ keyPath: WritableKeyPath<Value, Scoped>
  )

  /// Allows nested arrays to capture each parsed element.
  mutating func registerArrayHandler(
    _ keyPath: WritableKeyPath<Value, some StreamParseableArrayObject>
  )

  /// Allows nested dictionaries to capture members by key.
  mutating func registerDictionaryHandler(
    _ keyPath: WritableKeyPath<Value, some StreamParseableDictionaryObject>
  )
}

extension StreamParserHandlers {
  public mutating func registerStringHandler(
    _ keyPath: WritableKeyPath<Value, String>
  ) {
    missingHandlerImplementation()
  }

  public mutating func registerBoolHandler(
    _ keyPath: WritableKeyPath<Value, Bool>
  ) {
    missingHandlerImplementation()
  }

  public mutating func registerIntHandler(
    _ keyPath: WritableKeyPath<Value, Int>
  ) {
    missingHandlerImplementation()
  }

  public mutating func registerInt8Handler(
    _ keyPath: WritableKeyPath<Value, Int8>
  ) {
    missingHandlerImplementation()
  }

  public mutating func registerInt16Handler(
    _ keyPath: WritableKeyPath<Value, Int16>
  ) {
    missingHandlerImplementation()
  }

  public mutating func registerInt32Handler(
    _ keyPath: WritableKeyPath<Value, Int32>
  ) {
    missingHandlerImplementation()
  }

  public mutating func registerInt64Handler(
    _ keyPath: WritableKeyPath<Value, Int64>
  ) {
    missingHandlerImplementation()
  }

  @available(StreamParsing128BitIntegers, *)
  public mutating func registerInt128Handler(
    _ keyPath: WritableKeyPath<Value, Int128>
  ) {
    missingHandlerImplementation()
  }

  public mutating func registerUIntHandler(
    _ keyPath: WritableKeyPath<Value, UInt>
  ) {
    missingHandlerImplementation()
  }

  public mutating func registerUInt8Handler(
    _ keyPath: WritableKeyPath<Value, UInt8>
  ) {
    missingHandlerImplementation()
  }

  public mutating func registerUInt16Handler(
    _ keyPath: WritableKeyPath<Value, UInt16>
  ) {
    missingHandlerImplementation()
  }

  public mutating func registerUInt32Handler(
    _ keyPath: WritableKeyPath<Value, UInt32>
  ) {
    missingHandlerImplementation()
  }

  public mutating func registerUInt64Handler(
    _ keyPath: WritableKeyPath<Value, UInt64>
  ) {
    missingHandlerImplementation()
  }

  @available(StreamParsing128BitIntegers, *)
  public mutating func registerUInt128Handler(
    _ keyPath: WritableKeyPath<Value, UInt128>
  ) {
    missingHandlerImplementation()
  }

  public mutating func registerFloatHandler(
    _ keyPath: WritableKeyPath<Value, Float>
  ) {
    missingHandlerImplementation()
  }

  public mutating func registerDoubleHandler(
    _ keyPath: WritableKeyPath<Value, Double>
  ) {
    missingHandlerImplementation()
  }

  public mutating func registerNilHandler<Nullable: StreamParseableValue>(
    _ keyPath: WritableKeyPath<Value, Nullable?>
  ) {
    missingHandlerImplementation()
  }

  public mutating func registerKeyedHandler<Keyed: StreamParseableValue>(
    forKey key: String,
    _ keyPath: WritableKeyPath<Value, Keyed>
  ) {
    missingHandlerImplementation()
  }

  public mutating func registerScopedHandlers<Scoped: StreamParseableValue>(
    on type: Scoped.Type,
    _ keyPath: WritableKeyPath<Value, Scoped>
  ) {
    missingHandlerImplementation()
  }

  public mutating func registerArrayHandler(
    _ keyPath: WritableKeyPath<Value, some StreamParseableArrayObject>
  ) {
    missingHandlerImplementation()
  }

  public mutating func registerDictionaryHandler(
    _ keyPath: WritableKeyPath<Value, some StreamParseableDictionaryObject>
  ) {
    missingHandlerImplementation()
  }
}

private func missingHandlerImplementation(function: String = #function) -> Never {
  fatalError("\(function) is not supported")
}
