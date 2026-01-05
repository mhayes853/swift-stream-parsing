import StreamParsing

struct MockParser<Reducer: StreamParseableValue>: StreamParser {
  struct Handlers: StreamParserHandlers {
    private var storage = [MockHandlerKey: Any]()

    mutating func registerStringHandler(
      _ keyPath: WritableKeyPath<Reducer, String>
    ) {
      self.storage[.string] = { (reducer: inout Reducer, value: String) in
        reducer[keyPath: keyPath] = value
      }
    }

    mutating func registerBoolHandler(
      _ keyPath: WritableKeyPath<Reducer, Bool>
    ) {}

    mutating func registerIntHandler(
      _ keyPath: WritableKeyPath<Reducer, Int>
    ) {
      self.storage[.int] = { (reducer: inout Reducer, value: Int) in
        reducer[keyPath: keyPath] = value
      }
    }

    mutating func registerInt8Handler(
      _ keyPath: WritableKeyPath<Reducer, Int8>
    ) {}

    mutating func registerInt16Handler(
      _ keyPath: WritableKeyPath<Reducer, Int16>
    ) {}

    mutating func registerInt32Handler(
      _ keyPath: WritableKeyPath<Reducer, Int32>
    ) {}

    mutating func registerInt64Handler(
      _ keyPath: WritableKeyPath<Reducer, Int64>
    ) {}

    mutating func registerUIntHandler(
      _ keyPath: WritableKeyPath<Reducer, UInt>
    ) {
      self.storage[.uint] = { (reducer: inout Reducer, value: UInt) in
        reducer[keyPath: keyPath] = value
      }
    }

    mutating func registerUInt8Handler(
      _ keyPath: WritableKeyPath<Reducer, UInt8>
    ) {}

    mutating func registerUInt16Handler(
      _ keyPath: WritableKeyPath<Reducer, UInt16>
    ) {}

    mutating func registerUInt32Handler(
      _ keyPath: WritableKeyPath<Reducer, UInt32>
    ) {}

    mutating func registerUInt64Handler(
      _ keyPath: WritableKeyPath<Reducer, UInt64>
    ) {}

    mutating func registerFloatHandler(
      _ keyPath: WritableKeyPath<Reducer, Float>
    ) {}

    mutating func registerDoubleHandler(
      _ keyPath: WritableKeyPath<Reducer, Double>
    ) {
      self.storage[.double] = { (reducer: inout Reducer, value: Double) in
        reducer[keyPath: keyPath] = value
      }
    }

    mutating func registerNilHandler<Value: StreamParseableValue>(
      _ keyPath: WritableKeyPath<Reducer, Value?>
    ) {
      self.storage[.nilValue] = { (reducer: inout Reducer) in
        reducer[keyPath: keyPath] = nil
      }
    }

    mutating func registerKeyedHandler<Value: StreamParseableValue>(
      forKey key: String,
      _ keyPath: WritableKeyPath<Reducer, Value>
    ) {}

    mutating func registerScopedHandlers<Scoped: StreamParseableValue>(
      on type: Scoped.Type,
      _ keyPath: WritableKeyPath<Reducer, Scoped>
    ) {
      var scoped = MockParser<Scoped>.Handlers()
      Scoped.registerHandlers(in: &scoped)
      self.mergeScoped(from: scoped, keyPath: keyPath)
    }

    mutating func registerArrayHandler<C: StreamParseableArrayObject>(
      _ keyPath: WritableKeyPath<Reducer, C>
    ) {
      guard C.Element.self == Int.self else { return }
      self.storage[.arrayAppend] = { (reducer: inout Reducer, value: Int) in
        var collection = reducer[keyPath: keyPath]
        let element = value as! C.Element
        collection.append(contentsOf: CollectionOfOne(element))
        reducer[keyPath: keyPath] = collection
      }
      self.storage[.arraySet] = { (reducer: inout Reducer, index: Int, value: Int) in
        var collection = reducer[keyPath: keyPath]
        collection[index] = value as! C.Element
        reducer[keyPath: keyPath] = collection
      }
    }

    mutating func registerDictionaryHandler<D: StreamParseableDictionaryObject>(
      _ keyPath: WritableKeyPath<Reducer, D>
    ) {
      guard D.Value.self == Int.self else { return }
      self.storage[.dictionaryCreate] = { (reducer: inout Reducer, key: String) in
        var dictionary = reducer[keyPath: keyPath]
        dictionary[key] = D.Value.initialParseableValue()
        reducer[keyPath: keyPath] = dictionary
      }
      self.storage[.dictionarySet] = { (reducer: inout Reducer, key: String, value: Int) in
        var dictionary = reducer[keyPath: keyPath]
        dictionary[key] = value as? D.Value
        reducer[keyPath: keyPath] = dictionary
      }
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    mutating func registerInt128Handler(
      _ keyPath: WritableKeyPath<Reducer, Int128>
    ) {
      self.storage[.int128] = { (reducer: inout Reducer, value: Int128) in
        reducer[keyPath: keyPath] = value
      }
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    mutating func registerUInt128Handler(
      _ keyPath: WritableKeyPath<Reducer, UInt128>
    ) {}

    private mutating func mergeScoped<Scoped: StreamParseableValue>(
      from other: MockParser<Scoped>.Handlers,
      keyPath: WritableKeyPath<Reducer, Scoped>
    ) {
      if let typed = other.storage[.int] as? (inout Scoped, Int) -> Void {
        self.storage[.int] = self.bridge(typed, keyPath: keyPath)
      }
      if let typed = other.storage[.nilValue] as? (inout Scoped) -> Void {
        self.storage[.nilValue] = self.bridgeNil(typed, keyPath: keyPath)
      }
      if let typed = other.storage[.string] as? (inout Scoped, String) -> Void {
        self.storage[.string] = self.bridgeString(typed, keyPath: keyPath)
      }
      if let typed = other.storage[.uint] as? (inout Scoped, UInt) -> Void {
        self.storage[.uint] = self.bridgeUInt(typed, keyPath: keyPath)
      }
      if let typed = other.storage[.double] as? (inout Scoped, Double) -> Void {
        self.storage[.double] = self.bridgeDouble(typed, keyPath: keyPath)
      }
      if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) {
        if let typed = other.storage[.int128] as? (inout Scoped, Int128) -> Void {
          self.storage[.int128] = self.bridgeInt128(typed, keyPath: keyPath)
        }
      }
      if let typed = other.storage[.arrayAppend] as? (inout Scoped, Int) -> Void {
        self.storage[.arrayAppend] = self.bridgeArrayAppend(typed, keyPath: keyPath)
      }
      if let typed = other.storage[.arraySet] as? (inout Scoped, Int, Int) -> Void {
        self.storage[.arraySet] = self.bridgeArraySet(typed, keyPath: keyPath)
      }
      if let typed = other.storage[.dictionaryCreate] as? (inout Scoped, String) -> Void {
        self.storage[.dictionaryCreate] = self.bridgeDictionaryCreate(typed, keyPath: keyPath)
      }
      if let typed = other.storage[.dictionarySet] as? (inout Scoped, String, Int) -> Void {
        self.storage[.dictionarySet] = self.bridgeDictionarySet(typed, keyPath: keyPath)
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

    private func bridgeString<Scoped>(
      _ handler: @escaping (inout Scoped, String) -> Void,
      keyPath: WritableKeyPath<Reducer, Scoped>
    ) -> (inout Reducer, String) -> Void {
      { reducer, value in
        handler(&reducer[keyPath: keyPath], value)
      }
    }

    private func bridgeUInt<Scoped>(
      _ handler: @escaping (inout Scoped, UInt) -> Void,
      keyPath: WritableKeyPath<Reducer, Scoped>
    ) -> (inout Reducer, UInt) -> Void {
      { reducer, value in
        handler(&reducer[keyPath: keyPath], value)
      }
    }

    private func bridgeDouble<Scoped>(
      _ handler: @escaping (inout Scoped, Double) -> Void,
      keyPath: WritableKeyPath<Reducer, Scoped>
    ) -> (inout Reducer, Double) -> Void {
      { reducer, value in
        handler(&reducer[keyPath: keyPath], value)
      }
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    private func bridgeInt128<Scoped>(
      _ handler: @escaping (inout Scoped, Int128) -> Void,
      keyPath: WritableKeyPath<Reducer, Scoped>
    ) -> (inout Reducer, Int128) -> Void {
      { reducer, value in
        handler(&reducer[keyPath: keyPath], value)
      }
    }

    private func bridgeArrayAppend<Scoped>(
      _ handler: @escaping (inout Scoped, Int) -> Void,
      keyPath: WritableKeyPath<Reducer, Scoped>
    ) -> (inout Reducer, Int) -> Void {
      { reducer, value in
        handler(&reducer[keyPath: keyPath], value)
      }
    }

    private func bridgeArraySet<Scoped>(
      _ handler: @escaping (inout Scoped, Int, Int) -> Void,
      keyPath: WritableKeyPath<Reducer, Scoped>
    ) -> (inout Reducer, Int, Int) -> Void {
      { reducer, index, value in
        handler(&reducer[keyPath: keyPath], index, value)
      }
    }

    private func bridgeDictionaryCreate<Scoped>(
      _ handler: @escaping (inout Scoped, String) -> Void,
      keyPath: WritableKeyPath<Reducer, Scoped>
    ) -> (inout Reducer, String) -> Void {
      { reducer, key in
        handler(&reducer[keyPath: keyPath], key)
      }
    }

    private func bridgeDictionarySet<Scoped>(
      _ handler: @escaping (inout Scoped, String, Int) -> Void,
      keyPath: WritableKeyPath<Reducer, Scoped>
    ) -> (inout Reducer, String, Int) -> Void {
      { reducer, key, value in
        handler(&reducer[keyPath: keyPath], key, value)
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
      case .string(let value):
        self.callString(.string, into: &reducer, value: value)
      case .uint(let value):
        self.callUInt(.uint, into: &reducer, value: value)
      case .double(let value):
        self.callDouble(.double, into: &reducer, value: value)
      case .int128(let high, let low):
        if #available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *) {
          self.callInt128(.int128, into: &reducer, high: high, low: low)
        }
      case .arrayAppend:
        self.callArrayAppend(.arrayAppend, into: &reducer, value: .initialParseableValue())
      case .arraySet(let index, let value):
        self.callArraySet(.arraySet, into: &reducer, index: index, value: value)
      case .createDictionaryValue(let key):
        self.callDictionaryCreate(.dictionaryCreate, into: &reducer, key: key)
      case .setDictionaryValue(let key, let value):
        self.callDictionarySet(.dictionarySet, into: &reducer, key: key, value: value)
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

    private func callUInt(
      _ key: MockHandlerKey,
      into reducer: inout Reducer,
      value: UInt
    ) {
      guard let handler = self.storage[key] as? (inout Reducer, UInt) -> Void else { return }
      handler(&reducer, value)
    }

    private func callDouble(
      _ key: MockHandlerKey,
      into reducer: inout Reducer,
      value: Double
    ) {
      guard let handler = self.storage[key] as? (inout Reducer, Double) -> Void else { return }
      handler(&reducer, value)
    }

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    private func callInt128(
      _ key: MockHandlerKey,
      into reducer: inout Reducer,
      high: Int64,
      low: UInt64
    ) {
      guard let handler = self.storage[key] as? (inout Reducer, Int128) -> Void else { return }
      handler(&reducer, Int128(_low: low, _high: high))
    }

    private func callString(
      _ key: MockHandlerKey,
      into reducer: inout Reducer,
      value: String
    ) {
      guard let handler = self.storage[key] as? (inout Reducer, String) -> Void else { return }
      handler(&reducer, value)
    }

    private func callNil(_ key: MockHandlerKey, into reducer: inout Reducer) {
      guard let handler = self.storage[key] as? (inout Reducer) -> Void else { return }
      handler(&reducer)
    }

    private func callArrayAppend(
      _ key: MockHandlerKey,
      into reducer: inout Reducer,
      value: Int
    ) {
      guard let handler = self.storage[key] as? (inout Reducer, Int) -> Void else { return }
      handler(&reducer, value)
    }

    private func callArraySet(
      _ key: MockHandlerKey,
      into reducer: inout Reducer,
      index: Int,
      value: Int
    ) {
      guard let handler = self.storage[key] as? (inout Reducer, Int, Int) -> Void else { return }
      handler(&reducer, index, value)
    }

    private func callDictionaryCreate(
      _ key: MockHandlerKey,
      into reducer: inout Reducer,
      key dictionaryKey: String
    ) {
      guard let handler = self.storage[key] as? (inout Reducer, String) -> Void else { return }
      handler(&reducer, dictionaryKey)
    }

    private func callDictionarySet(
      _ key: MockHandlerKey,
      into reducer: inout Reducer,
      key dictionaryKey: String,
      value: Int
    ) {
      guard let handler = self.storage[key] as? (inout Reducer, String, Int) -> Void else { return }
      handler(&reducer, dictionaryKey, value)
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

    @available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    static func int128(_ value: Int128) -> Self {
      .int128(high: value._high, low: value._low)
    }
  }

  enum MockHandlerKey: Hashable {
    case int
    case nilValue
    case string
    case uint
    case double
    case int128
    case arrayAppend
    case arraySet
    case dictionaryCreate
    case dictionarySet
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
