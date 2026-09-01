// The field table: what a schema knows about each member of an object, as data.
//
// A key used to be resolved by a generated `switch` and then applied by a second generated
// `switch` behind a stored closure -- two closure calls per scalar, each a context load, a retain,
// an indirect call and a release, plus the decode of a decision the key match had already made.
// Measured in isolation (`Sink synthetic int fields`), that was 21 ns and one retain/release pair
// per integer member on a route that allocates nothing.
//
// A table entry says the same thing once: this key, this kind of destination, at this byte
// offset. The sink matches the key against the table and, for every kind the library knows the
// layout of, writes the value with a typed store at `storage + offset`. Nothing is called. The
// closures survive only for `custom` (a conforming type the library cannot see into) and for
// entering a container, which is once per container rather than once per value.

// MARK: - StreamFieldKind

/// How a value arriving at a field is written.
public enum StreamFieldKind: UInt8, Sendable {
  /// A conforming type the library has no layout for. Applied through the schema's closures with
  /// the entry's `index`, exactly as every field used to be.
  case custom = 0
  case int
  case int8
  case int16
  case int32
  case int64
  case uint
  case uint8
  case uint16
  case uint32
  case uint64
  case double
  case float
  case bool
  /// `StreamString`, appended in place; `capacity` is the reservation to make at the opening
  /// quote when the member carries one.
  case streamString
  /// `StreamInlineString<N>`: an `Int32` count and then exactly `capacity` bytes.
  case inlineString
  /// An object, array, dictionary or fixed-width vector. Entered from the entry itself when it
  /// carries the child's `schema` -- the frame is the member's address and that schema, after
  /// the entry's `prepare` (if any) has materialised an optional or reserved a capacity -- and
  /// through the schema's `enterField` closure with the entry's `index` when it does not. A scalar
  /// arriving here is a type mismatch.
  case container

  @inlinable
  public var isNumber: Bool {
    self.rawValue >= StreamFieldKind.int.rawValue && self.rawValue <= StreamFieldKind.float.rawValue
  }
}

// MARK: - StreamField

/// What runs over a container member's storage before a frame is pushed over it: materialising
/// an optional, reserving a declared capacity. `nil` for a member that needs neither. The second
/// argument is the entry's `capacity`, passed in so the closure need not capture it.
public typealias StreamFieldPrepare = @Sendable (UnsafeMutableRawPointer, Int32) -> Void

/// One member of an object schema, as declared. The schema packs these into the forty-byte
/// entries the sink matches against (`StreamFieldEntry`); this form keeps the key and the strong
/// references those entries only point at.
public struct StreamField: Sendable {
  /// The key's first eight bytes, little-endian, zero padded.
  public var keyWord: UInt64
  public var keyLength: UInt16
  public var kind: StreamFieldKind
  public var flags: Flags
  /// Byte offset of the member inside the object's storage.
  public var offset: UInt32
  /// The field identifier the schema's closures take, for `custom` and `container` entries. A
  /// property with several key names has one entry per name, all carrying the same index.
  public var index: Int32
  /// Kind-specific: an inline string's byte capacity, a string member's reservation hint.
  public var capacity: Int32
  /// Where the whole key starts in the schema's key byte blob; read only for keys longer than a
  /// word.
  @usableFromInline var keyStart: UInt32

  public struct Flags: OptionSet, Sendable {
    public var rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    /// The member is `Optional`; a write must materialise it and a null clears it.
    @inlinable public static var optional: Flags { Flags(rawValue: 1) }
    /// The entry has a `prepare` closure to run before a frame is pushed over the member.
    @inlinable public static var prepare: Flags { Flags(rawValue: 2) }
  }

  /// The key as declared, kept until the schema packs every entry's key into one blob.
  @usableFromInline var key: [UInt8]

  /// For a `container` member, the schema the frame over it carries: the hoisted static the
  /// enclosing `Partial` owns. The entry keeps an unowned copy; this is the reference that keeps
  /// the declaration form honest about what it points at.
  public var schema: StreamSchema?

  /// See ``StreamFieldPrepare``. Only a `container` member has one.
  public var prepare: StreamFieldPrepare?

  public init(
    key: String,
    index: Int32,
    kind: StreamFieldKind,
    optional: Bool,
    offset: Int,
    capacity: Int = 0
  ) {
    let bytes = Array(key.utf8)
    precondition(bytes.count <= Int(UInt16.max), "stream field key exceeds 65535 bytes")
    precondition(offset >= 0 && offset <= Int(UInt32.max), "stream field offset out of range")
    precondition(capacity <= Int(Int32.max), "stream field capacity exceeds Int32")
    self.key = bytes
    self.keyWord = bytes.withUnsafeBufferPointer { buffer in
      guard let base = buffer.baseAddress, !buffer.isEmpty else { return 0 }
      return streamPaddedWord(base: UnsafeRawPointer(base), from: 0, to: buffer.count)
    }
    self.keyLength = UInt16(bytes.count)
    self.kind = kind
    self.flags = optional ? .optional : []
    self.offset = UInt32(offset)
    self.index = index
    self.capacity = Int32(capacity)
    self.keyStart = 0
    self.schema = nil
    self.prepare = nil
  }

  @inlinable public var isOptional: Bool { self.flags.contains(.optional) }

  /// The form the macro emits: the route the member's type resolved to, and the capacity hint the
  /// declaration carried, which a route with its own capacity (an inline string) overrides.
  public init(key: String, index: Int32, route: StreamFieldRoute, offset: Int, capacity: Int = 0) {
    self.init(
      key: key, index: index, kind: route.kind, optional: route.optional, offset: offset,
      capacity: route.capacity != 0 ? route.capacity : capacity
    )
    self.schema = route.schema
    self.prepare = route.prepare
  }
}

/// The packed form of a ``StreamField``: what the sink reads.
///
/// Forty bytes, laid out so the match reads the first sixteen -- the key's first word and its
/// length -- and touches the rest only on a hit. The child schema is its object address as raw
/// bits rather than a reference of any strength: the sink copies the bits into a frame, and
/// forming a reference on the way -- even `unowned(unsafe)` bound with `if let` -- is a retain
/// and a release per container open that the optimizer does not remove, because nothing owns the
/// value it could prove the lifetime against. The table owns every schema an entry names.
@usableFromInline
struct StreamFieldEntry {
  @usableFromInline var keyWord: UInt64
  @usableFromInline var keyLength: UInt16
  @usableFromInline var kind: StreamFieldKind
  @usableFromInline var flags: StreamField.Flags
  @usableFromInline var offset: UInt32
  @usableFromInline var index: Int32
  @usableFromInline var capacity: Int32
  @usableFromInline var keyStart: UInt32
  // Padding the layout already had; a later kind may claim it.
  @usableFromInline var reserved: UInt32
  @usableFromInline var schemaBits: UnsafeRawPointer?

  @inlinable public var isOptional: Bool { self.flags.contains(.optional) }
  /// Whether the entry has a `prepare` closure in the table's parallel array.
  @inlinable public var hasPrepare: Bool { self.flags.contains(.prepare) }

  @usableFromInline
  init(_ field: StreamField, keyStart: Int) {
    self.keyWord = field.keyWord
    self.keyLength = field.keyLength
    self.kind = field.kind
    self.flags = field.flags
    if field.prepare != nil { self.flags.insert(.prepare) }
    self.offset = field.offset
    self.index = field.index
    self.capacity = field.capacity
    self.keyStart = UInt32(keyStart)
    self.reserved = 0
    self.schemaBits = field.schema.map { UnsafeRawPointer(Unmanaged.passUnretained($0).toOpaque()) }
  }
}

/// The classification a field's declared type resolves to: the kind, and whether the member is
/// wrapped in an `Optional`. Produced by the overloads in `StreamParsing`, which see the member's
/// concrete type; the macro only sees its spelling.
public struct StreamFieldRoute: Sendable {
  public var kind: StreamFieldKind
  public var optional: Bool
  /// A capacity the kind itself dictates -- an inline string's, a string member's reservation --
  /// or zero.
  public var capacity: Int
  /// A container member's child schema. See ``StreamField/schema``.
  public var schema: StreamSchema?
  /// See ``StreamFieldPrepare``.
  public var prepare: StreamFieldPrepare?

  public init(
    _ kind: StreamFieldKind,
    optional: Bool,
    capacity: Int = 0,
    schema: StreamSchema? = nil,
    prepare: StreamFieldPrepare? = nil
  ) {
    self.kind = kind
    self.optional = optional
    self.capacity = capacity
    self.schema = schema
    self.prepare = prepare
  }
}

// MARK: - Kinds for the types the library knows

// Each is a chain of metatype compares on a type the caller has made concrete, so after
// specialisation it is one constant.

@inlinable
public func _streamNumberFieldKind<T: StreamNumberConvertible>(_ type: T.Type) -> StreamFieldKind {
  if T.self == Int.self { return .int }
  if T.self == Double.self { return .double }
  if T.self == Int64.self { return .int64 }
  if T.self == UInt64.self { return .uint64 }
  if T.self == UInt.self { return .uint }
  if T.self == Int32.self { return .int32 }
  if T.self == UInt32.self { return .uint32 }
  if T.self == Int16.self { return .int16 }
  if T.self == UInt16.self { return .uint16 }
  if T.self == Int8.self { return .int8 }
  if T.self == UInt8.self { return .uint8 }
  if T.self == Float.self { return .float }
  return .custom
}

@inlinable
public func _streamStringFieldRoute<T: StreamStringConvertible>(
  _ type: T.Type, optional: Bool
) -> StreamFieldRoute {
  if T.self == StreamString.self { return StreamFieldRoute(.streamString, optional: optional) }
  let inlineCapacity = T._streamInlineCapacity
  if inlineCapacity > 0 {
    // The same layout `_streamStringSchema` checks before it emits the erased route: an `Int32`
    // count and then exactly `capacity` bytes.
    precondition(
      T._streamInlineByteOffset == _streamInlineStringByteOffset
        && MemoryLayout<T>.size == T._streamInlineByteOffset + inlineCapacity,
      "inline string storage does not match the layout the parser appends through"
    )
    return StreamFieldRoute(.inlineString, optional: optional, capacity: inlineCapacity)
  }
  return StreamFieldRoute(.custom, optional: optional)
}

@inlinable
public func _streamBooleanFieldKind<T: StreamBooleanConvertible>(_ type: T.Type) -> StreamFieldKind {
  T.self == Bool.self ? .bool : .custom
}

// MARK: - The packed table

/// The entries of one object schema, in one allocation, with their keys packed behind them.
///
/// A class so the schema can hand the sink a pointer to the entries that outlives every frame the
/// schema outlives, which is what `BorrowedFrame` already requires of the schema itself.
@usableFromInline
final class StreamFieldTable: @unchecked Sendable {
  @usableFromInline let entries: UnsafeMutablePointer<StreamFieldEntry>
  @usableFromInline let count: Int
  @usableFromInline let keyBytes: UnsafeMutablePointer<UInt8>
  // Parallel to `entries`, indexed by entry. Off the entry itself so the match's stride stays
  // forty bytes; a container open reads its slot once, and only when the entry's flag says so.
  @usableFromInline let prepares: UnsafeMutablePointer<StreamFieldPrepare?>
  // The owners of every schema an entry points at unowned.
  @usableFromInline let schemas: [StreamSchema]

  // Open-addressed slot table over `entries`, -1 where empty, built once at construction since a
  // field table never grows (unlike `StreamDictionary`, whose entries arrive at parse time). `nil`
  // below `indexThreshold`: a scan over a handful of entries measures the same as a probe and
  // costs no table at all. Above it, a struct like a 40-field API object pays for a hash instead
  // of a scan whose length no longer fits in what the prefetcher hides.
  @usableFromInline let index: UnsafeMutablePointer<Int32>?
  @usableFromInline let indexMask: Int

  /// Field counts at or below this scan for free; the index only pays for itself past it.
  @usableFromInline static var indexThreshold: Int { 16 }

  @usableFromInline
  init(_ fields: [StreamField]) {
    self.count = fields.count
    self.entries = .allocate(capacity: Swift.max(fields.count, 1))
    self.prepares = .allocate(capacity: Swift.max(fields.count, 1))
    self.schemas = fields.compactMap(\.schema)
    if fields.count > Self.indexThreshold {
      // Half load, same as `StreamDictionary`'s table: linear probing degrades sharply past it.
      var capacity = 16
      while capacity < fields.count &* 2 { capacity <<= 1 }
      let table = UnsafeMutablePointer<Int32>.allocate(capacity: capacity)
      table.initialize(repeating: -1, count: capacity)
      let mask = capacity - 1
      for (entryIndex, field) in fields.enumerated() {
        let hash = streamFieldHash(word: field.keyWord, length: field.keyLength)
        var probe = Int(truncatingIfNeeded: hash) & mask
        while table[probe] >= 0 { probe = (probe &+ 1) & mask }
        table[probe] = Int32(entryIndex)
      }
      self.index = table
      self.indexMask = mask
    } else {
      self.index = nil
      self.indexMask = 0
    }

    let keyByteCount = fields.reduce(0) { $0 + $1.key.count }
    self.keyBytes = .allocate(capacity: Swift.max(keyByteCount, 1))
    var keyStart = 0
    for (index, field) in fields.enumerated() {
      field.key.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return }
        (self.keyBytes + keyStart).update(from: base, count: buffer.count)
      }
      (self.entries + index).initialize(to: StreamFieldEntry(field, keyStart: keyStart))
      (self.prepares + index).initialize(to: field.prepare)
      keyStart &+= field.key.count
    }
  }

  deinit {
    self.entries.deinitialize(count: self.count)
    self.entries.deallocate()
    self.prepares.deinitialize(count: self.count)
    self.prepares.deallocate()
    self.keyBytes.deallocate()
    self.index?.deallocate()
  }

}

/// The entry index for `key` in a table, or -1.
///
/// A linear scan over the first word and the length. Objects declare a handful of members, so
/// the scan is a few compares against forty-byte strides the prefetcher already has; the
/// generated `switch` it replaces was the same compares as a chain. Keys longer than a word
/// verify their tail against the packed key bytes on a first-word hit. Takes the raw views
/// rather than the table object so nothing is retained on the way in.
@inlinable
@inline(__always)
func streamMatchField(
  _ entries: UnsafePointer<StreamFieldEntry>,
  count: Int,
  keyBytes: UnsafePointer<UInt8>,
  _ key: Span<UInt8>
) -> Int32 {
  let length = key.count
  guard length <= Int(UInt16.max) else { return -1 }
  let word = key.paddedLeadingWord()
  let keyLength = UInt16(truncatingIfNeeded: length)
  var index = 0
  while index < count {
    let entry = entries + index
    if entry.pointee.keyWord == word && entry.pointee.keyLength == keyLength {
      if length <= 8 || streamFieldTailMatches(entry, keyBytes: keyBytes, key) {
        return Int32(truncatingIfNeeded: index)
      }
    }
    index &+= 1
  }
  return -1
}

/// Murmur3's `fmix64`: two multiplies and three xor-shifts, chosen because the input is already a
/// dense 64-bit word (the key's leading bytes) rather than a byte stream -- there is nothing here
/// for a wider mix to fold in, only avalanche to add so nearby keys don't cluster in the table.
@inlinable
@inline(__always)
func streamFieldHash(word: UInt64, length: UInt16) -> UInt64 {
  var z = word ^ (UInt64(length) &<< 56)
  z = (z ^ (z >> 33)) &* 0xff51afd7ed558ccd
  z = (z ^ (z >> 33)) &* 0xc4ceb9fe1a85ec53
  z = z ^ (z >> 33)
  return z
}

/// The entry index for `key` in an indexed table, or -1. Same match as ``streamMatchField(_:count:keyBytes:_:)``
/// once a candidate is found; the difference is how the candidate is found; a probe rather than a
/// walk.
@inlinable
@inline(__always)
func streamMatchFieldIndexed(
  _ entries: UnsafePointer<StreamFieldEntry>,
  index: UnsafePointer<Int32>,
  mask: Int,
  keyBytes: UnsafePointer<UInt8>,
  _ key: Span<UInt8>
) -> Int32 {
  let length = key.count
  guard length <= Int(UInt16.max) else { return -1 }
  let word = key.paddedLeadingWord()
  let keyLength = UInt16(truncatingIfNeeded: length)
  let hash = streamFieldHash(word: word, length: keyLength)
  var probe = Int(truncatingIfNeeded: hash) & mask
  while true {
    let slot = index[probe]
    guard slot >= 0 else { return -1 }
    let entry = entries + Int(slot)
    if entry.pointee.keyWord == word && entry.pointee.keyLength == keyLength {
      if length <= 8 || streamFieldTailMatches(entry, keyBytes: keyBytes, key) {
        return slot
      }
    }
    probe = (probe &+ 1) & mask
  }
}

@usableFromInline
@inline(never)
func streamFieldTailMatches(
  _ entry: UnsafePointer<StreamFieldEntry>, keyBytes: UnsafePointer<UInt8>, _ key: Span<UInt8>
) -> Bool {
  key.withUnsafeBufferPointer { buffer in
    let stored = UnsafeRawPointer(keyBytes + Int(entry.pointee.keyStart) + 8)
    let given = UnsafeRawPointer(buffer.baseAddress.unsafelyUnwrapped + 8)
    return streamFieldKeyBytesEqual(stored, given, count: buffer.count &- 8)
  }
}

@usableFromInline
@inline(__always)
func streamFieldKeyBytesEqual(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer, count: Int) -> Bool {
  var offset = 0
  while offset &+ 8 <= count {
    if a.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
      != b.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
    {
      return false
    }
    offset &+= 8
  }
  while offset < count {
    if a.load(fromByteOffset: offset, as: UInt8.self) != b.load(fromByteOffset: offset, as: UInt8.self) {
      return false
    }
    offset &+= 1
  }
  return true
}

// MARK: - Offsets

/// The byte offset of `member` inside the value at `base`.
///
/// Pointer arithmetic rather than `MemoryLayout.offset(of:)`, because a key path does not compile
/// under Embedded Swift. `member` is a stored property reached through `base.pointee`, so the
/// address the inout binding yields is the property's own; `StreamFieldTableTests` pins the two
/// against each other where key paths are available.
@inlinable
@inline(__always)
public func _streamFieldOffset<Root, Member>(
  _ member: inout Member,
  in base: UnsafeMutablePointer<Root>
) -> Int {
  withUnsafeMutablePointer(to: &member) { pointer in
    UnsafeRawPointer(pointer) - UnsafeRawPointer(base)
  }
}

/// Runs `build` over a prototype instance so the field offsets can be taken from live storage.
@inlinable
public func _streamFields<Root>(
  of type: Root.Type,
  prototype: Root,
  _ build: (UnsafeMutablePointer<Root>) -> [StreamField]
) -> [StreamField] {
  var prototype = prototype
  return withUnsafeMutablePointer(to: &prototype) { build($0) }
}
