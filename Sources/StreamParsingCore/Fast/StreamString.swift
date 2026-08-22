// String storage the parser can append to without materializing a `String` per chunk.
//
// `String.streamAppend` is `self += String(decoding:)`: a whole intermediate `String` built and
// destroyed per chunk, re-validating UTF-8 the parser already validated. Bulk pays it once per
// escape-delimited run — every escape splits the run, so escaped markdown pays it every ~80
// bytes — and a byte fed stream pays it per content byte, ~61 ns each measured in
// `StringAppendBenchmarks`. Accumulating raw bytes and decoding once at read was the floor those
// measurements found, ~7x under the append path at small chunks; this is that accumulation.
//
// Values up to 64 UTF-8 bytes live inline. That covers the short keys and values which previously
// fit `String`'s small representation, without charging every non-empty partial string a tail
// allocation. Once the inline buffer overflows, storage takes `StreamArray`'s shape for the same
// snapshot reasons:
//
// - **Sealed bytes live in fixed size blocks.** Once a block fills it is never written again, so
//   a snapshot shares it forever and an append after a snapshot copies at most the tail, not the
//   accumulated string.
// - **Blocks are `ContiguousArray` rather than a class wrapping one.** A single refcounted
//   pointer each, copy on write for the shared tail comes for free, and every stored property
//   stays a value type, which is what lets `Sendable` be checked rather than asserted.
//
// The blocked layout is canonical: a block seals exactly when it fills, so where the block
// boundaries fall is a function of the byte count alone. Two equal values therefore pair up one
// contiguous window at a time whether they are inline or blocked.
public struct StreamString {
  @usableFromInline
  struct InlineBuffer: Hashable, Sendable {
    @usableFromInline var word0: UInt64 = 0
    @usableFromInline var word1: UInt64 = 0
    @usableFromInline var word2: UInt64 = 0
    @usableFromInline var word3: UInt64 = 0
    @usableFromInline var word4: UInt64 = 0
    @usableFromInline var word5: UInt64 = 0
    @usableFromInline var word6: UInt64 = 0
    @usableFromInline var word7: UInt64 = 0

    @usableFromInline
    init() {}
  }

  // Kept directly in the value. A copied short string copies these bytes, so snapshots need no
  // reference counting and a short append needs no allocation.
  @usableFromInline var inlineBytes: InlineBuffer
  @usableFromInline var inlineCount: Int

  // Sealed and never written again. Every block holds exactly `blockCapacity` bytes, which keeps
  // indexing a shift and a mask rather than a search over prefix sums.
  @usableFromInline var blocks: [ContiguousArray<UInt8>]

  // The filling block. The only allocated storage an append can touch, and so the most a
  // snapshot-sharing append ever copies after the inline representation overflows.
  @usableFromInline var tail: ContiguousArray<UInt8>

  @usableFromInline static var inlineCapacity: Int { 64 }

  // 512 bytes: big enough that a long string's spine stays short and its per block malloc
  // amortizes, small enough that the copy a snapshot forces stays trivial.
  @usableFromInline static var blockShift: Int { 9 }
  @usableFromInline static var blockCapacity: Int { 1 &<< Self.blockShift }
  @usableFromInline static var blockMask: Int { Self.blockCapacity &- 1 }

  public init() {
    self.inlineBytes = InlineBuffer()
    self.inlineCount = 0
    self.blocks = [ContiguousArray<UInt8>]()
    self.tail = ContiguousArray<UInt8>()
  }

  public init(_ string: some StringProtocol) {
    self.init()
    var copy = String(string)
    copy.withUTF8 { self.append(utf8: $0) }
  }

  @usableFromInline var usesInlineStorage: Bool { self.blocks.isEmpty && self.tail.isEmpty }
  @usableFromInline var sealedCount: Int { self.blocks.count &<< Self.blockShift }

  /// The number of UTF-8 bytes accumulated so far.
  @inlinable
  public var utf8Count: Int {
    self.usesInlineStorage ? self.inlineCount : self.sealedCount &+ self.tail.count
  }

  /// Whether no bytes have accumulated.
  @inlinable
  public var isEmpty: Bool { self.utf8Count == 0 }

  // MARK: Append

  @inlinable
  mutating func append(utf8 buffer: UnsafeBufferPointer<UInt8>) {
    guard let base = buffer.baseAddress, !buffer.isEmpty else { return }
    if self.usesInlineStorage {
      let needed = self.inlineCount &+ buffer.count
      if needed <= Self.inlineCapacity {
        withUnsafeMutableBytes(of: &self.inlineBytes) { destination in
          destination.baseAddress!.advanced(by: self.inlineCount).copyMemory(
            from: base, byteCount: buffer.count
          )
        }
        self.inlineCount = needed
        return
      }
      self.promoteInlineStorage(reserving: needed)
    }
    self.appendBlocked(buffer)
  }

  @inlinable
  mutating func promoteInlineStorage(reserving capacity: Int) {
    let count = self.inlineCount
    let reservation = count == 0
      ? min(capacity, Self.blockCapacity)
      : Self.blockCapacity
    self.tail.reserveCapacity(reservation)
    if count > 0 {
      withUnsafeBytes(of: self.inlineBytes) { source in
        self.tail.append(
          contentsOf: UnsafeBufferPointer(
            start: source.baseAddress!.assumingMemoryBound(to: UInt8.self), count: count
          )
        )
      }
    }
    self.inlineCount = 0
  }

  @inlinable
  mutating func appendBlocked(_ buffer: UnsafeBufferPointer<UInt8>) {
    guard let base = buffer.baseAddress else { return }
    var offset = 0
    while offset < buffer.count {
      let take = min(Self.blockCapacity &- self.tail.count, buffer.count &- offset)
      let needed = self.tail.count &+ take
      if self.tail.capacity < needed {
        self.tail.reserveCapacity(self.tail.isEmpty ? take : Self.blockCapacity)
      }
      self.tail.append(contentsOf: UnsafeBufferPointer(start: base + offset, count: take))
      offset &+= take
      guard self.tail.count == Self.blockCapacity else { continue }
      self.blocks.append(self.tail)
      self.tail = ContiguousArray<UInt8>()
    }
  }

  // MARK: Reading

  @usableFromInline
  func withInlineBuffer<R>(_ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R {
    try withUnsafeBytes(of: self.inlineBytes) { source in
      try body(
        UnsafeBufferPointer(
          start: source.baseAddress!.assumingMemoryBound(to: UInt8.self), count: self.inlineCount
        )
      )
    }
  }

  // Copies `range` into `destination`. Inline values are one memcpy. Blocked values use one
  // memcpy per block they touch, plus one for the tail — the floor for storage which can share
  // sealed bytes across snapshots without relocating them on growth.
  @usableFromInline
  func copyBytes(in range: Range<Int>, to destination: UnsafeMutableBufferPointer<UInt8>) {
    guard let base = destination.baseAddress, !range.isEmpty else { return }
    if self.usesInlineStorage {
      self.withInlineBuffer { source in
        base.initialize(from: source.baseAddress! + range.lowerBound, count: range.count)
      }
      return
    }
    let sealed = self.sealedCount
    var written = 0
    var position = range.lowerBound
    while position < min(range.upperBound, sealed) {
      let block = position &>> Self.blockShift
      let start = position & Self.blockMask
      let take = min(Self.blockCapacity &- start, range.upperBound &- position)
      self.blocks[block].withUnsafeBufferPointer { source in
        (base + written).initialize(from: source.baseAddress! + start, count: take)
      }
      written &+= take
      position &+= take
    }
    guard position < range.upperBound else { return }
    self.tail.withUnsafeBufferPointer { source in
      (base + written).initialize(
        from: source.baseAddress! + (position &- sealed),
        count: range.upperBound &- position
      )
    }
  }

  // Decodes `range`, repairing rather than validating: a repairing decode cannot fail, which is
  // what lets this be a plain `String` read rather than a throwing one.
  @usableFromInline
  func decode(in range: Range<Int>) -> String {
    guard !range.isEmpty else { return "" }
    if self.usesInlineStorage {
      return self.withInlineBuffer { buffer in
        String(
          decoding: UnsafeBufferPointer(rebasing: buffer[range.lowerBound..<range.upperBound]),
          as: UTF8.self
        )
      }
    }
    // A range in the allocated tail or inside one sealed block is contiguous, so both decode in
    // place with no gathering copy.
    if self.blocks.isEmpty {
      return self.tail.withUnsafeBufferPointer { buffer in
        String(
          decoding: UnsafeBufferPointer(rebasing: buffer[range.lowerBound..<range.upperBound]),
          as: UTF8.self
        )
      }
    }
    let firstBlock = range.lowerBound &>> Self.blockShift
    if range.lowerBound >= self.sealedCount {
      let start = range.lowerBound &- self.sealedCount
      let end = range.upperBound &- self.sealedCount
      return self.tail.withUnsafeBufferPointer { buffer in
        String(decoding: UnsafeBufferPointer(rebasing: buffer[start..<end]), as: UTF8.self)
      }
    }
    if range.upperBound <= (firstBlock &+ 1) &<< Self.blockShift {
      let start = range.lowerBound & Self.blockMask
      let end = start &+ range.count
      return self.blocks[firstBlock].withUnsafeBufferPointer { buffer in
        String(decoding: UnsafeBufferPointer(rebasing: buffer[start..<end]), as: UTF8.self)
      }
    }
    return String(unsafeUninitializedCapacity: range.count) { destination in
      self.copyBytes(in: range, to: destination)
      return range.count
    }
  }
}

// MARK: - Byte access

extension StreamString {
  // The one byte read every view routes through: an inline offset, a shift and mask into a sealed
  // block, or an offset into the tail.
  @inlinable
  func utf8Byte(at position: Int) -> UInt8 {
    if self.usesInlineStorage {
      precondition(position < self.inlineCount, "StreamString byte offset out of range")
      return self.withInlineBuffer { $0[position] }
    }
    let sealed = self.sealedCount
    if position < sealed {
      return self.blocks[position &>> Self.blockShift][position & Self.blockMask]
    }
    let offset = position &- sealed
    precondition(offset < self.tail.count, "StreamString byte offset out of range")
    return self.tail[offset]
  }

  // Runs `body` over the contiguous bytes at `[position, position + count)`, which must not
  // cross a 512-byte window. An inline value is entirely one window; block seals and the tail are
  // 512-aligned after promotion.
  @usableFromInline
  func withWindow<R>(
    at position: Int, count: Int, _ body: (UnsafeBufferPointer<UInt8>) -> R
  ) -> R {
    if self.usesInlineStorage {
      return self.withInlineBuffer { buffer in
        body(UnsafeBufferPointer(start: buffer.baseAddress! + position, count: count))
      }
    }
    let sealed = self.sealedCount
    if position < sealed {
      return self.blocks[position &>> Self.blockShift].withUnsafeBufferPointer { buffer in
        body(
          UnsafeBufferPointer(
            start: buffer.baseAddress! + (position & Self.blockMask), count: count
          )
        )
      }
    }
    return self.tail.withUnsafeBufferPointer { buffer in
      body(UnsafeBufferPointer(start: buffer.baseAddress! + (position &- sealed), count: count))
    }
  }
}

// MARK: - Scalar decoding

extension StreamString {
  // Decodes the scalar starting at `position`, repairing: a byte that does not begin a
  // well-formed sequence decodes as U+FFFD with length one, the same policy as the repairing
  // `String` decode, so the two views tell one story about invalid bytes. The narrowed
  // second-byte ranges are what reject overlong forms and surrogates.
  @usableFromInline
  func decodeScalar(at position: Int) -> (scalar: Unicode.Scalar, length: Int) {
    let lead = self.utf8Byte(at: position)
    if lead < 0x80 { return (Unicode.Scalar(lead), 1) }
    let length: Int
    var second: ClosedRange<UInt8> = 0x80...0xBF
    switch lead {
    case 0xC2...0xDF: length = 2
    case 0xE0: length = 3; second = 0xA0...0xBF
    case 0xE1...0xEC, 0xEE, 0xEF: length = 3
    case 0xED: length = 3; second = 0x80...0x9F
    case 0xF0: length = 4; second = 0x90...0xBF
    case 0xF1...0xF3: length = 4
    case 0xF4: length = 4; second = 0x80...0x8F
    default: return ("\u{FFFD}", 1)
    }
    guard position &+ length <= self.utf8Count else { return ("\u{FFFD}", 1) }
    let byte1 = self.utf8Byte(at: position &+ 1)
    guard second.contains(byte1) else { return ("\u{FFFD}", 1) }
    // The lead's payload mask follows from its length: 0x1F, 0x0F, 0x07 for two, three, four.
    var value = UInt32(lead & (0x7F &>> UInt8(length)))
    value = value &<< 6 | UInt32(byte1 & 0x3F)
    if length > 2 {
      let byte2 = self.utf8Byte(at: position &+ 2)
      guard byte2 & 0xC0 == 0x80 else { return ("\u{FFFD}", 1) }
      value = value &<< 6 | UInt32(byte2 & 0x3F)
    }
    if length > 3 {
      let byte3 = self.utf8Byte(at: position &+ 3)
      guard byte3 & 0xC0 == 0x80 else { return ("\u{FFFD}", 1) }
      value = value &<< 6 | UInt32(byte3 & 0x3F)
    }
    // In range and not a surrogate by the second-byte narrowing above.
    return (Unicode.Scalar(value).unsafelyUnwrapped, length)
  }

  // The largest scalar-aligned offset at or before `limit`: backs off over at most three
  // continuation bytes, so a window cut never tears a scalar. `limit` itself is aligned when
  // the byte at it starts a sequence, or when it is the end of the string.
  @usableFromInline
  func scalarAlignedOffset(before limit: Int) -> Int {
    var end = limit
    var steps = 0
    while steps < 3, end > 0, end < self.utf8Count, self.utf8Byte(at: end) & 0xC0 == 0x80 {
      end &-= 1
      steps &+= 1
    }
    return end
  }
}

// MARK: - UTF8View

extension StreamString {
  /// A random access view of the accumulated UTF-8 bytes.
  ///
  /// Byte offsets are the currency for substrings: a renderer that has drawn the first `n` bytes
  /// asks for `string.utf8[n...]` and decodes just the suffix, without materializing what it
  /// already drew.
  public struct UTF8View: RandomAccessCollection {
    public typealias Element = UInt8

    @usableFromInline let base: StreamString

    @usableFromInline
    init(_ base: StreamString) {
      self.base = base
    }

    @inlinable
    public var startIndex: Int { 0 }

    @inlinable
    public var endIndex: Int { self.base.utf8Count }

    @inlinable
    public subscript(position: Int) -> UInt8 {
      self.base.utf8Byte(at: position)
    }
  }

  /// The accumulated bytes as a random access collection.
  @inlinable
  public var utf8: UTF8View {
    UTF8View(self)
  }
}

// MARK: - UnicodeScalarView

extension StreamString {
  /// A bidirectional view of the accumulated bytes as Unicode scalars.
  ///
  /// Indices are byte offsets, the same currency as ``utf8``, so an index moves freely between
  /// the two views. Ill-formed bytes decode as U+FFFD one byte at a time, matching the repairing
  /// `String` decode. Table-free, so it stays inside the embedded subset.
  public struct UnicodeScalarView: BidirectionalCollection {
    public typealias Element = Unicode.Scalar

    @usableFromInline let base: StreamString

    @usableFromInline
    init(_ base: StreamString) {
      self.base = base
    }

    @inlinable
    public var startIndex: Int { 0 }

    @inlinable
    public var endIndex: Int { self.base.utf8Count }

    public func index(after index: Int) -> Int {
      index &+ self.base.decodeScalar(at: index).length
    }

    public func index(before index: Int) -> Int {
      // Walk back over at most three continuation bytes. When the lead byte reached does not
      // actually span back to `index`, the byte before `index` is ill-formed and stands alone as
      // its own U+FFFD, which keeps backward and forward traversal visiting the same positions.
      var candidate = index &- 1
      var steps = 0
      while steps < 3, candidate > 0, self.base.utf8Byte(at: candidate) & 0xC0 == 0x80 {
        candidate &-= 1
        steps &+= 1
      }
      return candidate &+ self.base.decodeScalar(at: candidate).length >= index
        ? candidate
        : index &- 1
    }

    public subscript(position: Int) -> Unicode.Scalar {
      self.base.decodeScalar(at: position).scalar
    }
  }

  /// The accumulated bytes as Unicode scalars, indexed by byte offset.
  @inlinable
  public var unicodeScalars: UnicodeScalarView {
    UnicodeScalarView(self)
  }
}

// MARK: - Characters

// Forward `String.Character` access without claiming that byte offsets are character indices.
// Grapheme segmentation is not public API and its tables are not something this package should
// carry, so the boundary question is delegated to `String`'s own breaker over a small decoded
// window. The window grows while its first character fills it entirely; once that character ends
// inside the window, the boundary is final.
extension StreamString {
  @usableFromInline
  func characterSpan(at offset: Int) -> (character: Character, end: Int) {
    var windowEnd = self.scalarAlignedOffset(before: min(offset &+ 8, self.utf8Count))
    if windowEnd <= offset { windowEnd = min(offset &+ 4, self.utf8Count) }
    while true {
      let window = self.decode(in: offset..<windowEnd)
      let first = window.first ?? "\u{FFFD}"
      // A decode that did not round-trip its byte count hit ill-formed bytes. Advance by the raw
      // scalar length so iteration continues one ill-formed byte at a time.
      guard window.utf8.count == windowEnd &- offset else {
        return (first, offset &+ self.decodeScalar(at: offset).length)
      }
      let end = offset &+ first.utf8.count
      if end < windowEnd || windowEnd == self.utf8Count { return (first, end) }
      let grown = self.scalarAlignedOffset(
        before: min(offset &+ (windowEnd &- offset) &* 2, self.utf8Count)
      )
      guard grown > windowEnd else { return (first, end) }
      windowEnd = grown
    }
  }

  /// The accumulated text as the same forward sequence of extended grapheme clusters that a
  /// Swift `String` exposes as `Character` elements.
  public struct CharacterSequence: Sequence, IteratorProtocol {
    @usableFromInline var base: StreamString
    @usableFromInline var offset = 0

    @usableFromInline
    init(_ base: StreamString) {
      self.base = base
    }

    public mutating func next() -> Character? {
      guard self.offset < self.base.utf8Count else { return nil }
      let span = self.base.characterSpan(at: self.offset)
      self.offset = span.end
      return span.character
    }
  }

  /// The accumulated text as forward `Character` values, agreeing with iteration over `String`.
  public var characters: CharacterSequence {
    CharacterSequence(self)
  }
}

// MARK: - String bridging

extension String {
  /// Decodes the accumulated bytes, repairing any ill-formed UTF-8.
  public init(_ streamString: StreamString) {
    self = streamString.decode(in: 0..<streamString.utf8Count)
  }

  /// Decodes a byte range of a ``StreamString``, repairing any ill-formed UTF-8.
  ///
  /// A slice's bounds are byte offsets, so a boundary that lands inside a multi-byte character
  /// decodes with replacement characters at the cut. Offsets that came from the view itself —
  /// a previously read `endIndex`, a delta boundary — land between characters and decode clean.
  public init(_ slice: Slice<StreamString.UTF8View>) {
    self = slice.base.base.decode(in: slice.startIndex..<slice.endIndex)
  }
}

// The `StringProtocol` bridge. `StreamString` cannot conform itself — the protocol requires
// `String.Index` positions and `Character` elements, neither of which block storage can vend,
// and only `String` and `Substring` are valid conformers by the standard library's own contract.
// A `Substring` over one decode is the next best thing: one materialization, then the full
// `String` API, accepted by anything generic over `StringProtocol`.
extension Substring {
  /// Decodes the accumulated bytes into a `Substring`, repairing any ill-formed UTF-8.
  public init(_ streamString: StreamString) {
    self = String(streamString)[...]
  }

  /// Decodes a byte range of a ``StreamString`` into a `Substring`, repairing any ill-formed
  /// UTF-8.
  public init(_ slice: Slice<StreamString.UTF8View>) {
    self = String(slice)[...]
  }
}

// MARK: - Conformances

extension StreamString: ExpressibleByStringInterpolation {
  public init(stringLiteral value: String) {
    self.init(value)
  }

  // A custom interpolation rather than `DefaultStringInterpolation`, so the segments append as
  // bytes directly instead of assembling a whole `String` and converting it.
  public struct StringInterpolation: StringInterpolationProtocol {
    @usableFromInline var value: StreamString

    public init(literalCapacity: Int, interpolationCount: Int) {
      self.value = StreamString()
      self.value.streamReserve(utf8ByteCount: literalCapacity)
    }

    public mutating func appendLiteral(_ literal: String) {
      self.value.append(literal)
    }

    public mutating func appendInterpolation(_ other: StreamString) {
      self.value.append(other)
    }

    public mutating func appendInterpolation(_ text: some StringProtocol) {
      self.value.append(text)
    }

    public mutating func appendInterpolation(_ item: some TextOutputStreamable) {
      item.write(to: &self.value)
    }

    #if !hasFeature(Embedded)
      // The catch-all goes through `String(describing:)`, which is reflection and outside the
      // embedded subset; the typed overloads above are what embedded interpolation gets.
      public mutating func appendInterpolation<T>(_ item: T) {
        self.value.append(String(describing: item))
      }
    #endif
  }

  public init(stringInterpolation: StringInterpolation) {
    self = stringInterpolation.value
  }
}

// Byte-wise, which for decoded JSON text means scalar-wise: the parser has already resolved
// escapes, so equal documents produce equal bytes. This is stricter than `String`'s canonical
// equivalence — NFC and NFD spellings of the same characters compare unequal here, as they do
// in the JSON grammar itself.
extension StreamString: Equatable {
  public static func == (lhs: Self, rhs: Self) -> Bool {
    let count = lhs.utf8Count
    guard count == rhs.utf8Count else { return false }
    var position = 0
    while position < count {
      let take = min(Self.blockCapacity &- (position & Self.blockMask), count &- position)
      let equal = lhs.withWindow(at: position, count: take) { left in
        rhs.withWindow(at: position, count: take) { right in
          streamBytesEqual(left.baseAddress!, right.baseAddress!, count: take)
        }
      }
      guard equal else { return false }
      position &+= take
    }
    return true
  }
}

// Comparison against `String` directly, because a partial's string fields are optional
// `StreamString`s and `partial.title == expected` is the single most common comparison a client
// writes. Byte-wise like the homogeneous `==`, so the two cannot disagree. The optional overloads
// exist because optional lifting only reaches the homogeneous operator.
extension StreamString {
  @usableFromInline
  func utf8Equals(_ other: some StringProtocol) -> Bool {
    var copy = String(other)
    return copy.withUTF8 { buffer in
      self.utf8Count == buffer.count && self.utf8Matches(buffer, at: 0)
    }
  }

  // Whether `buffer` matches the accumulated bytes starting at byte `offset`. The one comparison
  // against foreign contiguous bytes, shared by `==`, `hasPrefix`, `hasSuffix` and `contains`:
  // one `streamBytesEqual` per contiguous window the match touches.
  @usableFromInline
  func utf8Matches(_ buffer: UnsafeBufferPointer<UInt8>, at offset: Int) -> Bool {
    guard offset >= 0, offset &+ buffer.count <= self.utf8Count else { return false }
    guard let base = buffer.baseAddress, !buffer.isEmpty else { return true }
    let end = offset &+ buffer.count
    var compared = 0
    var position = offset
    while position < end {
      let take = min(Self.blockCapacity &- (position & Self.blockMask), end &- position)
      let matches = self.withWindow(at: position, count: take) { source in
        streamBytesEqual(source.baseAddress!, UnsafeRawPointer(base + compared), count: take)
      }
      guard matches else { return false }
      compared &+= take
      position &+= take
    }
    return true
  }

  @inlinable
  public static func == (lhs: Self, rhs: some StringProtocol) -> Bool {
    lhs.utf8Equals(rhs)
  }

  @inlinable
  public static func == (lhs: some StringProtocol, rhs: Self) -> Bool {
    rhs.utf8Equals(lhs)
  }

  @inlinable
  public static func != (lhs: Self, rhs: some StringProtocol) -> Bool {
    !lhs.utf8Equals(rhs)
  }

  @inlinable
  public static func != (lhs: some StringProtocol, rhs: Self) -> Bool {
    !rhs.utf8Equals(lhs)
  }

}

// Free functions rather than members, because a member operator must take `StreamString`
// itself somewhere and these take it wrapped.

@inlinable
public func == (lhs: StreamString?, rhs: some StringProtocol) -> Bool {
  lhs?.utf8Equals(rhs) ?? false
}

@inlinable
public func == (lhs: some StringProtocol, rhs: StreamString?) -> Bool {
  rhs?.utf8Equals(lhs) ?? false
}

@inlinable
public func != (lhs: StreamString?, rhs: some StringProtocol) -> Bool {
  !(lhs?.utf8Equals(rhs) ?? false)
}

@inlinable
public func != (lhs: some StringProtocol, rhs: StreamString?) -> Bool {
  !(rhs?.utf8Equals(lhs) ?? false)
}

// MARK: - Searching

// Byte-wise, like `==`: for decoded JSON text these answer the scalar-exact question and never
// materialize, where going through `String.hasPrefix` would cost a whole decode to answer a
// canonical-equivalence one.
extension StreamString {
  /// Whether the accumulated bytes start with `prefix`'s UTF-8, compared byte-wise.
  public func hasPrefix(_ prefix: some StringProtocol) -> Bool {
    var copy = String(prefix)
    return copy.withUTF8 { buffer in
      self.utf8Matches(buffer, at: 0)
    }
  }

  /// Whether the accumulated bytes end with `suffix`'s UTF-8, compared byte-wise.
  public func hasSuffix(_ suffix: some StringProtocol) -> Bool {
    var copy = String(suffix)
    return copy.withUTF8 { buffer in
      self.utf8Matches(buffer, at: self.utf8Count &- buffer.count)
    }
  }

  /// The byte range of the first occurrence of `needle`'s UTF-8 at or after `offset`,
  /// compared byte-wise.
  ///
  /// The bounds are byte offsets, the currency every other door accepts: `utf8[range]`,
  /// `String(_:)` and `Substring(_:)` of the slice. A match of well-formed text in well-formed
  /// text is always scalar-aligned — UTF-8 self-synchronizes — but not necessarily grapheme-
  /// cluster-aligned: searching for `"e"` finds the `e` inside a decomposed `"é"`. An empty
  /// needle matches emptily at `offset`.
  ///
  /// A first-byte scan with a full match at each candidate — worst case is quadratic, which a
  /// field-sized string never notices and a pathological one pays only when asked.
  public func range(of needle: some StringProtocol, from offset: Int = 0) -> Range<Int>? {
    precondition(
      offset >= 0 && offset <= self.utf8Count, "StreamString byte offset out of range"
    )
    var copy = String(needle)
    return copy.withUTF8 { buffer in
      guard !buffer.isEmpty else { return offset..<offset }
      guard buffer.count <= self.utf8Count &- offset else { return nil }
      let first = buffer[0]
      let last = self.utf8Count &- buffer.count
      var position = offset
      while position <= last {
        if self.utf8Byte(at: position) == first, self.utf8Matches(buffer, at: position) {
          return position..<(position &+ buffer.count)
        }
        position &+= 1
      }
      return nil
    }
  }

  /// Whether `other`'s UTF-8 occurs anywhere in the accumulated bytes, compared byte-wise.
  public func contains(_ other: some StringProtocol) -> Bool {
    self.range(of: other) != nil
  }
}

// MARK: - Appending

extension StreamString {
  /// Appends the UTF-8 bytes of `text`.
  public mutating func append(_ text: some StringProtocol) {
    var copy = String(text)
    copy.withUTF8 { buffer in
      self.append(utf8: buffer)
    }
  }

  /// Appends another accumulation, one contiguous storage window at a time, without materializing
  /// either side.
  public mutating func append(_ other: StreamString) {
    if other.usesInlineStorage {
      other.withInlineBuffer { self.append(utf8: $0) }
      return
    }
    for block in other.blocks {
      block.withUnsafeBufferPointer { buffer in
        self.append(utf8: buffer)
      }
    }
    other.tail.withUnsafeBufferPointer { buffer in
      self.append(utf8: buffer)
    }
  }

  /// Appends a single character's UTF-8 bytes.
  public mutating func append(_ character: Character) {
    self.append(String(character))
  }

  public static func += (lhs: inout Self, rhs: Self) {
    lhs.append(rhs)
  }

  public static func += (lhs: inout Self, rhs: some StringProtocol) {
    lhs.append(rhs)
  }

  public static func + (lhs: Self, rhs: Self) -> Self {
    var value = lhs
    value.append(rhs)
    return value
  }
}

// An accumulator is an output stream: `print(x, to: &value)` appends, which is the type's
// native operation.
extension StreamString: TextOutputStream {
  public mutating func write(_ string: String) {
    self.append(string)
  }
}

extension StreamString: TextOutputStreamable {
  // Block-at-a-time, with each cut backed off to a scalar boundary so no chunk decodes a torn
  // character — the whole value is never materialized at once.
  public func write<Target: TextOutputStream>(to target: inout Target) {
    var position = 0
    while position < self.utf8Count {
      var end = self.scalarAlignedOffset(
        before: min(position &+ Self.blockCapacity, self.utf8Count)
      )
      if end <= position { end = min(position &+ 4, self.utf8Count) }
      target.write(self.decode(in: position..<end))
      position = end
    }
  }
}

extension StreamString: Hashable {
  public func hash(into hasher: inout Hasher) {
    hasher.combine(self.utf8Count)
    if self.usesInlineStorage {
      self.withInlineBuffer { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
      return
    }
    // Deterministic across equal values because promoted storage has a canonical block layout.
    for block in self.blocks {
      block.withUnsafeBufferPointer { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
    }
    self.tail.withUnsafeBufferPointer { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
  }
}

// Byte-wise lexicographic, which for UTF-8 is Unicode scalar-value order: a deterministic,
// table-free ordering that differs from `String`'s canonical ordering exactly the way `==`
// already differs. Equal-length 512-byte windows pair up in one buffer on each side — block
// seals are 512-aligned and the tail starts 512-aligned — so `streamCompareBytes` can find the
// first unequal byte in one SIMD-backed pass.
extension StreamString: Comparable {
  public static func < (lhs: Self, rhs: Self) -> Bool {
    let common = min(lhs.utf8Count, rhs.utf8Count)
    var position = 0
    while position < common {
      let take = min(Self.blockCapacity &- (position & Self.blockMask), common &- position)
      let ordering = lhs.withWindow(at: position, count: take) { left in
        rhs.withWindow(at: position, count: take) { right in
          Self.windowOrdering(left, right)
        }
      }
      if ordering != 0 { return ordering < 0 }
      position &+= take
    }
    return lhs.utf8Count < rhs.utf8Count
  }

  @usableFromInline
  static func windowOrdering(
    _ left: UnsafeBufferPointer<UInt8>, _ right: UnsafeBufferPointer<UInt8>
  ) -> Int {
    streamCompareBytes(left.baseAddress!, right.baseAddress!, count: left.count)
  }
}

// Checked rather than `@unchecked`: every stored property is a value type, so the compiler can
// see that sharing a copy shares nothing mutable.
extension StreamString: Sendable {}

extension StreamString: CustomStringConvertible {
  public var description: String {
    String(self)
  }
}

extension StreamString: CustomDebugStringConvertible {
  public var debugDescription: String {
    String(self).debugDescription
  }
}

#if !hasFeature(Embedded)
  // Without this a reflecting printer walks the blocks and the tail, which puts the internals
  // into every custom dump and every recorded snapshot.
  extension StreamString: CustomReflectable {
    public var customMirror: Mirror {
      Mirror(reflecting: String(self))
    }
  }

  // As a single value, so a partial encodes the way the string it stands in for would. Both
  // sides are outside the embedded subset, which is why they are guarded rather than
  // unconditional.
  extension StreamString: Encodable {
    public func encode(to encoder: any Encoder) throws {
      var container = encoder.singleValueContainer()
      try container.encode(String(self))
    }
  }

  extension StreamString: Decodable {
    public init(from decoder: any Decoder) throws {
      let container = try decoder.singleValueContainer()
      self.init(try container.decode(String.self))
    }
  }
#endif

// MARK: - Parsing conformances

extension StreamString: StreamInitializable {
  public static func streamInitialValue() -> Self { Self() }
}

extension StreamString: StreamStringConvertible {
  @inlinable
  public mutating func streamAppend(utf8 bytes: Span<UInt8>) {
    bytes.withUnsafeBufferPointer { buffer in
      self.append(utf8: buffer)
    }
  }

  @inlinable
  public mutating func streamReserve(utf8ByteCount: Int) {
    guard utf8ByteCount > self.utf8Count else { return }
    if self.usesInlineStorage {
      guard utf8ByteCount > Self.inlineCapacity else { return }
      self.promoteInlineStorage(reserving: utf8ByteCount)
    }
    self.tail.reserveCapacity(min(utf8ByteCount, Self.blockCapacity))
    self.blocks.reserveCapacity(utf8ByteCount &>> Self.blockShift)
  }
}

extension StreamString: StreamParseableRoot {}

extension StreamString: StreamParseable {
  public typealias Partial = Self
}
