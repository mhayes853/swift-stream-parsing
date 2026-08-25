// String storage with a compile-time capacity and no heap behind it.
//
// `StreamString` grows to fit whatever arrives, which costs it two refcounted stored properties
// and a branch on every read between the inline buffer and the block list. A field whose length
// the schema already bounds -- an identifier, an enum-ish value, a key echoed back by a model --
// does not need either. `StreamInlineString<32>` is `count` plus 32 bytes, `BitwiseCopyable`,
// and therefore:
//
// - **A copy is a memcpy.** A partial tree built from these has no refcounted fields at all, so
//   emitting a partial retains nothing and a snapshot shares nothing.
// - **An append is a bounds check and a memcpy.** No uniqueness check, no block seal, no branch
//   between representations, because there is only one representation.
// - **There is no allocator.** Which is what makes it usable where `StreamString` is not: above
//   64 bytes that type takes a heap block.
//
// The cost is the mirror image and it is not small: a copy is O(capacity), not O(count). At
// capacity 32 that beats two retains; at capacity 4096 it loses badly to them. This type is for
// *bounded* fields. A field whose length the document decides still wants `StreamString`.
//
// Overflow is a parse failure, not a truncation. `streamAppend` answers `.capacityExceeded`
// without taking any of the bytes, so a rejected value holds exactly what it accumulated through
// the last append that fit, and the sink turns that answer into
// `StreamSinkFailure.Reason.capacityExceeded` at the byte offset where the overflow happened.
//
// Availability matches `InlineArray`'s: generic type metadata carrying a value argument needs a
// runtime that can instantiate it. Nothing in `PartialSink` names this type -- the fast path
// reaches it through a layout-erased route -- so the gate stops here rather than spreading into
// the core.
@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
public struct StreamInlineString<let capacity: Int>: BitwiseCopyable {
  // Layout is a contract, not an implementation detail: `_streamStringSchema` asserts these
  // offsets and the sink appends through them without knowing `capacity` statically. `count`
  // leads at offset 0 as an `Int32` -- the width the schema and frame already speak -- and the
  // bytes follow at offset 4, with `InlineArray<capacity, UInt8>` contributing alignment 1 so
  // nothing pads between them.
  @usableFromInline var _count: Int32
  @usableFromInline var _bytes: InlineArray<capacity, UInt8>

  public init() {
    self._count = 0
    // Zeroed rather than uninitialized: the type is `BitwiseCopyable`, so a copy of a
    // partially-filled value copies the unused tail too, and unused bytes that are always zero
    // keep that copy deterministic rather than leaking whatever the slot held before.
    self._bytes = InlineArray<capacity, UInt8>(repeating: 0)
  }

  /// Creates a value holding `string`'s UTF-8, or `nil` when those bytes do not fit `capacity`.
  ///
  /// Failable because overflow is this type's defining failure and silently truncating a caller's
  /// text would contradict what the parser does with the same overflow.
  ///
  /// A *literal* argument does not reach this initializer: `StreamInlineString<8>("too long")`
  /// resolves to the literal path and traps. That split is the intended one -- a literal too long
  /// for its capacity is a programmer error, while text arriving at runtime is a value to
  /// reject -- but it means `Self(someString)` and `Self("someString")` fail differently.
  public init?(_ string: some StringProtocol) {
    self.init()
    var copy = String(string)
    let fits = copy.withUTF8 { buffer in
      self.appendUTF8(buffer) == .applied
    }
    guard fits else { return nil }
  }

  /// The number of UTF-8 bytes accumulated so far.
  @inlinable
  public var utf8Count: Int { Int(self._count) }

  /// Whether no bytes have accumulated.
  @inlinable
  public var isEmpty: Bool { self._count == 0 }

  /// The number of further UTF-8 bytes this value can accept.
  @inlinable
  public var availableCapacity: Int { capacity &- Int(self._count) }

  /// The compile-time capacity, in UTF-8 bytes.
  @inlinable
  public static var utf8Capacity: Int { capacity }

  // MARK: Append

  // The whole write path. A chunk that does not fit is refused entire rather than partially
  // taken: a partial take would leave a torn UTF-8 sequence in a value the parser is about to
  // fail anyway, and "holds everything through the last append that fit" is a simpler rule to
  // reason about than "holds a prefix of some chunk".
  @inlinable
  @discardableResult
  mutating func appendUTF8(_ buffer: UnsafeBufferPointer<UInt8>) -> StreamApplyResult {
    guard let base = buffer.baseAddress, !buffer.isEmpty else { return .applied }
    let count = Int(self._count)
    guard buffer.count <= capacity &- count else { return .capacityExceeded }
    withUnsafeMutableBytes(of: &self._bytes) { destination in
      destination.baseAddress!.advanced(by: count).copyMemory(
        from: base, byteCount: buffer.count
      )
    }
    self._count = Int32(count &+ buffer.count)
    return .applied
  }

  /// Appends `text`'s UTF-8, reporting whether it fit.
  @discardableResult
  public mutating func append(_ text: some StringProtocol) -> StreamApplyResult {
    var copy = String(text)
    return copy.withUTF8 { self.appendUTF8($0) }
  }

  /// Appends another accumulation's bytes, reporting whether they fit.
  @discardableResult
  public mutating func append<let otherCapacity: Int>(
    _ other: StreamInlineString<otherCapacity>
  ) -> StreamApplyResult {
    other.withUTF8Buffer { self.appendUTF8($0) }
  }

  /// Appends a single character's UTF-8 bytes, reporting whether they fit.
  @discardableResult
  public mutating func append(_ character: Character) -> StreamApplyResult {
    self.append(String(character))
  }

  /// Removes every accumulated byte, keeping the capacity.
  public mutating func removeAll() {
    // The tail is rezeroed rather than merely forgotten, for the same reason `init` zeroes it.
    let count = Int(self._count)
    _ = withUnsafeMutableBytes(of: &self._bytes) { destination in
      destination.baseAddress!.initializeMemory(as: UInt8.self, repeating: 0, count: count)
    }
    self._count = 0
  }

  // MARK: Reading

  // Every read goes through here. One contiguous window, always -- which is the entire reason
  // this type's read layer is a fraction of `StreamString`'s.
  @inlinable
  public func withUTF8Buffer<R>(_ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R {
    try withUnsafeBytes(of: self._bytes) { source in
      try body(
        UnsafeBufferPointer(
          start: source.baseAddress!.assumingMemoryBound(to: UInt8.self), count: Int(self._count)
        )
      )
    }
  }

  @inlinable
  func utf8Byte(at position: Int) -> UInt8 {
    precondition(
      position >= 0 && position < Int(self._count), "StreamInlineString byte offset out of range"
    )
    return self.withUTF8Buffer { $0[position] }
  }

  // Decodes `range`, repairing rather than validating, exactly as `StreamString` does: a
  // repairing decode cannot fail, which is what lets this be a plain `String` read.
  @usableFromInline
  func decode(in range: Range<Int>) -> String {
    guard !range.isEmpty else { return "" }
    return self.withUTF8Buffer { buffer in
      String(
        decoding: UnsafeBufferPointer(rebasing: buffer[range.lowerBound..<range.upperBound]),
        as: UTF8.self
      )
    }
  }
}

// MARK: - Scalar decoding

// The same repairing policy as `StreamString`: a byte that does not begin a well-formed sequence
// decodes as U+FFFD with length one, so the scalar view and the `String` decode tell one story
// about invalid bytes. Duplicated rather than shared with `StreamString`, deliberately: that
// type reaches its bytes through a block dispatch and this one through a contiguous buffer, and
// a shared abstraction over both would put a call where each currently has a load.
@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
extension StreamInlineString {
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
    return (Unicode.Scalar(value).unsafelyUnwrapped, length)
  }

  // The largest scalar-aligned offset at or before `limit`: backs off over at most three
  // continuation bytes, so a window cut never tears a scalar.
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

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
extension StreamInlineString {
  /// A random access view of the accumulated UTF-8 bytes.
  ///
  /// Byte offsets are the currency for substrings, as they are for ``StreamString``: a renderer
  /// that has drawn the first `n` bytes asks for `string.utf8[n...]` and decodes just the suffix.
  public struct UTF8View: RandomAccessCollection {
    public typealias Element = UInt8

    @usableFromInline let base: StreamInlineString

    @usableFromInline
    init(_ base: StreamInlineString) {
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

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
extension StreamInlineString {
  /// A bidirectional view of the accumulated bytes as Unicode scalars.
  ///
  /// Indices are byte offsets, the same currency as ``utf8``. Ill-formed bytes decode as U+FFFD
  /// one byte at a time, matching the repairing `String` decode. Table-free, so it stays inside
  /// the embedded subset.
  public struct UnicodeScalarView: BidirectionalCollection {
    public typealias Element = Unicode.Scalar

    @usableFromInline let base: StreamInlineString

    @usableFromInline
    init(_ base: StreamInlineString) {
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

// Grapheme segmentation is delegated to `String`'s own breaker over a small decoded window, for
// the reason `StreamString` gives: the tables are not something this package should carry.
@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
extension StreamInlineString {
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
    @usableFromInline var base: StreamInlineString
    @usableFromInline var offset = 0

    @usableFromInline
    init(_ base: StreamInlineString) {
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

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
extension String {
  /// Decodes the accumulated bytes, repairing any ill-formed UTF-8.
  public init<let capacity: Int>(_ inlineString: StreamInlineString<capacity>) {
    self = inlineString.decode(in: 0..<inlineString.utf8Count)
  }

  /// Decodes a byte range of a ``StreamInlineString``, repairing any ill-formed UTF-8.
  ///
  /// A slice's bounds are byte offsets, so a boundary that lands inside a multi-byte character
  /// decodes with replacement characters at the cut.
  public init<let capacity: Int>(_ slice: Slice<StreamInlineString<capacity>.UTF8View>) {
    self = slice.base.base.decode(in: slice.startIndex..<slice.endIndex)
  }
}

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
extension Substring {
  /// Decodes the accumulated bytes into a `Substring`, repairing any ill-formed UTF-8.
  public init<let capacity: Int>(_ inlineString: StreamInlineString<capacity>) {
    self = String(inlineString)[...]
  }

  /// Decodes a byte range of a ``StreamInlineString`` into a `Substring`, repairing any
  /// ill-formed UTF-8.
  public init<let capacity: Int>(_ slice: Slice<StreamInlineString<capacity>.UTF8View>) {
    self = String(slice)[...]
  }
}

// MARK: - Literals

// The literal conformances are the one place this type cannot answer an overflow the way the
// parser does. `ExpressibleByStringLiteral` requires a total initializer, so a literal that does
// not fit its capacity traps: it is a programmer error visible at the first execution of the
// line that wrote it, not a document the parser has to survive. Runtime text goes through the
// failable `init?(_:)` instead.
@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
extension StreamInlineString: ExpressibleByStringInterpolation {
  public init(stringLiteral value: String) {
    guard let parsed = Self(value) else {
      preconditionFailure(
        "string literal of \(value.utf8.count) UTF-8 bytes exceeds StreamInlineString capacity "
          + "\(capacity)"
      )
    }
    self = parsed
  }

  // A custom interpolation rather than `DefaultStringInterpolation`, so segments append as bytes
  // instead of assembling a whole `String` first.
  public struct StringInterpolation: StringInterpolationProtocol {
    @usableFromInline var value: StreamInlineString
    // Overflow cannot be reported out of `appendLiteral`, whose signature returns nothing, so it
    // is recorded and raised once the finished value is demanded.
    @usableFromInline var overflowed = false

    public init(literalCapacity: Int, interpolationCount: Int) {
      self.value = StreamInlineString()
    }

    @usableFromInline
    mutating func take(_ result: StreamApplyResult) {
      if result != .applied { self.overflowed = true }
    }

    public mutating func appendLiteral(_ literal: String) {
      self.take(self.value.append(literal))
    }

    public mutating func appendInterpolation<let otherCapacity: Int>(
      _ other: StreamInlineString<otherCapacity>
    ) {
      self.take(self.value.append(other))
    }

    public mutating func appendInterpolation(_ text: some StringProtocol) {
      self.take(self.value.append(text))
    }

    public mutating func appendInterpolation(_ item: some TextOutputStreamable) {
      var text = ""
      item.write(to: &text)
      self.take(self.value.append(text))
    }

    #if !hasFeature(Embedded)
      // The catch-all goes through `String(describing:)`, which is reflection and outside the
      // embedded subset; the typed overloads above are what embedded interpolation gets.
      public mutating func appendInterpolation<T>(_ item: T) {
        self.take(self.value.append(String(describing: item)))
      }
    #endif
  }

  public init(stringInterpolation: StringInterpolation) {
    precondition(
      !stringInterpolation.overflowed,
      "string interpolation exceeds StreamInlineString capacity \(capacity)"
    )
    self = stringInterpolation.value
  }
}

// MARK: - Equality, ordering, hashing

// Byte-wise, like `StreamString`: for decoded JSON text the parser has already resolved escapes,
// so equal documents produce equal bytes. Stricter than `String`'s canonical equivalence -- NFC
// and NFD spellings compare unequal here, as they do in the JSON grammar itself.
//
// Capacity is not part of the value. Two accumulations of the same bytes are equal whatever room
// they were declared with, which is why the cross-capacity operators exist and why hashing feeds
// only the used bytes.
@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
extension StreamInlineString: Equatable {
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.utf8Equals(rhs)
  }

  @usableFromInline
  func utf8Equals<let otherCapacity: Int>(_ other: StreamInlineString<otherCapacity>) -> Bool {
    guard self._count == other._count else { return false }
    guard self._count != 0 else { return true }
    return self.withUTF8Buffer { left in
      other.withUTF8Buffer { right in
        streamBytesEqual(left.baseAddress!, right.baseAddress!, count: left.count)
      }
    }
  }
}

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
extension StreamInlineString: Hashable {
  public func hash(into hasher: inout Hasher) {
    // Count then bytes, and never the capacity, so a value equal to one of another capacity
    // hashes equal to it. This is also `StreamString`'s scheme for values under one 512-byte
    // window, which keeps a future bridge between the two types open.
    hasher.combine(self.utf8Count)
    self.withUTF8Buffer { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
  }
}

// Byte-wise lexicographic, which for UTF-8 is Unicode scalar-value order: deterministic and
// table-free, differing from `String`'s canonical ordering exactly the way `==` already does.
@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
extension StreamInlineString: Comparable {
  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.utf8Precedes(rhs)
  }

  @usableFromInline
  func utf8Precedes<let otherCapacity: Int>(_ other: StreamInlineString<otherCapacity>) -> Bool {
    let common = min(self.utf8Count, other.utf8Count)
    if common > 0 {
      let ordering = self.withUTF8Buffer { left in
        other.withUTF8Buffer { right in
          streamCompareBytes(left.baseAddress!, right.baseAddress!, count: common)
        }
      }
      if ordering != 0 { return ordering < 0 }
    }
    return self.utf8Count < other.utf8Count
  }
}

// Cross-capacity comparison. `Equatable` and `Comparable` can only relate a type to itself, so
// these are the spellings that let `StreamInlineString<32>` and `StreamInlineString<64>` holding
// the same bytes compare equal -- which they must, since hashing already says they are.
@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
@inlinable
public func == <let lhsCapacity: Int, let rhsCapacity: Int>(
  lhs: StreamInlineString<lhsCapacity>, rhs: StreamInlineString<rhsCapacity>
) -> Bool {
  lhs.utf8Equals(rhs)
}

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
@inlinable
public func != <let lhsCapacity: Int, let rhsCapacity: Int>(
  lhs: StreamInlineString<lhsCapacity>, rhs: StreamInlineString<rhsCapacity>
) -> Bool {
  !lhs.utf8Equals(rhs)
}

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
@inlinable
public func < <let lhsCapacity: Int, let rhsCapacity: Int>(
  lhs: StreamInlineString<lhsCapacity>, rhs: StreamInlineString<rhsCapacity>
) -> Bool {
  lhs.utf8Precedes(rhs)
}

// MARK: - Comparison against String

// The same convenience `StreamString` offers, and for the same reason: a partial's string fields
// are optional, and `partial.title == expected` is the most common comparison a client writes.
@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
extension StreamInlineString {
  @usableFromInline
  func utf8Equals(_ other: some StringProtocol) -> Bool {
    var copy = String(other)
    return copy.withUTF8 { buffer in
      self.utf8Count == buffer.count && self.utf8Matches(buffer, at: 0)
    }
  }

  // Whether `buffer` matches the accumulated bytes starting at byte `offset`. One
  // `streamBytesEqual` over one window, shared by `==`, `hasPrefix`, `hasSuffix` and `contains`.
  @usableFromInline
  func utf8Matches(_ buffer: UnsafeBufferPointer<UInt8>, at offset: Int) -> Bool {
    guard offset >= 0, offset &+ buffer.count <= self.utf8Count else { return false }
    guard let base = buffer.baseAddress, !buffer.isEmpty else { return true }
    return self.withUTF8Buffer { source in
      streamBytesEqual(
        source.baseAddress! + offset, UnsafeRawPointer(base), count: buffer.count
      )
    }
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

// Free functions rather than members, because a member operator must take the type itself
// somewhere and these take it wrapped.
@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
@inlinable
public func == <let capacity: Int>(
  lhs: StreamInlineString<capacity>?, rhs: some StringProtocol
) -> Bool {
  // Written as an explicit unwrap rather than `lhs?.utf8Equals(rhs) ?? false`: optional chaining
  // through a value-generic value crashes SILGen in 6.4-snapshot-2026-08-01 ("Can only bind plus
  // one values"). Same meaning, and it sidesteps the bug.
  guard let lhs else { return false }
  return lhs.utf8Equals(rhs)
}

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
@inlinable
public func == <let capacity: Int>(
  lhs: some StringProtocol, rhs: StreamInlineString<capacity>?
) -> Bool {
  guard let rhs else { return false }
  return rhs.utf8Equals(lhs)
}

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
@inlinable
public func != <let capacity: Int>(
  lhs: StreamInlineString<capacity>?, rhs: some StringProtocol
) -> Bool {
  guard let lhs else { return true }
  return !lhs.utf8Equals(rhs)
}

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
@inlinable
public func != <let capacity: Int>(
  lhs: some StringProtocol, rhs: StreamInlineString<capacity>?
) -> Bool {
  guard let rhs else { return true }
  return !rhs.utf8Equals(lhs)
}

// MARK: - Searching

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
extension StreamInlineString {
  /// Whether the accumulated bytes start with `prefix`'s UTF-8, compared byte-wise.
  public func hasPrefix(_ prefix: some StringProtocol) -> Bool {
    var copy = String(prefix)
    return copy.withUTF8 { self.utf8Matches($0, at: 0) }
  }

  /// Whether the accumulated bytes end with `suffix`'s UTF-8, compared byte-wise.
  public func hasSuffix(_ suffix: some StringProtocol) -> Bool {
    var copy = String(suffix)
    return copy.withUTF8 { buffer in
      self.utf8Matches(buffer, at: self.utf8Count &- buffer.count)
    }
  }

  /// The byte range of the first occurrence of `needle`'s UTF-8 at or after `offset`, compared
  /// byte-wise.
  ///
  /// The bounds are byte offsets, the currency every other door accepts. A match of well-formed
  /// text in well-formed text is always scalar-aligned -- UTF-8 self-synchronizes -- but not
  /// necessarily grapheme-cluster-aligned. An empty needle matches emptily at `offset`.
  public func range(of needle: some StringProtocol, from offset: Int = 0) -> Range<Int>? {
    precondition(
      offset >= 0 && offset <= self.utf8Count, "StreamInlineString byte offset out of range"
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

// MARK: - Output

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
extension StreamInlineString: TextOutputStreamable {
  public func write<Target: TextOutputStream>(to target: inout Target) {
    target.write(String(self))
  }
}

// Checked rather than `@unchecked`: the value is `BitwiseCopyable`, so there is nothing to share.
@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
extension StreamInlineString: Sendable {}

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
extension StreamInlineString: CustomStringConvertible {
  public var description: String {
    String(self)
  }
}

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
extension StreamInlineString: CustomDebugStringConvertible {
  public var debugDescription: String {
    String(self).debugDescription
  }
}

#if !hasFeature(Embedded)
  // Without this a reflecting printer walks the whole inline buffer, putting `capacity` bytes of
  // storage into every custom dump and recorded snapshot.
  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  extension StreamInlineString: CustomReflectable {
    public var customMirror: Mirror {
      Mirror(reflecting: String(self))
    }
  }

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  extension StreamInlineString: Encodable {
    public func encode(to encoder: any Encoder) throws {
      var container = encoder.singleValueContainer()
      try container.encode(String(self))
    }
  }

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  extension StreamInlineString: Decodable {
    // Decoding is the one direction with an error to report rather than a trap: the bytes come
    // from a document, exactly like the parser's, so they fail the decode rather than the process.
    public init(from decoder: any Decoder) throws {
      let container = try decoder.singleValueContainer()
      let text = try container.decode(String.self)
      guard let value = Self(text) else {
        throw DecodingError.dataCorruptedError(
          in: container,
          debugDescription:
            "string of \(text.utf8.count) UTF-8 bytes exceeds StreamInlineString capacity "
            + "\(capacity)"
        )
      }
      self = value
    }
  }
#endif

// MARK: - Parsing conformances

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
extension StreamInlineString: StreamInitializable {
  public static func streamInitialValue() -> Self { Self() }
}

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
extension StreamInlineString: StreamStringConvertible {
  @discardableResult
  @inlinable
  public mutating func streamAppend(utf8 bytes: Span<UInt8>) -> StreamApplyResult {
    bytes.withUnsafeBufferPointer { buffer in
      self.appendUTF8(buffer)
    }
  }

  // What `_streamStringSchema` reads to recognize this type without naming it, and the layout it
  // then promises the sink. Both are compile-time constants once the schema builder specializes.
  @inlinable
  public static var _streamInlineCapacity: Int { capacity }
  @inlinable
  public static var _streamInlineByteOffset: Int { _streamInlineStringByteOffset }
}

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
extension StreamInlineString: StreamParseableRoot {}

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
extension StreamInlineString: StreamParseable {
  public typealias Partial = Self
}

// MARK: - The layout-erased append

// Everything below is deliberately *not* availability-gated, because none of it names
// `StreamInlineString`. That is the whole point of erasing the layout: `PartialSink` appends to
// an inline string through a raw pointer and a capacity read off the schema, so the parser core
// stays buildable on every platform this package supports while the type itself is gated.
//
// The contract these two halves share:
//
// - offset 0: `Int32` count of accumulated UTF-8 bytes
// - offset `_streamInlineStringByteOffset`: exactly `capacity` bytes of storage
//
// `_streamStringSchema` checks it against `MemoryLayout` before ever emitting the route, so a
// layout that drifts fails when the schema is built rather than corrupting memory later.

@usableFromInline
let _streamInlineStringByteOffset = 4

// The append the string hot path reaches for a bounded destination: a compare, a memcpy and a
// store. No closure call, no generic dispatch, no branch between representations -- the shape
// `StreamString`'s own append cannot have, because it has two representations to choose between.
@inlinable
@inline(__always)
func _streamInlineStringAppend(
  _ storage: UnsafeMutableRawPointer, capacity: Int32, _ bytes: Span<UInt8>
) -> StreamApplyResult {
  // Widened rather than narrowed: `Int32(bytes.count)` emits an overflow trap check ahead of the
  // capacity compare, and the comparison it feeds is the same one done in `Int`. The store back
  // truncates without a check because the guard has already proved the sum is at most `capacity`,
  // which `_streamStringSchema` has already proved fits `Int32`.
  let count = Int(storage.load(as: Int32.self))
  let take = bytes.count
  // Refused entire rather than partially taken, matching `StreamInlineString.appendUTF8`.
  guard take <= Int(capacity) &- count else { return .capacityExceeded }
  guard take > 0 else { return .applied }
  bytes.withUnsafeBufferPointer { buffer in
    (storage + _streamInlineStringByteOffset + count).copyMemory(
      from: buffer.baseAddress!, byteCount: buffer.count
    )
  }
  storage.storeBytes(of: Int32(truncatingIfNeeded: count &+ take), as: Int32.self)
  return .applied
}
