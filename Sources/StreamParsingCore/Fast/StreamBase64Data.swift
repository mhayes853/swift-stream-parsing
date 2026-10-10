import StreamParsingShims

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
/// let png = attachment.contents.bytes
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
public struct StreamBase64Data: Sendable {
  // Every stored property takes its declared default and `init()` assigns nothing, so opening a
  // member is a run of stores: see NEW_ARCHITECTURE.md, "The initialiser trap".

  /// The decoded bytes.
  public private(set) var bytes: [UInt8] = []

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
    self.bytes = Array(bytes)
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

    // Room for every group and the slack, reserved geometrically: a value fed in small chunks
    // grows by doubling, not by the chunk. An empty value gets exactly that.
    let needed = self.bytes.count &+ groups &* 3 &+ Self.outputSlack
    if self.bytes.capacity < needed {
      self.bytes.reserveCapacity(Swift.max(needed, self.bytes.capacity &* 2))
    }
    let before = self.bytes.count
    self.bytes.append(
      contentsOf: DecodedGroups(
        source: UnsafeRawPointer(input.baseAddress.unsafelyUnwrapped + start),
        groups: groups,
        tables: tables
      )
    )
    return start &+ (self.bytes.count &- before) / 3 &* 4
  }

  // Whole groups, decoded straight into the spare capacity `Array.append(contentsOf:)` hands
  // `_copyContents`: nothing staged, nothing copied. How many decode is unknown until a group is
  // rejected, so `underestimatedCount` stays zero and the append reserves nothing itself;
  // `decodeGroups` has. Only ever appended: iterating it yields nothing.
  private struct DecodedGroups: Sequence {
    let source: UnsafeRawPointer
    let groups: Int
    let tables: UnsafePointer<UInt32>

    func makeIterator() -> EmptyCollection<UInt8>.Iterator {
      EmptyCollection.Iterator()
    }

    __consuming func _copyContents(
      initializing buffer: UnsafeMutableBufferPointer<UInt8>
    ) -> (EmptyCollection<UInt8>.Iterator, Int) {
      // The reserve leaves room for every group; were it short, the groups that fit decode and
      // the character-at-a-time path takes the rest.
      let fit = Swift.max(0, (buffer.count &- StreamBase64Data.outputSlack) / 3)
      guard let output = buffer.baseAddress, fit > 0 else { return (EmptyCollection.Iterator(), 0) }
      let decoded = StreamBase64Data.decodeRun(
        self.source, groups: Swift.min(self.groups, fit), into: UnsafeMutableRawPointer(output),
        self.tables
      )
      return (EmptyCollection.Iterator(), decoded &* 3)
    }
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
    self.bytes.append(UInt8(truncatingIfNeeded: self.pendingBits >> 16))
    if byteCount > 1 { self.bytes.append(UInt8(truncatingIfNeeded: self.pendingBits >> 8)) }
    if byteCount > 2 { self.bytes.append(UInt8(truncatingIfNeeded: self.pendingBits)) }
    self.pendingBits = 0
    self.pendingCount = 0
  }

  // Whether the decoded bytes are the whole value: no group is unfinished, and nothing was
  // rejected.
  private var isWhole: Bool {
    self.pendingCount == 0 && self.phase != .rejected
  }
}

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
    self.bytes = streamPartial.bytes
  }

  /// Creates a value from the bytes a partial has decoded, dropping any characters of an
  /// unfinished group.
  public init(orInitial partial: StreamBase64Data) {
    self.init()
    self.bytes = partial.bytes
  }
}

// MARK: - Value semantics

// The decoder's state is how the bytes arrived, not what they are: a value cut short and one
// built from the same bytes are the same data.
extension StreamBase64Data: Hashable {
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.bytes == rhs.bytes
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(self.bytes)
  }
}

#if !hasFeature(Embedded)
  // Otherwise a reflecting printer dumps the decoder's state beside the bytes.
  extension StreamBase64Data: CustomReflectable {
    public var customMirror: Mirror {
      Mirror(self, children: ["bytes": self.bytes])
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
      self.bytes = value.bytes
    }
  }

  extension StreamBase64Data {
    // The standard alphabet, padded: what parsing reads back.
    private func base64EncodedString() -> String {
      let alphabet = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8
      )
      var text = [UInt8]()
      text.reserveCapacity((self.bytes.count + 2) / 3 * 4)
      var index = 0
      while index < self.bytes.count {
        let remaining = self.bytes.count - index
        let word =
          UInt32(self.bytes[index]) << 16
          | (remaining > 1 ? UInt32(self.bytes[index + 1]) << 8 : 0)
          | (remaining > 2 ? UInt32(self.bytes[index + 2]) : 0)
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
