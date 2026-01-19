struct BitVector {
  private var words = [UInt64]()

  func contains(_ index: Int) -> Bool {
    guard index >= 0 else { return false }
    let wordIndex = index >> 6
    guard wordIndex < self.words.count else { return false }
    let bit = UInt64(1) << UInt64(index & 63)
    return (self.words[wordIndex] & bit) != 0
  }

  mutating func insert(_ index: Int) {
    guard index >= 0 else { return }
    let wordIndex = index >> 6
    if wordIndex >= self.words.count {
      self.words.append(contentsOf: repeatElement(0, count: wordIndex - self.words.count + 1))
    }
    let bit = UInt64(1) << UInt64(index & 63)
    self.words[wordIndex] |= bit
  }

  mutating func remove(_ index: Int) {
    guard index >= 0 else { return }
    let wordIndex = index >> 6
    guard wordIndex < self.words.count else { return }
    let bit = UInt64(1) << UInt64(index & 63)
    self.words[wordIndex] &= ~bit
  }
}
