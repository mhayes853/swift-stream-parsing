// MARK: - DigitBufferStorage

typealias DigitBufferStorage = (
  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
  UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

// MARK: - DigitBuffer

struct DigitBuffer: Collection {
  var storage: DigitBufferStorage
  var count: Int

  init() {
    self.storage = (
      0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0
    )
    self.count = 0
  }

  typealias Index = Int
  typealias Element = UInt8
  
  var isFirstNegative: Bool {
    self.storage.0 == .asciiDash
  }
  
  var isFirstPlusPositive: Bool {
    self.storage.0 == .asciiPlus
  }

  var startIndex: Int { 0 }
  var endIndex: Int { count }

  func index(after i: Int) -> Int { i + 1 }

  subscript(position: Int) -> UInt8 {
    withUnsafeBytes(of: storage) { ptr in
      ptr.load(fromByteOffset: position, as: UInt8.self)
    }
  }
}

// MARK: - Parsing

func parseFloatingPoint<T: BinaryFloatingPoint>(
  buffer: DigitBuffer,
  as type: T.Type
) -> T? {
  guard buffer.count > 0 else { return nil }
  let string = String(decoding: buffer, as: UTF8.self)
  guard let parsed = Double(string) else { return nil }
  let result = T(parsed)
  return result.isFinite ? result : nil
}

func parseInteger<T: FixedWidthInteger>(
  buffer: DigitBuffer,
  isHex: Bool,
  as type: T.Type
) -> T? {
  guard !buffer.isEmpty else { return nil }

  if isHex {
    return parseHexInteger(buffer: buffer, as: type)
  }

  let string = String(decoding: buffer, as: UTF8.self)
  guard let first = string.first else { return nil }

  if buffer.isFirstNegative {
    guard T.isSigned else { return nil }
    guard let parsed = Int64(string) else { return nil }
    guard parsed >= T.min else { return nil }
    return T(parsed)
  } else {
    let unsignedString = buffer.isFirstPlusPositive ? String(string.dropFirst()) : string
    guard let parsed = UInt64(unsignedString) else { return nil }
    guard parsed <= T.max else { return nil }
    return T(parsed)
  }
}

func parseHexInteger<T: FixedWidthInteger>(
  buffer: DigitBuffer,
  as type: T.Type
) -> T? {
  guard !buffer.isEmpty else { return nil }
  let string = String(decoding: buffer, as: UTF8.self)
  guard let first = string.first else { return nil }
  if buffer[0] == .asciiDash {
    guard T.isSigned else { return nil }
    let unsignedString = String(string.dropFirst())
    guard let parsed = UInt64(unsignedString, radix: 16) else { return nil }
    let negated = Int64(bitPattern: parsed)
    guard negated >= T.min else { return nil }
    return T(negated)
  } else {
    let unsignedString = buffer[0] == .asciiPlus ? String(string.dropFirst()) : string
    guard let parsed = UInt64(unsignedString, radix: 16) else { return nil }
    guard parsed <= T.max else { return nil }
    return T(parsed)
  }
}

@available(StreamParsing128BitIntegers, *)
func parseInt128(
  buffer: DigitBuffer,
  isHex: Bool
) -> Int128? {
  guard buffer.count > 0 else { return nil }
  let radix: Int128 = isHex ? 16 : 10
  var value: Int128 = 0
  var isNegative = false
  var started = false
  var index = buffer.startIndex
  if index < buffer.endIndex {
    if buffer.isFirstNegative {
      isNegative = true
    } else if !buffer.isFirstPlusPositive {
      let digit = digitValue(buffer[index], isHex: isHex)
      guard let digit else { return nil }
      let delta = Int128(digit)
      let (result, overflow) = value.addingReportingOverflow(delta)
      guard !overflow else { return nil }
      value = result
      started = true
    }
    index = buffer.index(after: index)
  }
  while index < buffer.endIndex {
    let byte = buffer[index]
    guard let digit = digitValue(byte, isHex: isHex) else { return nil }
    let (multiplied, overflowed) = value.multipliedReportingOverflow(by: radix)
    guard !overflowed else { return nil }
    let delta = Int128(digit)
    if isNegative {
      let (result, subtractOverflow) = multiplied.subtractingReportingOverflow(delta)
      guard !subtractOverflow else { return nil }
      value = result
    } else {
      let (result, addOverflow) = multiplied.addingReportingOverflow(delta)
      guard !addOverflow else { return nil }
      value = result
    }
    started = true
    index = buffer.index(after: index)
  }
  return started ? value : nil
}

@available(StreamParsing128BitIntegers, *)
func parseUInt128(
  buffer: DigitBuffer,
  isHex: Bool
) -> UInt128? {
  guard !buffer.isEmpty else { return nil }
  let radix: UInt128 = isHex ? 16 : 10
  var value: UInt128 = 0
  var started = false
  var index = buffer.startIndex
  if index < buffer.endIndex {
    if buffer.isFirstNegative {
      return nil
    }
    if !buffer.isFirstPlusPositive {
      guard let digit = digitValue(buffer[index], isHex: isHex) else { return nil }
      let (result, overflow) = value.addingReportingOverflow(UInt128(digit))
      guard !overflow else { return nil }
      value = result
      started = true
    }
    index = buffer.index(after: index)
  }
  while index < buffer.endIndex {
    guard let digit = digitValue(buffer[index], isHex: isHex) else { return nil }
    let (multiplied, overflowed) = value.multipliedReportingOverflow(by: radix)
    guard !overflowed else { return nil }
    let (result, addOverflow) = multiplied.addingReportingOverflow(UInt128(digit))
    guard !addOverflow else { return nil }
    value = result
    started = true
    index = buffer.index(after: index)
  }
  return started ? value : nil
}


private func digitValue(_ byte: UInt8, isHex: Bool) -> UInt8? {
  if byte >= .asciiZero && byte <= .asciiNine {
    return byte - .asciiZero
  }
  if !isHex { return nil }
  if byte >= .asciiUpperA && byte <= .asciiUpperF {
    return byte - .asciiUpperA + 10
  }
  if byte >= .asciiLowerA && byte <= .asciiLowerF {
    return byte - .asciiLowerA + 10
  }
  return nil
}
