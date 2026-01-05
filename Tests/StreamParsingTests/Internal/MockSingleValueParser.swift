import StreamParsing

struct MockSingleValueParser<Reducer: StreamParseableReducer>: StreamParser {
  struct Handlers: StreamParserHandlers {
    private var storage = [MockHandlerKey: Any]()

    mutating func registerStringHandler(
      _ handler: @escaping (inout Reducer, String) -> Void
    ) {
      fatalError("MockSingleValueParser only supports integer handlers")
    }

    mutating func registerBoolHandler(
      _ handler: @escaping (inout Reducer, Bool) -> Void
    ) {
      fatalError("MockSingleValueParser only supports integer handlers")
    }

    mutating func registerIntHandler(
      _ handler: @escaping (inout Reducer, Int) -> Void
    ) {
      self.storage[.int] = handler
    }

    mutating func registerInt8Handler(
      _ handler: @escaping (inout Reducer, Int8) -> Void
    ) {
      fatalError("MockSingleValueParser only supports integer handlers")
    }

    mutating func registerInt16Handler(
      _ handler: @escaping (inout Reducer, Int16) -> Void
    ) {
      fatalError("MockSingleValueParser only supports integer handlers")
    }

    mutating func registerInt32Handler(
      _ handler: @escaping (inout Reducer, Int32) -> Void
    ) {
      fatalError("MockSingleValueParser only supports integer handlers")
    }

    mutating func registerInt64Handler(
      _ handler: @escaping (inout Reducer, Int64) -> Void
    ) {
      fatalError("MockSingleValueParser only supports integer handlers")
    }

    mutating func registerUIntHandler(
      _ handler: @escaping (inout Reducer, UInt) -> Void
    ) {
      fatalError("MockSingleValueParser only supports integer handlers")
    }

    mutating func registerUInt8Handler(
      _ handler: @escaping (inout Reducer, UInt8) -> Void
    ) {
      fatalError("MockSingleValueParser only supports integer handlers")
    }

    mutating func registerUInt16Handler(
      _ handler: @escaping (inout Reducer, UInt16) -> Void
    ) {
      fatalError("MockSingleValueParser only supports integer handlers")
    }

    mutating func registerUInt32Handler(
      _ handler: @escaping (inout Reducer, UInt32) -> Void
    ) {
      fatalError("MockSingleValueParser only supports integer handlers")
    }

    mutating func registerUInt64Handler(
      _ handler: @escaping (inout Reducer, UInt64) -> Void
    ) {
      fatalError("MockSingleValueParser only supports integer handlers")
    }

    mutating func registerFloatHandler(
      _ handler: @escaping (inout Reducer, Float) -> Void
    ) {
      fatalError("MockSingleValueParser only supports integer handlers")
    }

    mutating func registerDoubleHandler(
      _ handler: @escaping (inout Reducer, Double) -> Void
    ) {
      fatalError("MockSingleValueParser only supports integer handlers")
    }

    mutating func registerNilHandler(
      _ handler: @escaping (inout Reducer) -> Void
    ) {
      self.storage[.nilValue] = handler
    }

    mutating func registerScopedHandlers<Scoped: StreamParseableReducer>(
      on type: Scoped.Type,
      _ body: @escaping (inout Reducer, (inout Scoped) -> Void) -> Void
    ) {
      var scoped = MockSingleValueParser<Scoped>.Handlers()
      Scoped.registerHandlers(in: &scoped)
      self.mergeScoped(from: scoped, body: body)
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    mutating func registerInt128Handler(
      _ handler: @escaping (inout Reducer, Int128) -> Void
    ) {
      fatalError("MockSingleValueParser only supports integer handlers")
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    mutating func registerUInt128Handler(
      _ handler: @escaping (inout Reducer, UInt128) -> Void
    ) {
      fatalError("MockSingleValueParser only supports integer handlers")
    }

    private mutating func mergeScoped<Scoped: StreamParseableReducer>(
      from other: MockSingleValueParser<Scoped>.Handlers,
      body: @escaping (inout Reducer, (inout Scoped) -> Void) -> Void
    ) {
      if let typed = other.storage[.int] as? (inout Scoped, Int) -> Void {
        self.storage[.int] = self.bridge(typed, body: body)
      }
      if let typed = other.storage[.nilValue] as? (inout Scoped) -> Void {
        self.storage[.nilValue] = self.bridgeNil(typed, body: body)
      }
    }

    private func bridge<Scoped>(
      _ handler: @escaping (inout Scoped, Int) -> Void,
      body: @escaping (inout Reducer, (inout Scoped) -> Void) -> Void
    ) -> (inout Reducer, Int) -> Void {
      { reducer, input in
        body(&reducer) {
          handler(&$0, input)
        }
      }
    }

    private func bridgeNil<Scoped>(
      _ handler: @escaping (inout Scoped) -> Void,
      body: @escaping (inout Reducer, (inout Scoped) -> Void) -> Void
    ) -> (inout Reducer) -> Void {
      { reducer in
        body(&reducer) {
          handler(&$0)
        }
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
