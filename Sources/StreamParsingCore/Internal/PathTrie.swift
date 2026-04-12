final class PathTrie<Value: StreamParseableValue> {
  struct Paths {
    var string: WritableKeyPath<Value, String>?
    var bool: WritableKeyPath<Value, Bool>?
    var number: WritableKeyPath<Value, NumberAccumulator>?
    var nullable: WritableKeyPath<Value, Void?>?
    var array: WritableKeyPath<Value, any StreamParseableArrayObject>?
    var dictionary: WritableKeyPath<Value, any StreamParseableDictionaryObject>?

    var hasAnyHandler: Bool {
      self.string != nil
        || self.bool != nil
        || self.number != nil
        || self.nullable != nil
        || self.array != nil
        || self.dictionary != nil
    }

    mutating func merge(from other: Paths) {
      if self.string == nil {
        self.string = other.string
      }
      if self.bool == nil {
        self.bool = other.bool
      }
      if self.number == nil {
        self.number = other.number
      }
      if self.nullable == nil {
        self.nullable = other.nullable
      }
      if self.array == nil {
        self.array = other.array
      }
      if self.dictionary == nil {
        self.dictionary = other.dictionary
      }
    }
  }

  enum Children {
    case none
    case array(PathTrie)
    case object(keys: [String: PathTrie], any: PathTrie?)
  }

  var paths = Paths()
  var children: Children = .none
  var dynamicKeyBuilder: ((String) -> PathTrie<Value>)?
  private var dynamicKeyCache = [String: PathTrie<Value>]()

  init(paths: Paths = Paths(), children: Children = .none) {
    self.paths = paths
    self.children = children
  }

  var expectsObject: Bool {
    if case .object = self.children { return true }
    return false
  }

  var hasAnyHandler: Bool {
    self.paths.hasAnyHandler || self.hasChildren
  }

  private var hasChildren: Bool {
    switch self.children {
    case .none: false
    case .array, .object: true
    }
  }

  func prefixed<Root: StreamParseableValue>(
    by prefix: WritableKeyPath<Root, Value>
  ) -> PathTrie<Root> {
    let prefixedPaths = PathTrie<Root>.Paths(
      string: self.paths.string.map { prefix.appending(path: $0) },
      bool: self.paths.bool.map { prefix.appending(path: $0) },
      number: self.paths.number.map { prefix.appending(path: $0) },
      nullable: self.paths.nullable.map { prefix.appending(path: $0) },
      array: self.paths.array.map { prefix.appending(path: $0) },
      dictionary: self.paths.dictionary.map { prefix.appending(path: $0) }
    )
    let node = PathTrie<Root>(paths: prefixedPaths)
    switch self.children {
    case .none:
      break
    case .array(let child):
      node.children = .array(child.prefixed(by: prefix))
    case .object(let keys, let any):
      var prefixedKeys = [String: PathTrie<Root>]()
      prefixedKeys.reserveCapacity(keys.count)
      for (key, child) in keys {
        prefixedKeys[key] = child.prefixed(by: prefix)
      }
      let prefixedAny = any.map { $0.prefixed(by: prefix) }
      node.children = .object(keys: prefixedKeys, any: prefixedAny)
    }
    if let builder = self.dynamicKeyBuilder {
      node.dynamicKeyBuilder = { key in
        builder(key).prefixed(by: prefix)
      }
    }
    return node
  }

  func merge(from other: PathTrie<Value>) {
    self.paths.merge(from: other.paths)
    switch other.children {
    case .none:
      break
    case .array(let otherChild):
      let child = self.ensureArrayChild()
      child.merge(from: otherChild)
    case .object(let keys, let any):
      for (key, otherChild) in keys {
        let child = self.ensureObjectChild(for: key)
        child.merge(from: otherChild)
      }
      if let otherAny = any {
        let anyChild = self.ensureAnyObjectChild()
        anyChild.merge(from: otherAny)
        if anyChild.dynamicKeyBuilder == nil {
          anyChild.dynamicKeyBuilder = otherAny.dynamicKeyBuilder
        }
      }
    }
    if self.dynamicKeyBuilder == nil {
      self.dynamicKeyBuilder = other.dynamicKeyBuilder
    }
  }

  func arrayChildNode() -> PathTrie<Value>? {
    if case .array(let child) = self.children {
      return child
    }
    return nil
  }

  func objectChildNode(for key: String) -> PathTrie<Value>? {
    guard case .object(let keys, let any) = self.children else { return nil }
    if let child = keys[key] {
      return child
    }
    guard let any else { return nil }
    return any.nodeForDynamicKey(key)
  }

  private func nodeForDynamicKey(_ key: String) -> PathTrie<Value> {
    if let cached = self.dynamicKeyCache[key] {
      return cached
    }
    guard let builder = self.dynamicKeyBuilder else { return self }
    let node = builder(key)
    self.dynamicKeyCache[key] = node
    return node
  }

  @discardableResult
  func ensureArrayChild() -> PathTrie<Value> {
    if case .array(let child) = self.children {
      return child
    }
    let child = PathTrie<Value>()
    self.children = .array(child)
    return child
  }

  @discardableResult
  func ensureObjectChild(for key: String) -> PathTrie<Value> {
    if case .object(var keys, let any) = self.children {
      if let child = keys[key] {
        return child
      }
      let child = PathTrie<Value>()
      keys[key] = child
      self.children = .object(keys: keys, any: any)
      return child
    }
    let child = PathTrie<Value>()
    self.children = .object(keys: [key: child], any: nil)
    return child
  }

  @discardableResult
  func ensureAnyObjectChild() -> PathTrie<Value> {
    if case .object(let keys, let any) = self.children {
      if let any {
        return any
      }
      let child = PathTrie<Value>()
      self.children = .object(keys: keys, any: child)
      return child
    }
    let child = PathTrie<Value>()
    self.children = .object(keys: [:], any: child)
    return child
  }
}
