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

  // Built only once linear scanning stops paying. Streamed objects usually carry a handful of
  // dynamic keys, where a scan beats hashing: a Dictionary lookup measured at 9 to 10 ns
  // against 1.3 ns for a comparison based match.
  @usableFromInline var index: [String: Int]?

  @usableFromInline static var indexThreshold: Int { 8 }

  public init() {
    self.storedKeys = []
    self.storedValues = []
  }

  public init(_ elements: some Sequence<(key: String, value: Value)>) {
    self.init()
    for element in elements { self.updateValue(element.value, forKey: element.key) }
  }

  public init(_ dictionary: [String: Value]) {
    self.init()
    for key in dictionary.keys.sorted() { self.updateValue(dictionary[key]!, forKey: key) }
  }

  public var count: Int { self.storedValues.count }
  public var isEmpty: Bool { self.storedValues.isEmpty }

  public var keys: [String] { self.storedKeys }
  public var values: [Value] { self.storedValues }

  public subscript(key: String) -> Value? {
    get {
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
    if let slot = self.slot(forKey: key) {
      let previous = self.storedValues[slot]
      self.storedValues[slot] = value
      return previous
    }
    self.append(value, forKey: key)
    return nil
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
  // Returns the slot for a key, appending one when the key is new. Underscored because only
  // macro generated code has a reason to call it.
  @inlinable
  public mutating func _slot(
    forKey key: Span<UInt8>,
    initial: @autoclosure () -> Value
  ) -> Int {
    var text = ""
    key.withUnsafeBufferPointer { text = String(decoding: $0, as: UTF8.self) }
    if let existing = self.slot(forKey: text) { return existing }
    self.append(initial(), forKey: text)
    return self.storedValues.count - 1
  }

  @inlinable
  public mutating func _withValueStorage<R>(
    at slot: Int,
    _ body: (UnsafeMutableRawPointer) -> R
  ) -> R {
    self.storedValues.withUnsafeMutableBufferPointer {
      body(UnsafeMutableRawPointer($0.baseAddress! + slot))
    }
  }
}

// MARK: - Collection

extension StreamDictionary: Sequence, Collection {
  public typealias Element = (key: String, value: Value)

  public var startIndex: Int { 0 }
  public var endIndex: Int { self.storedValues.count }
  public func index(after i: Int) -> Int { i + 1 }

  public subscript(position: Int) -> Element {
    (key: self.storedKeys[position], value: self.storedValues[position])
  }
}

extension StreamDictionary: Equatable where Value: Equatable {
  // Order sensitive, because the whole point of this type is that it has one.
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.storedKeys == rhs.storedKeys && lhs.storedValues == rhs.storedValues
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
