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
  /// An object, array, dictionary or fixed-width vector: entered through `enterField` with the
  /// entry's `index`. A scalar arriving here is a type mismatch.
  case container

  @inlinable
  public var isNumber: Bool {
    self.rawValue >= StreamFieldKind.int.rawValue && self.rawValue <= StreamFieldKind.float.rawValue
  }
}

// MARK: - StreamField

/// One member of an object schema, as the sink sees it.
///
/// Forty bytes, laid out so the match reads the first sixteen -- the key's first word and its
/// length -- and touches the rest only on a hit.
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
  }

  /// The key as declared, kept until the schema packs every entry's key into one blob.
  @usableFromInline var key: [UInt8]

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
  }

  @inlinable public var isOptional: Bool { self.flags.contains(.optional) }

  /// The form the macro emits: the route the member's type resolved to, and the capacity hint the
  /// declaration carried, which a route with its own capacity (an inline string) overrides.
  public init(key: String, index: Int32, route: StreamFieldRoute, offset: Int, capacity: Int = 0) {
    self.init(
      key: key, index: index, kind: route.kind, optional: route.optional, offset: offset,
      capacity: route.capacity != 0 ? route.capacity : capacity
    )
  }
}

/// The classification a field's declared type resolves to: the kind, and whether the member is
/// wrapped in an `Optional`. Produced by the overloads in `StreamParsing`, which see the member's
/// concrete type; the macro only sees its spelling.
public struct StreamFieldRoute: Sendable {
  public var kind: StreamFieldKind
  public var optional: Bool
  /// A capacity the kind itself dictates -- an inline string's -- or zero.
  public var capacity: Int

  public init(_ kind: StreamFieldKind, optional: Bool, capacity: Int = 0) {
    self.kind = kind
    self.optional = optional
    self.capacity = capacity
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
  @usableFromInline let entries: UnsafeMutablePointer<StreamField>
  @usableFromInline let count: Int
  @usableFromInline let keyBytes: UnsafeMutablePointer<UInt8>

  @usableFromInline
  init(_ fields: [StreamField]) {
    self.count = fields.count
    self.entries = .allocate(capacity: Swift.max(fields.count, 1))
    let keyByteCount = fields.reduce(0) { $0 + $1.key.count }
    self.keyBytes = .allocate(capacity: Swift.max(keyByteCount, 1))
    var keyStart = 0
    for (index, field) in fields.enumerated() {
      var entry = field
      entry.keyStart = UInt32(keyStart)
      field.key.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return }
        (self.keyBytes + keyStart).update(from: base, count: buffer.count)
      }
      keyStart &+= field.key.count
      (self.entries + index).initialize(to: entry)
    }
  }

  deinit {
    self.entries.deinitialize(count: self.count)
    self.entries.deallocate()
    self.keyBytes.deallocate()
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
  _ entries: UnsafePointer<StreamField>,
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

@usableFromInline
@inline(never)
func streamFieldTailMatches(
  _ entry: UnsafePointer<StreamField>, keyBytes: UnsafePointer<UInt8>, _ key: Span<UInt8>
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
