// String storage the parser appends raw UTF-8 to, decoding once at read instead of building a
// `String` per chunk (~7x under `String.streamAppend`, `StringAppendBenchmarks`). Up to 64 bytes
// live inline; past that, sealed blocks double from 512 bytes (or a size known at promotion) to an
// 8 KiB cap and are never written again, so a snapshot shares them and an append copies at most
// the tail. Every block boundary is a multiple of 512, so reads, equality, ordering and hashing
// walk canonical 512-byte windows whatever the physical layout. The value holds one reference, the
// tail, whose header carries the sealed blocks; it is `nil` while the bytes are inline.

// A `StreamString` block: one allocation for a header and the bytes, as `StreamBlock`.
@usableFromInline
struct StreamStringChunkHeader {
  // The bytes written. The owning value makes the chunk unique before changing anything here.
  @usableFromInline var count: Int
  // Stored rather than read back from `malloc_size` the way `ManagedBuffer.capacity` does.
  @usableFromInline let capacity: Int
  // The tail's: the sealed blocks ahead of it, in order. Moved out when the tail seals, so a sealed
  // block holds none and no block reaches itself.
  @usableFromInline var blocks: [StreamStringChunk]

  @usableFromInline
  init(count: Int, capacity: Int, blocks: [StreamStringChunk]) {
    self.count = count
    self.capacity = capacity
    self.blocks = blocks
  }
}

@usableFromInline
final class StreamStringChunk: ManagedBuffer<StreamStringChunkHeader, UInt8> {
  @inlinable
  static func make(capacity: Int, blocks: [StreamStringChunk]) -> StreamStringChunk {
    let buffer = Self.create(minimumCapacity: capacity) { _ in
      StreamStringChunkHeader(count: 0, capacity: capacity, blocks: blocks)
    }
    return unsafeDowncast(buffer, to: StreamStringChunk.self)
  }

  // Through the pointer, not `ManagedBuffer.header`: see `StreamBlock.headerPointer`.
  @inlinable
  var headerPointer: UnsafeMutablePointer<StreamStringChunkHeader> {
    self.withUnsafeMutablePointerToHeader { $0 }
  }

  @inlinable
  var bytes: UnsafeMutablePointer<UInt8> {
    self.withUnsafeMutablePointerToElements { $0 }
  }

  @inlinable
  var count: Int {
    get { self.headerPointer.pointee.count }
    set { self.headerPointer.pointee.count = newValue }
  }

  // Not `capacity`: `ManagedBuffer` owns that name for its `malloc_size` read.
  @inlinable
  var byteCapacity: Int { self.headerPointer.pointee.capacity }

  @inlinable
  var buffer: UnsafeBufferPointer<UInt8> {
    UnsafeBufferPointer(start: self.bytes, count: self.count)
  }

  @inlinable
  func takeBlocks() -> [StreamStringChunk] {
    var blocks = [StreamStringChunk]()
    swap(&blocks, &self.headerPointer.pointee.blocks)
    return blocks
  }
}

/// String storage a parser appends raw UTF-8 to, decoding once when it is read.
///
/// This is what a `String` member of a `@StreamParseable` type is stored as in its `Partial`.
/// Appending a chunk copies bytes and never builds a `String`, and a snapshot shares every block the
/// parser has finished with, so reading the value after every chunk stays cheap. Convert with
/// `String(_:)` to read the text.
///
/// **Comparison follows `String`.** `==`, `<` and `hash(into:)`, and `==` against a `String` or
/// any `StringProtocol`, use canonical equivalence, so two spellings of one character are equal.
/// Most comparisons never decode: the bytes are compared first, and both sides are decoded and
/// compared as `String`s only when a non-ASCII byte follows the first byte where they differ.
/// Different lengths alone do not make two values unequal. `==` settles most unequal pairs from
/// their last bytes, such as a value against its snapshot from before an append, and otherwise
/// reads both values up to their first difference.
///
/// **Searching is by UTF-8 bytes**, and the names say so: ``hasUTF8Prefix(_:)``,
/// ``hasUTF8Suffix(_:)``, ``containsUTF8(_:)``, ``utf8Range(of:from:)`` and ``isUTF8Prefix(of:)``
/// compare bytes, which for decoded JSON text is scalar by scalar, and never normalize:
///
/// ```swift
/// StreamString("\u{E9}") == StreamString("e\u{301}")      // true, as for `String`
/// StreamString("e\u{301}").hasUTF8Prefix("\u{E9}")         // false: the bytes differ
/// StreamString("e\u{301}").containsUTF8("e")               // true: scalar, not grapheme, aligned
/// ```
///
/// Convert to `String` first to search by canonical equivalence.
public struct StreamString {
  @usableFromInline
  struct InlineBuffer: Sendable {
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

  // Held in the value: a copied short string needs no refcount, a short append no allocation.
  @usableFromInline var inlineBytes = InlineBuffer()
  // Low byte: the inline count (0...64). Bits 8..15: the first block's shift (block `k` holds
  // `1 << min(shift + k, 13)` bytes). Bits 16..23: the tail block's shift, `min(first +
  // blocks.count, 13)`, cached so the append path reads a word it already loads. Measured: reading
  // `blocks.count` instead cost -6..-17% on the byte-fed rows.
  @usableFromInline var storageBits =
    (StreamString.blockShift &<< 16) | (StreamString.blockShift &<< 8)

  // `nil` while the bytes are inline, so opening a short value is a zeroed write and dropping it a
  // null release. Past that, the filling block, the only allocated storage an append touches and so
  // the most it can copy; its header holds the sealed blocks, which are never written again and
  // follow the schedule, see `sealedPosition(of:)`. One reference however many blocks: a copy is
  // one retain, and the inline test is this word.
  @usableFromInline var tail: StreamStringChunk? = nil

  @usableFromInline static var inlineCapacity: Int { 64 }

  // 512 bytes: the unhinted first block and the canonical logical window. The 8 KiB cap bounds the
  // tail a snapshot can force an append to copy; a hint may start the schedule anywhere in range.
  @usableFromInline static var blockShift: Int { 9 }
  @usableFromInline static var blockCapacity: Int { 1 &<< Self.blockShift }
  @usableFromInline static var blockMask: Int { Self.blockCapacity &- 1 }

  @usableFromInline static var maximumBlockShift: Int { 13 }

  @usableFromInline
  var inlineCount: Int {
    get { self.storageBits & 0xFF }
    set { self.storageBits = (self.storageBits & ~0xFF) | newValue }
  }

  // The first sealed block's shift; block `k` uses `min(startBlockShift + k, maximumBlockShift)`.
  @usableFromInline var startBlockShift: Int { (self.storageBits &>> 8) & 0xFF }
  @usableFromInline var startBlockCapacity: Int { 1 &<< self.startBlockShift }

  // The capacity of the block the tail is currently filling, read from the cached shift.
  @usableFromInline
  var tailBlockCapacity: Int { 1 &<< ((self.storageBits &>> 16) & 0xFF) }

  // (Re)starts the schedule and the tail cache at `shift`. Only called while the bytes are inline,
  // which keeps both consistent with no sealed blocks.
  @inlinable
  mutating func setStartBlockShift(_ shift: Int) {
    self.storageBits = (shift &<< 16) | (shift &<< 8) | self.inlineCount
  }

  // Bytes sealed ahead of block `k`: while the schedule doubles, prefix sums are the geometric
  // series `2^(s+k) - 2^s`; past the cap they grow linearly at `2^13` per block.
  @inlinable
  func sealedPrefix(before block: Int) -> Int {
    let shift = self.startBlockShift
    let ramp = min(block, Self.maximumBlockShift &- shift)
    return (1 &<< (shift &+ ramp)) &- (1 &<< shift)
      &+ ((block &- ramp) &<< Self.maximumBlockShift)
  }

  // Inverts `sealedPrefix`: inside the doubling ramp the block is `log2((position >> s) + 1)`, one
  // `clz`; past it, a shift and a mask.
  @inlinable
  func sealedPosition(of position: Int) -> (block: Int, offset: Int) {
    let shift = self.startBlockShift
    let rampBytes = (1 &<< Self.maximumBlockShift) &- (1 &<< shift)
    if position < rampBytes {
      let block = Int.bitWidth &- 1 &- ((position &>> shift) &+ 1).leadingZeroBitCount
      return (block, position &- ((1 &<< (shift &+ block)) &- (1 &<< shift)))
    }
    let beyond = position &- rampBytes
    return (
      (Self.maximumBlockShift &- shift) &+ (beyond &>> Self.maximumBlockShift),
      beyond & ((1 &<< Self.maximumBlockShift) &- 1)
    )
  }

  // Every property's value is its declared default. Measured: assigning the three here instead
  // built the value on the stack and copied it, an outlined retain and release of the `nil` tail
  // on every member opened, because the optimizer does not forward the stores of a struct this
  // many fields wide.
  public init() {}

  public init(_ string: some StringProtocol) {
    self.init()
    var copy = String(string)
    copy.withUTF8 { self.append(utf8: $0) }
  }

  // `@inlinable` because `append(utf8:)` and `utf8Count` are: out of line, a client specialisation
  // copied the whole value to the stack and called out per append. One-way: a value that has left
  // inline storage keeps a tail, empty or not.
  @inlinable var usesInlineStorage: Bool { self.tail == nil }

  // The rest are for a promoted value only.
  @inlinable var tailChunk: StreamStringChunk { self.tail.unsafelyUnwrapped }
  @inlinable var sealedBlockCount: Int { self.tailChunk.headerPointer.pointee.blocks.count }
  @inlinable var sealedCount: Int { self.sealedPrefix(before: self.sealedBlockCount) }

  @inlinable
  func sealedBlock(_ index: Int) -> StreamStringChunk {
    self.tailChunk.headerPointer.pointee.blocks[index]
  }

  /// The number of UTF-8 bytes accumulated so far.
  @inlinable
  public var utf8Count: Int {
    self.usesInlineStorage ? self.inlineCount : self.sealedCount &+ self.tailChunk.count
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
        let inlineCount = self.inlineCount
        withUnsafeMutableBytes(of: &self.inlineBytes) { destination in
          destination.baseAddress!.advanced(by: inlineCount).copyMemory(
            from: base, byteCount: buffer.count
          )
        }
        self.inlineCount = needed
        return
      }
      self.promoteSizedInlineStorage(reserving: needed)
    }
    self.appendBlocked(buffer)
  }

  // The first overflow append sizes the schedule from the *whole* byte count in hand (a reservation
  // uses half), so one big span lands in one block. Never lowers a reserved shift. Measured: LLM
  // bulk +73.7%, GSoC +11.6%; `@inline(never)` because inlined into every `stringChunk` site it
  // flips the parse loop's inlining. See NEW_ARCHITECTURE.md.
  @inlinable
  @inline(never)
  mutating func promoteSizedInlineStorage(reserving needed: Int) {
    let desiredShift = Int.bitWidth &- (needed &- 1).leadingZeroBitCount
    if desiredShift > self.startBlockShift {
      self.setStartBlockShift(min(desiredShift, Self.maximumBlockShift))
    }
    self.promoteInlineStorage(reserving: needed)
  }

  @inlinable
  mutating func promoteInlineStorage(reserving capacity: Int) {
    let count = self.inlineCount
    let blockCapacity = self.startBlockCapacity
    let reservation = count == 0
      ? min(capacity, blockCapacity)
      : blockCapacity
    let chunk = StreamStringChunk.make(capacity: reservation, blocks: [])
    if count > 0 {
      withUnsafeBytes(of: self.inlineBytes) { source in
        chunk.bytes.initialize(
          from: source.baseAddress!.assumingMemoryBound(to: UInt8.self), count: count
        )
      }
      chunk.count = count
    }
    self.tail = chunk
    self.inlineCount = 0
  }

  @inlinable
  mutating func appendBlocked(_ buffer: UnsafeBufferPointer<UInt8>) {
    guard let base = buffer.baseAddress else { return }
    var blockCapacity = self.tailBlockCapacity
    var offset = 0
    while offset < buffer.count {
      // Ahead of any local reference to the tail, which would itself make it shared.
      let unique = isKnownUniquelyReferenced(&self.tail)
      let count = self.tailChunk.count
      let capacity = self.tailChunk.byteCapacity
      let take = min(blockCapacity &- count, buffer.count &- offset)
      let needed = count &+ take
      // One test for both reasons to copy: a snapshot shares the tail, or it is too small.
      if !unique || capacity < needed {
        // An empty tail reserves only the fragment in hand, but only for the *first* block: after
        // a seal a fragment-fed value would reallocate its way up every block. "A block has sealed"
        // comes from `storageBits`, so it adds no dependent load on the blocks.
        let provenLong =
          blockCapacity != self.startBlockCapacity
          || blockCapacity == 1 &<< Self.maximumBlockShift
        let grown = count == 0 && !provenLong ? take : blockCapacity
        self.reallocateTail(capacity: capacity < needed ? grown : capacity, unique: unique)
      }
      let chunk = self.tailChunk
      (chunk.bytes + count).initialize(from: base + offset, count: take)
      chunk.count = needed
      offset &+= take
      guard needed == blockCapacity else { continue }
      // The schedule doubles until the cap, and the cached tail shift moves with it.
      if blockCapacity < 1 &<< Self.maximumBlockShift {
        self.storageBits &+= 1 &<< 16
        blockCapacity &<<= 1
      }
      self.sealTail(nextCapacity: blockCapacity)
    }
  }

  // Copies the tail into a chunk of `capacity`: a snapshot shares it, or it is too small. A unique
  // tail hands its sealed blocks over; a shared one keeps them for the value it is shared with.
  @usableFromInline
  @inline(never)
  mutating func reallocateTail(capacity: Int, unique: Bool) {
    let old = self.tailChunk
    let blocks = unique ? old.takeBlocks() : old.headerPointer.pointee.blocks
    let chunk = StreamStringChunk.make(capacity: capacity, blocks: blocks)
    chunk.bytes.initialize(from: old.bytes, count: old.count)
    chunk.count = old.count
    self.tail = chunk
  }

  // The full tail joins the sealed blocks and a `nextCapacity` block takes its place, allocated now
  // because a promoted value always has a tail; only a value ending exactly on a seal wastes it.
  // The tail is unique here: the append that filled it made it so.
  @usableFromInline
  @inline(never)
  mutating func sealTail(nextCapacity: Int) {
    let sealed = self.tailChunk
    var blocks = sealed.takeBlocks()
    // Reserved at the first seal: doubling from one cost a three-block value two reallocations.
    // Measured: keyed on `capacity`, not `isEmpty` -- `streamReserve` already sizes this array,
    // and reserving 4 over a hint of 2 cost +163 mallocs on hinted GSoC.
    if blocks.capacity == 0 { blocks.reserveCapacity(4) }
    blocks.append(sealed)
    self.tail = StreamStringChunk.make(capacity: nextCapacity, blocks: blocks)
  }

  // MARK: Reading

  @inlinable
  func withInlineBuffer<R>(_ body: (UnsafeBufferPointer<UInt8>) throws -> R) rethrows -> R {
    try withUnsafeBytes(of: self.inlineBytes) { source in
      try body(
        UnsafeBufferPointer(
          start: source.baseAddress!.assumingMemoryBound(to: UInt8.self), count: self.inlineCount
        )
      )
    }
  }

  // One memcpy inline; blocked, one per block touched plus one for the tail.
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
      let (index, start) = self.sealedPosition(of: position)
      let block = self.sealedBlock(index)
      // Sealed blocks are full, so a block's own count is its capacity on the schedule.
      let take = min(block.count &- start, range.upperBound &- position)
      (base + written).initialize(from: block.bytes + start, count: take)
      written &+= take
      position &+= take
    }
    guard position < range.upperBound else { return }
    (base + written).initialize(
      from: self.tailChunk.bytes + (position &- sealed),
      count: range.upperBound &- position
    )
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
    // A range in the tail or inside one sealed block is contiguous and decodes in place.
    let sealed = self.sealedCount
    if range.lowerBound >= sealed {
      let tail = self.tailChunk
      precondition(range.upperBound &- sealed <= tail.count, "StreamString byte range out of range")
      return String(
        decoding: UnsafeBufferPointer(
          start: tail.bytes + (range.lowerBound &- sealed), count: range.count
        ),
        as: UTF8.self
      )
    }
    let (firstBlock, start) = self.sealedPosition(of: range.lowerBound)
    let block = self.sealedBlock(firstBlock)
    if range.count <= block.count &- start {
      return String(
        decoding: UnsafeBufferPointer(start: block.bytes + start, count: range.count),
        as: UTF8.self
      )
    }
    let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: range.count)
    defer { buffer.deallocate() }
    self.copyBytes(in: range, to: buffer)
    return String(decoding: buffer, as: UTF8.self)
  }
}

// MARK: - Byte access

extension StreamString {
  // The byte read every view routes through.
  @inlinable
  func utf8Byte(at position: Int) -> UInt8 {
    if self.usesInlineStorage {
      // Both bounds: past this arm `UnsafeBufferPointer.subscript` checks only in debug.
      precondition(
        position >= 0 && position < self.inlineCount, "StreamString byte offset out of range"
      )
      return self.withInlineBuffer { $0[position] }
    }
    let sealed = self.sealedCount
    if position < sealed {
      // A negative position lands on a block index past the array's bounds, which traps.
      let (block, offset) = self.sealedPosition(of: position)
      return self.sealedBlock(block).bytes[offset]
    }
    let offset = position &- sealed
    precondition(offset < self.tailChunk.count, "StreamString byte offset out of range")
    return self.tailChunk.bytes[offset]
  }

  // Runs `body` over `[position, position + count)`, which must not cross a 512-byte window: seals
  // and the tail are 512-aligned after promotion, and an inline value is one window.
  @usableFromInline
  func withWindow<R>(
    at position: Int, count: Int, _ body: (UnsafeBufferPointer<UInt8>) -> R
  ) -> R {
    // Unchecked in release: callers derive `count` from the 512 mask, safe only because
    // `startBlockShift >= 9` (`init`, and `setStartBlockShift`'s callers only raise it).
    assert(
      count >= 0 && position >= 0 && position &+ count <= self.utf8Count,
      "StreamString window out of range"
    )
    assert(
      self.usesInlineStorage || count <= 512 &- (position & 511),
      "StreamString window crosses a physical block boundary"
    )
    if self.usesInlineStorage {
      return self.withInlineBuffer { buffer in
        body(UnsafeBufferPointer(start: buffer.baseAddress! + position, count: count))
      }
    }
    let sealed = self.sealedCount
    if position < sealed {
      let (block, offset) = self.sealedPosition(of: position)
      return body(UnsafeBufferPointer(start: self.sealedBlock(block).bytes + offset, count: count))
    }
    return body(UnsafeBufferPointer(start: self.tailChunk.bytes + (position &- sealed), count: count))
  }
}

// MARK: - Key words

// The read side of `Span<UInt8>.paddedWord(at:)`'s encoding, so a generated `String`-raw enum
// matcher compares a value against a literal with the same codegen it uses for object keys, and
// never materializes a `String`.
extension StreamString {
  /// The accumulated UTF-8 bytes `start..<start + 8`, little-endian, zero-padded past
  /// ``utf8Count``.
  ///
  /// A matcher must still test ``utf8Count``: a value may hold a decoded NUL, which the padding is
  /// otherwise indistinguishable from. `start` must be a multiple of eight, so the word never
  /// crosses a 512-byte block.
  @inlinable
  public func paddedWord(at start: Int) -> UInt64 {
    // Debug only: a `precondition` would land on the generated enum matcher path.
    assert(start & 7 == 0, "StreamString.paddedWord(at:) requires an eight-byte aligned start")
    let count = self.utf8Count
    guard start >= 0, start < count else { return 0 }
    // Clamped rather than overread: unlike a key span, a value's last block ends where it does.
    let available = min(8, count &- start)
    return self.withWindow(at: start, count: available) { buffer in
      streamPaddedWord(
        base: UnsafeRawPointer(buffer.baseAddress.unsafelyUnwrapped),
        from: 0,
        to: available
      )
    }
  }

  /// The first eight accumulated UTF-8 bytes as one little-endian word.
  ///
  /// - SeeAlso: ``paddedWord(at:)``
  @inlinable
  public func paddedLeadingWord() -> UInt64 {
    self.paddedWord(at: 0)
  }
}

// MARK: - Scalar decoding

// The primitives the read layer in `StreamString+Reading.swift` is written against.
extension StreamString {
  // Decodes the scalar at `position`, repairing as the `String` decode does: a byte that cannot
  // begin a sequence is U+FFFD of length one, and a sequence cut short is one U+FFFD over its
  // maximal subpart. The narrowed second-byte ranges reject overlong forms and surrogates.
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
    // A sequence cut short -- by a byte that cannot continue it, or by the end -- is one U+FFFD
    // spanning the lead and every byte that did continue it (the maximal subpart), as `String`
    // repairs it.
    let count = self.utf8Count
    guard position &+ 1 < count else { return ("\u{FFFD}", 1) }
    let byte1 = self.utf8Byte(at: position &+ 1)
    guard second.contains(byte1) else { return ("\u{FFFD}", 1) }
    // The lead's payload mask follows from its length: 0x1F, 0x0F, 0x07 for two, three, four.
    var value = UInt32(lead & (0x7F &>> UInt8(length)))
    value = value &<< 6 | UInt32(byte1 & 0x3F)
    if length > 2 {
      guard position &+ 2 < count else { return ("\u{FFFD}", 2) }
      let byte2 = self.utf8Byte(at: position &+ 2)
      guard byte2 & 0xC0 == 0x80 else { return ("\u{FFFD}", 2) }
      value = value &<< 6 | UInt32(byte2 & 0x3F)
    }
    if length > 3 {
      guard position &+ 3 < count else { return ("\u{FFFD}", 3) }
      let byte3 = self.utf8Byte(at: position &+ 3)
      guard byte3 & 0xC0 == 0x80 else { return ("\u{FFFD}", 3) }
      value = value &<< 6 | UInt32(byte3 & 0x3F)
    }
    // In range and not a surrogate by the second-byte narrowing above.
    return (Unicode.Scalar(value).unsafelyUnwrapped, length)
  }

  // The largest scalar-aligned offset at or before `limit`, backing off over at most three
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
  /// the two views. Ill-formed bytes decode as the repairing `String` decode does: one U+FFFD per
  /// byte that cannot begin a sequence, and one per sequence cut short. Table-free, so it stays
  /// inside the embedded subset.
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

// `characterSpan(at:)` is in `StreamString+Reading.swift`.
extension StreamString {
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

// `StreamString` cannot conform to `StringProtocol` (it requires `String.Index` positions and
// `Character` elements, and the stdlib admits only `String` and `Substring`), so this bridges:
// one decode, then the full `String` API.
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

  // Custom, so segments append as bytes instead of assembling a `String` first.
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
      // `String(describing:)` is reflection, outside the Embedded subset.
      public mutating func appendInterpolation<T>(_ item: T) {
        self.value.append(String(describing: item))
      }
    #endif
  }

  public init(stringInterpolation: StringInterpolation) {
    self = stringInterpolation.value
  }
}

// As `String` compares: canonical equivalence, decoding only when a non-ASCII byte follows the
// first difference. See `StreamString+Reading.swift`.
extension StreamString: Equatable {
  public static func == (lhs: Self, rhs: Self) -> Bool {
    // Equal lengths first: equal bytes are equal text, and a deduplicated stream mostly compares
    // a value with an unchanged snapshot of itself. Inlined, this is the byte-wise loop `==` was.
    var common: Int?
    if lhs.utf8Count == rhs.utf8Count {
      let agreed = lhs.utf8CommonPrefixCount(rhs)
      if agreed == lhs.utf8Count { return true }
      common = agreed
    }
    if streamLastBytesDiffer(lhs.utf8LastByte, rhs.utf8LastByte) { return false }
    if let ordering = lhs.utf8Ordering(rhs, common: common) { return ordering == 0 }
    return String(lhs) == String(rhs)
  }

  /// `String`'s order for two values when their bytes decide it, or `nil` when only decoding can.
  /// `common` is their common prefix's length when the caller already has it.
  @usableFromInline
  func utf8Ordering(_ other: Self, common known: Int? = nil) -> Int? {
    let common = known ?? self.utf8CommonPrefixCount(other)
    guard self.utf8IsASCII(from: common), other.utf8IsASCII(from: common) else { return nil }
    return streamASCIITailOrdering(
      common < self.utf8Count ? self.utf8Byte(at: common) : nil,
      common < other.utf8Count ? other.utf8Byte(at: common) : nil
    )
  }

  // One `streamFirstDifference` per 512-byte window, which both values cut at the same offsets.
  @inline(__always)
  func utf8CommonPrefixCount(_ other: Self) -> Int {
    let count = min(self.utf8Count, other.utf8Count)
    var position = 0
    while position < count {
      let take = min(Self.blockCapacity &- (position & Self.blockMask), count &- position)
      let agreed = self.withWindow(at: position, count: take) { left in
        other.withWindow(at: position, count: take) { right in
          streamFirstDifference(left.baseAddress!, right.baseAddress!, count: take)
        }
      }
      position &+= agreed
      guard agreed == take else { break }
    }
    return position
  }

  @usableFromInline
  func utf8CommonPrefixCount(_ buffer: UnsafeBufferPointer<UInt8>) -> Int {
    let count = min(self.utf8Count, buffer.count)
    var position = 0
    while position < count {
      let take = min(Self.blockCapacity &- (position & Self.blockMask), count &- position)
      let agreed = self.withWindow(at: position, count: take) { source in
        streamFirstDifference(source.baseAddress!, buffer.baseAddress! + position, count: take)
      }
      position &+= agreed
      guard agreed == take else { break }
    }
    return position
  }

  @usableFromInline
  func utf8IsASCII(from offset: Int) -> Bool {
    let count = self.utf8Count
    var position = offset
    while position < count {
      let take = min(Self.blockCapacity &- (position & Self.blockMask), count &- position)
      let isASCII = self.withWindow(at: position, count: take) { window in
        streamBytesAreASCII(window.baseAddress!, count: take)
      }
      guard isASCII else { return false }
      position &+= take
    }
    return true
  }
}

// Against `String` directly, because `partial.title == expected` is the commonest client
// comparison. Canonical equivalence like `==`; the optional overloads exist because optional
// lifting only reaches the homogeneous operator.
extension StreamString {
  // `textEquals(_:)` is in `StreamString+Reading.swift`.

  // Whether `buffer` matches the bytes at `offset`: one `streamBytesEqual` per window touched.
  // Shared by the searchers, which are byte-wise.
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
    lhs.textEquals(rhs)
  }

  @inlinable
  public static func == (lhs: some StringProtocol, rhs: Self) -> Bool {
    rhs.textEquals(lhs)
  }

  @inlinable
  public static func != (lhs: Self, rhs: some StringProtocol) -> Bool {
    !lhs.textEquals(rhs)
  }

  @inlinable
  public static func != (lhs: some StringProtocol, rhs: Self) -> Bool {
    !rhs.textEquals(lhs)
  }

}

// Free functions: a member operator must take `StreamString` itself somewhere.

@inlinable
public func == (lhs: StreamString?, rhs: some StringProtocol) -> Bool {
  lhs?.textEquals(rhs) ?? false
}

@inlinable
public func == (lhs: some StringProtocol, rhs: StreamString?) -> Bool {
  rhs?.textEquals(lhs) ?? false
}

@inlinable
public func != (lhs: StreamString?, rhs: some StringProtocol) -> Bool {
  !(lhs?.textEquals(rhs) ?? false)
}

@inlinable
public func != (lhs: some StringProtocol, rhs: StreamString?) -> Bool {
  !(rhs?.textEquals(lhs) ?? false)
}

// MARK: - Searching

// Byte-wise, unlike `==`, and named for it: the scalar-exact answer with no decode.
extension StreamString {
  /// Whether the accumulated bytes start with `prefix`'s UTF-8, compared byte-wise.
  public func hasUTF8Prefix(_ prefix: some StringProtocol) -> Bool {
    self.utf8HasPrefix(prefix)
  }

  /// Whether the accumulated bytes are a prefix of `text`'s UTF-8, compared byte-wise —
  /// including when they are all of it.
  ///
  /// The direction a *streaming* match needs: whether what has arrived so far is still consistent
  /// with `text`. A generated enum matcher walks its cases shortest-first asking this, so the
  /// first case still consistent with the bytes in hand is the shortest one.
  public func isUTF8Prefix(of text: some StringProtocol) -> Bool {
    var copy = String(text)
    return copy.withUTF8 { buffer in
      let count = self.utf8Count
      guard count <= buffer.count else { return false }
      return self.utf8Matches(UnsafeBufferPointer(start: buffer.baseAddress, count: count), at: 0)
    }
  }

  /// Whether the accumulated bytes end with `suffix`'s UTF-8, compared byte-wise.
  public func hasUTF8Suffix(_ suffix: some StringProtocol) -> Bool {
    self.utf8HasSuffix(suffix)
  }

  /// The byte range of the first occurrence of `needle`'s UTF-8 at or after `offset`, compared
  /// byte-wise.
  ///
  /// The bounds are byte offsets. A match in well-formed text is scalar-aligned but not
  /// necessarily grapheme-aligned: `"e"` matches inside a decomposed `"é"`. An empty needle matches
  /// emptily at `offset`. The worst case is quadratic.
  public func utf8Range(of needle: some StringProtocol, from offset: Int = 0) -> Range<Int>? {
    precondition(
      offset >= 0 && offset <= self.utf8Count, "StreamString byte offset out of range"
    )
    return self.utf8Search(for: needle, from: offset)
  }

  /// Whether `other`'s UTF-8 occurs anywhere in the accumulated bytes, compared byte-wise.
  public func containsUTF8(_ other: some StringProtocol) -> Bool {
    self.utf8Range(of: other) != nil
  }
}

// MARK: - Appending

extension StreamString {
  /// Reserves room for `utf8ByteCount` UTF-8 bytes, promoting out of the inline representation
  /// when the request cannot fit there.
  ///
  /// A request that is not larger than the current count, negative ones included, does nothing.
  @inlinable
  public mutating func streamReserve(utf8ByteCount: Int) {
    guard utf8ByteCount > self.utf8Count else { return }
    if self.usesInlineStorage {
      guard utf8ByteCount > Self.inlineCapacity else { return }
      let half = (utf8ByteCount &>> 1) &+ (utf8ByteCount & 1)
      let desiredShift = Int.bitWidth &- (half &- 1).leadingZeroBitCount
      let blockShift = min(max(desiredShift, Self.blockShift), Self.maximumBlockShift)
      // Only ever raises: an append-sized promotion cannot have run yet (no blocked bytes), and
      // a lower late hint must not shrink the schedule the cached tail shift already follows.
      if blockShift > self.startBlockShift {
        self.setStartBlockShift(blockShift)
      }
      self.promoteInlineStorage(reserving: utf8ByteCount)
    }
    // As `ContiguousArray.reserveCapacity`: a shared tail is copied even when it is large enough.
    let unique = isKnownUniquelyReferenced(&self.tail)
    let wanted = min(utf8ByteCount, self.tailBlockCapacity)
    let capacity = self.tailChunk.byteCapacity
    if !unique || capacity < wanted {
      self.reallocateTail(capacity: max(capacity, wanted), unique: unique)
    }
    // The block holding the last byte, plus one.
    self.tailChunk.headerPointer.pointee.blocks.reserveCapacity(
      self.sealedPosition(of: utf8ByteCount &- 1).block &+ 1
    )
  }

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
    // `other` holds its chunks for the whole loop, so `x.append(x)` reads storage the appends to
    // `self` only ever copy away from.
    let tail = other.tailChunk
    for block in tail.headerPointer.pointee.blocks {
      self.append(utf8: block.buffer)
    }
    self.append(utf8: tail.buffer)
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

// `print(x, to: &value)` appends.
extension StreamString: TextOutputStream {
  public mutating func write(_ string: String) {
    self.append(string)
  }
}

extension StreamString: TextOutputStreamable {
  // Block-at-a-time, each cut backed off to a scalar boundary; never materializes the whole value.
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

// Hashes what `==` compares, the normalized text. ASCII is its own normalization, so it hashes in
// place; anything else is normalized through `String`. Both feed the bytes and then 0xFF, which no
// UTF-8 contains, and `Hasher` sees one byte stream however it is split, so the two paths agree on
// equal text: `"K"` and the Kelvin sign `"\u{212A}"` are equal, and only one of them is ASCII.
extension StreamString: Hashable {
  public func hash(into hasher: inout Hasher) {
    if self.utf8IsASCII(from: 0) {
      var position = 0
      while position < self.utf8Count {
        let take = min(Self.blockCapacity, self.utf8Count &- position)
        self.withWindow(at: position, count: take) {
          hasher.combine(bytes: UnsafeRawBufferPointer($0))
        }
        position &+= take
      }
    } else {
      String(self)._withNFCCodeUnits { hasher.combine($0) }
    }
    hasher.combine(0xFF as UInt8)
  }
}

// As `String` orders: by normalized scalars, which the bytes decide unless a non-ASCII byte follows
// the first difference. See `StreamString+Reading.swift`.
extension StreamString: Comparable {
  public static func < (lhs: Self, rhs: Self) -> Bool {
    if let ordering = lhs.utf8Ordering(rhs) { return ordering < 0 }
    return String(lhs) < String(rhs)
  }
}

// `@unchecked` because a `ManagedBuffer` subclass cannot be `Sendable`; the chunks are written only
// while uniquely held, the grounds `StreamArray` asserts it on.
extension StreamString: @unchecked Sendable {}

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
  // Otherwise a reflecting printer dumps the blocks and the tail.
  extension StreamString: CustomReflectable {
    public var customMirror: Mirror {
      Mirror(reflecting: String(self))
    }
  }

  // A single value, encoding as the string it stands in for. Outside the Embedded subset.
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
  @discardableResult
  @inlinable
  public mutating func streamAppend(utf8 bytes: Span<UInt8>) -> StreamApplyResult {
    bytes.withUnsafeBufferPointer { buffer in
      self.append(utf8: buffer)
    }
    // Storage grows to fit; the constant folds away once the schema closure specializes.
    return .applied
  }
}

extension StreamString: StreamPartial {}

extension StreamString: StreamParseable {
  public typealias Partial = Self
}
