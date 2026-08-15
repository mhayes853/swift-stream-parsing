// MARK: - Configuration

public struct JSONParserConfiguration: Hashable, Sendable {
  public var validatesUTF8: Bool
  public var validatesNumberGrammar: Bool
  public var validatesLiterals: Bool

  public init(
    validatesUTF8: Bool = true,
    validatesNumberGrammar: Bool = true,
    validatesLiterals: Bool = true
  ) {
    self.validatesUTF8 = validatesUTF8
    self.validatesNumberGrammar = validatesNumberGrammar
    self.validatesLiterals = validatesLiterals
  }

  public static let strict = Self()

  public static let unchecked = Self(
    validatesUTF8: false,
    validatesNumberGrammar: false,
    validatesLiterals: false
  )
}

// MARK: - Error

public struct JSONParsingError: Error, Hashable, Sendable {
  public enum Reason: Hashable, Sendable {
    case unexpectedToken
    case invalidNumber
    case invalidLiteral
    case invalidEscape
    case invalidUTF8
    case unterminatedString
    case unterminatedContainer
    case trailingContent
    case depthExceeded
    case bufferExhausted
    case sinkRejectedToken(StreamSinkFailure)
  }

  public var reason: Reason
  public var byteOffset: Int

  public init(reason: Reason, byteOffset: Int) {
    self.reason = reason
    self.byteOffset = byteOffset
  }
}

// MARK: - JSONParser

public struct JSONParser: ~Copyable {
  @usableFromInline
  enum State: UInt8 {
    case value, firstValue, afterValue, key, firstKey, afterKey, inString, inKey, escape
    case unicode, number, literal, done
  }

  // 1 = object, 0 = array. Depth beyond `maximumDepth` is rejected rather than spilled, which
  // keeps container tracking to a single register.
  @usableFromInline static let maximumDepth = 64

  @usableFromInline var state = State.value
  @usableFromInline var containers: UInt64 = 0
  @usableFromInline var depth = 0

  @usableFromInline var buffer: UnsafeMutableBufferPointer<UInt8>
  @usableFromInline var bufferCount = 0
  @usableFromInline var ownsBuffer: Bool

  @usableFromInline var magnitude: UInt64 = 0
  @usableFromInline var digitCount: UInt16 = 0
  @usableFromInline var fractionDigits: Int32 = 0
  @usableFromInline var explicitExponent: Int32 = 0
  @usableFromInline var numberFlags = NumberInfo.Flags()
  @usableFromInline var inExponent = false
  @usableFromInline var sawDot = false
  @usableFromInline var exponentNegative = false
  @usableFromInline var exponentDigits = 0
  @usableFromInline var integerDigits: Int32 = 0
  @usableFromInline var firstIntegerDigitIsZero = false

  @usableFromInline var unicodeValue: UInt32 = 0
  @usableFromInline var unicodeRemaining = 0
  @usableFromInline var highSurrogate: UInt32 = 0

  // Whether the string token being read is a key. The escape and unicode states are shared
  // between keys and string values, so this has to be remembered rather than derived:
  // `bufferCount > 0` cannot stand in for it, because a key whose first character is an escape
  // has buffered nothing yet, and misrouting it emitted the decoded byte as string content.
  @usableFromInline var isKeyToken = false

  @usableFromInline var literalKind: UInt8 = 0
  @usableFromInline var literalIndex = 0

  @usableFromInline var pendingUTF8Count = 0
  @usableFromInline var consumedByteCount = 0
  @usableFromInline var configuration: JSONParserConfiguration

  public init(configuration: JSONParserConfiguration = .strict, bufferCapacity: Int = 4096) {
    self.configuration = configuration
    self.buffer = .allocate(capacity: Swift.max(bufferCapacity, 64))
    self.ownsBuffer = true
  }

  public init(
    buffer: UnsafeMutableBufferPointer<UInt8>,
    configuration: JSONParserConfiguration = .strict
  ) {
    self.configuration = configuration
    self.buffer = buffer
    self.ownsBuffer = false
  }

  deinit {
    if self.ownsBuffer { self.buffer.deallocate() }
  }

  public var byteOffset: Int { self.consumedByteCount }

  // MARK: Entry points

  @inlinable
  public mutating func parse<Sink: StreamParseSink & ~Copyable>(
    _ input: Span<UInt8>,
    into sink: inout Sink
  ) throws(JSONParsingError) {
    try input.withUnsafeBufferPointer { buffer throws(JSONParsingError) in
      try self.parse(buffer, into: &sink)
    }
  }

  @inlinable
  public mutating func parse<Sink: StreamParseSink & ~Copyable>(
    byte: UInt8,
    into sink: inout Sink
  ) throws(JSONParsingError) {
    var scalar = byte
    try withUnsafePointer(to: &scalar) { pointer throws(JSONParsingError) in
      try self.parse(UnsafeBufferPointer(start: pointer, count: 1), into: &sink)
    }
  }

  @inlinable
  public mutating func parse<Sink: StreamParseSink & ~Copyable>(
    _ input: UnsafeBufferPointer<UInt8>,
    into sink: inout Sink
  ) throws(JSONParsingError) {
    guard let start = input.baseAddress, !input.isEmpty else { return }
    let base = UnsafeRawPointer(start)
    let n = input.count
    var i = 0

    if self.pendingUTF8Count > 0 {
      i = try self.completePendingUTF8(base: base, count: n, into: &sink)
    }

    while i < n {
      switch self.state {
      case .value, .firstValue, .afterValue, .key, .firstKey, .afterKey, .done:
        i = streamWhitespaceEnd(base: base, from: i, to: n)
        if i == n { break }
        let byte = base.load(fromByteOffset: i, as: UInt8.self)
        i &+= 1
        if try self.consumeStructural(byte, at: i, into: &sink) { i &-= 1 }

      case .inString, .inKey:
        i = try self.consumeStringRun(base: base, from: i, to: n, into: &sink)

      case .escape:
        let byte = base.load(fromByteOffset: i, as: UInt8.self)
        i &+= 1
        try self.consumeEscape(byte, at: i, into: &sink)

      case .unicode:
        let byte = base.load(fromByteOffset: i, as: UInt8.self)
        i &+= 1
        try self.consumeUnicodeDigit(byte, at: i, into: &sink)

      case .number:
        i = try self.consumeNumber(base: base, from: i, to: n, into: &sink)

      case .literal:
        i = try self.consumeLiteral(base: base, from: i, to: n, into: &sink)
      }
      try self.checkSink(&sink, at: i)
    }

    self.consumedByteCount &+= n
  }

  @inlinable
  public mutating func finish<Sink: StreamParseSink & ~Copyable>(
    into sink: inout Sink
  ) throws(JSONParsingError) {
    switch self.state {
    case .number:
      try self.emitBufferedNumber(into: &sink)
      self.state = .done
    case .value, .firstValue, .key, .firstKey, .afterKey:
      throw self.error(.unexpectedToken)
    case .inString, .inKey, .escape, .unicode:
      throw self.error(.unterminatedString)
    case .literal:
      throw self.error(.invalidLiteral)
    case .afterValue, .done:
      break
    }
    if self.depth > 0 { throw self.error(.unterminatedContainer) }
    if self.pendingUTF8Count > 0 { throw self.error(.invalidUTF8) }
    try self.checkSink(&sink, at: self.consumedByteCount)
  }

  // MARK: Structural

  @inlinable
  mutating func consumeStructural<Sink: StreamParseSink & ~Copyable>(
    _ byte: UInt8,
    at offset: Int,
    into sink: inout Sink
  ) throws(JSONParsingError) -> Bool {
    switch self.state {
    case .value, .firstValue:
      switch byte {
      case .asciiObjectStart:
        sink.beginObject()
        try self.push(isObject: true, at: offset)
        self.state = .firstKey
      case .asciiArrayStart:
        sink.beginArray()
        try self.push(isObject: false, at: offset)
        self.state = .firstValue
      case .asciiArrayEnd:
        guard self.state == .firstValue, self.depth > 0, !self.topIsObject else {
          throw self.error(.unexpectedToken)
        }
        sink.endArray()
        self.pop()
      case .asciiQuote:
        self.isKeyToken = false
        sink.stringBegin()
        self.state = .inString
      case .asciiLowerT: self.startLiteral(kind: 0)
      case .asciiLowerF: self.startLiteral(kind: 1)
      case .asciiLowerN: self.startLiteral(kind: 2)
      case .asciiDash, .asciiZero ... .asciiNine:
        self.resetNumber()
        self.state = .number
        return true
      default:
        throw self.error(.unexpectedToken)
      }

    case .afterValue:
      switch byte {
      case .asciiComma:
        guard self.depth > 0 else { throw self.error(.unexpectedToken) }
        self.state = self.topIsObject ? .key : .value
      case .asciiArrayEnd:
        guard self.depth > 0, !self.topIsObject else { throw self.error(.unexpectedToken) }
        sink.endArray()
        self.pop()
      case .asciiObjectEnd:
        guard self.depth > 0, self.topIsObject else { throw self.error(.unexpectedToken) }
        sink.endObject()
        self.pop()
      default:
        throw self.error(.unexpectedToken)
      }

    case .key, .firstKey:
      switch byte {
      case .asciiQuote:
        self.isKeyToken = true
        self.bufferCount = 0
        self.state = .inKey
      case .asciiObjectEnd:
        guard self.state == .firstKey, self.depth > 0, self.topIsObject else {
          throw self.error(.unexpectedToken)
        }
        sink.endObject()
        self.pop()
      default:
        throw self.error(.unexpectedToken)
      }

    case .afterKey:
      guard byte == .asciiColon else { throw self.error(.unexpectedToken) }
      self.state = .value

    case .done:
      throw self.error(.trailingContent)

    default:
      throw self.error(.unexpectedToken)
    }
    return false
  }

  // MARK: Strings

  // Keys are always copied into the buffer, which gives contiguity across chunks and the
  // padding a generated matcher relies on in one step. They are short enough that the copy
  // costs less than the branch needed to sometimes avoid it.
  @inlinable
  mutating func consumeStringRun<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer,
    from: Int,
    to: Int,
    into sink: inout Sink
  ) throws(JSONParsingError) -> Int {
    let isKey = self.state == .inKey
    var i = from
    let end = streamStringRunEnd(base: base, from: i, to: to)

    if end > i {
      if self.highSurrogate != 0, self.configuration.validatesUTF8 {
        throw self.error(.invalidEscape)
      }
      if isKey {
        try self.appendToBuffer(base: base, from: i, count: end &- i)
      } else {
        let emitEnd = end == to ? try self.trimmingIncompleteUTF8(base: base, from: i, to: end) : end
        if emitEnd > i {
          try self.validateUTF8IfNeeded(base: base, from: i, to: emitEnd)
          let slice = UnsafeBufferPointer(
            start: base.advanced(by: i).assumingMemoryBound(to: UInt8.self),
            count: emitEnd &- i
          )
          sink.stringChunk(Span(_unsafeElements: slice))
        }
        if emitEnd < end {
          try self.holdPendingUTF8(base: base, from: emitEnd, to: end)
        }
      }
      i = end
    }

    guard i < to else { return i }

    let byte = base.load(fromByteOffset: i, as: UInt8.self)
    i &+= 1
    if byte == .asciiQuote {
      if self.highSurrogate != 0, self.configuration.validatesUTF8 {
        throw self.error(.invalidEscape)
      }
      if isKey {
        try self.emitBufferedKey(into: &sink)
        self.state = .afterKey
      } else {
        sink.stringEnd()
        self.state = .afterValue
      }
    } else if byte == .asciiBackslash {
      self.state = .escape
    } else {
      throw self.error(.unterminatedString)
    }
    return i
  }

  @inlinable
  mutating func consumeEscape<Sink: StreamParseSink & ~Copyable>(
    _ byte: UInt8,
    at offset: Int,
    into sink: inout Sink
  ) throws(JSONParsingError) {
    if byte == .asciiLowerU {
      self.unicodeValue = 0
      self.unicodeRemaining = 4
      self.state = .unicode
      return
    }
    // A high surrogate must be followed immediately by a low surrogate escape. Any other escape
    // severs the pair, and emitting it first would also reorder the content around the error.
    if self.highSurrogate != 0, self.configuration.validatesUTF8 {
      throw self.error(.invalidEscape)
    }
    let decoded: UInt8
    switch byte {
    case .asciiQuote, .asciiBackslash, .asciiSlash: decoded = byte
    case .asciiLowerN: decoded = .asciiLineFeed
    case .asciiLowerR: decoded = .asciiCarriageReturn
    case .asciiLowerT: decoded = .asciiTab
    case .asciiLowerB: decoded = .asciiBackspace
    case .asciiLowerF: decoded = .asciiFormFeed
    default:
      guard !self.configuration.validatesLiterals else { throw self.error(.invalidEscape) }
      decoded = byte
    }
    try self.emitDecoded(byte: decoded, into: &sink)
    self.state = self.stateAfterEscape
  }

  @inlinable
  mutating func consumeUnicodeDigit<Sink: StreamParseSink & ~Copyable>(
    _ byte: UInt8,
    at offset: Int,
    into sink: inout Sink
  ) throws(JSONParsingError) {
    guard let value = Self.hexValue(byte) else { throw self.error(.invalidEscape) }
    self.unicodeValue = (self.unicodeValue << 4) | value
    self.unicodeRemaining &-= 1
    guard self.unicodeRemaining == 0 else { return }

    let scalar = self.unicodeValue
    if scalar >= .highSurrogateFloor, scalar <= .highSurrogateCeiling {
      // A second high surrogate would silently replace the pending one, leaving the first lone.
      if self.highSurrogate != 0, self.configuration.validatesUTF8 {
        throw self.error(.invalidEscape)
      }
      self.highSurrogate = scalar
      self.state = self.stateAfterEscape
      return
    }
    if scalar >= .lowSurrogateFloor, scalar <= .lowSurrogateCeiling, self.highSurrogate == 0,
      self.configuration.validatesUTF8
    {
      throw self.error(.invalidEscape)
    }
    if scalar >= .lowSurrogateFloor, scalar <= .lowSurrogateCeiling, self.highSurrogate != 0 {
      let combined =
        .utf8ThreeByteCeiling &+ ((self.highSurrogate &- .highSurrogateFloor) << 10)
        &+ (scalar &- .lowSurrogateFloor)
      self.highSurrogate = 0
      try self.emitScalar(combined, into: &sink)
    } else {
      // A pending high surrogate followed by any scalar but a low surrogate is lone.
      if self.highSurrogate != 0, self.configuration.validatesUTF8 {
        throw self.error(.invalidEscape)
      }
      try self.emitScalar(scalar, into: &sink)
    }
    self.state = self.stateAfterEscape
  }

  @inlinable
  var stateAfterEscape: State {
    self.isKeyToken ? .inKey : .inString
  }

  // MARK: Numbers

  @inlinable
  mutating func resetNumber() {
    self.magnitude = 0
    self.digitCount = 0
    self.fractionDigits = 0
    self.explicitExponent = 0
    self.numberFlags = []
    self.inExponent = false
    self.sawDot = false
    self.exponentNegative = false
    self.exponentDigits = 0
    self.integerDigits = 0
    self.firstIntegerDigitIsZero = false
    self.bufferCount = 0
  }

  // Fused: the boundary scan and the magnitude accumulation happen in one pass, using wrapping
  // arithmetic and a digit count check rather than per digit overflow checks. Measured 17%
  // faster end to end on a number dense payload.
  @inlinable
  mutating func consumeNumber<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer,
    from: Int,
    to: Int,
    into sink: inout Sink
  ) throws(JSONParsingError) -> Int {
    let start = from
    var i = from
    // A number that began in an earlier chunk has its head in the buffer, so the provisional
    // span has to come from there to stay contiguous. One that begins here is already
    // contiguous in the input and needs no copy, which is the common case.
    let spansChunks = self.bufferCount > 0
    while i < to {
      let byte = base.load(fromByteOffset: i, as: UInt8.self)
      let digit = byte &- .asciiZero
      var isDigit = false
      if digit < 10 {
        isDigit = true
        if self.inExponent {
          self.exponentDigits &+= 1
          if self.explicitExponent < 10_000 {
            self.explicitExponent = self.explicitExponent &* 10 &+ Int32(digit)
          }
        } else {
          self.magnitude = self.magnitude &* 10 &+ UInt64(digit)
          self.digitCount &+= 1
          if self.sawDot {
            self.fractionDigits &+= 1
          } else {
            self.integerDigits &+= 1
            if self.integerDigits == 1 { self.firstIntegerDigitIsZero = digit == 0 }
          }
        }
      } else if byte == .asciiDot, !self.sawDot, !self.inExponent {
        self.sawDot = true
        self.numberFlags.insert(.fraction)
      } else if byte == .asciiLowerE || byte == .asciiUpperE, !self.inExponent {
        self.inExponent = true
        self.numberFlags.insert(.exponent)
      } else if byte == .asciiDash {
        if self.inExponent && self.exponentDigits == 0 {
          self.exponentNegative = true
        } else if self.digitCount == 0, !self.sawDot, !self.numberFlags.contains(.negative) {
          self.numberFlags.insert(.negative)
        } else {
          break
        }
      } else if byte == .asciiPlus {
        guard self.inExponent, self.exponentDigits == 0 else { break }
      } else {
        break
      }

      // Past every break, so the byte is part of the token. The spanning case copies as it goes,
      // because its span has to include the head already sitting in the buffer.
      if spansChunks {
        try self.appendToBuffer(base: base, from: i, count: 1)
      }

      // Only digits move the value, so only digits are worth reporting: a dot or an exponent
      // marker on its own describes the same number as the digit before it.
      if isDigit {
        if spansChunks {
          let buffered = UnsafeBufferPointer(
            start: self.buffer.baseAddress!, count: self.bufferCount
          )
          self.emitProvisionalNumber(Span(_unsafeElements: buffered), into: &sink)
        } else {
          let prefix = UnsafeBufferPointer(
            start: base.advanced(by: start).assumingMemoryBound(to: UInt8.self),
            count: i &- start &+ 1
          )
          self.emitProvisionalNumber(Span(_unsafeElements: prefix), into: &sink)
        }
      }
      i &+= 1
    }

    // A token that both starts and ends inside this chunk is already contiguous, so it can be
    // handed over in place. Only one spanning a boundary needs the copy.
    if i < to, self.bufferCount == 0 {
      let slice = UnsafeBufferPointer(
        start: base.advanced(by: start).assumingMemoryBound(to: UInt8.self),
        count: i &- start
      )
      try self.emitNumber(Span(_unsafeElements: slice), into: &sink)
      self.state = .afterValue
      return i
    }

    // The spanning path already copied every digit it consumed, so only the non digit bytes of
    // this run remain to be appended.
    if !spansChunks {
      try self.appendToBuffer(base: base, from: start, count: i &- start)
    }

    guard i < to else { return i }
    try self.emitBufferedNumber(into: &sink)
    self.state = .afterValue
    return i
  }

  @inlinable
  mutating func emitBufferedNumber<Sink: StreamParseSink & ~Copyable>(
    into sink: inout Sink
  ) throws(JSONParsingError) {
    let count = self.bufferCount
    let slice = UnsafeBufferPointer(start: self.buffer.baseAddress!, count: count)
    try self.emitNumber(Span(_unsafeElements: slice), into: &sink)
    self.bufferCount = 0
  }

  // Emits the value the digits seen so far describe, without validating: a prefix of a valid
  // token is not itself a valid token, so `1e` and `0` on the way to `01` must not be rejected
  // here. Validation stays at the token boundary, where the grammar is decidable.
  @inlinable
  mutating func emitProvisionalNumber<Sink: StreamParseSink & ~Copyable>(
    _ bytes: Span<UInt8>,
    into sink: inout Sink
  ) {
    if self.digitCount > 19 { self.numberFlags.insert(.overflowed) }
    let signedExponent = self.exponentNegative ? -self.explicitExponent : self.explicitExponent
    let net = signedExponent &- self.fractionDigits
    let info = NumberInfo(
      magnitude: self.magnitude,
      exponent: Int16(clamping: net),
      digitCount: self.digitCount,
      flags: self.numberFlags.union(.incomplete)
    )
    sink.number(bytes, info: info)
  }

  @inlinable
  mutating func emitNumber<Sink: StreamParseSink & ~Copyable>(
    _ bytes: Span<UInt8>,
    into sink: inout Sink
  ) throws(JSONParsingError) {
    if self.configuration.validatesNumberGrammar {
      guard self.integerDigits > 0 else { throw self.error(.invalidNumber) }
      guard self.integerDigits == 1 || !self.firstIntegerDigitIsZero else {
        throw self.error(.invalidNumber)
      }
      guard !self.sawDot || self.fractionDigits > 0 else { throw self.error(.invalidNumber) }
      guard !self.inExponent || self.exponentDigits > 0 else { throw self.error(.invalidNumber) }
    }
    if self.digitCount > 19 { self.numberFlags.insert(.overflowed) }
    let signedExponent = self.exponentNegative ? -self.explicitExponent : self.explicitExponent
    let net = signedExponent &- self.fractionDigits
    let info = NumberInfo(
      magnitude: self.magnitude,
      exponent: Int16(clamping: net),
      digitCount: self.digitCount,
      flags: self.numberFlags
    )
    sink.number(bytes, info: info)
  }

  // MARK: Literals

  @usableFromInline
  static let literalBytes: [[UInt8]] = [
    [.asciiLowerT, .asciiLowerR, .asciiLowerU, .asciiLowerE],
    [.asciiLowerF, .asciiLowerA, .asciiLowerL, .asciiLowerS, .asciiLowerE],
    [.asciiLowerN, .asciiLowerU, .asciiLowerL, .asciiLowerL],
  ]

  @inlinable
  mutating func startLiteral(kind: UInt8) {
    self.literalKind = kind
    self.literalIndex = 1
    self.state = .literal
  }

  @inlinable
  mutating func consumeLiteral<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer,
    from: Int,
    to: Int,
    into sink: inout Sink
  ) throws(JSONParsingError) -> Int {
    let expected = Self.literalBytes[Int(self.literalKind)]
    var i = from
    while i < to && self.literalIndex < expected.count {
      let byte = base.load(fromByteOffset: i, as: UInt8.self)
      if self.configuration.validatesLiterals && byte != expected[self.literalIndex] {
        throw self.error(.invalidLiteral)
      }
      self.literalIndex &+= 1
      i &+= 1
    }
    if self.literalIndex == expected.count {
      switch self.literalKind {
      case 0: sink.boolean(true)
      case 1: sink.boolean(false)
      default: sink.null()
      }
      self.state = .afterValue
    }
    return i
  }

  // MARK: Buffer

  @inlinable
  mutating func appendToBuffer(
    base: UnsafeRawPointer, from: Int, count: Int
  ) throws(JSONParsingError) {
    guard count > 0 else { return }
    guard self.bufferCount &+ count &+ StreamParsingLayout.keyPaddingByteCount
      <= self.buffer.count
    else {
      throw self.error(.bufferExhausted)
    }
    UnsafeMutableRawPointer(self.buffer.baseAddress! + self.bufferCount)
      .copyMemory(from: base.advanced(by: from), byteCount: count)
    self.bufferCount &+= count
  }

  @inlinable
  mutating func emitBufferedKey<Sink: StreamParseSink & ~Copyable>(
    into sink: inout Sink
  ) throws(JSONParsingError) {
    let count = self.bufferCount
    try self.validateUTF8IfNeeded(
      base: UnsafeRawPointer(self.buffer.baseAddress!), from: 0, to: count
    )
    // Zero the padding so a matcher loading a whole vector sees defined bytes.
    for offset in count..<(count &+ StreamParsingLayout.keyPaddingByteCount) {
      self.buffer[offset] = 0
    }
    let slice = UnsafeBufferPointer(start: self.buffer.baseAddress!, count: count)
    sink.key(Span(_unsafeElements: slice))
    self.bufferCount = 0
  }

  // MARK: UTF-8

  @inlinable
  mutating func trimmingIncompleteUTF8(
    base: UnsafeRawPointer, from: Int, to: Int
  ) throws(JSONParsingError) -> Int {
    var index = to &- 1
    let lowest = Swift.max(from, to &- 4)
    while index >= lowest {
      let byte = base.load(fromByteOffset: index, as: UInt8.self)
      if byte < .utf8ContinuationFloor { return to }
      if byte >= .utf8TwoByteFloor {
        let needed = Self.sequenceLength(byte)
        let available = to &- index
        return available >= needed ? to : index
      }
      index &-= 1
    }
    return to
  }

  @inlinable
  mutating func holdPendingUTF8(
    base: UnsafeRawPointer, from: Int, to: Int
  ) throws(JSONParsingError) {
    let count = to &- from
    guard count <= 4 else { throw self.error(.invalidUTF8) }
    // An invalid lead can be rejected before anything is held, which leaves completion with only
    // the second byte constraints to check.
    if self.configuration.validatesUTF8 {
      let lead = base.load(fromByteOffset: from, as: UInt8.self)
      guard lead >= .utf8TwoByteMinimum, lead <= .utf8LeadCeiling else {
        throw self.error(.invalidUTF8)
      }
    }
    for offset in 0..<count {
      self.buffer[self.buffer.count &- 8 &+ offset] =
        base.load(fromByteOffset: from &+ offset, as: UInt8.self)
    }
    self.pendingUTF8Count = count
  }

  // Only continuation bytes are taken, and the reassembled sequence goes through the same
  // validation a contiguous one would. Filling blindly swallowed whatever byte came next — a
  // closing quote, structurally — and emitting without validating accepted overlongs, encoded
  // surrogates and out of range leads whenever the split fell inside the sequence, which is
  // every sequence when fed byte by byte.
  @inlinable
  mutating func completePendingUTF8<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer, count n: Int, into sink: inout Sink
  ) throws(JSONParsingError) -> Int {
    let tailStart = self.buffer.count &- 8
    let lead = self.buffer[tailStart]
    let needed = Self.sequenceLength(lead)
    var have = self.pendingUTF8Count
    var i = 0
    while have < needed && i < n {
      let byte = base.load(fromByteOffset: i, as: UInt8.self)
      guard byte >= .utf8ContinuationFloor, byte < .utf8TwoByteFloor else { break }
      self.buffer[tailStart &+ have] = byte
      have &+= 1
      i &+= 1
    }
    if have < needed {
      if i == n {
        self.pendingUTF8Count = have
        return n
      }
      // The next byte is not a continuation, so the sequence is truncated. Unchecked parsing
      // emits the fragment and lets the byte be what it is, matching what the bulk path does
      // with a truncated sequence mid chunk.
      if self.configuration.validatesUTF8 { throw self.error(.invalidUTF8) }
      self.pendingUTF8Count = 0
      let slice = UnsafeBufferPointer(start: self.buffer.baseAddress! + tailStart, count: have)
      sink.stringChunk(Span(_unsafeElements: slice))
      return i
    }
    self.pendingUTF8Count = 0
    // The fill loop admitted only continuation bytes and the hold rejected invalid leads, so the
    // sequence is valid unless its second byte encodes an overlong, a surrogate or a scalar past
    // U+10FFFF — the same second byte constraints the contiguous validator applies, without its
    // ASCII prescan, which measured 32% of byte fed non-ASCII throughput.
    if self.configuration.validatesUTF8, needed > 1 {
      let second = self.buffer[tailStart &+ 1]
      switch lead {
      case .utf8ThreeByteFloor:
        guard second >= .utf8ThreeByteLowerBound else { throw self.error(.invalidUTF8) }
      case .utf8SurrogateLead:
        guard second <= .utf8SurrogateCeiling else { throw self.error(.invalidUTF8) }
      case .utf8FourByteFloor:
        guard second >= .utf8FourByteLowerBound else { throw self.error(.invalidUTF8) }
      case .utf8MaximumLead:
        guard second <= .utf8MaximumSecond else { throw self.error(.invalidUTF8) }
      default:
        break
      }
    }
    let slice = UnsafeBufferPointer(start: self.buffer.baseAddress! + tailStart, count: needed)
    sink.stringChunk(Span(_unsafeElements: slice))
    return i
  }

  @inlinable
  static func sequenceLength(_ lead: UInt8) -> Int {
    if lead < .utf8ContinuationFloor { return 1 }
    if lead >= .utf8FourByteFloor { return 4 }
    if lead >= .utf8ThreeByteFloor { return 3 }
    if lead >= .utf8TwoByteFloor { return 2 }
    return 1
  }

  @inlinable
  mutating func validateUTF8IfNeeded(
    base: UnsafeRawPointer, from: Int, to: Int
  ) throws(JSONParsingError) {
    guard self.configuration.validatesUTF8 else { return }
    guard streamContainsNonASCII(base: base, from: from, to: to) else { return }
    var i = from
    while i < to {
      let lead = base.load(fromByteOffset: i, as: UInt8.self)
      if lead < .utf8ContinuationFloor {
        i &+= 1
        continue
      }
      guard lead >= .utf8TwoByteMinimum, lead <= .utf8LeadCeiling else { throw self.error(.invalidUTF8) }
      let needed = Self.sequenceLength(lead)
      guard i &+ needed <= to else { throw self.error(.invalidUTF8) }
      for offset in 1..<needed {
        let continuation = base.load(fromByteOffset: i &+ offset, as: UInt8.self)
        guard continuation >= .utf8ContinuationFloor, continuation < .utf8TwoByteFloor else {
          throw self.error(.invalidUTF8)
        }
      }
      let second = base.load(fromByteOffset: i &+ 1, as: UInt8.self)
      switch lead {
      case .utf8ThreeByteFloor:
        guard second >= .utf8ThreeByteLowerBound else { throw self.error(.invalidUTF8) }
      case .utf8SurrogateLead:
        guard second <= .utf8SurrogateCeiling else { throw self.error(.invalidUTF8) }
      case .utf8FourByteFloor:
        guard second >= .utf8FourByteLowerBound else { throw self.error(.invalidUTF8) }
      case .utf8MaximumLead:
        guard second <= .utf8MaximumSecond else { throw self.error(.invalidUTF8) }
      default:
        break
      }
      i &+= needed
    }
  }

  // MARK: Emission helpers

  // The last sixteen bytes of the buffer are reserved: eight for a UTF-8 sequence straddling a
  // chunk boundary and four for an escape being decoded. Neither can be live at once.
  @inlinable
  var escapeScratchOffset: Int { self.buffer.count &- 4 }

  @inlinable
  mutating func emitScalar<Sink: StreamParseSink & ~Copyable>(
    _ value: UInt32, into sink: inout Sink
  ) throws(JSONParsingError) {
    let at = self.escapeScratchOffset
    let count: Int
    if value < .utf8OneByteCeiling {
      self.buffer[at] = UInt8(value)
      count = 1
    } else if value < .utf8TwoByteCeiling {
      self.buffer[at] = UInt8(0xC0 | (value >> 6))
      self.buffer[at &+ 1] = UInt8(0x80 | (value & .utf8ContinuationMask))
      count = 2
    } else if value < .utf8ThreeByteCeiling {
      self.buffer[at] = UInt8(0xE0 | (value >> 12))
      self.buffer[at &+ 1] = UInt8(0x80 | ((value >> 6) & .utf8ContinuationMask))
      self.buffer[at &+ 2] = UInt8(0x80 | (value & .utf8ContinuationMask))
      count = 3
    } else {
      self.buffer[at] = UInt8(0xF0 | (value >> 18))
      self.buffer[at &+ 1] = UInt8(0x80 | ((value >> 12) & .utf8ContinuationMask))
      self.buffer[at &+ 2] = UInt8(0x80 | ((value >> 6) & .utf8ContinuationMask))
      self.buffer[at &+ 3] = UInt8(0x80 | (value & .utf8ContinuationMask))
      count = 4
    }
    try self.emitScratch(count: count, into: &sink)
  }

  @inlinable
  mutating func emitDecoded<Sink: StreamParseSink & ~Copyable>(
    byte: UInt8, into sink: inout Sink
  ) throws(JSONParsingError) {
    self.buffer[self.escapeScratchOffset] = byte
    try self.emitScratch(count: 1, into: &sink)
  }

  @inlinable
  mutating func emitScratch<Sink: StreamParseSink & ~Copyable>(
    count: Int, into sink: inout Sink
  ) throws(JSONParsingError) {
    let at = self.escapeScratchOffset
    if self.isKeyToken {
      try self.appendToBuffer(
        base: UnsafeRawPointer(self.buffer.baseAddress! + at), from: 0, count: count
      )
      return
    }
    let slice = UnsafeBufferPointer(start: self.buffer.baseAddress! + at, count: count)
    sink.stringChunk(Span(_unsafeElements: slice))
  }

  // MARK: Container stack

  @inlinable
  var topIsObject: Bool {
    self.depth > 0 && (self.containers >> UInt64(self.depth &- 1)) & 1 == 1
  }

  @inlinable
  mutating func push(isObject: Bool, at offset: Int) throws(JSONParsingError) {
    guard self.depth < Self.maximumDepth else { throw self.error(.depthExceeded) }
    if isObject {
      self.containers |= 1 << UInt64(self.depth)
    } else {
      self.containers &= ~(1 << UInt64(self.depth))
    }
    self.depth &+= 1
  }

  @inlinable
  mutating func pop() {
    if self.depth > 0 { self.depth &-= 1 }
    self.state = self.depth == 0 ? .done : .afterValue
  }

  // MARK: Diagnostics

  @inlinable
  func error(_ reason: JSONParsingError.Reason) -> JSONParsingError {
    JSONParsingError(reason: reason, byteOffset: self.consumedByteCount)
  }

  @inlinable
  mutating func checkSink<Sink: StreamParseSink & ~Copyable>(
    _ sink: inout Sink, at offset: Int
  ) throws(JSONParsingError) {
    if let failure = sink.streamFailure {
      throw JSONParsingError(
        reason: .sinkRejectedToken(failure), byteOffset: self.consumedByteCount &+ offset
      )
    }
  }

  @inlinable
  static func hexValue(_ byte: UInt8) -> UInt32? {
    switch byte {
    case .asciiZero ... .asciiNine: UInt32(byte &- .asciiZero)
    case .asciiLowerA ... .asciiLowerF: UInt32(byte &- .asciiLowerA &+ 10)
    case .asciiUpperA ... .asciiUpperF: UInt32(byte &- .asciiUpperA &+ 10)
    default: nil
    }
  }
}
