// MARK: - String

extension String: StreamActionReducer {
  public typealias Action = DefaultStreamParserAction

  public mutating func reduce(action: DefaultStreamParserAction) throws {
    self = try reduceToValue(action: action, expectedType: "String") { streamedValue in
      guard case .string(let value) = streamedValue else { return nil }
      return value
    }
  }
}

// MARK: - Double

extension Double: StreamActionReducer {
  public typealias Action = DefaultStreamParserAction

  public mutating func reduce(action: DefaultStreamParserAction) throws {
    self = try reduceToValue(action: action, expectedType: "Double") { streamedValue in
      guard case .double(let value) = streamedValue else { return nil }
      return value
    }
  }
}

// MARK: - Float

extension Float: StreamActionReducer {
  public typealias Action = DefaultStreamParserAction

  public mutating func reduce(action: DefaultStreamParserAction) throws {
    self = try reduceToValue(action: action, expectedType: "Float") { streamedValue in
      guard case .float(let value) = streamedValue else { return nil }
      return value
    }
  }
}

// MARK: - Bool

extension Bool: StreamActionReducer {
  public typealias Action = DefaultStreamParserAction

  public mutating func reduce(action: DefaultStreamParserAction) throws {
    self = try reduceToValue(action: action, expectedType: "Bool") { streamedValue in
      guard case .boolean(let value) = streamedValue else { return nil }
      return value
    }
  }
}

// MARK: - Int8

extension Int8: StreamActionReducer {
  public typealias Action = DefaultStreamParserAction

  public mutating func reduce(action: DefaultStreamParserAction) throws {
    self = try reduceToValue(action: action, expectedType: "Int8") { streamedValue in
      guard case .int8(let value) = streamedValue else { return nil }
      return value
    }
  }
}

// MARK: - Int16

extension Int16: StreamActionReducer {
  public typealias Action = DefaultStreamParserAction

  public mutating func reduce(action: DefaultStreamParserAction) throws {
    self = try reduceToValue(action: action, expectedType: "Int16") { streamedValue in
      guard case .int16(let value) = streamedValue else { return nil }
      return value
    }
  }
}

// MARK: - Int32

extension Int32: StreamActionReducer {
  public typealias Action = DefaultStreamParserAction

  public mutating func reduce(action: DefaultStreamParserAction) throws {
    self = try reduceToValue(action: action, expectedType: "Int32") { streamedValue in
      guard case .int32(let value) = streamedValue else { return nil }
      return value
    }
  }
}

// MARK: - Int64

extension Int64: StreamActionReducer {
  public typealias Action = DefaultStreamParserAction

  public mutating func reduce(action: DefaultStreamParserAction) throws {
    self = try reduceToValue(action: action, expectedType: "Int64") { streamedValue in
      guard case .int64(let value) = streamedValue else { return nil }
      return value
    }
  }
}

// MARK: - Int

extension Int: StreamActionReducer {
  public typealias Action = DefaultStreamParserAction

  public mutating func reduce(action: DefaultStreamParserAction) throws {
    self = try reduceToValue(action: action, expectedType: "Int") { streamedValue in
      guard case .int(let value) = streamedValue else { return nil }
      return value
    }
  }
}

// MARK: - UInt8

extension UInt8: StreamActionReducer {
  public typealias Action = DefaultStreamParserAction

  public mutating func reduce(action: DefaultStreamParserAction) throws {
    self = try reduceToValue(action: action, expectedType: "UInt8") { streamedValue in
      guard case .uint8(let value) = streamedValue else { return nil }
      return value
    }
  }
}

// MARK: - UInt16

extension UInt16: StreamActionReducer {
  public typealias Action = DefaultStreamParserAction

  public mutating func reduce(action: DefaultStreamParserAction) throws {
    self = try reduceToValue(action: action, expectedType: "UInt16") { streamedValue in
      guard case .uint16(let value) = streamedValue else { return nil }
      return value
    }
  }
}

// MARK: - UInt32

extension UInt32: StreamActionReducer {
  public typealias Action = DefaultStreamParserAction

  public mutating func reduce(action: DefaultStreamParserAction) throws {
    self = try reduceToValue(action: action, expectedType: "UInt32") { streamedValue in
      guard case .uint32(let value) = streamedValue else { return nil }
      return value
    }
  }
}

// MARK: - UInt64

extension UInt64: StreamActionReducer {
  public typealias Action = DefaultStreamParserAction

  public mutating func reduce(action: DefaultStreamParserAction) throws {
    self = try reduceToValue(action: action, expectedType: "UInt64") { streamedValue in
      guard case .uint64(let value) = streamedValue else { return nil }
      return value
    }
  }
}

// MARK: - UInt

extension UInt: StreamActionReducer {
  public typealias Action = DefaultStreamParserAction

  public mutating func reduce(action: DefaultStreamParserAction) throws {
    self = try reduceToValue(action: action, expectedType: "UInt") { streamedValue in
      guard case .uint(let value) = streamedValue else { return nil }
      return value
    }
  }
}

// MARK: - Int128

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
extension Int128: StreamActionReducer {
  public typealias Action = DefaultStreamParserAction

  public mutating func reduce(action: DefaultStreamParserAction) throws {
    self = try reduceToValue(action: action, expectedType: "Int128") { streamedValue in
      guard case .int128(high: let high, low: let low) = streamedValue else { return nil }
      return Int128(_low: low, _high: high)
    }
  }
}

// MARK: - UInt128

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
extension UInt128: StreamActionReducer {
  public typealias Action = DefaultStreamParserAction

  public mutating func reduce(action: DefaultStreamParserAction) throws {
    self = try reduceToValue(action: action, expectedType: "UInt128") { streamedValue in
      guard case .uint128(high: let high, low: let low) = streamedValue else { return nil }
      return UInt128(_low: low, _high: high)
    }
  }
}

// MARK: - Helpers

private enum StandardLibraryStreamActionReducerError: Error {
  case unsupportedAction(DefaultStreamParserAction)
  case typeMismatch(expected: String, actual: StreamedValue)
}

private func reduceToValue<T>(
  action: DefaultStreamParserAction,
  expectedType: String,
  extract: (StreamedValue) -> T?
) throws -> T {
  guard case .setValue(let streamedValue) = action else {
    throw StandardLibraryStreamActionReducerError.unsupportedAction(action)
  }
  guard let value = extract(streamedValue) else {
    throw StandardLibraryStreamActionReducerError.typeMismatch(
      expected: expectedType,
      actual: streamedValue
    )
  }
  return value
}
