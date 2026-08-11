// MARK: - ParserByteChunkState

struct ParserByteChunkState<Value: StreamParseableValue> {
  var valueStringBuffer: String?
  var valueNumberAccumulator: NumberAccumulator?

  mutating func flush(
    into reducer: inout Value,
    stringPath: WritableKeyPath<Value, String>?,
    numberPath: WritableKeyPath<Value, NumberAccumulator>?
  ) {
    if let valueStringBuffer = self.valueStringBuffer, let stringPath {
      reducer[keyPath: stringPath] = valueStringBuffer
      self.valueStringBuffer = nil
    }
    if let valueNumberAccumulator = self.valueNumberAccumulator, let numberPath {
      reducer[keyPath: numberPath] = valueNumberAccumulator
      self.valueNumberAccumulator = nil
    }
  }

  /// Ensures a string buffer exists so that callers can append into it in place.
  ///
  /// Callers must append through ``valueStringBuffer`` rather than copying it out and
  /// assigning it back. Mutating the stored optional directly keeps the buffer uniquely
  /// referenced, which makes accumulation amortized O(1); copying it out puts it at a
  /// reference count of two and copies the whole accumulated value on every append.
  mutating func ensureValueStringBuffer(
    in reducer: Value,
    path: WritableKeyPath<Value, String>?
  ) {
    guard self.valueStringBuffer == nil else { return }
    self.valueStringBuffer = path.map { reducer[keyPath: $0] } ?? ""
  }

  mutating func ensureValueNumberAccumulator(
    in reducer: Value,
    path: WritableKeyPath<Value, NumberAccumulator>?
  ) -> NumberAccumulator? {
    if let valueNumberAccumulator = self.valueNumberAccumulator {
      return valueNumberAccumulator
    }
    guard let path else { return nil }
    let valueNumberAccumulator = reducer[keyPath: path]
    self.valueNumberAccumulator = valueNumberAccumulator
    return valueNumberAccumulator
  }
}

// MARK: - LiteralState

struct LiteralState {
  var expected = [UInt8]()
  var index = 0
}
