#if canImport(Foundation)
  import Foundation

  // MARK: - Data

  extension Data: StreamActionReducer {
    public typealias StreamAction = DefaultStreamAction

    public mutating func reduce(action: DefaultStreamAction) throws {
      self = try action.foundationValue(as: Data.self)
    }
  }

  // MARK: - Decimal

  extension Decimal: StreamActionReducer {
    public typealias StreamAction = DefaultStreamAction

    public mutating func reduce(action: DefaultStreamAction) throws {
      self = try action.foundationValue(as: Decimal.self)
    }
  }

  // MARK: - Helpers

  extension DefaultStreamAction {
    fileprivate func foundationValue<T>(as type: T.Type) throws -> T {
      guard case .setValue(let streamedValue) = self else {
        throw StandardLibraryStreamActionReducerError.unsupportedAction(self)
      }
      guard let value = streamedValue.foundationValue(as: type) else {
        throw StandardLibraryStreamActionReducerError.typeMismatch(
          expected: String(describing: type),
          actual: streamedValue
        )
      }
      return value
    }
  }

  extension StreamedValue {
    fileprivate func foundationValue<T>(as type: T.Type) -> T? {
      if type == Data.self {
        return self.dataValue() as? T
      }
      if type == Decimal.self {
        return self.decimalValue() as? T
      }
      return nil
    }

    private func dataValue() -> Data? {
      guard case .string(let value) = self else { return nil }
      return Data(value.utf8)
    }

    private func decimalValue() -> Decimal? {
      switch self {
      case .double(let value):
        return Decimal(value)
      case .float(let value):
        return Decimal(Double(value))
      case .int8(let value):
        return Decimal(value)
      case .int16(let value):
        return Decimal(value)
      case .int32(let value):
        return Decimal(value)
      case .int64(let value):
        return Decimal(value)
      case .int(let value):
        return Decimal(value)
      case .uint8(let value):
        return Decimal(value)
      case .uint16(let value):
        return Decimal(value)
      case .uint32(let value):
        return Decimal(value)
      case .uint64(let value):
        return Decimal(value)
      case .uint(let value):
        return Decimal(value)
      case .int128(let high, let low):
        if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) {
          let value = Int128(_low: low, _high: high)
          return Decimal(string: String(value))
        }
        return nil
      case .uint128(let high, let low):
        if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) {
          let value = UInt128(_low: low, _high: high)
          return Decimal(string: String(value))
        }
        return nil
      case .string, .boolean, .null:
        return nil
      }
    }
  }
#endif
