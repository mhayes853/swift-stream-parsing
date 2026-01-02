// MARK: - ConvertibleFromStreamedValue

public protocol ConvertibleFromStreamedValue {
  init?(streamedValue: StreamedValue)
}

// MARK: - StreamActionReducer

extension StreamActionReducer where Self: ConvertibleFromStreamedValue {
  public mutating func reduce(action: StreamAction) throws {
    self = try action.extractedValue(expected: Self.self) { streamedValue in
      Self(streamedValue: streamedValue)
    }
  }
}

extension StreamAction {
  fileprivate func extractedValue<T>(
    expected type: T.Type,
    extractor: (StreamedValue) -> T?
  ) throws -> T {
    guard case .setValue(let streamedValue) = self else {
      throw StreamParsingError.unsupportedAction(self)
    }
    guard let value = extractor(streamedValue) else {
      throw StreamParsingError.invalidValue(streamedValue)
    }
    return value
  }
}

// MARK: - BinaryInteger

extension ConvertibleFromStreamedValue where Self: FixedWidthInteger {
  public init?(streamedValue: StreamedValue) {
    switch streamedValue {
    case .int8(let value):
      guard let value = Self.convert(value) else { return nil }
      self = value
    case .int16(let value):
      guard let value = Self.convert(value) else { return nil }
      self = value
    case .int32(let value):
      guard let value = Self.convert(value) else { return nil }
      self = value
    case .int64(let value):
      guard let value = Self.convert(value) else { return nil }
      self = value
    case .int(let value):
      guard let value = Self.convert(value) else { return nil }
      self = value
    case .uint8(let value):
      guard let value = Self.convert(value) else { return nil }
      self = value
    case .uint16(let value):
      guard let value = Self.convert(value) else { return nil }
      self = value
    case .uint32(let value):
      guard let value = Self.convert(value) else { return nil }
      self = value
    case .uint64(let value):
      guard let value = Self.convert(value) else { return nil }
      self = value
    case .uint(let value):
      guard let value = Self.convert(value) else { return nil }
      self = value
    case .int128(let high, let low):
      if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) {
        let value = Int128(_low: low, _high: high)
        guard let converted = Self.convert(value) else { return nil }
        self = converted
        return
      }
      return nil
    case .uint128(let high, let low):
      if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) {
        let value = UInt128(_low: low, _high: high)
        guard let converted = Self.convert(value) else { return nil }
        self = converted
        return
      }
      return nil
    case .double(let value):
      guard let converted = Self.convert(value) else { return nil }
      self = converted
    case .float(let value):
      guard let converted = Self.convert(value) else { return nil }
      self = converted
    case .string, .boolean, .null:
      return nil
    }
  }

  private static func convert<T: BinaryInteger>(_ value: T) -> Self? {
    if Self.isSigned {
      if value < Self.min || value > Self.max { return nil }
    } else {
      if value < 0 || value > Self.max { return nil }
    }
    return Self(value)
  }

  private static func convert<T: BinaryFloatingPoint>(_ value: T) -> Self? {
    if value.isNaN || value.isInfinite {
      return nil
    }
    let rounded = value.rounded(.towardZero)
    if rounded != value {
      return nil
    }
    let minValue = T(Self.min)
    let maxValue = T(Self.max)
    if value < minValue || value > maxValue {
      return nil
    }
    return Self(value)
  }
}

// MARK: - BinaryFloatingPoint

extension ConvertibleFromStreamedValue where Self: BinaryFloatingPoint {
  private static func convert<T: BinaryFloatingPoint>(_ value: T) -> Self? {
    let converted = Self(value)
    if converted.isInfinite {
      return nil
    }
    return converted
  }

  private static func convert<T: BinaryInteger>(_ value: T) -> Self? {
    let converted = Self(value)
    if converted.isInfinite {
      return nil
    }
    return converted
  }

  public init?(streamedValue: StreamedValue) {
    switch streamedValue {
    case .double(let value):
      if value.isNaN {
        self = .nan
        return
      }
      if value.isInfinite {
        self = value.sign == .minus ? -Self.infinity : Self.infinity
        return
      }
      guard let converted = Self.convert(value) else { return nil }
      self = converted
    case .float(let value):
      if value.isNaN {
        self = .nan
        return
      }
      if value.isInfinite {
        self = value.sign == .minus ? -Self.infinity : Self.infinity
        return
      }
      guard let converted = Self.convert(value) else { return nil }
      self = converted
    case .int8(let value):
      guard let converted = Self.convert(value) else { return nil }
      self = converted
    case .int16(let value):
      guard let converted = Self.convert(value) else { return nil }
      self = converted
    case .int32(let value):
      guard let converted = Self.convert(value) else { return nil }
      self = converted
    case .int64(let value):
      guard let converted = Self.convert(value) else { return nil }
      self = converted
    case .int(let value):
      guard let converted = Self.convert(value) else { return nil }
      self = converted
    case .uint8(let value):
      guard let converted = Self.convert(value) else { return nil }
      self = converted
    case .uint16(let value):
      guard let converted = Self.convert(value) else { return nil }
      self = converted
    case .uint32(let value):
      guard let converted = Self.convert(value) else { return nil }
      self = converted
    case .uint64(let value):
      guard let converted = Self.convert(value) else { return nil }
      self = converted
    case .uint(let value):
      guard let converted = Self.convert(value) else { return nil }
      self = converted
    case .string, .boolean, .int128, .uint128, .null:
      return nil
    }
  }
}
