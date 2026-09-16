// String storage with a compile-time capacity and no heap: `count` plus `capacity` bytes,
// `BitwiseCopyable`, so a copy is a memcpy and a partial built from these has no refcounted
// fields. A copy is O(capacity), not O(count), so this is for *bounded* fields. Overflow is a
// parse failure, not a truncation: `streamAppend` refuses the whole chunk. Availability matches
// `InlineArray`'s; `PartialSink` reaches it through a layout-erased route (end of file), so the
// gate stays out of the core.
@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
public struct StreamInlineString<let capacity: Int>: BitwiseCopyable {
  // A contract: `_streamStringSchema` asserts these offsets and the sink appends through them
  // without knowing `capacity`. `count` is an `Int32` at offset 0 (the width the schema and frame
  // speak), the bytes at offset 4; `InlineArray<capacity, UInt8>` has alignment 1, so no padding.
  @usableFromInline var _count: Int32
  @usableFromInline var _bytes: InlineArray<capacity, UInt8>

  public init() {
    self._count = 0
    // Zeroed: a `BitwiseCopyable` copy copies the unused tail too, and zeros keep it deterministic.
    self._bytes = InlineArray<capacity, UInt8>(repeating: 0)
  }

  /// Creates a value holding `string`'s UTF-8, or `nil` when those bytes do not fit `capacity`.
  ///
  /// A *literal* argument does not reach here: `StreamInlineString<8>("too long")` resolves to the
  /// literal initializer and traps.
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

  // The whole write path. A chunk that does not fit is refused entire, so the value never holds a
  // torn UTF-8 sequence, only everything through the last append that fit.
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
    // Rezeroed, for the same reason `init` zeroes.
    let count = Int(self._count)
    _ = withUnsafeMutableBytes(of: &self._bytes) { destination in
      destination.baseAddress!.initializeMemory(as: UInt8.self, repeating: 0, count: count)
    }
    self._count = 0
  }

  // MARK: Reading

  // Every read goes through here: one contiguous window, always.
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

  // Repairing rather than validating, as `StreamString` does, so the read cannot fail.
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

// The same repairing scalar policy as `StreamString`. Duplicated deliberately: that type reaches
// bytes through a block dispatch and this one through a buffer, and a shared abstraction would
// put a call where each has a load. Everything built on top is shared via `_StreamUTF8Backed`.
@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
extension StreamInlineString: _StreamUTF8Backed {}

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

  // The largest scalar-aligned offset at or before `limit`, over at most three continuations.
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
      self.base.scalarIndex(before: index)
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

// `characterSpan(at:)` is shared; see `_StreamUTF8Backed`.
@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
extension StreamInlineString {
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

// A literal that does not fit traps: `ExpressibleByStringLiteral` requires a total initializer,
// and it is a programmer error rather than a document to survive. Runtime text uses `init?(_:)`.
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

  // Custom, so segments append as bytes instead of assembling a `String` first.
  public struct StringInterpolation: StringInterpolationProtocol {
    @usableFromInline var value: StreamInlineString
    // `appendLiteral` cannot report overflow, so it is recorded and raised at the finished value.
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
      // `String(describing:)` is reflection, outside the Embedded subset.
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

// Byte-wise, like `StreamString`, so NFC and NFD spellings compare unequal. Capacity is not part
// of the value: equal bytes are equal at any capacity, hence the cross-capacity operators and
// hashing only the used bytes.
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
    // Count then bytes, never the capacity; also `StreamString`'s scheme under one 512-byte window.
    hasher.combine(self.utf8Count)
    self.withUTF8Buffer { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
  }
}

// Byte-wise lexicographic, which for UTF-8 is scalar-value order.
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

// Cross-capacity comparison: `Equatable` and `Comparable` only relate a type to itself, and equal
// bytes at different capacities must compare equal, since they hash equal.
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

// As on `StreamString`: `partial.title == expected` is the commonest client comparison.
@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
extension StreamInlineString {
  // `utf8Equals(_:)` against `StringProtocol` is shared; see `_StreamUTF8Backed`.

  // Whether `buffer` matches the bytes at `offset`; shared by `==` and the searchers.
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

// Free functions: a member operator must take the type itself somewhere.
@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
@inlinable
public func == <let capacity: Int>(
  lhs: StreamInlineString<capacity>?, rhs: some StringProtocol
) -> Bool {
  // An explicit unwrap, not `lhs?.utf8Equals(rhs) ?? false`: optional chaining through a
  // value-generic value crashes SILGen in 6.4-snapshot-2026-08-01.
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
    self.utf8HasPrefix(prefix)
  }

  /// Whether the accumulated bytes end with `suffix`'s UTF-8, compared byte-wise.
  public func hasSuffix(_ suffix: some StringProtocol) -> Bool {
    self.utf8HasSuffix(suffix)
  }

  /// The byte range of the first occurrence of `needle`'s UTF-8 at or after `offset`, compared
  /// byte-wise.
  ///
  /// The bounds are byte offsets. A match in well-formed text is scalar-aligned but not necessarily
  /// grapheme-aligned. An empty needle matches emptily at `offset`.
  public func range(of needle: some StringProtocol, from offset: Int = 0) -> Range<Int>? {
    precondition(
      offset >= 0 && offset <= self.utf8Count, "StreamInlineString byte offset out of range"
    )
    return self.utf8Range(of: needle, from: offset)
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

// Checked, not `@unchecked`: the value is `BitwiseCopyable`.
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
  // Otherwise a reflecting printer dumps all `capacity` bytes of the buffer.
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
    // Throws rather than traps: the bytes come from a document, like the parser's.
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

  // How `_streamStringSchema` recognizes this type without naming it, and the layout it promises
  // the sink; both fold to constants once the schema builder specializes.
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

// Not availability-gated, because none of this names `StreamInlineString`: `PartialSink` appends
// through a raw pointer and a capacity read off the schema. `_streamStringSchema` checks the
// shared layout (`Int32` count at 0, `capacity` bytes at `_streamInlineStringByteOffset`) against
// `MemoryLayout` before emitting the route.

@usableFromInline
let _streamInlineStringByteOffset = 4

// The bounded string append: a compare, a memcpy and a store, with no closure, generic dispatch
// or representation branch.
@inlinable
@inline(__always)
func _streamInlineStringAppend(
  _ storage: UnsafeMutableRawPointer, capacity: Int32, _ bytes: Span<UInt8>
) -> StreamApplyResult {
  // Widened, not narrowed: `Int32(bytes.count)` emits an overflow trap ahead of the compare. The
  // store truncates unchecked: the guard proves the sum <= `capacity`, which fits `Int32`.
  let count = Int(storage.load(as: Int32.self))
  let take = bytes.count
  // Refused entire, matching `StreamInlineString.appendUTF8`.
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
