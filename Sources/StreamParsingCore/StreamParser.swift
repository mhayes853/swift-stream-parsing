// MARK: - StreamParser

public protocol StreamParser<Reducer> {
  associatedtype Reducer: StreamParseableReducer
  associatedtype Handlers: StreamParserHandlers<Reducer>

  mutating func parse(bytes: some Sequence<UInt8>, into reducer: inout Reducer) throws
  mutating func registerHandlers()
}

extension StreamParser {
  public mutating func registerHandlers() {}
}

// MARK: - StreamParserHandlers

public protocol StreamParserHandlers<Reducer> {
  associatedtype Reducer: StreamParseableReducer

  mutating func registerStringHandler(
    _ keyPath: WritableKeyPath<Reducer, String>
  )
  mutating func registerBoolHandler(
    _ keyPath: WritableKeyPath<Reducer, Bool>
  )
  mutating func registerIntHandler(
    _ keyPath: WritableKeyPath<Reducer, Int>
  )
  mutating func registerInt8Handler(
    _ keyPath: WritableKeyPath<Reducer, Int8>
  )
  mutating func registerInt16Handler(
    _ keyPath: WritableKeyPath<Reducer, Int16>
  )
  mutating func registerInt32Handler(
    _ keyPath: WritableKeyPath<Reducer, Int32>
  )
  mutating func registerInt64Handler(
    _ keyPath: WritableKeyPath<Reducer, Int64>
  )
  @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
  mutating func registerInt128Handler(
    _ keyPath: WritableKeyPath<Reducer, Int128>
  )
  mutating func registerUIntHandler(
    _ keyPath: WritableKeyPath<Reducer, UInt>
  )
  mutating func registerUInt8Handler(
    _ keyPath: WritableKeyPath<Reducer, UInt8>
  )
  mutating func registerUInt16Handler(
    _ keyPath: WritableKeyPath<Reducer, UInt16>
  )
  mutating func registerUInt32Handler(
    _ keyPath: WritableKeyPath<Reducer, UInt32>
  )
  mutating func registerUInt64Handler(
    _ keyPath: WritableKeyPath<Reducer, UInt64>
  )
  @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
  mutating func registerUInt128Handler(
    _ keyPath: WritableKeyPath<Reducer, UInt128>
  )
  mutating func registerFloatHandler(
    _ keyPath: WritableKeyPath<Reducer, Float>
  )
  mutating func registerDoubleHandler(
    _ keyPath: WritableKeyPath<Reducer, Double>
  )

  mutating func registerNilHandler<Value: StreamParseableReducer>(
    _ keyPath: WritableKeyPath<Reducer, Value?>
  )

  mutating func registerScopedHandlers<Scoped: StreamParseableReducer>(
    on type: Scoped.Type,
    _ keyPath: WritableKeyPath<Reducer, Scoped>
  )

  mutating func registerArrayHandler<Collection: RangeReplaceableCollection>(
    _ keyPath: WritableKeyPath<Reducer, Collection>
  ) where Collection.Element: StreamParseableReducer, Collection.Index == Int
}
