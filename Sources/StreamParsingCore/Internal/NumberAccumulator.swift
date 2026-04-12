// MARK: - NumberAccumulator

enum NumberAccumulator {
  case int(Int)
  case int8(Int8)
  case int16(Int16)
  case int32(Int32)
  case int64(Int64)
  case int128(low: UInt64, high: Int64)
  case uint(UInt)
  case uint8(UInt8)
  case uint16(UInt16)
  case uint32(UInt32)
  case uint64(UInt64)
  case uint128(low: UInt64, high: UInt64)
  case float(Float)
  case double(Double)

  mutating func reset() {
    switch self {
    case .int: self = .int(.zero)
    case .int8: self = .int8(.zero)
    case .int16: self = .int16(.zero)
    case .int32: self = .int32(.zero)
    case .int64: self = .int64(.zero)
    case .int128: self = .int128(low: .zero, high: .zero)
    case .uint: self = .uint(.zero)
    case .uint8: self = .uint8(.zero)
    case .uint16: self = .uint16(.zero)
    case .uint32: self = .uint32(.zero)
    case .uint64: self = .uint64(.zero)
    case .uint128: self = .uint128(low: .zero, high: .zero)
    case .float: self = .float(.zero)
    case .double: self = .double(.zero)
    }
  }

  mutating func parseDigits(buffer: DigitBuffer, isHex: Bool) -> Bool {
    switch self {
    case .int:
      guard let value: Int = parseInteger(buffer: buffer, isHex: isHex, as: Int.self) else {
        return false
      }
      self = .int(value)
    case .int8:
      guard let value: Int8 = parseInteger(buffer: buffer, isHex: isHex, as: Int8.self) else {
        return false
      }
      self = .int8(value)
    case .int16:
      guard let value: Int16 = parseInteger(buffer: buffer, isHex: isHex, as: Int16.self) else {
        return false
      }
      self = .int16(value)
    case .int32:
      guard let value: Int32 = parseInteger(buffer: buffer, isHex: isHex, as: Int32.self) else {
        return false
      }
      self = .int32(value)
    case .int64:
      guard let value: Int64 = parseInteger(buffer: buffer, isHex: isHex, as: Int64.self) else {
        return false
      }
      self = .int64(value)
    case .int128:
      guard #available(StreamParsing128BitIntegers, *) else { return true }
      guard let value = parseInt128(buffer: buffer, isHex: isHex) else { return false }
      self = .int128(low: value._low, high: value._high)
    case .uint:
      guard let value: UInt = parseInteger(buffer: buffer, isHex: isHex, as: UInt.self) else {
        return false
      }
      self = .uint(value)
    case .uint8:
      guard let value: UInt8 = parseInteger(buffer: buffer, isHex: isHex, as: UInt8.self) else {
        return false
      }
      self = .uint8(value)
    case .uint16:
      guard let value: UInt16 = parseInteger(buffer: buffer, isHex: isHex, as: UInt16.self) else {
        return false
      }
      self = .uint16(value)
    case .uint32:
      guard let value: UInt32 = parseInteger(buffer: buffer, isHex: isHex, as: UInt32.self) else {
        return false
      }
      self = .uint32(value)
    case .uint64:
      guard let value: UInt64 = parseInteger(buffer: buffer, isHex: isHex, as: UInt64.self) else {
        return false
      }
      self = .uint64(value)
    case .uint128:
      guard #available(StreamParsing128BitIntegers, *) else { return true }
      guard let value = parseUInt128(buffer: buffer, isHex: isHex) else { return false }
      self = .uint128(low: value._low, high: value._high)
    case .float:
      guard let value: Float = parseFloatingPoint(buffer: buffer, as: Float.self) else {
        return false
      }
      self = .float(value)
    case .double:
      guard let value: Double = parseFloatingPoint(buffer: buffer, as: Double.self) else {
        return false
      }
      self = .double(value)
    }
    return true
  }
}

extension Int {
  var erasedAccumulator: NumberAccumulator {
    get { .int(self) }
    set {
      guard case .int(let value) = newValue else { numberAccumulatorCaseMismatch() }
      self = value
    }
  }
}

extension Int8 {
  var erasedAccumulator: NumberAccumulator {
    get { .int8(self) }
    set {
      guard case .int8(let value) = newValue else { numberAccumulatorCaseMismatch() }
      self = value
    }
  }
}

extension Int16 {
  var erasedAccumulator: NumberAccumulator {
    get { .int16(self) }
    set {
      guard case .int16(let value) = newValue else { numberAccumulatorCaseMismatch() }
      self = value
    }
  }
}

extension Int32 {
  var erasedAccumulator: NumberAccumulator {
    get { .int32(self) }
    set {
      guard case .int32(let value) = newValue else { numberAccumulatorCaseMismatch() }
      self = value
    }
  }
}

extension Int64 {
  var erasedAccumulator: NumberAccumulator {
    get { .int64(self) }
    set {
      guard case .int64(let value) = newValue else { numberAccumulatorCaseMismatch() }
      self = value
    }
  }
}

@available(StreamParsing128BitIntegers, *)
extension Int128 {
  var erasedAccumulator: NumberAccumulator {
    get { .int128(low: self._low, high: self._high) }
    set {
      guard case .int128(let low, let high) = newValue else { numberAccumulatorCaseMismatch() }
      self = Int128(_low: low, _high: high)
    }
  }
}

extension UInt {
  var erasedAccumulator: NumberAccumulator {
    get { .uint(self) }
    set {
      guard case .uint(let value) = newValue else { numberAccumulatorCaseMismatch() }
      self = value
    }
  }
}

extension UInt8 {
  var erasedAccumulator: NumberAccumulator {
    get { .uint8(self) }
    set {
      guard case .uint8(let value) = newValue else { numberAccumulatorCaseMismatch() }
      self = value
    }
  }
}

extension UInt16 {
  var erasedAccumulator: NumberAccumulator {
    get { .uint16(self) }
    set {
      guard case .uint16(let value) = newValue else { numberAccumulatorCaseMismatch() }
      self = value
    }
  }
}

extension UInt32 {
  var erasedAccumulator: NumberAccumulator {
    get { .uint32(self) }
    set {
      guard case .uint32(let value) = newValue else { numberAccumulatorCaseMismatch() }
      self = value
    }
  }
}

extension UInt64 {
  var erasedAccumulator: NumberAccumulator {
    get { .uint64(self) }
    set {
      guard case .uint64(let value) = newValue else { numberAccumulatorCaseMismatch() }
      self = value
    }
  }
}

@available(StreamParsing128BitIntegers, *)
extension UInt128 {
  var erasedAccumulator: NumberAccumulator {
    get { .uint128(low: self._low, high: self._high) }
    set {
      guard case .uint128(let low, let high) = newValue else { numberAccumulatorCaseMismatch() }
      self = UInt128(_low: low, _high: high)
    }
  }
}

extension Float {
  var erasedAccumulator: NumberAccumulator {
    get { .float(self) }
    set {
      guard case .float(let value) = newValue else { numberAccumulatorCaseMismatch() }
      self = value
    }
  }
}

extension Double {
  var erasedAccumulator: NumberAccumulator {
    get { .double(self) }
    set {
      guard case .double(let value) = newValue else { numberAccumulatorCaseMismatch() }
      self = value
    }
  }
}

private func numberAccumulatorCaseMismatch() -> Never {
  fatalError("NumberAccumulator case mismatch.")
}
