// MARK: - String

extension String: StreamActionReducer {
  public typealias StreamAction = DefaultStreamParserAction

  public mutating func reduce(action: DefaultStreamParserAction) throws {
    self = try action.standardLibraryValue(as: String.self)
  }
}

// MARK: - Double

extension Double: StreamActionReducer {
  public typealias StreamAction = DefaultStreamParserAction

  public mutating func reduce(action: DefaultStreamParserAction) throws {
    self = try action.standardLibraryValue(as: Double.self)
  }
}

// MARK: - Float

extension Float: StreamActionReducer {
  public typealias StreamAction = DefaultStreamParserAction

  public mutating func reduce(action: DefaultStreamParserAction) throws {
    self = try action.standardLibraryValue(as: Float.self)
  }
}

// MARK: - Bool

extension Bool: StreamActionReducer {
  public typealias StreamAction = DefaultStreamParserAction

  public mutating func reduce(action: DefaultStreamParserAction) throws {
    self = try action.standardLibraryValue(as: Bool.self)
  }
}

// MARK: - Int8

extension Int8: StreamActionReducer {
  public typealias StreamAction = DefaultStreamParserAction

  public mutating func reduce(action: DefaultStreamParserAction) throws {
    self = try action.standardLibraryValue(as: Int8.self)
  }
}

// MARK: - Int16

extension Int16: StreamActionReducer {
  public typealias StreamAction = DefaultStreamParserAction

  public mutating func reduce(action: DefaultStreamParserAction) throws {
    self = try action.standardLibraryValue(as: Int16.self)
  }
}

// MARK: - Int32

extension Int32: StreamActionReducer {
  public typealias StreamAction = DefaultStreamParserAction

  public mutating func reduce(action: DefaultStreamParserAction) throws {
    self = try action.standardLibraryValue(as: Int32.self)
  }
}

// MARK: - Int64

extension Int64: StreamActionReducer {
  public typealias StreamAction = DefaultStreamParserAction

  public mutating func reduce(action: DefaultStreamParserAction) throws {
    self = try action.standardLibraryValue(as: Int64.self)
  }
}

// MARK: - Int

extension Int: StreamActionReducer {
  public typealias StreamAction = DefaultStreamParserAction

  public mutating func reduce(action: DefaultStreamParserAction) throws {
    self = try action.standardLibraryValue(as: Int.self)
  }
}

// MARK: - UInt8

extension UInt8: StreamActionReducer {
  public typealias StreamAction = DefaultStreamParserAction

  public mutating func reduce(action: DefaultStreamParserAction) throws {
    self = try action.standardLibraryValue(as: UInt8.self)
  }
}

// MARK: - UInt16

extension UInt16: StreamActionReducer {
  public typealias StreamAction = DefaultStreamParserAction

  public mutating func reduce(action: DefaultStreamParserAction) throws {
    self = try action.standardLibraryValue(as: UInt16.self)
  }
}

// MARK: - UInt32

extension UInt32: StreamActionReducer {
  public typealias StreamAction = DefaultStreamParserAction

  public mutating func reduce(action: DefaultStreamParserAction) throws {
    self = try action.standardLibraryValue(as: UInt32.self)
  }
}

// MARK: - UInt64

extension UInt64: StreamActionReducer {
  public typealias StreamAction = DefaultStreamParserAction

  public mutating func reduce(action: DefaultStreamParserAction) throws {
    self = try action.standardLibraryValue(as: UInt64.self)
  }
}

// MARK: - UInt

extension UInt: StreamActionReducer {
  public typealias StreamAction = DefaultStreamParserAction

  public mutating func reduce(action: DefaultStreamParserAction) throws {
    self = try action.standardLibraryValue(as: UInt.self)
  }
}

// MARK: - Int128

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
extension Int128: StreamActionReducer {
  public typealias StreamAction = DefaultStreamParserAction

  public mutating func reduce(action: DefaultStreamParserAction) throws {
    self = try action.standardLibraryValue(as: Int128.self)
  }
}

// MARK: - UInt128

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
extension UInt128: StreamActionReducer {
  public typealias StreamAction = DefaultStreamParserAction

  public mutating func reduce(action: DefaultStreamParserAction) throws {
    self = try action.standardLibraryValue(as: UInt128.self)
  }
}

// MARK: - Optional

extension Optional: StreamActionReducer
where Wrapped: StreamActionReducer, Wrapped.StreamAction == DefaultStreamParserAction {
  public typealias StreamAction = DefaultStreamParserAction

  public mutating func reduce(action: DefaultStreamParserAction) throws {
    switch action {
    case .setValue(let value):
      if case .null = value {
        self = nil
        return
      }
      if var wrapped = self {
        try wrapped.reduce(action: action)
        self = wrapped
        return
      }
      guard let value = value.standardLibraryValue(as: Wrapped.self) else {
        throw StandardLibraryStreamActionReducerError.typeMismatch(
          expected: String(describing: Wrapped.self),
          actual: value
        )
      }
      self = value
    default:
      guard var wrapped = self else {
        throw StandardLibraryStreamActionReducerError.unsupportedAction(action)
      }
      try wrapped.reduce(action: action)
      self = wrapped
    }
  }
}

// MARK: - Helpers

private enum StandardLibraryStreamActionReducerError: Error {
  case unsupportedAction(DefaultStreamParserAction)
  case typeMismatch(expected: String, actual: StreamedValue)
}

extension DefaultStreamParserAction {
  fileprivate func standardLibraryValue<T>(as type: T.Type) throws -> T {
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
  fileprivate func standardLibraryValue<T>(as type: T.Type) -> T? {
    switch self {
    case .string(let value):
      return value as? T
    case .double(let value):
      return value as? T
    case .float(let value):
      return value as? T
    case .boolean(let value):
      return value as? T
    case .int8(let value):
      return value as? T
    case .int16(let value):
      return value as? T
    case .int32(let value):
      return value as? T
    case .int64(let value):
      return value as? T
    case .int(let value):
      return value as? T
    case .uint8(let value):
      return value as? T
    case .uint16(let value):
      return value as? T
    case .uint32(let value):
      return value as? T
    case .uint64(let value):
      return value as? T
    case .uint(let value):
      return value as? T
    case .int128(let high, let low):
      if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) {
        let value = Int128(_low: low, _high: high)
        return value as? T
      }
      return nil
    case .uint128(let high, let low):
      if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) {
        let value = UInt128(_low: low, _high: high)
        return value as? T
      }
      return nil
    case .null:
      return nil
    }
  }
}
