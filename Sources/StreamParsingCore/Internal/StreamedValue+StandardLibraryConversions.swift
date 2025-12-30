enum StandardLibraryStreamActionReducerError: Error {
  case unsupportedAction(DefaultStreamAction)
  case typeMismatch(expected: String, actual: StreamedValue)
  case rawValueInitializationFailed(type: String, rawValue: String)
}

extension DefaultStreamAction {
  func standardLibraryValue<T>(as type: T.Type) throws -> T {
    guard case .setValue(let streamedValue) = self else {
      throw StandardLibraryStreamActionReducerError.unsupportedAction(self)
    }
    guard let value = streamedValue.standardLibraryValue(as: type) else {
      throw StandardLibraryStreamActionReducerError.typeMismatch(
        expected: String(describing: type),
        actual: streamedValue
      )
    }
    return value
  }
}

extension StreamedValue {
  func standardLibraryValue<T>(as type: T.Type) -> T? {
    switch self {
    case .string(let value):
      return value as? T
    case .double(let value):
      return self.doubleValue(from: value, as: type)
    case .float(let value):
      return self.floatValue(from: value, as: type)
    case .boolean(let value):
      return value as? T
    case .int8(let value):
      return self.integerValue(from: value, as: type)
    case .int16(let value):
      return self.integerValue(from: value, as: type)
    case .int32(let value):
      return self.integerValue(from: value, as: type)
    case .int64(let value):
      return self.integerValue(from: value, as: type)
    case .int(let value):
      return self.integerValue(from: value, as: type)
    case .uint8(let value):
      return self.integerValue(from: value, as: type)
    case .uint16(let value):
      return self.integerValue(from: value, as: type)
    case .uint32(let value):
      return self.integerValue(from: value, as: type)
    case .uint64(let value):
      return self.integerValue(from: value, as: type)
    case .uint(let value):
      return self.integerValue(from: value, as: type)
    case .int128(let high, let low):
      if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) {
        let value = Int128(_low: low, _high: high)
        return self.integerValue(from: value, as: type)
      }
      return nil
    case .uint128(let high, let low):
      if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) {
        let value = UInt128(_low: low, _high: high)
        return self.integerValue(from: value, as: type)
      }
      return nil
    case .null:
      return nil
    }
  }

  private func integerValue<T>(from value: some BinaryInteger, as type: T.Type) -> T? {
    guard let type = type as? any BinaryInteger.Type else { return nil }
    return type.init(exactly: value) as! T?
  }

  private func doubleValue<T>(from value: Double, as type: T.Type) -> T? {
    guard let type = type as? any BinaryFloatingPoint.Type else { return nil }
    return type.init(exactly: value) as! T?
  }

  private func floatValue<T>(from value: Float, as type: T.Type) -> T? {
    guard let type = type as? any BinaryFloatingPoint.Type else { return nil }
    return type.init(exactly: value) as! T?
  }
}
