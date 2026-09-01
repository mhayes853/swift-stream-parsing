// Dictionary storage the parser can hold a pointer into, and that a snapshot can copy without
// copying the entries.
//
// `Dictionary` can rehash and relocate every value on insertion, so there is no address to write a
// nested value through byte by byte. Entries here live in append only storage, which inherits the
// invariant the array path relies on, and insertion order is preserved, which makes conversion to
// an ordered container lossless.
//
// Lookups go through a byte keyed slot table rather than a `[String: Int]`, which measured faster
// at every key count and on every axis: 12 to 17 ns per hit against 34 to 42, flat in key count,
// and no allocation on a lookup where a `Dictionary` materialises a `String` for one.
//
// Two things here were measured rather than assumed, and both went against the plan. Blocking the
// storage the way `StreamArray` does cost 2x on the discarding path, because a dictionary reads its
// storage back on every lookup where an array never reads at all. And a retained state's cost
// tracks the *number* of buffers it shares, not their size, so the key and its hash travel
// together and the table is one array rather than a heads and next pair.
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
  @usableFromInline var storedValues: [Value]

  // Open addressed slot table, -1 where empty, held at half load since linear probing degrades
  // sharply past that. Nil below the threshold, where a scan over `entries` measures the same and
  // costs no table at all.
  @usableFromInline var table: ContiguousArray<Int32>?

  // The entry being parsed, held inline for the same reason `StreamArray` holds its open element
  // there: the parser's frame points at a slot no other value can see, so a write through it is an
  // ordinary mutation rather than a raw write into a buffer a kept state is sharing.
  //
  // `pendingSlot` is -1 when no entry is open, an existing slot when the key repeats, which is what
  // keeps `{"a":1,"b":2,"a":3}` in its original order, and `storedValues.count` when it is new.
  // A new key is inserted into `entries` and the table immediately, so those can lead
  // `storedValues` by one while its value remains in the stable pending slot.
  @usableFromInline var pendingValue: Value?
  @usableFromInline var pendingSlot: Int32

  @usableFromInline static var indexThreshold: Int { 8 }

  public init() {
    self.entries = ContiguousArray<StreamDictionaryEntry>()
    self.storedValues = [Value]()
    self.table = nil
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

  // Writes the open entry into storage. Both paths are ordinary mutations, so a state that shares
  // the buffers copies them here rather than seeing them change.
  @inlinable
  mutating func drainPending() {
    guard self.pendingSlot >= 0 else { return }
    var taken = Value?.none
    swap(&taken, &self.pendingValue)
    let slot = Int(self.pendingSlot)
    self.pendingSlot = -1
    // The payload is moved out of the optional bitwise rather than unwrapped, for the same reason
    // `StreamArray.drainPending` does: `unsafelyUnwrapped` is a read accessor, so unwrapping copies
    // the value — a retain for every reference field and a matching release when `taken` is
    // destroyed, once per committed key. A single-payload enum keeps its payload at offset zero, so
    // `.some`'s bits are the value's bits; after the move the slot is re-marked nil so nothing is
    // destroyed twice. `pendingSlot >= 0` guarantees the case is `.some` — `_openValue` and
    // `updateValue` set both together.
    let value = withUnsafeMutablePointer(to: &taken) { box -> Value in
      let value = UnsafeMutableRawPointer(box).assumingMemoryBound(to: Value.self).move()
      box.initialize(to: nil)
      return value
    }
    if slot < self.storedValues.count {
      self.storedValues[slot] = value
    } else {
      self.storedValues.append(value)
    }
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
    guard self.table != nil else {
      if self.entries.count > Self.indexThreshold { self.rebuildTable() }
      return slot
    }
    guard self.entries.count * 2 <= self.table.unsafelyUnwrapped.count else {
      self.rebuildTable()
      return slot
    }
    if vacantBucket >= 0 {
      assert(self.table.unsafelyUnwrapped[vacantBucket] < 0)
      self.table![vacantBucket] = slot
      return slot
    }
    self.claim(slot: slot, hash: hash)
    return slot
  }

  // Takes the first free probe for a key already known to be absent, which is what lets it stop at
  // the first empty rather than comparing anything.
  @inlinable
  mutating func claim(slot: Int32, hash: UInt64) {
    let mask = self.table.unsafelyUnwrapped.count - 1
    var probe = Int(hash & UInt64(mask))
    while self.table.unsafelyUnwrapped[probe] >= 0 { probe = (probe &+ 1) & mask }
    self.table![probe] = slot
  }

  // Rebuilt from the entries' stored hashes, so growth hashes nothing and never looks at a key.
  @inlinable
  mutating func rebuildTable(minimumEntryCapacity: Int = 0) {
    var capacity = 16
    let entryCapacity = Swift.max(self.entries.count, minimumEntryCapacity)
    while capacity < entryCapacity * 2 { capacity &*= 2 }
    if let table = self.table, table.count >= capacity { return }
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
  // A fixed basis rather than a seeded `Hasher`, which is what keeps this inside the embedded
  // subset. Deliberately collided keys degrade the chain walk to the scan it replaces, since every
  // step compares a `UInt64` before it compares bytes, so the worst case is bounded by the measured
  // scan rather than being unbounded.
  //
  // The mix itself is `streamHashBytes`, which reads sixteen bytes per vector load into two
  // independent accumulators. It replaced FNV-1a, whose per byte multiply chain was the cost.
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

  // On an indexed miss, hands the empty bucket back so insertion does not walk the same probe
  // chain again. It remains unchanged for the small linear scan and every successful lookup.
  @inlinable
  func slot(
    forKey key: UnsafeBufferPointer<UInt8>,
    hash: UInt64,
    vacantBucket: inout Int
  ) -> Int32? {
    guard let table = self.table else {
      var slot = 0
      while slot < self.entries.count {
        if self.entries[slot].hash == hash, self.keyMatches(slot, key) {
          return Int32(slot)
        }
        slot &+= 1
      }
      return nil
    }
    let mask = table.count - 1
    var probe = Int(hash & UInt64(mask))
    while true {
      let slot = table[probe]
      guard slot >= 0 else {
        vacantBucket = probe
        return nil
      }
      let position = Int(slot)
      if self.entries[position].hash == hash, self.keyMatches(position, key) {
        return slot
      }
      probe = (probe &+ 1) & mask
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

  @inlinable
  func keyMatches(_ slot: Int, _ key: UnsafeBufferPointer<UInt8>) -> Bool {
    let stored = self.entries[slot].key
    let equal = stored.utf8.withContiguousStorageIfAvailable { storage in
      Self.bytesEqual(storage, key)
    }
    guard let equal else { return stored.utf8.elementsEqual(key) }
    return equal
  }

  // Sixteen bytes per compare through `streamBytesEqual`, which is what a resumed key and every
  // colliding probe walk.
  @inlinable
  static func bytesEqual(
    _ lhs: UnsafeBufferPointer<UInt8>,
    _ rhs: UnsafeBufferPointer<UInt8>
  ) -> Bool {
    guard lhs.count == rhs.count else { return false }
    guard let left = lhs.baseAddress, let right = rhs.baseAddress else { return true }
    return streamBytesEqual(UnsafeRawPointer(left), UnsafeRawPointer(right), count: lhs.count)
  }
}

// MARK: - View

extension StreamDictionary where Value: StreamParseableRoot {
  /// A borrowed window onto the dictionary, for reading a value by key without copying the
  /// dictionary or the value.
  ///
  /// Unlike ``StreamArray``, `storedValues` is not exposed as a bulk `Span`: a repeated key
  /// reuses its existing slot (see `pendingSlot`), so the position that slot occupies in
  /// `storedValues` can briefly hold a stale value while the live one sits in `pendingValue`,
  /// until the next `drainPending()`. A single `subscript(key:)` lookup routes around that by
  /// checking the pending entry first, the same way the non-view `subscript(key:)` does — a raw
  /// span over `storedValues` would not.
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
    /// single value read by key.
    @inlinable
    public var value: StreamDictionary<Value> { self.storage.pointee }

    /// A view onto the value stored under `key`, or `nil` when there is no such entry.
    public subscript(key: String) -> Value.View? {
      @_lifetime(borrow self)
      get {
        // Resolve the address of the live slot in fully escapable terms first, then form the
        // one `~Escapable` view at a single exit. Building a view per branch and returning it
        // from there is equivalent, but it leaves several `Optional<Value.View>` stack slots
        // for the optimizer to merge, which crashes PredictableDeadAllocationElimination on
        // Swift 6.3 (fixed in 6.4). Single-address, single-view keeps that shape from arising.
        let address: UnsafeMutableRawPointer?
        if self.storage.pointee.pendingEntryKey == key {
          address =
            self.storage.pointee.pendingValue == nil
            ? nil
            : withUnsafeMutablePointer(to: &self.storage.pointee.pendingValue) {
              UnsafeMutableRawPointer($0)
            }
        } else if let slot = self.storage.pointee.slot(forKey: key) {
          let base = self.storage.pointee.storedValues
            .withUnsafeBufferPointer { $0.baseAddress! }
          address = UnsafeMutableRawPointer(mutating: base + Int(slot))
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
  /// Commits the open entry and opens one for `key`, returning the address of its slot.
  ///
  /// A repeated key resumes from the value already stored under it rather than resetting, and never
  /// materialises a `String`, since the span is matched against the stored keys directly.
  /// Underscored because only the frame entry helpers call it.
  @inlinable
  public mutating func _openValue(
    forKey key: Span<UInt8>,
    initial: @autoclosure () -> Value
  ) -> UnsafeMutableRawPointer {
    self.drainPending()
    key.withUnsafeBufferPointer { buffer in
      let hash = Self.hash(buffer)
      var vacantBucket = -1
      if let existing = self.slot(
        forKey: buffer, hash: hash, vacantBucket: &vacantBucket
      ) {
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
  // Order sensitive, because the whole point of this type is that it has one. Element wise rather
  // than storage wise, since two dictionaries holding the same entries can differ in whether the
  // last one has been committed out of the pending slot yet.
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

extension StreamDictionary: CustomStringConvertible {
  public var description: String {
    "[" + self.map { "\($0.key): \($0.value)" }.joined(separator: ", ") + "]"
  }
}

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
  public static func _benchmarkHash(_ key: Span<UInt8>) -> UInt64 {
    key.withUnsafeBufferPointer { Self.hash($0) }
  }

  @_spi(Benchmarking)
  public func _benchmarkSlot(_ key: Span<UInt8>, hash: UInt64) -> Int32 {
    key.withUnsafeBufferPointer { self.slot(forKey: $0, hash: hash) ?? -1 }
  }

  @_spi(Benchmarking)
  public mutating func _benchmarkDrain() {
    self.drainPending()
  }

  @_spi(Benchmarking)
  public var _benchmarkStoredHashes: [UInt64] {
    self.entries.map(\.hash)
  }

}
