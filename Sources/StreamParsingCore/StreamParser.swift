public protocol StreamParser<Reducer> {
  associatedtype Reducer: StreamParseableReducer

  mutating func parse(bytes: some Sequence<UInt8>, into reducer: inout Reducer) throws

  mutating func registerStringHandler(
    _ handler: @escaping (inout Reducer, String) -> Void
  )
  mutating func registerBoolHandler(
    _ handler: @escaping (inout Reducer, Bool) -> Void
  )
  mutating func registerIntHandler(
    _ handler: @escaping (inout Reducer, Int) -> Void
  )
  mutating func registerInt8Handler(
    _ handler: @escaping (inout Reducer, Int8) -> Void
  )
  mutating func registerInt16Handler(
    _ handler: @escaping (inout Reducer, Int16) -> Void
  )
  mutating func registerInt32Handler(
    _ handler: @escaping (inout Reducer, Int32) -> Void
  )
  mutating func registerInt64Handler(
    _ handler: @escaping (inout Reducer, Int64) -> Void
  )
  mutating func registerUIntHandler(
    _ handler: @escaping (inout Reducer, UInt) -> Void
  )
  mutating func registerUInt8Handler(
    _ handler: @escaping (inout Reducer, UInt8) -> Void
  )
  mutating func registerUInt16Handler(
    _ handler: @escaping (inout Reducer, UInt16) -> Void
  )
  mutating func registerUInt32Handler(
    _ handler: @escaping (inout Reducer, UInt32) -> Void
  )
  mutating func registerUInt64Handler(
    _ handler: @escaping (inout Reducer, UInt64) -> Void
  )
  mutating func registerFloatHandler(
    _ handler: @escaping (inout Reducer, Float) -> Void
  )
  mutating func registerDoubleHandler(
    _ handler: @escaping (inout Reducer, Double) -> Void
  )
  mutating func registerNilHandler(
    _ handler: @escaping (inout Reducer) -> Void
  )

  @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
  mutating func registerInt128Handler(
    _ handler: @escaping (inout Reducer, Int128) -> Void
  )
  @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
  mutating func registerUInt128Handler(
    _ handler: @escaping (inout Reducer, UInt128) -> Void
  )

  mutating func registerArrayHandler<Element: StreamParseableReducer>(
    for type: Element.Type,
    _ handler: @escaping (inout Reducer, Element, Int) -> Void
  )
  mutating func registerHandlers<Element: StreamParseableReducer>(
    forKey key: String,
    on type: Element.Type,
    _ handler: @escaping (inout Reducer, Element) -> Void
  )
}

extension StreamParser {
  public mutating func registerStringHandler(
    _ handler: @escaping (inout Reducer, String) -> Void
  ) {}
  public mutating func registerBoolHandler(
    _ handler: @escaping (inout Reducer, Bool) -> Void
  ) {}
  public mutating func registerIntHandler(
    _ handler: @escaping (inout Reducer, Int) -> Void
  ) {}
  public mutating func registerInt8Handler(
    _ handler: @escaping (inout Reducer, Int8) -> Void
  ) {}
  public mutating func registerInt16Handler(
    _ handler: @escaping (inout Reducer, Int16) -> Void
  ) {}
  public mutating func registerInt32Handler(
    _ handler: @escaping (inout Reducer, Int32) -> Void
  ) {}
  public mutating func registerInt64Handler(
    _ handler: @escaping (inout Reducer, Int64) -> Void
  ) {}
  public mutating func registerUIntHandler(
    _ handler: @escaping (inout Reducer, UInt) -> Void
  ) {}
  public mutating func registerUInt8Handler(
    _ handler: @escaping (inout Reducer, UInt8) -> Void
  ) {}
  public mutating func registerUInt16Handler(
    _ handler: @escaping (inout Reducer, UInt16) -> Void
  ) {}
  public mutating func registerUInt32Handler(
    _ handler: @escaping (inout Reducer, UInt32) -> Void
  ) {}
  public mutating func registerUInt64Handler(
    _ handler: @escaping (inout Reducer, UInt64) -> Void
  ) {}
  public mutating func registerFloatHandler(
    _ handler: @escaping (inout Reducer, Float) -> Void
  ) {}
  public mutating func registerDoubleHandler(
    _ handler: @escaping (inout Reducer, Double) -> Void
  ) {}
  public mutating func registerNilHandler(
    _ handler: @escaping (inout Reducer) -> Void
  ) {}

  @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
  public mutating func registerInt128Handler(
    _ handler: @escaping (inout Reducer, Int128) -> Void
  ) {}
  @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
  public mutating func registerUInt128Handler(
    _ handler: @escaping (inout Reducer, UInt128) -> Void
  ) {}

  public mutating func registerArrayHandler<Element: StreamParseableReducer>(
    for type: Element.Type,
    _ handler: @escaping (inout Reducer, Element, Int) -> Void
  ) {}

  public mutating func registerHandlers<Element: StreamParseableReducer>(
    forKey key: String,
    on type: Element.Type,
    _ handler: @escaping (inout Reducer, Element) -> Void
  ) {}
}
