// MARK: - String

extension String: StreamActionReducer {
  public typealias StreamAction = DefaultStreamAction
}

extension String: ConvertibleFromStreamedValue {
  public init?(streamedValue: StreamedValue) {
    guard case .string(let value) = streamedValue else { return nil }
    self = value
  }
}

// MARK: - Double

extension Double: StreamActionReducer {
  public typealias StreamAction = DefaultStreamAction
}

extension Double: ConvertibleFromStreamedValue {}

// MARK: - Float

extension Float: StreamActionReducer {
  public typealias StreamAction = DefaultStreamAction
}

extension Float: ConvertibleFromStreamedValue {}

// MARK: - Bool

extension Bool: StreamActionReducer {
  public typealias StreamAction = DefaultStreamAction
}

extension Bool: ConvertibleFromStreamedValue {
  public init?(streamedValue: StreamedValue) {
    guard case .boolean(let value) = streamedValue else { return nil }
    self = value
  }
}

// MARK: - Int8

extension Int8: StreamActionReducer {
  public typealias StreamAction = DefaultStreamAction
}

extension Int8: ConvertibleFromStreamedValue {}

// MARK: - Int16

extension Int16: StreamActionReducer {
  public typealias StreamAction = DefaultStreamAction
}

extension Int16: ConvertibleFromStreamedValue {}

// MARK: - Int32

extension Int32: StreamActionReducer {
  public typealias StreamAction = DefaultStreamAction
}

extension Int32: ConvertibleFromStreamedValue {}

// MARK: - Int64

extension Int64: StreamActionReducer {
  public typealias StreamAction = DefaultStreamAction
}

extension Int64: ConvertibleFromStreamedValue {}

// MARK: - Int

extension Int: StreamActionReducer {
  public typealias StreamAction = DefaultStreamAction
}

extension Int: ConvertibleFromStreamedValue {}

// MARK: - UInt8

extension UInt8: StreamActionReducer {
  public typealias StreamAction = DefaultStreamAction
}

extension UInt8: ConvertibleFromStreamedValue {}

// MARK: - UInt16

extension UInt16: StreamActionReducer {
  public typealias StreamAction = DefaultStreamAction
}

extension UInt16: ConvertibleFromStreamedValue {}

// MARK: - UInt32

extension UInt32: StreamActionReducer {
  public typealias StreamAction = DefaultStreamAction
}

extension UInt32: ConvertibleFromStreamedValue {}

// MARK: - UInt64

extension UInt64: StreamActionReducer {
  public typealias StreamAction = DefaultStreamAction
}

extension UInt64: ConvertibleFromStreamedValue {}

// MARK: - UInt

extension UInt: StreamActionReducer {
  public typealias StreamAction = DefaultStreamAction
}

extension UInt: ConvertibleFromStreamedValue {}

// MARK: - Int128

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
extension Int128: StreamActionReducer {
  public typealias StreamAction = DefaultStreamAction
}

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
extension Int128: ConvertibleFromStreamedValue {}

// MARK: - UInt128

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
extension UInt128: StreamActionReducer {
  public typealias StreamAction = DefaultStreamAction
}

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
extension UInt128: ConvertibleFromStreamedValue {}

// MARK: - Optional

extension Optional: ConvertibleFromStreamedValue where Wrapped: ConvertibleFromStreamedValue {
  public init?(streamedValue: StreamedValue) {
    switch streamedValue {
    case .null:
      self = nil
    default:
      guard let wrapped = Wrapped(streamedValue: streamedValue) else { return nil }
      self = wrapped
    }
  }
}

// MARK: - RawRepresentable

extension RawRepresentable
where RawValue: StreamActionReducer, RawValue.StreamAction == DefaultStreamAction {
  public typealias StreamAction = DefaultStreamAction

  public mutating func reduce(action: DefaultStreamAction) throws {
    var updatedRawValue = rawValue
    try updatedRawValue.reduce(action: action)
    guard let updatedValue = Self(rawValue: updatedRawValue) else {
      throw DefaultStreamActionReducerError.rawValueInitializationFailed(
        type: String(describing: Self.self),
        rawValue: String(describing: updatedRawValue)
      )
    }
    self = updatedValue
  }
}

extension RawRepresentable where RawValue: ConvertibleFromStreamedValue {
  public init?(streamedValue: StreamedValue) {
    guard let rawValue = RawValue(streamedValue: streamedValue) else {
      return nil
    }
    guard let value = Self(rawValue: rawValue) else {
      return nil
    }
    self = value
  }
}
