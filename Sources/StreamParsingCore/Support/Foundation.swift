#if canImport(Foundation)
  import Foundation

  // MARK: - Data

  extension Data: StreamParseable {
    public typealias Partial = Self
  }

  extension Data: StreamParseableReducer {}

  extension Data: ConvertibleFromStreamedValue {
    public init?(streamedValue: StreamedValue) {
      guard let value = streamedValue.dataValue else { return nil }
      self = value
    }
  }

  // MARK: - Decimal

  extension Decimal: StreamParseable {
    public typealias Partial = Self
  }

  extension Decimal: StreamParseableReducer {}

  extension Decimal: ConvertibleFromStreamedValue {
    public init?(streamedValue: StreamedValue) {
      guard let value = streamedValue.decimalValue else { return nil }
      self = value
    }
  }

  // MARK: - Helpers

  extension StreamedValue {
    fileprivate var dataValue: Data? {
      guard case .string(let value) = self else { return nil }
      return Data(value.utf8)
    }

    fileprivate var decimalValue: Decimal? {
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
