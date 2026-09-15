// The read surface `StreamString` and `StreamInlineString` share: scalar decoding, grapheme spans,
// byte-wise comparison against foreign text, searching. All of it reduces to the four primitives
// this protocol requires, and the bodies below are written once against them.
//
// Deliberately NOT a home for the primitives themselves. `decodeScalar` and `scalarAlignedOffset`
// stay per-type: one reaches its bytes through a block dispatch and the other through a contiguous
// buffer, and a shared body would put a call where each currently has a load. Nothing the parser's
// chunk path touches is reachable from here.
//
// Ungated, because `StreamString` is; only `StreamInlineString`'s conformance carries availability.
// Internal, which is why each type still spells its own public methods out as one-line forwarders:
// an extension member of an internal protocol is internal however it is spelled.
@usableFromInline
protocol _StreamUTF8Backed {
  /// The number of UTF-8 bytes accumulated so far.
  var utf8Count: Int { get }

  /// The byte at `position`, which must be in range.
  func utf8Byte(at position: Int) -> UInt8

  /// The bytes in `range`, decoded with ill-formed sequences repaired.
  func decode(in range: Range<Int>) -> String

  /// The scalar starting at `position`, repairing: a byte that does not begin a well-formed
  /// sequence decodes as U+FFFD with length one.
  func decodeScalar(at position: Int) -> (scalar: Unicode.Scalar, length: Int)

  /// The largest scalar-aligned offset at or before `limit`, so a window cut never tears a
  /// scalar.
  func scalarAlignedOffset(before limit: Int) -> Int

  /// Whether `buffer` matches the accumulated bytes starting at byte `offset`.
  func utf8Matches(_ buffer: UnsafeBufferPointer<UInt8>, at offset: Int) -> Bool
}

// MARK: - Scalar traversal

extension _StreamUTF8Backed {
  /// The scalar-view index before `index`.
  ///
  /// Walks back over at most three continuation bytes. When the lead byte reached does not
  /// actually span back to `index`, the byte before `index` is ill-formed and stands alone as its
  /// own U+FFFD, which keeps backward and forward traversal visiting the same positions.
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

// Forward `Character` access without claiming that byte offsets are character indices. Grapheme
// segmentation is not public API and its tables are not something this package should carry, so
// the boundary question is delegated to `String`'s own breaker over a small decoded window. The
// window grows while its first character fills it entirely; once that character ends inside the
// window, the boundary is final.
extension _StreamUTF8Backed {
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
}

// MARK: - Comparison against StringProtocol

// Byte-wise, like each type's homogeneous `==`: for decoded JSON text the parser has already
// resolved escapes, so equal documents produce equal bytes. Every one of these borrows the
// foreign text's contiguous UTF-8 once and hands it to `utf8Matches`, which is the single
// requirement that knows how the accumulated bytes are laid out.
extension _StreamUTF8Backed {
  @usableFromInline
  func utf8Equals(_ other: some StringProtocol) -> Bool {
    var copy = String(other)
    return copy.withUTF8 { buffer in
      self.utf8Count == buffer.count && self.utf8Matches(buffer, at: 0)
    }
  }

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

  /// A first-byte scan with a full match at each candidate — worst case is quadratic, which a
  /// field-sized string never notices and a pathological one pays only when asked. `offset` is
  /// range-checked by the caller, whose `precondition` message names its own type.
  @usableFromInline
  func utf8Range(of needle: some StringProtocol, from offset: Int) -> Range<Int>? {
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
