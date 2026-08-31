extension UInt8 {
  @usableFromInline static let asciiSpace: UInt8 = 0x20
  @usableFromInline static let asciiTab: UInt8 = 0x09
  @usableFromInline static let utf8ContinuationFloor: UInt8 = 0x80
  @usableFromInline static let utf8TwoByteFloor: UInt8 = 0xC0
  @usableFromInline static let utf8TwoByteMinimum: UInt8 = 0xC2
  @usableFromInline static let utf8ThreeByteFloor: UInt8 = 0xE0
  @usableFromInline static let utf8FourByteFloor: UInt8 = 0xF0
  @usableFromInline static let utf8LeadCeiling: UInt8 = 0xF4
  @usableFromInline static let utf8MaximumSecond: UInt8 = 0x8F
  @usableFromInline static let utf8MaximumLead: UInt8 = 0xF4
  @usableFromInline static let utf8FourByteLowerBound: UInt8 = 0x90
  @usableFromInline static let utf8SurrogateCeiling: UInt8 = 0x9F
  @usableFromInline static let utf8SurrogateLead: UInt8 = 0xED
  @usableFromInline static let utf8ThreeByteLowerBound: UInt8 = 0xA0
  @usableFromInline static let asciiQuote: UInt8 = 0x22
  @usableFromInline static let asciiComma: UInt8 = 0x2C
  @usableFromInline static let asciiDash: UInt8 = 0x2D
  @usableFromInline static let asciiDot: UInt8 = 0x2E
  @usableFromInline static let asciiPlus: UInt8 = 0x2B
  @usableFromInline static let asciiColon: UInt8 = 0x3A
  @usableFromInline static let asciiBackslash: UInt8 = 0x5C
  @usableFromInline static let asciiArrayStart: UInt8 = 0x5B
  @usableFromInline static let asciiArrayEnd: UInt8 = 0x5D
  @usableFromInline static let asciiObjectStart: UInt8 = 0x7B
  @usableFromInline static let asciiObjectEnd: UInt8 = 0x7D
  @usableFromInline static let asciiLineFeed: UInt8 = 0x0A
  @usableFromInline static let asciiCarriageReturn: UInt8 = 0x0D
  @usableFromInline static let asciiZero: UInt8 = 0x30
  @usableFromInline static let asciiNine: UInt8 = 0x39
  @usableFromInline static let asciiUpperA: UInt8 = 0x41
  @usableFromInline static let asciiUpperE: UInt8 = 0x45
  @usableFromInline static let asciiUpperF: UInt8 = 0x46
  @usableFromInline static let asciiLowerN: UInt8 = 0x6E
  @usableFromInline static let asciiLowerR: UInt8 = 0x72
  @usableFromInline static let asciiLowerT: UInt8 = 0x74
  @usableFromInline static let asciiLowerU: UInt8 = 0x75
  @usableFromInline static let asciiLowerA: UInt8 = 0x61
  @usableFromInline static let asciiLowerS: UInt8 = 0x73
  @usableFromInline static let asciiLowerL: UInt8 = 0x6C
  @usableFromInline static let asciiLowerE: UInt8 = 0x65
  @usableFromInline static let asciiLowerF: UInt8 = 0x66
  @usableFromInline static let asciiLowerZ: UInt8 = 0x7A
}

extension UInt32 {
  @usableFromInline static let utf8OneByteCeiling: UInt32 = 0x80
  @usableFromInline static let utf8TwoByteCeiling: UInt32 = 0x800
  @usableFromInline static let utf8ThreeByteCeiling: UInt32 = 0x1_0000
  @usableFromInline static let utf8ContinuationMask: UInt32 = 0x3F
  @usableFromInline static let highSurrogateFloor: UInt32 = 0xD800
  @usableFromInline static let highSurrogateCeiling: UInt32 = 0xDBFF
  @usableFromInline static let lowSurrogateFloor: UInt32 = 0xDC00
  @usableFromInline static let lowSurrogateCeiling: UInt32 = 0xDFFF
}
