// MARK: - String

extension String: StreamParseable {
  public typealias Partial = Self
}

extension String: StreamParseableReducer {}

extension String: ConvertibleFromStreamedValue {
  public init?(streamedValue: StreamedValue) {
    guard case .string(let value) = streamedValue else { return nil }
    self = value
  }
}

// MARK: - Double

extension Double: StreamParseable {
  public typealias Partial = Self
}

extension Double: StreamParseableReducer {}

extension Double: ConvertibleFromStreamedValue {}

// MARK: - Float

extension Float: StreamParseable {
  public typealias Partial = Self
}

extension Float: StreamParseableReducer {}

extension Float: ConvertibleFromStreamedValue {}

// MARK: - Bool

extension Bool: StreamParseable {
  public typealias Partial = Self
}

extension Bool: StreamParseableReducer {}

extension Bool: ConvertibleFromStreamedValue {
  public init?(streamedValue: StreamedValue) {
    guard case .boolean(let value) = streamedValue else { return nil }
    self = value
  }
}

// MARK: - Int8

extension Int8: StreamParseable {
  public typealias Partial = Self
}

extension Int8: StreamParseableReducer {}

extension Int8: ConvertibleFromStreamedValue {}

// MARK: - Int16

extension Int16: StreamParseable {
  public typealias Partial = Self
}

extension Int16: StreamParseableReducer {}

extension Int16: ConvertibleFromStreamedValue {}

// MARK: - Int32

extension Int32: StreamParseable {
  public typealias Partial = Self
}

extension Int32: StreamParseableReducer {}

extension Int32: ConvertibleFromStreamedValue {}

// MARK: - Int64

extension Int64: StreamParseable {
  public typealias Partial = Self
}

extension Int64: StreamParseableReducer {}

extension Int64: ConvertibleFromStreamedValue {}

// MARK: - Int

extension Int: StreamParseable {
  public typealias Partial = Self
}

extension Int: StreamParseableReducer {}

extension Int: ConvertibleFromStreamedValue {}

// MARK: - UInt8

extension UInt8: StreamParseable {
  public typealias Partial = Self
}

extension UInt8: StreamParseableReducer {}

extension UInt8: ConvertibleFromStreamedValue {}

// MARK: - UInt16

extension UInt16: StreamParseable {
  public typealias Partial = Self
}

extension UInt16: StreamParseableReducer {}

extension UInt16: ConvertibleFromStreamedValue {}

// MARK: - UInt32

extension UInt32: StreamParseable {
  public typealias Partial = Self
}

extension UInt32: StreamParseableReducer {}

extension UInt32: ConvertibleFromStreamedValue {}

// MARK: - UInt64

extension UInt64: StreamParseable {
  public typealias Partial = Self
}

extension UInt64: StreamParseableReducer {}

extension UInt64: ConvertibleFromStreamedValue {}

// MARK: - UInt

extension UInt: StreamParseable {
  public typealias Partial = Self
}

extension UInt: StreamParseableReducer {}

extension UInt: ConvertibleFromStreamedValue {}

// MARK: - Int128

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
extension Int128: StreamParseable {
  public typealias Partial = Self
}

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
extension Int128: StreamParseableReducer {}

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
extension Int128: ConvertibleFromStreamedValue {}

// MARK: - UInt128

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
extension UInt128: StreamParseable {
  public typealias Partial = Self
}

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
extension UInt128: StreamParseableReducer {}

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
extension UInt128: ConvertibleFromStreamedValue {}

// MARK: - Array

extension Array: StreamParseable
where Element: StreamParseableReducer {
  public typealias Partial = Self
}

extension Array: StreamActionReducer where Element: StreamParseableReducer {}

extension Array: StreamParseableReducer where Element: StreamParseableReducer {
  public init(action: StreamAction) throws {
    self = []
  }

  public mutating func reduce(action: StreamAction) throws {
    switch action {
    case .delegateUnkeyed(let index, let nestedAction):
      try self[index].reduce(action: nestedAction)
    case .appendArrayElement(let value):
      try self.append(Element(action: .setValue(value)))
    default:
      throw StreamActionReducerError.unsupportedAction(action)
    }
  }
}

// MARK: - Dictionary

extension Dictionary: StreamParseable
where Key == String, Value: StreamParseableReducer {
  public typealias Partial = Self
}

extension Dictionary: StreamActionReducer
where Key == String, Value: StreamParseableReducer {}

extension Dictionary: StreamParseableReducer
where Key == String, Value: StreamParseableReducer {
  public init(action: StreamAction) throws {
    self = [:]
  }

  public mutating func reduce(action: StreamAction) throws {
    switch action {
    case .delegateKeyed(let key, .createObjectValue(let value)):
      self[key] = try Value(action: .setValue(value))
    case .delegateKeyed(let key, let action):
      try self[key]?.reduce(action: action)
    default:
      throw StreamActionReducerError.unsupportedAction(action)
    }
  }
}

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
where RawValue: StreamActionReducer {
  public mutating func reduce(action: StreamAction) throws {
    var updatedRawValue = rawValue
    try updatedRawValue.reduce(action: action)
    guard let updatedValue = Self(rawValue: updatedRawValue) else {
      throw StreamActionReducerError.rawValueInitializationFailed(
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
