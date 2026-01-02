struct TrackingReducer<Value: StreamActionReducer>: StreamActionReducer {
  private(set) var value: Value
  private(set) var reduceCount: Int

  init(value: Value) {
    self.value = value
    self.reduceCount = 0
  }

  mutating func reduce(action: StreamAction) throws {
    self.reduceCount += 1
    try self.value.reduce(action: action)
  }
}

extension TrackingReducer: Sendable where Value: Sendable {}
