import Benchmark
import Foundation
import StreamParsing
import StreamParsingCore

// What the index buys.
//
// The parser-facing `StreamDictionary` uses an open-addressed table past eight entries. These
// measurements keep the old chained flat-array prototype as a comparison, but also measure the
// shipped type itself so the table benchmark cannot drift away from production code.
//
// The honest baseline is a scan that never materialises a `String`, since that is the shape the
// hot path wants anyway. Measuring against today's materialising scan charges the scan for an
// allocation the fix deletes.
//
// Two key sets, because a prefilter's worth depends entirely on the keys. `prefixed` keys all
// share their first eight bytes, which is the worst case for a leading word and the case a counts
// style payload actually produces; `diverse` keys differ from the first byte, which is what an
// object's field names look like. Absent keys are generated in the same shape and length as
// present ones, so a miss is not measured against a key that a length check rejects for free.

// MARK: - Comparison

@inline(__always)
private func matches(_ text: String, _ key: UnsafeBufferPointer<UInt8>) -> Bool {
  let equal = text.utf8.withContiguousStorageIfAvailable { stored -> Bool in
    stored.count == key.count
      && (stored.count == 0 || memcmp(stored.baseAddress!, key.baseAddress!, stored.count) == 0)
  }
  return equal ?? text.utf8.elementsEqual(key)
}

@inline(__always)
private func leadingWord(_ key: UnsafeBufferPointer<UInt8>) -> UInt64 {
  var word = UInt64(0)
  for offset in 0..<min(key.count, 8) {
    word |= UInt64(key[offset]) &<< UInt64(offset &* 8)
  }
  return word
}

@inline(__always)
private func fnv1a(_ key: UnsafeBufferPointer<UInt8>) -> UInt64 {
  var hash = UInt64(0xcbf2_9ce4_8422_2325)
  for byte in key {
    hash ^= UInt64(byte)
    hash &*= 0x100_0000_01b3
  }
  return hash
}

@inline(__always)
private func bucket(_ hash: UInt64, count: Int) -> Int {
  Int(hash & UInt64(count - 1))
}

// MARK: - Strategies

private protocol KeyTable {
  init()
  mutating func insert(_ key: UnsafeBufferPointer<UInt8>, value: Int)
  func lookup(_ key: UnsafeBufferPointer<UInt8>) -> Int?
}

// Today's shape: decode the span, then compare String to String.
private struct MaterializingScan: KeyTable {
  private var keys = [String]()
  private var values = [Int]()

  init() {}

  mutating func insert(_ key: UnsafeBufferPointer<UInt8>, value: Int) {
    let text = String(decoding: key, as: UTF8.self)
    if let slot = self.slot(forText: text) {
      self.values[slot] = value
      return
    }
    self.keys.append(text)
    self.values.append(value)
  }

  func lookup(_ key: UnsafeBufferPointer<UInt8>) -> Int? {
    self.slot(forText: String(decoding: key, as: UTF8.self)).map { self.values[$0] }
  }

  private func slot(forText text: String) -> Int? {
    for slot in self.keys.indices where self.keys[slot] == text { return slot }
    return nil
  }
}

// The span compared against the stored keys directly, with no String built for a key already
// present.
private struct SpanScan: KeyTable {
  private var keys = [String]()
  private var values = [Int]()

  init() {}

  mutating func insert(_ key: UnsafeBufferPointer<UInt8>, value: Int) {
    if let slot = self.slot(forKey: key) {
      self.values[slot] = value
      return
    }
    self.keys.append(String(decoding: key, as: UTF8.self))
    self.values.append(value)
  }

  func lookup(_ key: UnsafeBufferPointer<UInt8>) -> Int? {
    self.slot(forKey: key).map { self.values[$0] }
  }

  private func slot(forKey key: UnsafeBufferPointer<UInt8>) -> Int? {
    for slot in self.keys.indices where matches(self.keys[slot], key) { return slot }
    return nil
  }
}

// The same scan with the padded leading word the schema layer already computes for static keys, so
// a mismatch costs one comparison rather than a walk over the bytes.
private struct WordScan: KeyTable {
  private var keys = [String]()
  private var words = [UInt64]()
  private var lengths = [Int32]()
  private var values = [Int]()

  init() {}

  mutating func insert(_ key: UnsafeBufferPointer<UInt8>, value: Int) {
    let word = leadingWord(key)
    if let slot = self.slot(forKey: key, word: word) {
      self.values[slot] = value
      return
    }
    self.keys.append(String(decoding: key, as: UTF8.self))
    self.words.append(word)
    self.lengths.append(Int32(key.count))
    self.values.append(value)
  }

  func lookup(_ key: UnsafeBufferPointer<UInt8>) -> Int? {
    self.slot(forKey: key, word: leadingWord(key)).map { self.values[$0] }
  }

  private func slot(forKey key: UnsafeBufferPointer<UInt8>, word: UInt64) -> Int? {
    let length = Int32(key.count)
    for slot in self.words.indices {
      guard self.words[slot] == word, self.lengths[slot] == length else { continue }
      // Eight bytes or fewer are settled by the word and the length; only longer keys need the
      // tail compared.
      guard key.count <= 8 || matches(self.keys[slot], key) else { continue }
      return slot
    }
    return nil
  }
}

// The scan with a whole key hash as the prefilter rather than a leading word, which costs a walk
// over the key once per lookup and is not fooled by a shared prefix.
private struct HashScan: KeyTable {
  private var keys = [String]()
  private var hashes = [UInt64]()
  private var values = [Int]()

  init() {}

  mutating func insert(_ key: UnsafeBufferPointer<UInt8>, value: Int) {
    let hash = fnv1a(key)
    if let slot = self.slot(forKey: key, hash: hash) {
      self.values[slot] = value
      return
    }
    self.keys.append(String(decoding: key, as: UTF8.self))
    self.hashes.append(hash)
    self.values.append(value)
  }

  func lookup(_ key: UnsafeBufferPointer<UInt8>) -> Int? {
    self.slot(forKey: key, hash: fnv1a(key)).map { self.values[$0] }
  }

  private func slot(forKey key: UnsafeBufferPointer<UInt8>, hash: UInt64) -> Int? {
    for slot in self.hashes.indices {
      guard self.hashes[slot] == hash, matches(self.keys[slot], key) else { continue }
      return slot
    }
    return nil
  }
}

// Today's index.
private struct DictionaryIndex: KeyTable {
  private var keys = [String]()
  private var values = [Int]()
  private var index = [String: Int]()

  init() {}

  mutating func insert(_ key: UnsafeBufferPointer<UInt8>, value: Int) {
    let text = String(decoding: key, as: UTF8.self)
    if let slot = self.index[text] {
      self.values[slot] = value
      return
    }
    self.index[text] = self.keys.count
    self.keys.append(text)
    self.values.append(value)
  }

  func lookup(_ key: UnsafeBufferPointer<UInt8>) -> Int? {
    self.index[String(decoding: key, as: UTF8.self)].map { self.values[$0] }
  }
}

// A byte keyed hash over chains held in flat parallel arrays. This was the prototype considered
// for the parser; it remains useful as a comparison, but is not the shipped implementation.
private struct BucketIndex: KeyTable {
  private var keys = [String]()
  private var hashes = [UInt64]()
  private var values = [Int]()
  private var heads: [Int32]
  private var next = [Int32]()

  init() {
    self.heads = [Int32](repeating: -1, count: 8)
  }

  mutating func insert(_ key: UnsafeBufferPointer<UInt8>, value: Int) {
    let hash = fnv1a(key)
    if let slot = self.slot(forKey: key, hash: hash) {
      self.values[slot] = value
      return
    }
    let slot = self.keys.count
    self.keys.append(String(decoding: key, as: UTF8.self))
    self.hashes.append(hash)
    self.values.append(value)
    let head = bucket(hash, count: self.heads.count)
    self.next.append(self.heads[head])
    self.heads[head] = Int32(slot)
    if self.keys.count > self.heads.count * 2 { self.grow() }
  }

  func lookup(_ key: UnsafeBufferPointer<UInt8>) -> Int? {
    self.slot(forKey: key, hash: fnv1a(key)).map { self.values[$0] }
  }

  private func slot(forKey key: UnsafeBufferPointer<UInt8>, hash: UInt64) -> Int? {
    var slot = self.heads[bucket(hash, count: self.heads.count)]
    while slot >= 0 {
      let position = Int(slot)
      if self.hashes[position] == hash, matches(self.keys[position], key) { return position }
      slot = self.next[position]
    }
    return nil
  }

  private mutating func grow() {
    self.heads = [Int32](repeating: -1, count: self.heads.count * 2)
    for slot in self.hashes.indices {
      let head = bucket(self.hashes[slot], count: self.heads.count)
      self.next[slot] = self.heads[head]
      self.heads[head] = Int32(slot)
    }
  }
}

// The implementation used by the parser. This uses the public String lookup because the
// parser-facing span route is measured by the end-to-end Dictionary benchmarks. Keeping this
// benchmark on the real type still covers its storage, threshold, probing, and rehash behavior.
private struct StreamDictionaryIndex: KeyTable {
  private var dictionary: StreamDictionary<Int>

  init() {
    self.dictionary = StreamDictionary<Int>()
  }

  mutating func insert(_ key: UnsafeBufferPointer<UInt8>, value: Int) {
    self.dictionary.updateValue(value, forKey: String(decoding: key, as: UTF8.self))
  }

  func lookup(_ key: UnsafeBufferPointer<UInt8>) -> Int? {
    self.dictionary[String(decoding: key, as: UTF8.self)]
  }
}

// MARK: - Benchmarks

// Allocated once at registration and never freed, so no sample pays for the setup. The process
// exits when the run does.
private func keyPointers(_ keys: [[UInt8]]) -> [UnsafeBufferPointer<UInt8>] {
  keys.map { key in
    let copy = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: key.count)
    _ = copy.initialize(fromContentsOf: key)
    return UnsafeBufferPointer(copy)
  }
}

private func buildTable<Table: KeyTable>(
  _ type: Table.Type,
  keys: [UnsafeBufferPointer<UInt8>]
) -> Table {
  var table = Table()
  for (value, key) in keys.enumerated() { table.insert(key, value: value) }
  return table
}

private func registerKeyTable<Table: KeyTable>(
  _ type: Table.Type,
  named name: String,
  configuration: Benchmark.Configuration
) {
  for shape in KeyShape.allCases {
    for count in Payloads.keyCounts {
      let present = keyPointers(shape.keys(count))
      let absent = keyPointers(shape.absentKeys(count))
      let built = buildTable(Table.self, keys: present)

      Benchmark(
        "Keys \(shape.label) \(name) - build \(count)", configuration: configuration
      ) { benchmark in
        for _ in benchmark.scaledIterations {
          blackHole(buildTable(Table.self, keys: present))
        }
      }

      Benchmark(
        "Keys \(shape.label) \(name) - hit \(count)", configuration: configuration
      ) { benchmark in
        for _ in benchmark.scaledIterations {
          for key in present { blackHole(built.lookup(key)) }
        }
      }

      Benchmark(
        "Keys \(shape.label) \(name) - miss \(count)", configuration: configuration
      ) { benchmark in
        for _ in benchmark.scaledIterations {
          for key in absent { blackHole(built.lookup(key)) }
        }
      }
    }
  }

  // Past fifteen bytes a key is heap allocated, which is what the materialising strategies pay per
  // occurrence and the span based ones pay only on a new key.
  let longKeys = keyPointers(Payloads.countKeys(128, prefix: Payloads.longKeyPrefix))
  let longBuilt = buildTable(Table.self, keys: longKeys)

  Benchmark("Keys long \(name) - build 128", configuration: configuration) { benchmark in
    for _ in benchmark.scaledIterations {
      blackHole(buildTable(Table.self, keys: longKeys))
    }
  }

  Benchmark("Keys long \(name) - hit 128", configuration: configuration) { benchmark in
    for _ in benchmark.scaledIterations {
      for key in longKeys { blackHole(longBuilt.lookup(key)) }
    }
  }
}

private enum KeyShape: CaseIterable {
  case prefixed
  case diverse

  var label: String {
    switch self {
    case .prefixed: "prefixed"
    case .diverse: "diverse"
    }
  }

  func keys(_ count: Int) -> [[UInt8]] {
    switch self {
    case .prefixed: Payloads.countKeys(count, prefix: Payloads.shortKeyPrefix)
    case .diverse: Payloads.diverseKeys(count, from: 0)
    }
  }

  // Absent keys in the same shape and length distribution as the present ones, so a miss is not
  // rejected for free by a length check.
  func absentKeys(_ count: Int) -> [[UInt8]] {
    switch self {
    case .prefixed: Payloads.countKeys(count, prefix: Payloads.shortKeyPrefix, from: count)
    case .diverse: Payloads.diverseKeys(count, from: count)
    }
  }
}

func keyLookupBenchmarks() {
  var configuration = Benchmark.defaultConfiguration
  configuration.maxDuration = .seconds(1)

  registerKeyTable(MaterializingScan.self, named: "materializing scan", configuration: configuration)
  registerKeyTable(SpanScan.self, named: "span scan", configuration: configuration)
  registerKeyTable(WordScan.self, named: "word scan", configuration: configuration)
  registerKeyTable(HashScan.self, named: "hash scan", configuration: configuration)
  registerKeyTable(DictionaryIndex.self, named: "dictionary index", configuration: configuration)
  registerKeyTable(
    StreamDictionaryIndex.self,
    named: "StreamDictionary (String lookup)",
    configuration: configuration
  )
  registerKeyTable(BucketIndex.self, named: "bucket index prototype", configuration: configuration)
}
