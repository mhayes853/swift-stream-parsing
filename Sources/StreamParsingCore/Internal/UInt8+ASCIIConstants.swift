extension UInt8 {
  static let asciiSpace: UInt8 = 0x20
  static let asciiTab: UInt8 = 0x09
  static let asciiQuote: UInt8 = 0x22
  static let asciiHash: UInt8 = 0x23
  static let asciiSlash: UInt8 = 0x2F
  static let asciiAsterisk: UInt8 = 0x2A
  static let asciiApostrophe: UInt8 = 0x27
  static let asciiComma: UInt8 = 0x2C
  static let asciiDash: UInt8 = 0x2D
  static let asciiDot: UInt8 = 0x2E
  static let asciiPlus: UInt8 = 0x2B
  static let asciiColon: UInt8 = 0x3A
  static let asciiGreaterThan: UInt8 = 0x3E
  static let asciiBackslash: UInt8 = 0x5C
  static let asciiArrayStart: UInt8 = 0x5B
  static let asciiArrayEnd: UInt8 = 0x5D
  static let asciiPipe: UInt8 = 0x7C
  static let asciiObjectStart: UInt8 = 0x7B
  static let asciiObjectEnd: UInt8 = 0x7D
  static let asciiLineFeed: UInt8 = 0x0A
  static let asciiCarriageReturn: UInt8 = 0x0D
  static let asciiZero: UInt8 = 0x30
  static let asciiNine: UInt8 = 0x39
  static let asciiUpperA: UInt8 = 0x41
  static let asciiLowerB: UInt8 = 0x62
  static let asciiUpperE: UInt8 = 0x45
  static let asciiUpperF: UInt8 = 0x46
  static let asciiUpperI: UInt8 = 0x49
  static let asciiLowerN: UInt8 = 0x6E
  static let asciiUpperN: UInt8 = 0x4E
  static let asciiLowerR: UInt8 = 0x72
  static let asciiLowerT: UInt8 = 0x74
  static let asciiLowerU: UInt8 = 0x75
  static let asciiLowerA: UInt8 = 0x61
  static let asciiLowerE: UInt8 = 0x65
  static let asciiLowerX: UInt8 = 0x78
  static let asciiLowerF: UInt8 = 0x66
  static let asciiFalseStart: UInt8 = 0x66
  static let asciiLowerZ: UInt8 = 0x7A
  static let asciiNullStart: UInt8 = 0x6E
  static let asciiTrueStart: UInt8 = 0x74
  static let asciiUnderscore: UInt8 = 0x5F
  static let asciiUpperX: UInt8 = 0x58
  static let asciiUpperZ: UInt8 = 0x5A

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
