// Dictionary storage the parser can hold a pointer into, and that a snapshot can copy without
// copying the entries. `Dictionary` rehashes and relocates on insertion, so it offers no address to
// write a nested value through; entries here are append only and insertion ordered, and lookups go
// through a byte keyed slot table rather than a `[String: Int]`.
// Measured: blocking the *entry* storage the way `StreamArray` blocks elements cost 2x on the
// discarding path, and key-with-hash in one array beat a heads/next pair; keep both forms.
@usableFromInline
struct StreamDictionaryEntry: Hashable, Sendable {
  @usableFromInline var hash: UInt64
  @usableFromInline var key: String

  @usableFromInline
  init(hash: UInt64, key: String) {
    self.hash = hash
    self.key = key
  }
}

public struct StreamDictionary<Value> {
  // The key and the hash that guards it, kept in one buffer so a probe reads one cache line and a
  // retained state copies one thing.
  @usableFromInline var entries: ContiguousArray<StreamDictionaryEntry>
  // Blocked like an array's elements and for the same reason: a snapshot shares the blocks instead
  // of copying them, and the open value is the array's own inline `pending` slot, so a repeated key
  // resumes in the slot it already has. Measured: a flat `[Value]` copied the whole value array per
  // byte on a snapshot-per-byte parse, -58% on the dictionary snapshot rows.
  @usableFromInline var storedValues: StreamArray<Value>

  // Open addressed slot table, -1 where empty, held at half load since linear probing degrades
  // sharply past that. Empty below `indexThreshold`, where a scan over `entries` measures the same,
  // rather than `nil`: an `Optional<ContiguousArray>` cannot be handed to a borrowing probe without
  // unwrapping, and every unwrap is a retain that makes the buffer non-unique for the next write.
  @usableFromInline var table: ContiguousArray<Int32>

  // The entry being parsed, held inline so the parser's frame points at a slot no other value can
  // see. It cannot borrow the values array's open element, because a repeated key's open value is
  // an element the array already holds and a kept state can see. `pendingSlot` is -1 when nothing
  // is open, an existing slot when the key repeats, and `storedValues.count` when it is new.
  @usableFromInline var pendingValue: Value?
  @usableFromInline var pendingSlot: Int32

  @usableFromInline static var indexThreshold: Int { 8 }

  public init() {
    self.entries = ContiguousArray<StreamDictionaryEntry>()
    self.storedValues = StreamArray<Value>()
    self.table = []
    self.pendingValue = nil
    self.pendingSlot = -1
  }

  /// Creates an empty streaming dictionary with storage reserved for at least the expected number
  /// of unique keys. Small dictionaries retain the table-free linear scan representation.
  public init(initialCapacity: Int) {
    self.init()
    self.reserveCapacity(initialCapacity)
  }

  public init(_ elements: some Sequence<(key: String, value: Value)>) {
    self.init()
    for element in elements { self.updateValue(element.value, forKey: element.key) }
  }

  public init(_ dictionary: [String: Value]) {
    self.init()
    for key in dictionary.keys.sorted() { self.updateValue(dictionary[key]!, forKey: key) }
  }

  @usableFromInline
  var pendingEntryKey: String? {
    guard self.pendingSlot >= 0 else { return nil }
    return self.entries[Int(self.pendingSlot)].key
  }

  public var count: Int { self.entries.count }
  public var isEmpty: Bool { self.count == 0 }

  public var keys: [String] { self.map(\.key) }
  public var values: [Value] { self.map(\.value) }

  /// Reserves storage for at least the expected total number of unique keys.
  public mutating func reserveCapacity(_ minimumCapacity: Int) {
    precondition(minimumCapacity >= 0, "StreamDictionary capacity must not be negative")
    self.entries.reserveCapacity(minimumCapacity)
    self.storedValues.reserveCapacity(minimumCapacity)
    if minimumCapacity > Self.indexThreshold {
      self.rebuildTable(minimumEntryCapacity: minimumCapacity)
    }
  }

  /// The value stored under `key`, or `nil` when there is none.
  ///
  /// - Important: Assigning `nil` is a no-op. The storage is append only -- entries, their keys
  ///   and their values are three parallel runs indexed by slot, and nothing in the type can take
  ///   an entry out of the middle of them -- so there is no removal to perform. Use the
  ///   non-optional ``updateValue(_:forKey:)`` when a write must be total.
  public subscript(key: String) -> Value? {
    get {
      if let pendingEntryKey, pendingEntryKey == key { return self.pendingValue }
      guard let slot = self.slot(forKey: key) else { return nil }
      return self.storedValues[Int(slot)]
    }
    set {
      guard let newValue else { return }
      self.updateValue(newValue, forKey: key)
    }
  }

  @discardableResult
  public mutating func updateValue(_ value: Value, forKey key: String) -> Value? {
    self.drainPending()
    if let slot = self.slot(forKey: key) {
      let previous = self.storedValues[Int(slot)]
      self.storedValues[Int(slot)] = value
      return previous
    }
    self.append(value, forKey: key, hash: Self.hash(key))
    return nil
  }

  // Writes the open entry into storage: an appended value moves into the slot it will live in, a
  // repeated key's value is assigned into the element it already occupies, that block made unique
  // first. Both happen inside this call, so no state can be taken between the uniqueness check and
  // the write -- the whole reason the open value is held here.
  @inlinable
  mutating func drainPending() {
    guard self.pendingSlot >= 0 else { return }
    let slot = Int(self.pendingSlot)
    self.pendingSlot = -1
    let isAppend = slot >= self.storedValues.closedCount
    // Resolved before the payload is projected: both of these mutate `storedValues`.
    let destination =
      isAppend
      ? self.storedValues._slotForAppend()
      : self.storedValues._uniqueSlotAddress(slot)
    withUnsafeMutablePointer(to: &self.pendingValue) { box in
      // The payload is moved out of the optional bitwise rather than unwrapped: `unsafelyUnwrapped` is
      // a read accessor, so it copies -- a retain per reference field and a release when the optional
      // dies, once per key. A single-payload enum keeps its payload at offset zero, so `.some`'s bits
      // are the value's; the slot is re-marked nil after, so nothing is destroyed twice.
      let payload = UnsafeMutableRawPointer(box).assumingMemoryBound(to: Value.self)
      let typed = destination.assumingMemoryBound(to: Value.self)
      if isAppend {
        typed.moveInitialize(from: payload, count: 1)
      } else {
        typed.pointee = payload.move()
      }
      box.initialize(to: nil)
    }
    if isAppend { self.storedValues._commitAppend() }
  }

  @inlinable
  mutating func append(_ value: Value, forKey key: String, hash: UInt64) {
    self.appendEntry(forKey: key, hash: hash)
    self.storedValues.append(value)
  }

  @discardableResult
  @inlinable
  mutating func appendEntry(
    forKey key: String,
    hash: UInt64,
    vacantBucket: Int = -1
  ) -> Int32 {
    let slot = Int32(self.entries.count)
    self.entries.append(StreamDictionaryEntry(hash: hash, key: key))
    guard !self.table.isEmpty else {
      if self.entries.count > Self.indexThreshold { self.rebuildTable() }
      return slot
    }
    guard self.entries.count * 2 <= self.table.count else {
      self.rebuildTable()
      return slot
    }
    if vacantBucket >= 0 {
      // Positional promise: `vacantBucket` was found by the caller's own probe, so it is only
      // valid while the table has not changed since. It holds because the entry above is appended
      // before the load factor test and every arm that can rebuild the table has already returned.
      assert(self.table[vacantBucket] < 0)
      self.table[vacantBucket] = slot
      return slot
    }
    self.claim(slot: slot, hash: hash)
    return slot
  }

  // Takes the first free probe for a key already known to be absent, which is what lets it stop at
  // the first empty rather than comparing anything.
  @inlinable
  mutating func claim(slot: Int32, hash: UInt64) {
    let mask = self.table.count - 1
    var probe = Int(hash & UInt64(mask))
    while self.table[probe] >= 0 { probe = (probe &+ 1) & mask }
    self.table[probe] = slot
  }

  // Rebuilt from the entries' stored hashes, so growth hashes nothing and never looks at a key.
  @inlinable
  mutating func rebuildTable(minimumEntryCapacity: Int = 0) {
    var capacity = 16
    let entryCapacity = Swift.max(self.entries.count, minimumEntryCapacity)
    while capacity < entryCapacity * 2 { capacity &*= 2 }
    if self.table.count >= capacity { return }
    var built = ContiguousArray<Int32>(repeating: -1, count: capacity)
    let mask = capacity - 1
    var slot = 0
    while slot < self.entries.count {
      var probe = Int(self.entries[slot].hash & UInt64(mask))
      while built[probe] >= 0 { probe = (probe &+ 1) & mask }
      built[probe] = Int32(slot)
      slot &+= 1
    }
    self.table = built
  }
}

// MARK: - Lookup

extension StreamDictionary {
  // A fixed basis rather than a seeded `Hasher`, which is what keeps this inside the Embedded
  // subset. Deliberately collided keys degrade to the scan the table replaces, since every step
  // compares a `UInt64` before it compares bytes, so the worst case stays bounded. `streamHashBytes`
  // replaced FNV-1a, whose per byte multiply chain was the cost.
  @inlinable
  static func hash(_ key: UnsafeBufferPointer<UInt8>) -> UInt64 {
    guard let base = key.baseAddress else { return streamHashBytes(base: emptyKeyAddress, count: 0) }
    return streamHashBytes(base: UnsafeRawPointer(base), count: key.count)
  }

  @usableFromInline
  static func hash(_ key: String) -> UInt64 {
    var key = key
    return key.withUTF8 { Self.hash($0) }
  }

  // On an indexed miss, hands the empty bucket back so insertion does not walk the same probe chain
  // again. Forced inline, which is worth more than the code it costs: this is a *non-mutating*
  // method called from inside `_openValue`'s `inout self`, and `Self` is loadable but large.
  // Measured: out of line the caller stages the whole struct, `memcpy(sp, self, 2164)` per key.
  @inlinable
  @inline(__always)
  static func slot(
    entries: UnsafeBufferPointer<StreamDictionaryEntry>,
    table: UnsafeBufferPointer<Int32>,
    forKey key: UnsafeBufferPointer<UInt8>,
    hash: UInt64,
    vacantBucket: inout Int
  ) -> Int32? {
    // Tested on the counts, not the base addresses: an empty `ContiguousArray` still yields a
    // non-nil base (the empty singleton's first element address), so a `baseAddress == nil` test
    // sends an unindexed dictionary down the table path with `mask == -1`.
    guard let base = entries.baseAddress, !entries.isEmpty else { return nil }
    guard !table.isEmpty else {
      var slot = 0
      while slot < entries.count {
        if base[slot].hash == hash, _streamEntryKeyMatches(base + slot, key) {
          return Int32(slot)
        }
        slot &+= 1
      }
      return nil
    }
    let index = table.baseAddress.unsafelyUnwrapped
    let mask = table.count - 1
    var probe = Int(hash & UInt64(mask))
    while true {
      let slot = index[probe]
      guard slot >= 0 else {
        vacantBucket = probe
        return nil
      }
      let position = Int(slot)
      if base[position].hash == hash, _streamEntryKeyMatches(base + position, key) {
        return slot
      }
      probe = (probe &+ 1) & mask
    }
  }

  // The instance spelling, for the callers that are not on the parse path.
  @inlinable
  func slot(
    forKey key: UnsafeBufferPointer<UInt8>,
    hash: UInt64,
    vacantBucket: inout Int
  ) -> Int32? {
    self.entries.withUnsafeBufferPointer { entries in
      self.table.withUnsafeBufferPointer { table in
        Self.slot(
          entries: entries, table: table, forKey: key, hash: hash, vacantBucket: &vacantBucket
        )
      }
    }
  }

  @inlinable
  func slot(forKey key: UnsafeBufferPointer<UInt8>, hash: UInt64) -> Int32? {
    var vacantBucket = -1
    return self.slot(forKey: key, hash: hash, vacantBucket: &vacantBucket)
  }

  @usableFromInline
  func slot(forKey key: String) -> Int32? {
    var key = key
    return key.withUTF8 { buffer in self.slot(forKey: buffer, hash: Self.hash(buffer)) }
  }

}

// MARK: - View

extension StreamDictionary where Value: StreamParseableRoot {
  /// A borrowed window onto the dictionary, for reading a value by key without copying the
  /// dictionary or the value.
  ///
  /// Unlike ``StreamArray``, `storedValues` is not exposed as a bulk `Span`: a repeated key reuses
  /// its existing slot (see `pendingSlot`), so that position can briefly hold a stale value while
  /// the live one sits in `pendingValue`. `subscript(key:)` routes around that by checking the
  /// pending entry first; a raw span would not.
  public struct View: ~Copyable, ~Escapable {
    @usableFromInline let storage: UnsafeMutablePointer<StreamDictionary<Value>>

    @_lifetime(borrow storage)
    @usableFromInline
    init(_ storage: UnsafeMutableRawPointer) {
      self.storage = storage.assumingMemoryBound(to: StreamDictionary<Value>.self)
    }

    /// The number of entries.
    @inlinable
    public var count: Int { self.storage.pointee.count }

    /// A copy of the whole dictionary, for callers that want an escaping snapshot rather than a
    /// single value read by key. The blocks are retained, not copied; the open value is copied,
    /// which is what makes the copy stable while parsing continues.
    @inlinable
    public var value: StreamDictionary<Value> { self.storage.pointee }

    /// A view onto the value stored under `key`, or `nil` when there is no such entry.
    public subscript(key: String) -> Value.View? {
      @_lifetime(borrow self)
      get {
        // Resolve the address of the live slot in fully escapable terms first, then form the one
        // `~Escapable` view at a single exit. A view per branch is equivalent but leaves several
        // `Optional<Value.View>` stack slots for the optimizer to merge, which crashes
        // PredictableDeadAllocationElimination on Swift 6.3 (fixed in 6.4).
        let address: UnsafeMutableRawPointer?
        if self.storage.pointee.pendingEntryKey == key {
          address =
            self.storage.pointee.pendingValue == nil
            ? nil
            : withUnsafeMutablePointer(to: &self.storage.pointee.pendingValue) {
              UnsafeMutableRawPointer($0)
            }
        } else if let slot = self.storage.pointee.slot(forKey: key) {
          address = self.storage.pointee.storedValues._elementAddress(Int(slot))
        } else {
          address = nil
        }
        guard let address else { return nil }
        return _overrideLifetime(Value.streamView(address), borrowing: self)
      }
    }
  }

  @_lifetime(borrow storage)
  public static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
    View(storage)
  }
}

// MARK: - Parsing support

extension StreamDictionary {
  /// Opens the entry for `key`, returning the address of its value slot, copy-initialised from
  /// `template` -- already the `.some` the slot must end up holding -- when the key is new. A
  /// repeated key resumes from the value stored under it rather than resetting, never materialises
  /// a `String`, and only the frame entry helpers call it.
  ///
  /// Three shapes are measured: do not fuse `drainPending()` into the open (-32%, and the same rule
  /// puts the projections below on mutually exclusive returns); do not fold the two overloads into
  /// one helper (loses every `Value` specialisation, GSoC -20%); keep the template `Value?`, not `Value`.
  @inlinable
  public mutating func _openValue(
    forKey key: Span<UInt8>,
    copyingSome template: UnsafePointer<Value?>
  ) -> UnsafeMutableRawPointer {
    self.drainPending()
    // `pendingSlot < 0` and `pendingValue == nil` are the same state; `drainPending()` has just
    // established it, and the copy-initialise below depends on it.
    assert(self.pendingValue == nil)
    var isNew = false
    key.withUnsafeBufferPointer { buffer in
      let hash = Self.hash(buffer)
      var vacantBucket = -1
      // Probed through the two buffers rather than through `self`: see `slot(entries:table:...)`.
      let existing = self.entries.withUnsafeBufferPointer { entries in
        self.table.withUnsafeBufferPointer { table in
          Self.slot(
            entries: entries, table: table, forKey: buffer, hash: hash, vacantBucket: &vacantBucket
          )
        }
      }
      if let existing {
        self.pendingSlot = existing
        self.pendingValue = self.storedValues[Int(existing)]
      } else {
        self.pendingSlot = self.appendEntry(
          forKey: String(decoding: buffer, as: UTF8.self),
          hash: hash,
          vacantBucket: vacantBucket
        )
        isNew = true
      }
    }
    guard isNew else {
      return withUnsafeMutablePointer(to: &self.pendingValue) { UnsafeMutableRawPointer($0) }
    }
    return withUnsafeMutablePointer(to: &self.pendingValue) { box in
      _streamCopyInitialize(box, from: template)
      return UnsafeMutableRawPointer(box)
    }
  }

  /// The same, for a value passed in by value: the scalar kinds the sink opens directly.
  @inlinable
  public mutating func _openValue(
    forKey key: Span<UInt8>,
    initial: @autoclosure () -> Value
  ) -> UnsafeMutableRawPointer {
    self.drainPending()
    key.withUnsafeBufferPointer { buffer in
      let hash = Self.hash(buffer)
      var vacantBucket = -1
      if let existing = self.slot(forKey: buffer, hash: hash, vacantBucket: &vacantBucket) {
        self.pendingSlot = existing
        self.pendingValue = self.storedValues[Int(existing)]
      } else {
        self.pendingSlot = self.appendEntry(
          forKey: String(decoding: buffer, as: UTF8.self),
          hash: hash,
          vacantBucket: vacantBucket
        )
        self.pendingValue = initial()
      }
    }
    return withUnsafeMutablePointer(to: &self.pendingValue) { UnsafeMutableRawPointer($0) }
  }
}

// MARK: - Collection

extension StreamDictionary: Sequence, Collection {
  public typealias Element = (key: String, value: Value)

  public var startIndex: Int { 0 }
  public var endIndex: Int { self.count }
  public func index(after position: Int) -> Int { position + 1 }

  public subscript(position: Int) -> Element {
    if self.pendingSlot >= 0, position == Int(self.pendingSlot) {
      return (
        key: self.pendingEntryKey.unsafelyUnwrapped,
        value: self.pendingValue.unsafelyUnwrapped
      )
    }
    return (key: self.entries[position].key, value: self.storedValues[position])
  }
}

extension StreamDictionary: Equatable where Value: Equatable {
  // Order sensitive, because the whole point of this type is that it has one.
  public static func == (lhs: Self, rhs: Self) -> Bool {
    guard lhs.count == rhs.count else { return false }
    for position in lhs.startIndex..<lhs.endIndex where lhs[position] != rhs[position] {
      return false
    }
    return true
  }
}

// Checked rather than `@unchecked`: every stored property is a value type, which is what dropping
// `Dictionary` for the flat index preserved.
extension StreamDictionary: Sendable where Value: Sendable {}

#if !hasFeature(Embedded)
  // Interpolating an unconstrained `Value` is `String(describing:)`, i.e. reflection, which is
  // outside the embedded subset.
  extension StreamDictionary: CustomStringConvertible {
    public var description: String {
      "[" + self.map { "\($0.key): \($0.value)" }.joined(separator: ", ") + "]"
    }
  }
#endif

extension StreamDictionary: ExpressibleByDictionaryLiteral {
  public init(dictionaryLiteral elements: (String, Value)...) {
    self.init()
    for (key, value) in elements { self.updateValue(value, forKey: key) }
  }
}

// MARK: - Bridging

extension Dictionary where Key == String {
  public init(_ streamDictionary: StreamDictionary<Value>) {
    self.init(minimumCapacity: streamDictionary.count)
    for element in streamDictionary { self[element.key] = element.value }
  }
}

extension StreamDictionary: StreamInitializable {
  public static func streamInitialValue() -> Self { Self() }
}

extension StreamDictionary: StreamParseable where Value: StreamParseableRoot {
  public typealias Partial = Self

  public var streamPartialValue: Self { self }
}

// Compares a stored entry's key against a key span, reached through the entry's address so that
// nothing copies the `ContiguousArray` the entry lives in. Sixteen bytes per compare through
// `streamBytesEqual`, which is what a resumed key and every colliding probe walk.
@usableFromInline
@inline(__always)
func _streamEntryKeyMatches(
  _ entry: UnsafePointer<StreamDictionaryEntry>,
  _ key: UnsafeBufferPointer<UInt8>
) -> Bool {
  let equal = entry.pointee.key.utf8.withContiguousStorageIfAvailable { storage in
    storage.count == key.count
      && (storage.baseAddress == nil || key.baseAddress == nil
        || streamBytesEqual(
          UnsafeRawPointer(storage.baseAddress.unsafelyUnwrapped),
          UnsafeRawPointer(key.baseAddress.unsafelyUnwrapped),
          count: storage.count
        ))
  }
  guard let equal else { return _streamForeignKeyMatches(entry.pointee.key, key) }
  return equal
}

// A stored key with no contiguous UTF-8 -- a bridged or otherwise foreign `String`. Out of line
// and at file scope so `slot(forKey:hash:vacantBucket:)`, which is force-inlined into
// `_openValue`, does not carry `Sequence.elementsEqual`'s generic body into every caller.
@inline(never)
@usableFromInline
func _streamForeignKeyMatches(_ stored: String, _ key: UnsafeBufferPointer<UInt8>) -> Bool {
  stored.utf8.elementsEqual(key)
}

// An empty buffer has no base address, and hashing zero bytes never reads one; this gives the
// hash a non-null address to be handed rather than a branch inside it.
@usableFromInline
nonisolated(unsafe) let emptyKeyAddress = UnsafeRawPointer(bitPattern: 0x1000).unsafelyUnwrapped

// MARK: - Breakdown hooks (temporary)

// Underscored shims so the benchmark package, which is a separate package and cannot see
// `package` or `@usableFromInline` symbols, can time the pieces of `_openValue` against the whole.
// Remove with the measurement they support.
extension StreamDictionary {
  @_spi(Benchmarking)
  public var _benchmarkStoredHashes: [UInt64] {
    self.entries.map(\.hash)
  }

}
