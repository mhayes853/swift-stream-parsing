// MARK: - String

extension String: StreamActionReducer {
  public typealias StreamAction = DefaultStreamAction

  public mutating func reduce(action: DefaultStreamAction) throws {
    self = try action.standardLibraryValue(as: String.self)
  }
}

// MARK: - Double

extension Double: StreamActionReducer {
  public typealias StreamAction = DefaultStreamAction

  public mutating func reduce(action: DefaultStreamAction) throws {
    self = try action.standardLibraryValue(as: Double.self)
  }
}

// MARK: - Float

extension Float: StreamActionReducer {
  public typealias StreamAction = DefaultStreamAction

  public mutating func reduce(action: DefaultStreamAction) throws {
    self = try action.standardLibraryValue(as: Float.self)
  }
}

// MARK: - Bool

extension Bool: StreamActionReducer {
  public typealias StreamAction = DefaultStreamAction

  public mutating func reduce(action: DefaultStreamAction) throws {
    self = try action.standardLibraryValue(as: Bool.self)
  }
}

// MARK: - Int8

extension Int8: StreamActionReducer {
  public typealias StreamAction = DefaultStreamAction

  public mutating func reduce(action: DefaultStreamAction) throws {
    self = try action.standardLibraryValue(as: Int8.self)
  }
}

// MARK: - Int16

extension Int16: StreamActionReducer {
  public typealias StreamAction = DefaultStreamAction

  public mutating func reduce(action: DefaultStreamAction) throws {
    self = try action.standardLibraryValue(as: Int16.self)
  }
}

// MARK: - Int32

extension Int32: StreamActionReducer {
  public typealias StreamAction = DefaultStreamAction

  public mutating func reduce(action: DefaultStreamAction) throws {
    self = try action.standardLibraryValue(as: Int32.self)
  }
}

// MARK: - Int64

extension Int64: StreamActionReducer {
  public typealias StreamAction = DefaultStreamAction

  public mutating func reduce(action: DefaultStreamAction) throws {
    self = try action.standardLibraryValue(as: Int64.self)
  }
}

// MARK: - Int

extension Int: StreamActionReducer {
  public typealias StreamAction = DefaultStreamAction

  public mutating func reduce(action: DefaultStreamAction) throws {
    self = try action.standardLibraryValue(as: Int.self)
  }
}

// MARK: - UInt8

extension UInt8: StreamActionReducer {
  public typealias StreamAction = DefaultStreamAction

  public mutating func reduce(action: DefaultStreamAction) throws {
    self = try action.standardLibraryValue(as: UInt8.self)
  }
}

// MARK: - UInt16

extension UInt16: StreamActionReducer {
  public typealias StreamAction = DefaultStreamAction

  public mutating func reduce(action: DefaultStreamAction) throws {
    self = try action.standardLibraryValue(as: UInt16.self)
  }
}

// MARK: - UInt32

extension UInt32: StreamActionReducer {
  public typealias StreamAction = DefaultStreamAction

  public mutating func reduce(action: DefaultStreamAction) throws {
    self = try action.standardLibraryValue(as: UInt32.self)
  }
}

// MARK: - UInt64

extension UInt64: StreamActionReducer {
  public typealias StreamAction = DefaultStreamAction

  public mutating func reduce(action: DefaultStreamAction) throws {
    self = try action.standardLibraryValue(as: UInt64.self)
  }
}

// MARK: - UInt

extension UInt: StreamActionReducer {
  public typealias StreamAction = DefaultStreamAction

  public mutating func reduce(action: DefaultStreamAction) throws {
    self = try action.standardLibraryValue(as: UInt.self)
  }
}

// MARK: - Int128

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
extension Int128: StreamActionReducer {
  public typealias StreamAction = DefaultStreamAction

  public mutating func reduce(action: DefaultStreamAction) throws {
    self = try action.standardLibraryValue(as: Int128.self)
  }
}

// MARK: - UInt128

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
extension UInt128: StreamActionReducer {
  public typealias StreamAction = DefaultStreamAction

  public mutating func reduce(action: DefaultStreamAction) throws {
    self = try action.standardLibraryValue(as: UInt128.self)
  }
}

// MARK: - Optional

extension Optional: StreamActionReducer
where Wrapped: StreamActionReducer, Wrapped.StreamAction == DefaultStreamAction {
  public typealias StreamAction = DefaultStreamAction

  public mutating func reduce(action: DefaultStreamAction) throws {
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

// MARK: - RawRepresentable

extension RawRepresentable
where RawValue: StreamActionReducer, RawValue.StreamAction == DefaultStreamAction {
  public typealias StreamAction = DefaultStreamAction

  public mutating func reduce(action: DefaultStreamAction) throws {
    var updatedRawValue = rawValue
    try updatedRawValue.reduce(action: action)
    guard let updatedValue = Self(rawValue: updatedRawValue) else {
      throw StandardLibraryStreamActionReducerError.rawValueInitializationFailed(
        type: String(describing: Self.self),
        rawValue: String(describing: updatedRawValue)
      )
    }
    self = updatedValue
  }
}
