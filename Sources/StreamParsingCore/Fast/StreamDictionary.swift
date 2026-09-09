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
  // Blocked, like an array's elements, and for the same reason: the parser writes the open value
  // in place, a snapshot shares the blocks, and the first write after a snapshot copies one
  // block rather than every value. A flat `[Value]` here made a snapshot-per-byte parse copy the
  // whole value array per byte (-58% on the dictionary snapshot rows).
  @usableFromInline var storedValues: StreamArray<Value>

  // Open addressed slot table, -1 where empty, held at half load since linear probing degrades
  // sharply past that. Nil below the threshold, where a scan over `entries` measures the same and
  // costs no table at all.
  @usableFromInline var table: ContiguousArray<Int32>?

  // The slot of the entry being parsed, or -1. The value itself lives in `storedValues` and is
  // written there in place, the same way `StreamArray` writes its open element in its block: a
  // repeated key resumes in the slot it already has, which is what keeps `{"a":1,"b":2,"a":3}` in
  // its original order. Kept only so `_reopenValue()` can find the slot again after a snapshot
  // has shared `storedValues` -- see `PartialSink.reseat()`.
  @usableFromInline var pendingSlot: Int32

  @usableFromInline static var indexThreshold: Int { 8 }

  public init() {
    self.entries = ContiguousArray<StreamDictionaryEntry>()
    self.storedValues = StreamArray<Value>()
    self.table = nil
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
    if let slot = self.slot(forKey: key) {
      let previous = self.storedValues[Int(slot)]
      self.storedValues[Int(slot)] = value
      return previous
    }
    self.append(value, forKey: key, hash: Self.hash(key))
    return nil
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
  /// reuses its existing slot (see `pendingSlot`), so entry order and value order are the same
  /// thing here, and a single `subscript(key:)` lookup is the shape the type is built around.
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
    /// single value read by key. The copy is recorded, so the parser knows to stop writing into
    /// blocks this copy now holds (see `_streamValueCopied`).
    @inlinable
    public var value: StreamDictionary<Value> {
      _streamValueCopied()
      return self.storage.pointee
    }

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
        if let slot = self.storage.pointee.slot(forKey: key) {
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
  /// Opens the entry for `key`, returning the address of its value slot.
  ///
  /// A repeated key resumes from the value already stored under it rather than resetting, and never
  /// materialises a `String`, since the span is matched against the stored keys directly. A new
  /// key's value is copy-initialised from `template` in place: one `initializeWithCopy` into the
  /// slot it will live in, with no temporary (see `StreamArray._openElement(copying:)`).
  /// Underscored because only the frame entry helpers call it.
  @inlinable
  public mutating func _openValue(
    forKey key: Span<UInt8>,
    copying template: UnsafePointer<Value>
  ) -> UnsafeMutableRawPointer {
    self.openSlot(forKey: key) { $0._openElement(copying: template) }
  }

  /// The same, for a value passed in by value: the scalar kinds the sink opens directly.
  @inlinable
  public mutating func _openValue(
    forKey key: Span<UInt8>,
    initial: @autoclosure () -> Value
  ) -> UnsafeMutableRawPointer {
    self.openSlot(forKey: key) { $0._openElement(initial()) }
  }

  // Resolves the slot and hands back its address: a new key's value is appended in place through
  // `appendNew` (the values' tail is unique by the same contract as an array's -- see
  // `StreamArray.nextSlot`); a repeated key's value is written where it is, with its block made
  // unique first, since a snapshot may hold it.
  @inlinable
  mutating func openSlot(
    forKey key: Span<UInt8>,
    appendNew: (inout StreamArray<Value>) -> UnsafeMutableRawPointer
  ) -> UnsafeMutableRawPointer {
    let (slot, address) = key.withUnsafeBufferPointer { buffer -> (Int32, UnsafeMutableRawPointer) in
      let hash = Self.hash(buffer)
      var vacantBucket = -1
      if let existing = self.slot(forKey: buffer, hash: hash, vacantBucket: &vacantBucket) {
        return (existing, self.storedValues._uniqueSlotAddress(Int(existing)))
      }
      let slot = self.appendEntry(
        forKey: String(decoding: buffer, as: UTF8.self),
        hash: hash,
        vacantBucket: vacantBucket
      )
      return (slot, appendNew(&self.storedValues))
    }
    self.pendingSlot = slot
    return address
  }

  /// Makes the values safe to write into; called by the sink when it enters the dictionary.
  /// See `StreamArray._prepareForWrites()`.
  @inlinable
  public mutating func _prepareForWrites() {
    self.storedValues._prepareForWrites()
  }

  /// The address of the open value, safe to write into, or nil when no entry is open. For
  /// ``PartialSink/reseat()``: the open value is normally the last one, and re-pointing it after
  /// a snapshot costs that one value (see `StreamArray._reopenElement()`); a repeated key's value
  /// sits elsewhere and its block is copied instead.
  @inlinable
  public mutating func _reopenValue() -> UnsafeMutableRawPointer? {
    guard self.pendingSlot >= 0 else {
      self.storedValues._prepareForWrites()
      return nil
    }
    let slot = Int(self.pendingSlot)
    if slot == self.storedValues.count &- 1 { return self.storedValues._reopenElement() }
    return self.storedValues._uniqueSlotAddress(slot)
  }
}

// MARK: - Collection

extension StreamDictionary: Sequence, Collection {
  public typealias Element = (key: String, value: Value)

  public var startIndex: Int { 0 }
  public var endIndex: Int { self.count }
  public func index(after position: Int) -> Int { position + 1 }

  public subscript(position: Int) -> Element {
    (key: self.entries[position].key, value: self.storedValues[position])
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
  public var _benchmarkStoredHashes: [UInt64] {
    self.entries.map(\.hash)
  }

}
