// The read surface `StreamString` and `StreamInlineString` share (scalar traversal, grapheme spans,
// comparison, searching), written once against the primitives below.
// `decodeScalar` and `scalarAlignedOffset` stay per type: a shared body would put a call where
// each has a load. Internal, so each type forwards its public methods; ungated.
@usableFromInline
protocol _StreamUTF8Backed {
  /// The number of UTF-8 bytes accumulated so far.
  var utf8Count: Int { get }

  /// The byte at `position`, which must be in range.
  func utf8Byte(at position: Int) -> UInt8

  /// The bytes in `range`, decoded with ill-formed sequences repaired.
  func decode(in range: Range<Int>) -> String

  /// The scalar starting at `position`, repairing as `String` does: a byte that cannot begin a
  /// sequence decodes as U+FFFD with length one, and a sequence cut short as one U+FFFD spanning
  /// its maximal subpart.
  func decodeScalar(at position: Int) -> (scalar: Unicode.Scalar, length: Int)

  /// The largest scalar-aligned offset at or before `limit`, so a window cut never tears a
  /// scalar.
  func scalarAlignedOffset(before limit: Int) -> Int

  /// Whether `buffer` matches the accumulated bytes starting at byte `offset`.
  func utf8Matches(_ buffer: UnsafeBufferPointer<UInt8>, at offset: Int) -> Bool

  /// The number of leading bytes the accumulated bytes and `buffer` agree on.
  func utf8CommonPrefixCount(_ buffer: UnsafeBufferPointer<UInt8>) -> Int

  /// Whether every accumulated byte from `offset` on is ASCII.
  func utf8IsASCII(from offset: Int) -> Bool
}

// MARK: - Scalar traversal

extension _StreamUTF8Backed {
  /// The scalar-view index before `index`.
  ///
  /// Walks back over at most three continuation bytes. When the lead byte reached does not span
  /// back to `index`, the byte before `index` stands alone as U+FFFD, so backward and forward
  /// traversal visit the same positions.
  @usableFromInline
  func scalarIndex(before index: Int) -> Int {
    var candidate = index &- 1
    var steps = 0
    while steps < 3, candidate > 0, self.utf8Byte(at: candidate) & 0xC0 == 0x80 {
      candidate &-= 1
      steps &+= 1
    }
    return candidate &+ self.decodeScalar(at: candidate).length >= index ? candidate : index &- 1
  }
}

// MARK: - Characters

// Forward `Character` access. Grapheme segmentation is not public API, so boundaries come from
// `String`'s own breaker over a small decoded window, grown while its first character fills it.
extension _StreamUTF8Backed {
  @usableFromInline
  func characterSpan(at offset: Int) -> (character: Character, end: Int) {
    var windowEnd = self.scalarAlignedOffset(before: min(offset &+ 8, self.utf8Count))
    if windowEnd <= offset { windowEnd = min(offset &+ 4, self.utf8Count) }
    while true {
      let window = self.decode(in: offset..<windowEnd)
      let first = window.first ?? "\u{FFFD}"
      var end = offset &+ first.utf8.count
      // A decode that did not round-trip its byte count repaired something, so the character's
      // decoded length is not its byte length: walk its scalars back through the same repair.
      // Returning after one scalar instead re-read a multi-scalar character's tail as the next
      // character (`e\u{301}` then `\u{301}` again).
      if window.utf8.count != windowEnd &- offset {
        end = offset
        for _ in first.unicodeScalars { end &+= self.decodeScalar(at: end).length }
      }
      if end < windowEnd || windowEnd == self.utf8Count { return (first, end) }
      let grown = self.scalarAlignedOffset(
        before: min(offset &+ (windowEnd &- offset) &* 2, self.utf8Count)
      )
      guard grown > windowEnd else { return (first, end) }
      windowEnd = grown
    }
  }
}

// MARK: - Comparison as `String` compares

// `==`, `<` and hashing follow `String`: canonical equivalence, so the NFC and NFD spellings of a
// character are equal, ordered by their normalized scalars. Most comparisons never decode. Two
// texts whose bytes agree up to some offset and are ASCII from there on normalize to the shared
// prefix's normalization followed by their own ASCII tails: no ASCII byte composes with what
// precedes it, and one ends any sequence the prefix left open, which then repairs alike on both
// sides. So the byte order at that offset is `String`'s order, and differing bytes are differing
// text. Any other pair is decoded and compared as `String`s.

/// The order of two texts whose bytes agree up to an offset and are ASCII from there, given each
/// one's byte at that offset, `nil` where it has ended: negative, zero or positive.
func streamASCIITailOrdering(_ left: UInt8?, _ right: UInt8?) -> Int {
  switch (left, right) {
  case (nil, nil): 0
  case (nil, _): -1
  case (_, nil): 1
  case let (left?, right?): left < right ? -1 : 1
  }
}

/// Whether two texts are unequal by their last bytes alone, each `nil` when its text is empty.
///
/// An ASCII last byte is the last scalar of the normalized text as well: nothing composes with it
/// or reorders past it, and it ends any sequence left open before it. Two that differ settle `==`
/// without reading further, as does an empty text against one that is not, since no text
/// normalizes to nothing. That is the comparison a deduplicated stream makes, a value against its
/// own snapshot from one append earlier, so it stays O(1) rather than a scan of both.
func streamLastBytesDiffer(_ left: UInt8?, _ right: UInt8?) -> Bool {
  switch (left, right) {
  case (nil, nil): false
  case (nil, _), (_, nil): true
  case let (left?, right?): left != right && (left | right) < 0x80
  }
}

extension _StreamUTF8Backed {
  /// The last accumulated byte, or `nil` when there is none.
  @usableFromInline
  var utf8LastByte: UInt8? {
    let count = self.utf8Count
    return count > 0 ? self.utf8Byte(at: count &- 1) : nil
  }

  /// `String`'s order for the text against the UTF-8 in `buffer` when the bytes decide it, or
  /// `nil` when a non-ASCII byte follows their first difference and only decoding can.
  @usableFromInline
  func utf8Ordering(_ buffer: UnsafeBufferPointer<UInt8>) -> Int? {
    let common = self.utf8CommonPrefixCount(buffer)
    guard self.utf8IsASCII(from: common), streamBytesAreASCII(buffer, from: common) else {
      return nil
    }
    return streamASCIITailOrdering(
      common < self.utf8Count ? self.utf8Byte(at: common) : nil,
      common < buffer.count ? buffer[common] : nil
    )
  }

  /// Whether the text equals `other` as `String` compares them.
  @usableFromInline
  func textEquals(_ other: some StringProtocol) -> Bool {
    var copy = String(other)
    let decided: Bool? = copy.withUTF8 { buffer in
      if streamLastBytesDiffer(self.utf8LastByte, buffer.last) { return false }
      return self.utf8Ordering(buffer).map { $0 == 0 }
    }
    if let decided { return decided }
    return self.decode(in: 0..<self.utf8Count) == copy
  }

  /// Whether the text orders before the UTF-8 in `buffer` as `String` orders them.
  @usableFromInline
  func textPrecedes(utf8 buffer: UnsafeBufferPointer<UInt8>) -> Bool {
    if let ordering = self.utf8Ordering(buffer) { return ordering < 0 }
    return self.decode(in: 0..<self.utf8Count) < String(decoding: buffer, as: UTF8.self)
  }

  /// Whether the text equals the UTF-8 in `buffer` as `String` compares them.
  @usableFromInline
  func textEquals(utf8 buffer: UnsafeBufferPointer<UInt8>) -> Bool {
    if streamLastBytesDiffer(self.utf8LastByte, buffer.last) { return false }
    if let ordering = self.utf8Ordering(buffer) { return ordering == 0 }
    return self.decode(in: 0..<self.utf8Count) == String(decoding: buffer, as: UTF8.self)
  }
}

// MARK: - Searching

// Byte-wise, and named for it: each borrows the foreign text's UTF-8 once and hands it to
// `utf8Matches`, the one requirement that knows the storage layout.
extension _StreamUTF8Backed {
  @usableFromInline
  func utf8HasPrefix(_ prefix: some StringProtocol) -> Bool {
    var copy = String(prefix)
    return copy.withUTF8 { self.utf8Matches($0, at: 0) }
  }

  @usableFromInline
  func utf8HasSuffix(_ suffix: some StringProtocol) -> Bool {
    var copy = String(suffix)
    return copy.withUTF8 { buffer in
      self.utf8Matches(buffer, at: self.utf8Count &- buffer.count)
    }
  }

  /// A first-byte scan with a full match at each candidate, so the worst case is quadratic. The
  /// caller range-checks `offset`, so its `precondition` names its own type.
  @usableFromInline
  func utf8Search(for needle: some StringProtocol, from offset: Int) -> Range<Int>? {
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
}
