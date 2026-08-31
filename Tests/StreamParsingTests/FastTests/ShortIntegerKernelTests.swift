import Testing

import StreamParsing
import StreamParsingCore

// The kernel is held to the oracle the structured walk provides: scalar accumulation, one digit
// at a time. The tokens are placed after deliberately hostile leading bytes, because the kernel
// reads the eight bytes *ending* at the token and a byte below `'0'` there borrows into the
// leading digit unless the mask precedes the bias. A suite that padded with spaces or digits
// would not see that, and did not: the defect was found by randomising the prefix.
@Suite
struct `Short integer kernel tests` {
  private static let junk: [UInt8] = Array(0x20...0x7E) + [0x0A, 0x09, 0x0D]

  private static func oracle(_ text: String) -> UInt64? {
    guard (1...8).contains(text.utf8.count) else { return nil }
    var value: UInt64 = 0
    for byte in text.utf8 {
      guard (0x30...0x39).contains(byte) else { return nil }
      value = value &* 10 &+ UInt64(byte &- 0x30)
    }
    return value
  }

  private static func run(_ text: String, prefix: [UInt8]) -> UInt64? {
    var bytes = prefix
    let from = bytes.count
    bytes.append(contentsOf: Array(text.utf8))
    let end = bytes.count
    bytes.append(0x2C)
    return bytes.withUnsafeBytes { streamShortInteger(base: $0.baseAddress!, from: from, end: end) }
  }

  // A fixed xorshift, so the sweep is identical on every machine and every run: a differential
  // test that samples a different space each time cannot be bisected when it fails.
  private struct Random {
    var state: UInt64 = 0x5EED_2026_0821_0001

    mutating func next() -> UInt64 {
      self.state ^= self.state << 13
      self.state ^= self.state >> 7
      self.state ^= self.state << 17
      return self.state
    }
  }

  @Test
  func `The kernel agrees with the scalar walk on every length and prefix`() {
    var random = Random()
    var checked = 0
    for width in 1...8 {
      let bound = (1...width).reduce(UInt64(1)) { product, _ in product &* 10 }
      for _ in 0..<20_000 {
        let text = String(random.next() % bound)
        guard text.utf8.count == width else { continue }
        let prefix = (0..<8).map { _ in Self.junk[Int(random.next() % UInt64(Self.junk.count))] }
        #expect(Self.run(text, prefix: prefix) == Self.oracle(text), "\(text) after \(prefix)")
        checked += 1
      }
    }
    #expect(checked > 50_000)
  }

  // The exact shape of the borrow defect: a byte below `'0'` immediately before the token.
  @Test
  func `A byte below ASCII zero before the token does not borrow into it`() {
    for lead: UInt8 in [0x0A, 0x2C, 0x22, 0x20, 0x2D, 0x2E, 0x00, 0x09] {
      let value = Self.run("582", prefix: Array(repeating: lead, count: 8))
      #expect(value == 582, "borrowed from 0x\(String(lead, radix: 16))")
    }
  }

  @Test
  func `Anything that is not a pure digit run is declined`() {
    for text in ["-123", "1.23", "1e23", "12+3", "1,23", "0x12", " 123", "123 ", "1E9"] {
      #expect(
        Self.run(text, prefix: [UInt8](repeating: 0x5B, count: 8)) == nil, "took \(text)"
      )
    }
  }

  // Randomised over bytes rather than over digits, so most cases are malformed. What is pinned
  // here is that the kernel refuses the same inputs the walk refuses, not merely that it agrees
  // on the ones it accepts.
  @Test
  func `Random byte runs are accepted only when the walk would accept them`() {
    var random = Random()
    for _ in 0..<200_000 {
      let width = Int(random.next() % 8) + 1
      let body = (0..<width).map { _ in Self.junk[Int(random.next() % UInt64(Self.junk.count))] }
      let text = String(decoding: body, as: UTF8.self)
      let prefix = (0..<8).map { _ in Self.junk[Int(random.next() % UInt64(Self.junk.count))] }
      #expect(Self.run(text, prefix: prefix) == Self.oracle(text), "disagreement on \(text)")
    }
  }

  // End to end through the parser, which is where the leading zero rule and the kernel's own
  // guards meet. The recording sink checks the emitted value, not just that parsing succeeded:
  // a kernel that silently returned the wrong magnitude would pass a throws-or-not assertion.
  @Test
  func `The parser rejects a leading zero and still accepts a bare zero`() throws {
    for text in ["0123", "01", "00"] {
      #expect(throws: JSONParsingError.self) { try Self.parse("[\(text)]") }
    }
    #expect(try Self.parse("[0,10,100000000,99999999]") == [0, 10, 100_000_000, 99_999_999])
  }

  // Every token width the kernel serves, and the two either side of it, driven through the real
  // parser so the guards are exercised as the parser composes them.
  @Test
  func `Every width the parser routes through the kernel emits the right value`() throws {
    var values: [UInt64] = []
    for width in 1...10 {
      let digit = UInt64(width % 9 + 1)
      values.append((1...width).reduce(UInt64(0)) { accumulated, _ in accumulated &* 10 &+ digit })
    }
    let document = "[" + values.map(String.init).joined(separator: ",") + "]"
    #expect(try Self.parse(document) == values)
  }

  private static func parse(_ text: String) throws -> [UInt64] {
    var parser = JSONParser()
    var sink = NumberRecordingSink()
    try Array(text.utf8).withUnsafeBufferPointer { try parser.parse($0, into: &sink) }
    try parser.finish(into: &sink)
    return sink.magnitudes
  }
}

private struct NumberRecordingSink: StreamParseSink {
  var streamFailure: StreamSinkFailure?
  var magnitudes: [UInt64] = []

  mutating func beginObject() -> StreamContainerDisposition { .stream }
  mutating func endObject() {}
  mutating func beginArray() -> StreamContainerDisposition { .stream }
  mutating func endArray() {}
  mutating func key(_ bytes: Span<UInt8>) {}
  mutating func stringBegin() {}
  mutating func stringChunk(_ bytes: Span<UInt8>) {}
  mutating func stringEnd() {}
  mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) { self.magnitudes.append(info.magnitude) }
  mutating func boolean(_ value: Bool) {}
  mutating func null() {}
}
