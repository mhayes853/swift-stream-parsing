extension UInt8 {
  @inlinable package static var asciiSpace: UInt8 { 0x20 }
  @inlinable package static var asciiTab: UInt8 { 0x09 }
  @inlinable package static var asciiBackspace: UInt8 { 0x08 }
  @inlinable package static var asciiFormFeed: UInt8 { 0x0C }
  @inlinable package static var asciiDelete: UInt8 { 0x7F }
  @inlinable package static var utf8ContinuationFloor: UInt8 { 0x80 }
  @inlinable package static var utf8TwoByteFloor: UInt8 { 0xC0 }
  @inlinable package static var utf8TwoByteMinimum: UInt8 { 0xC2 }
  @inlinable package static var utf8ThreeByteFloor: UInt8 { 0xE0 }
  @inlinable package static var utf8FourByteFloor: UInt8 { 0xF0 }
  @inlinable package static var utf8LeadCeiling: UInt8 { 0xF4 }
  @inlinable package static var utf8MaximumSecond: UInt8 { 0x8F }
  @inlinable package static var utf8MaximumLead: UInt8 { 0xF4 }
  @inlinable package static var utf8FourByteLowerBound: UInt8 { 0x90 }
  @inlinable package static var utf8SurrogateCeiling: UInt8 { 0x9F }
  @inlinable package static var utf8SurrogateLead: UInt8 { 0xED }
  @inlinable package static var utf8ThreeByteLowerBound: UInt8 { 0xA0 }
  @inlinable package static var asciiQuote: UInt8 { 0x22 }
  @inlinable package static var asciiHash: UInt8 { 0x23 }
  @inlinable package static var asciiSlash: UInt8 { 0x2F }
  @inlinable package static var asciiAsterisk: UInt8 { 0x2A }
  @inlinable package static var asciiApostrophe: UInt8 { 0x27 }
  @inlinable package static var asciiComma: UInt8 { 0x2C }
  @inlinable package static var asciiDash: UInt8 { 0x2D }
  @inlinable package static var asciiDot: UInt8 { 0x2E }
  @inlinable package static var asciiPlus: UInt8 { 0x2B }
  @inlinable package static var asciiColon: UInt8 { 0x3A }
  @inlinable package static var asciiGreaterThan: UInt8 { 0x3E }
  @inlinable package static var asciiBackslash: UInt8 { 0x5C }
  @inlinable package static var asciiArrayStart: UInt8 { 0x5B }
  @inlinable package static var asciiArrayEnd: UInt8 { 0x5D }
  @inlinable package static var asciiPipe: UInt8 { 0x7C }
  @inlinable package static var asciiObjectStart: UInt8 { 0x7B }
  @inlinable package static var asciiObjectEnd: UInt8 { 0x7D }
  @inlinable package static var asciiLineFeed: UInt8 { 0x0A }
  @inlinable package static var asciiCarriageReturn: UInt8 { 0x0D }
  @inlinable package static var asciiZero: UInt8 { 0x30 }
  @inlinable package static var asciiNine: UInt8 { 0x39 }
  @inlinable package static var asciiUpperA: UInt8 { 0x41 }
  @inlinable package static var asciiLowerB: UInt8 { 0x62 }
  @inlinable package static var asciiUpperE: UInt8 { 0x45 }
  @inlinable package static var asciiUpperF: UInt8 { 0x46 }
  @inlinable package static var asciiUpperI: UInt8 { 0x49 }
  @inlinable package static var asciiLowerN: UInt8 { 0x6E }
  @inlinable package static var asciiUpperN: UInt8 { 0x4E }
  @inlinable package static var asciiLowerR: UInt8 { 0x72 }
  @inlinable package static var asciiLowerT: UInt8 { 0x74 }
  @inlinable package static var asciiLowerU: UInt8 { 0x75 }
  @inlinable package static var asciiLowerA: UInt8 { 0x61 }
  @inlinable package static var asciiLowerS: UInt8 { 0x73 }
  @inlinable package static var asciiLowerL: UInt8 { 0x6C }
  @inlinable package static var asciiLowerE: UInt8 { 0x65 }
  @inlinable package static var asciiLowerX: UInt8 { 0x78 }
  @inlinable package static var asciiLowerF: UInt8 { 0x66 }
  @inlinable package static var asciiFalseStart: UInt8 { 0x66 }
  @inlinable package static var asciiLowerZ: UInt8 { 0x7A }
  @inlinable package static var asciiNullStart: UInt8 { 0x6E }
  @inlinable package static var asciiTrueStart: UInt8 { 0x74 }
  @inlinable package static var asciiUnderscore: UInt8 { 0x5F }
  @inlinable package static var asciiUpperX: UInt8 { 0x58 }
  @inlinable package static var asciiUpperZ: UInt8 { 0x5A }

  var digitValue: UInt8? {
    switch self {
    case .asciiZero ... .asciiNine: self &- .asciiZero
    default: nil
    }
  }

  var hexValue: UInt8? {
    switch self {
    case .asciiZero ... .asciiNine: self &- .asciiZero
    case .asciiUpperA ... .asciiUpperF: self &- .asciiUpperA &+ 10
    case .asciiLowerA ... .asciiLowerF: self &- .asciiLowerA &+ 10
    default: nil
    }
  }

  var isLetter: Bool {
    switch self {
    case .asciiUpperA ... .asciiUpperZ, .asciiLowerA ... .asciiLowerZ: true
    default: false
    }
  }

  var isAlphaNumeric: Bool {
    self.isLetter || self.digitValue != nil
  }

  var isWhitespace: Bool {
    switch self {
    case .asciiSpace, .asciiTab, .asciiLineFeed, .asciiCarriageReturn: true
    default: false
    }
  }
}

extension UInt32 {
  @inlinable package static var utf8OneByteCeiling: UInt32 { 0x80 }
  @inlinable package static var utf8TwoByteCeiling: UInt32 { 0x800 }
  @inlinable package static var utf8ThreeByteCeiling: UInt32 { 0x1_0000 }
  @inlinable package static var utf8ContinuationMask: UInt32 { 0x3F }
  @inlinable package static var highSurrogateFloor: UInt32 { 0xD800 }
  @inlinable package static var highSurrogateCeiling: UInt32 { 0xDBFF }
  @inlinable package static var lowSurrogateFloor: UInt32 { 0xDC00 }
  @inlinable package static var lowSurrogateCeiling: UInt32 { 0xDFFF }
}
