import StreamParsing

struct MockSingleValueParser<Reducer: StreamParseableReducer>: StreamParser {
  struct Handlers: StreamParserHandlers {
    private var storage = [MockHandlerKey: Any]()

    mutating func registerStringHandler(
      _ keyPath: WritableKeyPath<Reducer, String>
    ) {
      fatalError("MockSingleValueParser only supports integer handlers")
    }

    mutating func registerBoolHandler(
      _ keyPath: WritableKeyPath<Reducer, Bool>
    ) {
      fatalError("MockSingleValueParser only supports integer handlers")
    }

    mutating func registerIntHandler(
      _ keyPath: WritableKeyPath<Reducer, Int>
    ) {
      self.storage[.int] = { (reducer: inout Reducer, value: Int) in
        reducer[keyPath: keyPath] = value
      }
    }

    mutating func registerInt8Handler(
      _ keyPath: WritableKeyPath<Reducer, Int8>
    ) {
      fatalError("MockSingleValueParser only supports integer handlers")
    }

    mutating func registerInt16Handler(
      _ keyPath: WritableKeyPath<Reducer, Int16>
    ) {
      fatalError("MockSingleValueParser only supports integer handlers")
    }

    mutating func registerInt32Handler(
      _ keyPath: WritableKeyPath<Reducer, Int32>
    ) {
      fatalError("MockSingleValueParser only supports integer handlers")
    }

    mutating func registerInt64Handler(
      _ keyPath: WritableKeyPath<Reducer, Int64>
    ) {
      fatalError("MockSingleValueParser only supports integer handlers")
    }

    mutating func registerUIntHandler(
      _ keyPath: WritableKeyPath<Reducer, UInt>
    ) {
      fatalError("MockSingleValueParser only supports integer handlers")
    }

    mutating func registerUInt8Handler(
      _ keyPath: WritableKeyPath<Reducer, UInt8>
    ) {
      fatalError("MockSingleValueParser only supports integer handlers")
    }

    mutating func registerUInt16Handler(
      _ keyPath: WritableKeyPath<Reducer, UInt16>
    ) {
      fatalError("MockSingleValueParser only supports integer handlers")
    }

    mutating func registerUInt32Handler(
      _ keyPath: WritableKeyPath<Reducer, UInt32>
    ) {
      fatalError("MockSingleValueParser only supports integer handlers")
    }

    mutating func registerUInt64Handler(
      _ keyPath: WritableKeyPath<Reducer, UInt64>
    ) {
      fatalError("MockSingleValueParser only supports integer handlers")
    }

    mutating func registerFloatHandler(
      _ keyPath: WritableKeyPath<Reducer, Float>
    ) {
      fatalError("MockSingleValueParser only supports integer handlers")
    }

    mutating func registerDoubleHandler(
      _ keyPath: WritableKeyPath<Reducer, Double>
    ) {
      fatalError("MockSingleValueParser only supports integer handlers")
    }

    mutating func registerNilHandler<Value: StreamParseableReducer>(
      _ keyPath: WritableKeyPath<Reducer, Value?>
    ) {
      self.storage[.nilValue] = { (reducer: inout Reducer) in
        reducer[keyPath: keyPath] = nil
      }
    }

    mutating func registerScopedHandlers<Scoped: StreamParseableReducer>(
      on type: Scoped.Type,
      _ keyPath: WritableKeyPath<Reducer, Scoped>
    ) {
      var scoped = MockSingleValueParser<Scoped>.Handlers()
      Scoped.registerHandlers(in: &scoped)
      self.mergeScoped(from: scoped, keyPath: keyPath)
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    mutating func registerInt128Handler(
      _ keyPath: WritableKeyPath<Reducer, Int128>
    ) {
      fatalError("MockSingleValueParser only supports integer handlers")
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    mutating func registerUInt128Handler(
      _ keyPath: WritableKeyPath<Reducer, UInt128>
    ) {
      fatalError("MockSingleValueParser only supports integer handlers")
    }

    private mutating func mergeScoped<Scoped: StreamParseableReducer>(
      from other: MockSingleValueParser<Scoped>.Handlers,
      keyPath: WritableKeyPath<Reducer, Scoped>
    ) {
      if let typed = other.storage[.int] as? (inout Scoped, Int) -> Void {
        self.storage[.int] = self.bridge(typed, keyPath: keyPath)
      }
      if let typed = other.storage[.nilValue] as? (inout Scoped) -> Void {
        self.storage[.nilValue] = self.bridgeNil(typed, keyPath: keyPath)
      }
    }

    private func bridge<Scoped>(
      _ handler: @escaping (inout Scoped, Int) -> Void,
      keyPath: WritableKeyPath<Reducer, Scoped>
    ) -> (inout Reducer, Int) -> Void {
      { reducer, input in
        handler(&reducer[keyPath: keyPath], input)
      }
    }

    private func bridgeNil<Scoped>(
      _ handler: @escaping (inout Scoped) -> Void,
      keyPath: WritableKeyPath<Reducer, Scoped>
    ) -> (inout Reducer) -> Void {
      { reducer in
        handler(&reducer[keyPath: keyPath])
      }
    }

    fileprivate func invoke(
      _ invocation: MockHandlerInvocation,
      into reducer: inout Reducer
    ) {
      switch invocation {
      case .int(let value):
        self.call(.int, into: &reducer, value: value)
      case .nilValue:
        self.callNil(.nilValue, into: &reducer)
      }
    }

    private func call(
      _ key: MockHandlerKey,
      into reducer: inout Reducer,
      value: Int
    ) {
      guard let handler = self.storage[key] as? (inout Reducer, Int) -> Void else { return }
      handler(&reducer, value)
    }

    private func callNil(_ key: MockHandlerKey, into reducer: inout Reducer) {
      guard let handler = self.storage[key] as? (inout Reducer) -> Void else { return }
      handler(&reducer)
    }
  }

  enum MockHandlerInvocation {
    case int(Int)
    case nilValue
  }

  enum MockHandlerKey: Hashable {
    case int
    case nilValue
  }

  private var actions: [UInt8: MockHandlerInvocation]
  private var handlers = Handlers()

  init(actions: [UInt8: MockHandlerInvocation]) {
    self.actions = actions
  }

  mutating func parse(bytes: some Sequence<UInt8>, into reducer: inout Reducer) throws {
    for byte in bytes {
      guard let invocation = self.actions[byte] else { continue }
      self.handlers.invoke(invocation, into: &reducer)
    }
  }

  mutating func registerHandlers() {
    Reducer.registerHandlers(in: &self.handlers)
  }
}
