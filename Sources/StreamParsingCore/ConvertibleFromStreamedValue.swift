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

extension StreamParseableReducer
where Self: ConvertibleFromStreamedValue {
  public init(action: StreamAction) throws {
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
      throw StreamActionReducerError.unsupportedAction(self)
    }
    guard let value = extractor(streamedValue) else {
      throw StreamActionReducerError.typeMismatch(
        expected: String(describing: type),
        actual: streamedValue
      )
    }
    return value
  }
}

// MARK: - BinaryInteger

extension ConvertibleFromStreamedValue where Self: BinaryInteger {
  public init?(streamedValue: StreamedValue) {
    switch streamedValue {
    case .int8(let value):
      guard let value = Self(exactly: value) else { return nil }
      self = value
    case .int16(let value):
      guard let value = Self(exactly: value) else { return nil }
      self = value
    case .int32(let value):
      guard let value = Self(exactly: value) else { return nil }
      self = value
    case .int64(let value):
      guard let value = Self(exactly: value) else { return nil }
      self = value
    case .int(let value):
      guard let value = Self(exactly: value) else { return nil }
      self = value
    case .uint8(let value):
      guard let value = Self(exactly: value) else { return nil }
      self = value
    case .uint16(let value):
      guard let value = Self(exactly: value) else { return nil }
      self = value
    case .uint32(let value):
      guard let value = Self(exactly: value) else { return nil }
      self = value
    case .uint64(let value):
      guard let value = Self(exactly: value) else { return nil }
      self = value
    case .uint(let value):
      guard let value = Self(exactly: value) else { return nil }
      self = value
    case .int128(let high, let low):
      if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) {
        let value = Int128(_low: low, _high: high)
        guard let converted = Self(exactly: value) else { return nil }
        self = converted
        return
      }
      return nil
    case .uint128(let high, let low):
      if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) {
        let value = UInt128(_low: low, _high: high)
        guard let converted = Self(exactly: value) else { return nil }
        self = converted
        return
      }
      return nil
    case .string, .double, .float, .boolean, .null:
      return nil
    }
  }
}

// MARK: - BinaryFloatingPoint

extension ConvertibleFromStreamedValue where Self: BinaryFloatingPoint {
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
      guard let converted = Self(exactly: value) else { return nil }
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
      guard let converted = Self(exactly: value) else { return nil }
      self = converted
    case .string, .boolean, .int8, .int16, .int32, .int64, .int, .uint8, .uint16, .uint32,
      .uint64, .uint, .int128, .uint128, .null:
      return nil
    }
  }
}
