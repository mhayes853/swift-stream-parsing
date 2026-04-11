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

  mutating func ensureValueStringBuffer(
    in reducer: Value,
    path: WritableKeyPath<Value, String>?
  ) -> String {
    if let valueStringBuffer = self.valueStringBuffer {
      return valueStringBuffer
    }
    guard let path else { return "" }
    let valueStringBuffer = reducer[keyPath: path]
    self.valueStringBuffer = valueStringBuffer
    return valueStringBuffer
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
