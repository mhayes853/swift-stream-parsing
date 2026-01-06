// MARK: - StreamParser

public protocol StreamParser<Value> {
  associatedtype Value: StreamParseableValue
  associatedtype Handlers: StreamParserHandlers<Value>

  mutating func parse(bytes: some Sequence<UInt8>, into reducer: inout Value) throws
  mutating func registerHandlers()
}

// MARK: - StreamParserHandlers

public protocol StreamParserHandlers<Value> {
  associatedtype Value: StreamParseableValue

  mutating func registerStringHandler(
    _ keyPath: WritableKeyPath<Value, String>
  )
  mutating func registerBoolHandler(
    _ keyPath: WritableKeyPath<Value, Bool>
  )
  mutating func registerIntHandler(
    _ keyPath: WritableKeyPath<Value, Int>
  )
  mutating func registerInt8Handler(
    _ keyPath: WritableKeyPath<Value, Int8>
  )
  mutating func registerInt16Handler(
    _ keyPath: WritableKeyPath<Value, Int16>
  )
  mutating func registerInt32Handler(
    _ keyPath: WritableKeyPath<Value, Int32>
  )
  mutating func registerInt64Handler(
    _ keyPath: WritableKeyPath<Value, Int64>
  )
  @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
  mutating func registerInt128Handler(
    _ keyPath: WritableKeyPath<Value, Int128>
  )
  mutating func registerUIntHandler(
    _ keyPath: WritableKeyPath<Value, UInt>
  )
  mutating func registerUInt8Handler(
    _ keyPath: WritableKeyPath<Value, UInt8>
  )
  mutating func registerUInt16Handler(
    _ keyPath: WritableKeyPath<Value, UInt16>
  )
  mutating func registerUInt32Handler(
    _ keyPath: WritableKeyPath<Value, UInt32>
  )
  mutating func registerUInt64Handler(
    _ keyPath: WritableKeyPath<Value, UInt64>
  )
  @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
  mutating func registerUInt128Handler(
    _ keyPath: WritableKeyPath<Value, UInt128>
  )
  mutating func registerFloatHandler(
    _ keyPath: WritableKeyPath<Value, Float>
  )
  mutating func registerDoubleHandler(
    _ keyPath: WritableKeyPath<Value, Double>
  )

  mutating func registerNilHandler<Nullable: StreamParseableValue>(
    _ keyPath: WritableKeyPath<Value, Nullable?>
  )

  mutating func registerKeyedHandler<Keyed: StreamParseableValue>(
    forKey key: String,
    _ keyPath: WritableKeyPath<Value, Keyed>
  )

  mutating func registerScopedHandlers<Scoped: StreamParseableValue>(
    on type: Scoped.Type,
    _ keyPath: WritableKeyPath<Value, Scoped>
  )

  mutating func registerArrayHandler(
    _ keyPath: WritableKeyPath<Value, some StreamParseableArrayObject>
  )

  mutating func registerDictionaryHandler(
    _ keyPath: WritableKeyPath<Value, some StreamParseableDictionaryObject>
  )
}
