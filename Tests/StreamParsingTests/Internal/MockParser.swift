import StreamParsing

extension UInt8 {
  static let mockParserDecimalDoubleDoubling: UInt8 = 0x7D
  static let mockParserThrows: UInt8 = 0x7E
}

enum MockParserError: Error {
  case simulatedThrow
}

struct MockParser<Value: StreamParseableValue>: StreamParser {
  struct Handlers: StreamParserHandlers {
    var stringPath: WritableKeyPath<Value, String>?
    var boolPath: WritableKeyPath<Value, Bool>?
    var intPath: WritableKeyPath<Value, Int>?
    var int8Path: WritableKeyPath<Value, Int8>?
    var int16Path: WritableKeyPath<Value, Int16>?
    var int32Path: WritableKeyPath<Value, Int32>?
    var int64Path: WritableKeyPath<Value, Int64>?
    var uintPath: WritableKeyPath<Value, UInt>?
    var uint8Path: WritableKeyPath<Value, UInt8>?
    var uint16Path: WritableKeyPath<Value, UInt16>?
    var uint32Path: WritableKeyPath<Value, UInt32>?
    var uint64Path: WritableKeyPath<Value, UInt64>?
    var floatPath: WritableKeyPath<Value, Float>?
    var doublePath: WritableKeyPath<Value, Double>?
    var nullablePath: WritableKeyPath<Value, Void?>?
    var int128Path: WritableKeyPath<Value, any Sendable>?
    var uint128Path: WritableKeyPath<Value, any Sendable>?
    var arrayPath: WritableKeyPath<Value, any StreamParseableArrayObject<Int>>?
    var dictionaryPath: WritableKeyPath<Value, any StreamParseableDictionaryObject<Int>>?

    mutating func registerStringHandler(
      _ keyPath: WritableKeyPath<Value, String>
    ) {
      self.stringPath = keyPath
    }

    mutating func registerBoolHandler(
      _ keyPath: WritableKeyPath<Value, Bool>
    ) {
      self.boolPath = keyPath
    }

    mutating func registerIntHandler(
      _ keyPath: WritableKeyPath<Value, Int>
    ) {
      self.intPath = keyPath
    }

    mutating func registerInt8Handler(
      _ keyPath: WritableKeyPath<Value, Int8>
    ) {
      self.int8Path = keyPath
    }

    mutating func registerInt16Handler(
      _ keyPath: WritableKeyPath<Value, Int16>
    ) {
      self.int16Path = keyPath
    }

    mutating func registerInt32Handler(
      _ keyPath: WritableKeyPath<Value, Int32>
    ) {
      self.int32Path = keyPath
    }

    mutating func registerInt64Handler(
      _ keyPath: WritableKeyPath<Value, Int64>
    ) {
      self.int64Path = keyPath
    }

    mutating func registerUIntHandler(
      _ keyPath: WritableKeyPath<Value, UInt>
    ) {
      self.uintPath = keyPath
    }

    mutating func registerUInt8Handler(
      _ keyPath: WritableKeyPath<Value, UInt8>
    ) {
      self.uint8Path = keyPath
    }

    mutating func registerUInt16Handler(
      _ keyPath: WritableKeyPath<Value, UInt16>
    ) {
      self.uint16Path = keyPath
    }

    mutating func registerUInt32Handler(
      _ keyPath: WritableKeyPath<Value, UInt32>
    ) {
      self.uint32Path = keyPath
    }

    mutating func registerUInt64Handler(
      _ keyPath: WritableKeyPath<Value, UInt64>
    ) {
      self.uint64Path = keyPath
    }

    mutating func registerFloatHandler(
      _ keyPath: WritableKeyPath<Value, Float>
    ) {
      self.floatPath = keyPath
    }

    mutating func registerDoubleHandler(
      _ keyPath: WritableKeyPath<Value, Double>
    ) {
      self.doublePath = keyPath
    }

    mutating func registerNilHandler<Nullable: StreamParseableValue>(
      _ keyPath: WritableKeyPath<Value, Nullable?>
    ) {
      self.nullablePath = keyPath.appending(path: \.nullablePath)
    }

    mutating func registerKeyedHandler<Keyed: StreamParseableValue>(
      forKey key: String,
      _ keyPath: WritableKeyPath<Value, Keyed>
    ) {}

    mutating func registerScopedHandlers<Scoped: StreamParseableValue>(
      on type: Scoped.Type,
      _ keyPath: WritableKeyPath<Value, Scoped>
    ) {
      var scoped = MockParser<Scoped>.Handlers()
      Scoped.registerHandlers(in: &scoped)
      self.merge(with: scoped, using: keyPath)
    }

    private mutating func merge<Scoped: StreamParseableValue>(
      with handlers: MockParser<Scoped>.Handlers,
      using path: WritableKeyPath<Value, Scoped>
    ) {
      if let stringPath = handlers.stringPath {
        self.stringPath = path.appending(path: stringPath)
      }
      if let boolPath = handlers.boolPath {
        self.boolPath = path.appending(path: boolPath)
      }
      if let intPath = handlers.intPath {
        self.intPath = path.appending(path: intPath)
      }
      if let int8Path = handlers.int8Path {
        self.int8Path = path.appending(path: int8Path)
      }
      if let int16Path = handlers.int16Path {
        self.int16Path = path.appending(path: int16Path)
      }
      if let int32Path = handlers.int32Path {
        self.int32Path = path.appending(path: int32Path)
      }
      if let int64Path = handlers.int64Path {
        self.int64Path = path.appending(path: int64Path)
      }
      if let uintPath = handlers.uintPath {
        self.uintPath = path.appending(path: uintPath)
      }
      if let uint8Path = handlers.uint8Path {
        self.uint8Path = path.appending(path: uint8Path)
      }
      if let uint16Path = handlers.uint16Path {
        self.uint16Path = path.appending(path: uint16Path)
      }
      if let uint32Path = handlers.uint32Path {
        self.uint32Path = path.appending(path: uint32Path)
      }
      if let uint64Path = handlers.uint64Path {
        self.uint64Path = path.appending(path: uint64Path)
      }
      if let floatPath = handlers.floatPath {
        self.floatPath = path.appending(path: floatPath)
      }
      if let doublePath = handlers.doublePath {
        self.doublePath = path.appending(path: doublePath)
      }
      if let nullablePath = handlers.nullablePath {
        self.nullablePath = path.appending(path: nullablePath)
      }
      if let int128Path = handlers.int128Path {
        self.int128Path = path.appending(path: int128Path)
      }
      if let uint128Path = handlers.uint128Path {
        self.uint128Path = path.appending(path: uint128Path)
      }
      if let arrayPath = handlers.arrayPath {
        self.arrayPath = path.appending(path: arrayPath)
      }
      if let dictionaryPath = handlers.dictionaryPath {
        self.dictionaryPath = path.appending(path: dictionaryPath)
      }
    }

    mutating func registerArrayHandler<C: StreamParseableArrayObject>(
      _ keyPath: WritableKeyPath<Value, C>
    ) {
      guard C.Element.self == Int.self else { return }
      let erased = keyPath.appending(path: \.erasedPath)
      // Safe due to the Element type check above.
      self.arrayPath = unsafeBitCast(
        erased,
        to: WritableKeyPath<Value, any StreamParseableArrayObject<Int>>.self
      )
    }

    mutating func registerDictionaryHandler<D: StreamParseableDictionaryObject>(
      _ keyPath: WritableKeyPath<Value, D>
    ) {
      guard D.Value.self == Int.self else { return }
      let erased = keyPath.appending(path: \.erasedPath)
      // Safe due to the Value type check above.
      self.dictionaryPath = unsafeBitCast(
        erased,
        to: WritableKeyPath<Value, any StreamParseableDictionaryObject<Int>>.self
      )
    }

    @available(StreamParsing128BitIntegers, *)
    mutating func registerInt128Handler(
      _ keyPath: WritableKeyPath<Value, Int128>
    ) {
      self.int128Path = keyPath.appending(path: \.erasedPath)
    }

    @available(StreamParsing128BitIntegers, *)
    mutating func registerUInt128Handler(
      _ keyPath: WritableKeyPath<Value, UInt128>
    ) {
      self.uint128Path = keyPath.appending(path: \.erasedPath)
    }

    fileprivate func invoke(
      _ invocation: MockHandlerInvocation,
      into reducer: inout Value
    ) {
      switch invocation {
      case .int(let value):
        guard let intPath = self.intPath else { return }
        reducer[keyPath: intPath] = value
      case .nilValue:
        guard let nullablePath = self.nullablePath else { return }
        reducer[keyPath: nullablePath] = nil
      case .string(let value):
        guard let stringPath = self.stringPath else { return }
        reducer[keyPath: stringPath] = value
      case .uint(let value):
        guard let uintPath = self.uintPath else { return }
        reducer[keyPath: uintPath] = value
      case .double(let value):
        guard let doublePath = self.doublePath else { return }
        reducer[keyPath: doublePath] = value
      case .int128(let high, let low):
        if #available(StreamParsing128BitIntegers , *) {
          guard let int128Path = self.int128Path else { return }
          reducer[keyPath: int128Path] = Int128(_low: low, _high: high)
        }
      case .arrayAppend:
        guard let arrayPath = self.arrayPath else { return }
        reducer[keyPath: arrayPath]
          .append(
            contentsOf: CollectionOfOne(Int.initialParseableValue())
          )
      case .arraySet(let index, let value):
        guard let arrayPath = self.arrayPath else { return }
        reducer[keyPath: arrayPath][index] = value
      case .createDictionaryValue(let key):
        guard let dictionaryPath = self.dictionaryPath else { return }
        reducer[keyPath: dictionaryPath][key] = Int.initialParseableValue()
      case .setDictionaryValue(let key, let value):
        guard let dictionaryPath = self.dictionaryPath else { return }
        reducer[keyPath: dictionaryPath][key] = value
      case .doubleValue:
        guard let doublePath = self.doublePath else { return }
        reducer[keyPath: doublePath] *= 2
      }
    }
  }

  enum MockHandlerInvocation {
    case int(Int)
    case nilValue
    case string(String)
    case uint(UInt)
    case double(Double)
    case int128(high: Int64, low: UInt64)
    case arrayAppend
    case arraySet(index: Int, value: Int)
    case createDictionaryValue(key: String)
    case setDictionaryValue(key: String, value: Int)
    case doubleValue

    @available(StreamParsing128BitIntegers, *)
    static func int128(_ value: Int128) -> Self {
      .int128(high: value._high, low: value._low)
    }
  }

  private var actions: [UInt8: MockHandlerInvocation]
  private var handlers = Handlers()
  private let throwOnByte: UInt8?

  init(actions: [UInt8: MockHandlerInvocation], throwOnByte: UInt8? = nil) {
    self.actions = actions
    self.throwOnByte = throwOnByte
  }

  mutating func parse(bytes: some Sequence<UInt8>, into reducer: inout Value) throws {
    for byte in bytes {
      if let throwByte = self.throwOnByte, byte == throwByte {
        throw MockParserError.simulatedThrow
      }
      guard let invocation = self.actions[byte] else { continue }
      self.handlers.invoke(invocation, into: &reducer)
    }
  }

  mutating func finish(reducer: inout Value) throws {
  }

  mutating func registerHandlers() {
    Value.registerHandlers(in: &self.handlers)
  }
}
