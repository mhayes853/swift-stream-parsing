struct UTF8State {
  private var state: UInt32 = 0

  private static let stateMask: UInt32 = 0x0F

  init() {}

  @inlinable
  mutating func process(byte: UInt8) -> Bool {
    let type = utf8dByte[Int(byte)]
    let currentFSM = self.state & Self.stateMask
    let newFSM = UInt32(utf8dState[Int(currentFSM) * 16 + Int(type)])
    let valueBits = self.computeValueBits(byte: byte, type: type, currentFSM: currentFSM)
    self.state = (valueBits << Self.stateMask) | newFSM
    return newFSM == 0
  }

  private func computeValueBits(byte: UInt8, type: UInt8, currentFSM: UInt32) -> UInt32 {
    if currentFSM == 0 {
      switch type {
      case 2:
        return UInt32(byte & 0x1F)
      case 3:
        return UInt32(byte & 0x0F) << 6
      case 4:
        return UInt32(byte & 0x07) << 12
      default:
        return UInt32(byte)
      }
    } else {
      let currentValue = self.state >> Self.stateMask
      return (currentValue << 6) | UInt32(byte & 0x3F)
    }
  }

  @inlinable
  mutating func reset() {
    self.state = 0
  }

  @inlinable
  mutating func consume(byte: UInt8) -> ConsumeAction {
    let completed = self.process(byte: byte)
    guard completed else { return .doNothing }
    defer { self.state = 0 }
    let scalarValue = self.state >> Self.stateMask
    return .consume(Unicode.Scalar(scalarValue)!)
  }

  enum ConsumeAction {
    case doNothing
    case consume(Unicode.Scalar)
  }
}

@usableFromInline
let utf8dByte: [UInt8] = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9,
  7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
  8, 8, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
  0xa, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x3, 0x4, 0x3, 0x3,
  0xb, 0x6, 0x6, 0x6, 0x5, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8, 0x8
]

@usableFromInline
let utf8dState: [UInt8] = [
  0x0, 0x1, 0x2, 0x3, 0x5, 0x8, 0x7, 0x1, 0x1, 0x1, 0x4, 0x6, 0x1, 0x1, 0x1, 0x1,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 0, 1, 0, 1, 1, 1, 1, 1, 1,
  1, 2, 1, 1, 1, 1, 1, 2, 1, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 2, 1, 1, 1, 1, 1, 1, 1, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 3, 1, 3, 1, 1, 1, 1, 1, 1,
  1, 3, 1, 1, 1, 1, 1, 3, 1, 3, 1, 1, 1, 1, 1, 1, 1, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
]
