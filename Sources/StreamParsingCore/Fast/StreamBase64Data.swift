import StreamParsingShims

// `realloc` and `free` for `Storage`. Not gated on Embedded as `StreamLock`'s imports are: the type
// runs there, and the Embedded (wasm) smoke reaches it.
#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#elseif canImport(Android)
  import Android
#elseif canImport(WASILibc)
  import WASILibc
#elseif canImport(WinSDK)
  import WinSDK
#endif

/// Binary data a JSON string carries as base64, decoded while the string streams in.
///
/// A string parses into `Data` as the UTF-8 bytes of its own text. Declare a member as
/// `StreamBase64Data` where a document writes bytes in base64 instead, as `JSONEncoder` writes
/// `Data` by default:
///
/// ```swift
/// @StreamParseable
/// struct Attachment {
///   var name: String
///   var contents: StreamBase64Data
/// }
///
/// // {"name": "logo.png", "contents": "iVBORw0KGgoAAAANSUhEUgAA..."}
/// let attachment = try stream.finish()
/// let png = Array(attachment.contents.bytes)
/// ```
///
/// The string must be standard base64 (RFC 4648, section 4) with its `=` padding, as
/// `Data(base64Encoded:)` requires. A character outside that alphabet, whitespace included, or
/// anything after the padding, fails the parse with ``StreamSinkFailure/Reason/conversionFailed``.
///
/// The type is its own partial. While the string streams in, ``bytes`` holds each completed group
/// of four characters, decoded; the up to three characters of an unfinished group wait unseen.
/// ``init(streamPartial:)`` fails while any are waiting, so ``PartialsStream/finish()`` throws
/// ``StreamParsingError/incompleteValue`` for a string that ended inside a group, an unpadded
/// one included. ``init(orInitial:)`` keeps ``bytes`` and drops them. Equality and hashing
/// compare ``bytes`` alone.
public struct StreamBase64Data {
  // Every stored property takes its declared default and `init()` assigns nothing, so opening a
  // member is a run of stores: see NEW_ARCHITECTURE.md, "The initialiser trap".

  // The decoded bytes, nil until there are any. Shared by copies of the value, and by ``bytes``,
  // until one appends: the append copies first unless this reference is the only one, as
  // `Array`'s does.
  @usableFromInline var storage: Storage? = nil

  // The unfinished group's sextets, the latest in the low six bits, and how many (0 ... 3).
  private var pendingBits: UInt32 = 0
  private var pendingCount: UInt8 = 0
  private var phase = Phase.open

  private enum Phase: UInt8 {
    // Taking alphabet characters, or the `=` that begins padding.
    case open
    // One `=` after a group's second character: the second `=` must follow.
    case padding
    // The padding is complete, so the value is: any further character is rejected.
    case closed
    // A character was rejected. The sink keeps handing over the rest of that string, since it
    // reports the failure at the closing quote, so every later append is refused unread.
    case rejected
  }

  /// Creates an empty value.
  public init() {}

  /// Creates a value holding `bytes`, which are already decoded.
  public init(_ bytes: some Sequence<UInt8>) {
    let bytes = ContiguousArray(bytes)
    guard !bytes.isEmpty else { return }
    let storage = Storage.make(capacity: bytes.count)
    bytes.withUnsafeBufferPointer {
      storage.base.update(from: $0.baseAddress.unsafelyUnwrapped, count: $0.count)
    }
    storage.count = bytes.count
    self.storage = storage
  }

  // MARK: Storage

  // A value streamed in chunks grows by doubling, and an `Array` takes every doubling into a fresh
  // allocation, copying what it holds and faulting in the new pages: those copies were 11.5% of the
  // per-1400B row. Here the first bytes live in the storage object's own tail, so a string that
  // arrives whole costs one allocation, as an array's does; the first growth moves them to a
  // block of their own, which every later one `realloc`s. Past a few tens of KiB Darwin's
  // allocator grows a block in place wherever the address space beside it is free (glibc remaps
  // it), so most doublings copy nothing: per 1400B -13.8%. See NEW_ARCHITECTURE.md, "The storage".
  @usableFromInline
  struct StorageHeader {
    // The storage's own tail until the bytes first outgrow it, then a block from `realloc`.
    @usableFromInline var base: UnsafeMutablePointer<UInt8>
    @usableFromInline var count: Int
    @usableFromInline var capacity: Int

    @usableFromInline
    init(base: UnsafeMutablePointer<UInt8>, count: Int, capacity: Int) {
      self.base = base
      self.count = count
      self.capacity = capacity
    }
  }

  // Only ever written while the one reference to it is the value appending.
  @usableFromInline
  final class Storage: ManagedBuffer<StorageHeader, UInt8> {
    static func make(capacity: Int) -> Storage {
      let buffer = Self.create(minimumCapacity: capacity) { buffer in
        StorageHeader(
          base: buffer.withUnsafeMutablePointerToElements { $0 }, count: 0, capacity: capacity
        )
      }
      return unsafeDowncast(buffer, to: Storage.self)
    }

    deinit {
      let base = self.headerPointer.pointee.base
      if base != self.tail { free(base) }
    }

    // Through the pointer, not `ManagedBuffer.header`, whose accesses are checked for exclusivity
    // at run time: see `StreamBlock.headerPointer`.
    @inlinable
    var headerPointer: UnsafeMutablePointer<StorageHeader> {
      self.withUnsafeMutablePointerToHeader { $0 }
    }

    var tail: UnsafeMutablePointer<UInt8> {
      self.withUnsafeMutablePointerToElements { $0 }
    }

    @inlinable
    var base: UnsafeMutablePointer<UInt8> { self.headerPointer.pointee.base }

    @inlinable
    var count: Int {
      get { self.headerPointer.pointee.count }
      set { self.headerPointer.pointee.count = newValue }
    }

    // Not `capacity`: `ManagedBuffer` owns that name for its `malloc_size` read.
    var byteCapacity: Int { self.headerPointer.pointee.capacity }

    // Room for `capacity` bytes, keeping those written: out of the tail into a block, or the
    // block `realloc`ed.
    func reallocate(capacity: Int) {
      let header = self.headerPointer
      let block = realloc(
        header.pointee.base == self.tail ? nil : header.pointee.base, capacity
      )
      guard let block = block?.bindMemory(to: UInt8.self, capacity: capacity) else {
        fatalError("StreamBase64Data: out of memory")
      }
      if header.pointee.base == self.tail {
        block.update(from: self.tail, count: header.pointee.count)
      }
      header.pointee.base = block
      header.pointee.capacity = capacity
    }
  }

  // The header of storage this value alone holds, with room for `extra` bytes past its count. The
  // decoding paths write at `base + count` and then advance `count`. A pointer, not the `Storage`:
  // `self.storage` keeps the object alive, and returning the reference cost a retain and a release
  // per chunk and per string.
  @inline(__always)
  private mutating func reserve(_ extra: Int) -> UnsafeMutablePointer<StorageHeader> {
    if isKnownUniquelyReferenced(&self.storage) {
      let header = self.storage.unsafelyUnwrapped.headerPointer
      if header.pointee.capacity &- header.pointee.count >= extra { return header }
    }
    return self.grow(by: extra)
  }

  // Out of line: once per doubling, or once per append while a copy shares the bytes. An empty
  // value gets exactly what it asked for (most strings arrive whole), at least 16 bytes. A shared
  // one is copied into the capacity it had, doubled if that is short, as `Array` does.
  @inline(never)
  private mutating func grow(by extra: Int) -> UnsafeMutablePointer<StorageHeader> {
    // Asked before `old` binds: that is a second reference, and nothing would ever be unique.
    let unique = isKnownUniquelyReferenced(&self.storage)
    guard let old = self.storage else {
      let storage = Storage.make(capacity: Swift.max(extra, 16))
      self.storage = storage
      return storage.headerPointer
    }
    let needed = old.count &+ extra
    let capacity =
      old.byteCapacity >= needed ? old.byteCapacity : Swift.max(needed, old.byteCapacity &* 2)
    if unique {
      old.reallocate(capacity: capacity)
      return old.headerPointer
    }
    let storage = Storage.make(capacity: capacity)
    storage.base.update(from: old.base, count: old.count)
    storage.count = old.count
    self.storage = storage
    return storage.headerPointer
  }

  // MARK: Decoding

  // How far `decodeRun` may write past the last group's three bytes: the AVX2 tier stores a block's
  // 24 bytes as 32.
  private static let outputSlack = 8

  // False once the string is rejected. An unfinished group or padding goes a character at a time,
  // then whole groups go four at a time until one holds a character outside the alphabet (`=`
  // included); the character-at-a-time path takes the rest. Past that point the string can only
  // close or be rejected, so the bulk path is never needed again.
  private mutating func decode(_ input: UnsafeBufferPointer<UInt8>) -> Bool {
    let tables = stream_parsing_base64_decode_tables().unsafelyUnwrapped
    var index = 0
    while index < input.count, self.pendingCount != 0 || self.phase != .open {
      guard self.take(input[index], tables) else { return false }
      index &+= 1
    }
    index = self.decodeGroups(input, from: index, tables)
    while index < input.count {
      guard self.take(input[index], tables) else { return false }
      index &+= 1
    }
    return true
  }

  // Decodes whole groups from `start` until the input runs short of one or a group holds a
  // character outside the alphabet, and returns where it stopped. The caller has closed any
  // unfinished group, so `start` begins one.
  private mutating func decodeGroups(
    _ input: UnsafeBufferPointer<UInt8>,
    from start: Int,
    _ tables: UnsafePointer<UInt32>
  ) -> Int {
    let groups = (input.count &- start) / 4
    guard groups > 0 else { return start }

    // Room for every group and the slack, decoded straight into the storage: nothing staged,
    // nothing copied. A value fed in small chunks grows by doubling, not by the chunk.
    let header = self.reserve(groups &* 3 &+ Self.outputSlack)
    let decoded = Self.decodeRun(
      UnsafeRawPointer(input.baseAddress.unsafelyUnwrapped + start), groups: groups,
      into: UnsafeMutableRawPointer(header.pointee.base + header.pointee.count), tables
    )
    header.pointee.count &+= decoded &* 3
    return start &+ decoded &* 4
  }

  // Decodes up to `groups` whole groups, stopping at one that holds a character outside the
  // alphabet, and returns how many it decoded. `output` needs `outputSlack` bytes past the last
  // group's three.
  //
  // The vector tier takes whole blocks first; the scalar loop takes the groups left over, and finds
  // the group a rejected block stopped on. Per group it does one load for the four characters, one
  // table entry per character ORed into the three bytes (see `Base64.c`), one compare, and one
  // four-byte store whose fourth byte the next group overwrites. 1.6x a 256-byte sextet table with
  // shifts and three one-byte stores, on x86_64: see NEW_ARCHITECTURE.md, "`StreamBase64Data`".
  @inline(__always)
  private static func decodeRun(
    _ source: UnsafeRawPointer,
    groups: Int,
    into output: UnsafeMutableRawPointer,
    _ tables: UnsafePointer<UInt32>
  ) -> Int {
    let first = tables
    let second = tables + 256
    let third = tables + 512
    let fourth = tables + 768
    var group = Self.decodeBlocks(source, groups: groups, into: output)
    while group < groups {
      // Character i of the group in byte i.
      let characters = UInt32(
        littleEndian: source.loadUnaligned(fromByteOffset: group &* 4, as: UInt32.self)
      )
      let word =
        first[Int(characters & 0xFF)] | second[Int(characters >> 8 & 0xFF)]
        | third[Int(characters >> 16 & 0xFF)] | fourth[Int(characters >> 24)]
      guard word < 1 << 24 else { break }
      output.storeBytes(of: word.littleEndian, toByteOffset: group &* 3, as: UInt32.self)
      group &+= 1
    }
    return group
  }

  // The vector tier: Muła and Lemire's decoder, a block of groups at a time, until fewer than a
  // block remain or a block holds a character outside the alphabet. Returns how many groups it
  // decoded. `StreamParsingShims.h` and `AVX2.c` hold the kernels.
  @inline(__always)
  private static func decodeBlocks(
    _ source: UnsafeRawPointer,
    groups: Int,
    into output: UnsafeMutableRawPointer
  ) -> Int {
    #if arch(arm64)
      return stream_parsing_base64_decode_neon(source, groups, output)
    #elseif arch(x86_64)
      // Out of line, as every AVX2 kernel is, and called once per chunk of a string: the feature
      // check, a `swift_once` call and a load, is paid at that rate too. Short of one AVX2 block
      // (eight groups) the call is skipped.
      guard groups >= 8, streamHasAVX2 else { return 0 }
      return stream_parsing_base64_decode_avx2(source, groups, output)
    #else
      return 0
    #endif
  }

  // One character through the decoder, or false to reject the string. The fourth character's
  // table holds each sextet unmasked, `sextet << 16`.
  private mutating func take(_ character: UInt8, _ tables: UnsafePointer<UInt32>) -> Bool {
    let entry = tables[768 &+ Int(character)]
    switch self.phase {
    case .open where entry < 1 << 24:
      self.pendingBits = self.pendingBits << 6 | entry >> 16
      self.pendingCount &+= 1
      if self.pendingCount == 4 { self.emitPending(byteCount: 3) }
      return true
    // Padding fills out a group of two or three characters. As `Data(base64Encoded:)` does, the
    // bits the padding leaves over are dropped rather than required to be zero.
    case .open where character == UInt8(ascii: "=") && self.pendingCount == 3:
      self.pendingBits <<= 6
      self.emitPending(byteCount: 2)
      self.phase = .closed
      return true
    case .open where character == UInt8(ascii: "=") && self.pendingCount == 2:
      self.phase = .padding
      return true
    case .padding where character == UInt8(ascii: "="):
      self.pendingBits <<= 12
      self.emitPending(byteCount: 1)
      self.phase = .closed
      return true
    default:
      self.phase = .rejected
      return false
    }
  }

  // Appends the leading `byteCount` bytes of the 24 the four sextets in `pendingBits` make.
  private mutating func emitPending(byteCount: Int) {
    let header = self.reserve(byteCount)
    let output = header.pointee.base + header.pointee.count
    output[0] = UInt8(truncatingIfNeeded: self.pendingBits >> 16)
    if byteCount > 1 { output[1] = UInt8(truncatingIfNeeded: self.pendingBits >> 8) }
    if byteCount > 2 { output[2] = UInt8(truncatingIfNeeded: self.pendingBits) }
    header.pointee.count &+= byteCount
    self.pendingBits = 0
    self.pendingCount = 0
  }

  // Whether the decoded bytes are the whole value: no group is unfinished, and nothing was
  // rejected.
  private var isWhole: Bool {
    self.pendingCount == 0 && self.phase != .rejected
  }
}

// MARK: - The bytes

extension StreamBase64Data {
  /// The decoded bytes, without copying them: ``Bytes`` shares the value's storage.
  /// `Array(value.bytes)` copies them out, as, with the `Foundation` trait, does `data`.
  @inlinable
  public var bytes: Bytes {
    Bytes(storage: self.storage)
  }

  /// The decoded bytes of a ``StreamBase64Data``, as a random access collection over storage the
  /// value shares. Holding one keeps that storage as it was: the value's next append copies it.
  public struct Bytes: RandomAccessCollection {
    public typealias Element = UInt8

    @usableFromInline let storage: Storage?

    @usableFromInline
    init(storage: Storage?) {
      self.storage = storage
    }

    @inlinable
    public var startIndex: Int { 0 }

    @inlinable
    public var endIndex: Int { self.storage?.count ?? 0 }

    @inlinable
    public subscript(position: Int) -> UInt8 {
      precondition(position >= 0 && position < self.endIndex, "Index out of range")
      return self.storage.unsafelyUnwrapped.base[position]
    }

    /// Calls `body` with a pointer to the bytes, valid only for the duration of the call.
    @inlinable
    public func withUnsafeBufferPointer<R>(
      _ body: (UnsafeBufferPointer<UInt8>) throws -> R
    ) rethrows -> R {
      try body(UnsafeBufferPointer(start: self.storage?.base, count: self.endIndex))
    }

    /// Calls `body` with a pointer to the bytes, valid only for the duration of the call.
    @inlinable
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
      try self.withUnsafeBufferPointer { try body(UnsafeRawBufferPointer($0)) }
    }

    // What `Array(_:)` and `Data(_:)` look for: a copy becomes one `memcpy` rather than a loop over
    // the subscript.
    @inlinable
    public func withContiguousStorageIfAvailable<R>(
      _ body: (UnsafeBufferPointer<UInt8>) throws -> R
    ) rethrows -> R? {
      try self.withUnsafeBufferPointer(body)
    }
  }
}

// `@unchecked` because a `ManagedBuffer` subclass cannot be `Sendable`. The storage is written only
// while one value holds the only reference to it, so a copy sent elsewhere is never written under
// it, as with `StreamString`.
extension StreamBase64Data: @unchecked Sendable {}
extension StreamBase64Data.Bytes: @unchecked Sendable {}

// MARK: - Parsing conformances

extension StreamBase64Data: StreamStringConvertible {
  public static func streamInitialValue() -> Self { Self() }

  @discardableResult
  public mutating func streamAppend(utf8 bytes: Span<UInt8>) -> StreamApplyResult {
    // The opening quote's empty span, sent to settle acceptance: there is nothing to decode.
    guard !bytes.isEmpty else { return .applied }
    let accepted = bytes.withUnsafeBufferPointer { self.decode($0) }
    return accepted ? .applied : .conversionFailed
  }
}

extension StreamBase64Data: StreamPartial {}

extension StreamBase64Data: StreamParseable {
  public typealias Partial = Self

  /// Creates a value from a partial whose string ended on a whole group, or fails.
  ///
  /// Fails while characters of an unfinished group are waiting: the string either has more to
  /// come or ended without its padding.
  public init?(streamPartial: StreamBase64Data) {
    guard streamPartial.isWhole else { return nil }
    self.init()
    self.storage = streamPartial.storage
  }

  /// Creates a value from the bytes a partial has decoded, dropping any characters of an
  /// unfinished group.
  public init(orInitial partial: StreamBase64Data) {
    self.init()
    self.storage = partial.storage
  }
}

// MARK: - Value semantics

// The decoder's state is how the bytes arrived, not what they are: a value cut short and one
// built from the same bytes are the same data.
extension StreamBase64Data: Hashable {
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.storage === rhs.storage
      || lhs.bytes.withUnsafeBytes { lhs in
        rhs.bytes.withUnsafeBytes { rhs in lhs.elementsEqual(rhs) }
      }
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(self.bytes.count)
    self.bytes.withUnsafeBytes { hasher.combine(bytes: $0) }
  }
}

#if !hasFeature(Embedded)
  // Otherwise a reflecting printer dumps the decoder's state beside the bytes.
  extension StreamBase64Data: CustomReflectable {
    public var customMirror: Mirror {
      Mirror(self, children: ["bytes": Array(self.bytes)])
    }
  }

  // A single value, encoding as the padded base64 string it parses from. Decoding accepts what
  // parsing does. Outside the Embedded subset.
  extension StreamBase64Data: Encodable {
    public func encode(to encoder: any Encoder) throws {
      var container = encoder.singleValueContainer()
      try container.encode(self.base64EncodedString())
    }
  }

  extension StreamBase64Data: Decodable {
    public init(from decoder: any Decoder) throws {
      let container = try decoder.singleValueContainer()
      let text = Array(try container.decode(String.self).utf8)
      var value = Self()
      let accepted = text.withUnsafeBufferPointer { value.decode($0) }
      guard accepted, value.isWhole else {
        throw DecodingError.dataCorruptedError(
          in: container, debugDescription: "Expected a padded, standard base64 string."
        )
      }
      self.init()
      self.storage = value.storage
    }
  }

  extension StreamBase64Data {
    // The standard alphabet, padded: what parsing reads back.
    private func base64EncodedString() -> String {
      let alphabet = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8
      )
      let bytes = self.bytes
      var text = [UInt8]()
      text.reserveCapacity((bytes.count + 2) / 3 * 4)
      var index = 0
      while index < bytes.count {
        let remaining = bytes.count - index
        let word =
          UInt32(bytes[index]) << 16
          | (remaining > 1 ? UInt32(bytes[index + 1]) << 8 : 0)
          | (remaining > 2 ? UInt32(bytes[index + 2]) : 0)
        text.append(alphabet[Int(word >> 18 & 63)])
        text.append(alphabet[Int(word >> 12 & 63)])
        text.append(remaining > 1 ? alphabet[Int(word >> 6 & 63)] : UInt8(ascii: "="))
        text.append(remaining > 2 ? alphabet[Int(word & 63)] : UInt8(ascii: "="))
        index += 3
      }
      return String(decoding: text, as: UTF8.self)
    }
  }
#endif
