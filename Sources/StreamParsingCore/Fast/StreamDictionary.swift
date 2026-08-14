// Dictionary storage the parser can hold a pointer into.
//
// Dictionary can rehash and relocate every value on insertion, so there is no address to write
// a nested value through byte by byte. Values here live in an append-only array, which inherits
// the same invariant the array path relies on: the buffer can only move on the next append, and
// that cannot happen while the current value is the innermost open container.
//
// Insertion order is preserved, which Dictionary cannot offer, and which makes conversion to an
// ordered container lossless.
public struct StreamDictionary<Value> {
  @usableFromInline var storedKeys: [String]
  @usableFromInline var storedValues: [Value]

  // The entry being parsed, held inline for the same reason `StreamArray` holds its open element
  // there: the parser's frame points at a slot no other value can see, so a write through it is an
  // ordinary mutation rather than a raw write into a buffer a kept state is sharing. Without it,
  // every state handed out while an object streams aliases the one being written.
  //
  // `pendingSlot` is where the entry belongs: an existing slot when the key repeats, which is what
  // keeps `{"a":1,"b":2,"a":3}` in its original order, or `storedValues.count` when it is new.
  @usableFromInline var pendingKey: String?
  @usableFromInline var pendingValue: Value?
  @usableFromInline var pendingSlot: Int

  // Built only once linear scanning stops paying. Streamed objects usually carry a handful of
  // dynamic keys, where a scan beats hashing: a Dictionary lookup measured at 9 to 10 ns
  // against 1.3 ns for a comparison based match.
  @usableFromInline var index: [String: Int]?

  @usableFromInline static var indexThreshold: Int { 8 }

  public init() {
    self.storedKeys = []
    self.storedValues = []
    self.pendingKey = nil
    self.pendingValue = nil
    self.pendingSlot = 0
  }

  public init(_ elements: some Sequence<(key: String, value: Value)>) {
    self.init()
    for element in elements { self.updateValue(element.value, forKey: element.key) }
  }

  public init(_ dictionary: [String: Value]) {
    self.init()
    for key in dictionary.keys.sorted() { self.updateValue(dictionary[key]!, forKey: key) }
  }

  // The pending entry only adds to the count when its key is a new one; a repeat shadows the slot
  // it already occupies.
  @usableFromInline var hasPendingAppend: Bool {
    self.pendingKey != nil && self.pendingSlot == self.storedValues.count
  }

  public var count: Int { self.storedValues.count + (self.hasPendingAppend ? 1 : 0) }
  public var isEmpty: Bool { self.count == 0 }

  public var keys: [String] { self.map(\.key) }
  public var values: [Value] { self.map(\.value) }

  public subscript(key: String) -> Value? {
    get {
      if let pendingKey, pendingKey == key { return self.pendingValue }
      guard let slot = self.slot(forKey: key) else { return nil }
      return self.storedValues[slot]
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
      let previous = self.storedValues[slot]
      self.storedValues[slot] = value
      return previous
    }
    self.append(value, forKey: key)
    return nil
  }

  // Writes the open entry into storage. Both paths are ordinary mutations, so a state that shares
  // the buffers copies them here rather than seeing them change.
  @usableFromInline
  mutating func drainPending() {
    guard self.pendingKey != nil else { return }
    var key = String?.none
    var value = Value?.none
    swap(&key, &self.pendingKey)
    swap(&value, &self.pendingValue)
    if self.pendingSlot < self.storedValues.count {
      self.storedValues[self.pendingSlot] = value.unsafelyUnwrapped
    } else {
      self.append(value.unsafelyUnwrapped, forKey: key.unsafelyUnwrapped)
    }
  }

  @usableFromInline
  mutating func append(_ value: Value, forKey key: String) {
    self.storedKeys.append(key)
    self.storedValues.append(value)
    if self.index != nil {
      self.index![key] = self.storedValues.count - 1
    } else if self.storedValues.count > Self.indexThreshold {
      self.buildIndex()
    }
  }

  @usableFromInline
  func slot(forKey key: String) -> Int? {
    if let index { return index[key] }
    for slot in self.storedKeys.indices where self.storedKeys[slot] == key { return slot }
    return nil
  }

  @usableFromInline
  mutating func buildIndex() {
    var built = [String: Int](minimumCapacity: self.storedKeys.count * 2)
    for slot in self.storedKeys.indices { built[self.storedKeys[slot]] = slot }
    self.index = built
  }
}

// MARK: - Parsing support

extension StreamDictionary {
  /// Commits the open entry and opens one for `key`, returning the address of its slot.
  ///
  /// A repeated key resumes from the value already stored under it rather than resetting, which is
  /// what the slot based version did. Underscored because only the frame entry helpers call it.
  @inlinable
  public mutating func _openValue(
    forKey key: Span<UInt8>,
    initial: @autoclosure () -> Value
  ) -> UnsafeMutableRawPointer {
    var text = ""
    key.withUnsafeBufferPointer { text = String(decoding: $0, as: UTF8.self) }
    self.drainPending()
    if let existing = self.slot(forKey: text) {
      self.pendingSlot = existing
      self.pendingValue = self.storedValues[existing]
    } else {
      self.pendingSlot = self.storedValues.count
      self.pendingValue = initial()
    }
    self.pendingKey = text
    return withUnsafeMutablePointer(to: &self.pendingValue) { UnsafeMutableRawPointer($0) }
  }
}

// MARK: - Collection

extension StreamDictionary: Sequence, Collection {
  public typealias Element = (key: String, value: Value)

  public var startIndex: Int { 0 }
  public var endIndex: Int { self.count }
  public func index(after i: Int) -> Int { i + 1 }

  public subscript(position: Int) -> Element {
    if let pendingKey, position == self.pendingSlot {
      return (key: pendingKey, value: self.pendingValue.unsafelyUnwrapped)
    }
    return (key: self.storedKeys[position], value: self.storedValues[position])
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
