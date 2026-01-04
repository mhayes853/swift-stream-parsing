import StreamParsing

struct MockSingleValueParser<Reducer: StreamParseableReducer>: StreamParser {
  struct Handlers: StreamParserHandlers {
    private var storage = [MockHandlerKey: Any]()

    mutating func registerStringHandler(
      _ handler: @escaping (inout Reducer, String) -> Void
    ) {
      self.storage[.string] = handler
    }

    mutating func registerBoolHandler(
      _ handler: @escaping (inout Reducer, Bool) -> Void
    ) {
      self.storage[.bool] = handler
    }

    mutating func registerIntHandler(
      _ handler: @escaping (inout Reducer, Int) -> Void
    ) {
      self.storage[.int] = handler
    }

    mutating func registerInt8Handler(
      _ handler: @escaping (inout Reducer, Int8) -> Void
    ) {
      self.storage[.int8] = handler
    }

    mutating func registerInt16Handler(
      _ handler: @escaping (inout Reducer, Int16) -> Void
    ) {
      self.storage[.int16] = handler
    }

    mutating func registerInt32Handler(
      _ handler: @escaping (inout Reducer, Int32) -> Void
    ) {
      self.storage[.int32] = handler
    }

    mutating func registerInt64Handler(
      _ handler: @escaping (inout Reducer, Int64) -> Void
    ) {
      self.storage[.int64] = handler
    }

    mutating func registerUIntHandler(
      _ handler: @escaping (inout Reducer, UInt) -> Void
    ) {
      self.storage[.uint] = handler
    }

    mutating func registerUInt8Handler(
      _ handler: @escaping (inout Reducer, UInt8) -> Void
    ) {
      self.storage[.uint8] = handler
    }

    mutating func registerUInt16Handler(
      _ handler: @escaping (inout Reducer, UInt16) -> Void
    ) {
      self.storage[.uint16] = handler
    }

    mutating func registerUInt32Handler(
      _ handler: @escaping (inout Reducer, UInt32) -> Void
    ) {
      self.storage[.uint32] = handler
    }

    mutating func registerUInt64Handler(
      _ handler: @escaping (inout Reducer, UInt64) -> Void
    ) {
      self.storage[.uint64] = handler
    }

    mutating func registerFloatHandler(
      _ handler: @escaping (inout Reducer, Float) -> Void
    ) {
      self.storage[.float] = handler
    }

    mutating func registerDoubleHandler(
      _ handler: @escaping (inout Reducer, Double) -> Void
    ) {
      self.storage[.double] = handler
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
      fatalError("not supported")
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    mutating func registerUInt128Handler(
      _ handler: @escaping (inout Reducer, UInt128) -> Void
    ) {
      fatalError("not supported")
    }

    private mutating func mergeScoped<Scoped: StreamParseableReducer>(
      from other: MockSingleValueParser<Scoped>.Handlers,
      body: @escaping (inout Reducer, (inout Scoped) -> Void) -> Void
    ) {
      for (key, handler) in other.storage {
        switch key {
        case .string:
          if let typed = handler as? (inout Scoped, String) -> Void {
            self.storage[.string] = self.bridge(typed, body: body)
          }
        case .bool:
          if let typed = handler as? (inout Scoped, Bool) -> Void {
            self.storage[.bool] = self.bridge(typed, body: body)
          }
        case .int:
          if let typed = handler as? (inout Scoped, Int) -> Void {
            self.storage[.int] = self.bridge(typed, body: body)
          }
        case .int8:
          if let typed = handler as? (inout Scoped, Int8) -> Void {
            self.storage[.int8] = self.bridge(typed, body: body)
          }
        case .int16:
          if let typed = handler as? (inout Scoped, Int16) -> Void {
            self.storage[.int16] = self.bridge(typed, body: body)
          }
        case .int32:
          if let typed = handler as? (inout Scoped, Int32) -> Void {
            self.storage[.int32] = self.bridge(typed, body: body)
          }
        case .int64:
          if let typed = handler as? (inout Scoped, Int64) -> Void {
            self.storage[.int64] = self.bridge(typed, body: body)
          }
        case .uint:
          if let typed = handler as? (inout Scoped, UInt) -> Void {
            self.storage[.uint] = self.bridge(typed, body: body)
          }
        case .uint8:
          if let typed = handler as? (inout Scoped, UInt8) -> Void {
            self.storage[.uint8] = self.bridge(typed, body: body)
          }
        case .uint16:
          if let typed = handler as? (inout Scoped, UInt16) -> Void {
            self.storage[.uint16] = self.bridge(typed, body: body)
          }
        case .uint32:
          if let typed = handler as? (inout Scoped, UInt32) -> Void {
            self.storage[.uint32] = self.bridge(typed, body: body)
          }
        case .uint64:
          if let typed = handler as? (inout Scoped, UInt64) -> Void {
            self.storage[.uint64] = self.bridge(typed, body: body)
          }
        case .float:
          if let typed = handler as? (inout Scoped, Float) -> Void {
            self.storage[.float] = self.bridge(typed, body: body)
          }
        case .double:
          if let typed = handler as? (inout Scoped, Double) -> Void {
            self.storage[.double] = self.bridge(typed, body: body)
          }
        case .nilValue:
          if let typed = handler as? (inout Scoped) -> Void {
            self.storage[.nilValue] = self.bridgeNil(typed, body: body)
          }
        }
      }
    }

    private func bridge<Scoped, Input>(
      _ handler: @escaping (inout Scoped, Input) -> Void,
      body: @escaping (inout Reducer, (inout Scoped) -> Void) -> Void
    ) -> (inout Reducer, Input) -> Void {
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
      case .string(let value):
        self.call(.string, into: &reducer, value: value)
      case .bool(let value):
        self.call(.bool, into: &reducer, value: value)
      case .int(let value):
        self.call(.int, into: &reducer, value: value)
      case .int8(let value):
        self.call(.int8, into: &reducer, value: value)
      case .int16(let value):
        self.call(.int16, into: &reducer, value: value)
      case .int32(let value):
        self.call(.int32, into: &reducer, value: value)
      case .int64(let value):
        self.call(.int64, into: &reducer, value: value)
      case .uint(let value):
        self.call(.uint, into: &reducer, value: value)
      case .uint8(let value):
        self.call(.uint8, into: &reducer, value: value)
      case .uint16(let value):
        self.call(.uint16, into: &reducer, value: value)
      case .uint32(let value):
        self.call(.uint32, into: &reducer, value: value)
      case .uint64(let value):
        self.call(.uint64, into: &reducer, value: value)
      case .float(let value):
        self.call(.float, into: &reducer, value: value)
      case .double(let value):
        self.call(.double, into: &reducer, value: value)
      case .nilValue:
        self.callNil(.nilValue, into: &reducer)
      }
    }

    private func call<Input>(
      _ key: MockHandlerKey,
      into reducer: inout Reducer,
      value: Input
    ) {
      guard let handler = self.storage[key] as? (inout Reducer, Input) -> Void else { return }
      handler(&reducer, value)
    }

    private func callNil(_ key: MockHandlerKey, into reducer: inout Reducer) {
      guard let handler = self.storage[key] as? (inout Reducer) -> Void else { return }
      handler(&reducer)
    }
  }

  enum MockHandlerInvocation {
    case string(String)
    case bool(Bool)
    case int(Int)
    case int8(Int8)
    case int16(Int16)
    case int32(Int32)
    case int64(Int64)
    case uint(UInt)
    case uint8(UInt8)
    case uint16(UInt16)
    case uint32(UInt32)
    case uint64(UInt64)
    case float(Float)
    case double(Double)
    case nilValue
  }

  enum MockHandlerKey: Hashable {
    case string
    case bool
    case int
    case int8
    case int16
    case int32
    case int64
    case uint
    case uint8
    case uint16
    case uint32
    case uint64
    case float
    case double
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
