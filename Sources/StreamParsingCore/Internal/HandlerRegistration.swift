extension PathTrie {
  func path<Path>(
    _ keyPath: KeyPath<Paths, Path?>,
    isInvalidType: (PathTrie<Value>) -> Bool = { $0.hasAnyHandler }
  ) -> (Path?, Bool) {
    let path = self.paths[keyPath: keyPath]
    return (path, path == nil && isInvalidType(self))
  }

  func mergeKeyedHandlerTrie<Keyed: StreamParseableValue>(
    decodedKey: String,
    keyPath: WritableKeyPath<Value, Keyed>,
    nestedTrie: @autoclosure () -> PathTrie<Keyed>
  ) {
    let keyNode = self.ensureObjectChild(for: decodedKey)
    let prefixedTrie = nestedTrie().prefixed(by: keyPath)
    keyNode.merge(from: prefixedTrie)
  }

  func mergeScopedHandlerTrie<Scoped: StreamParseableValue>(
    keyPath: WritableKeyPath<Value, Scoped>,
    nestedTrie: @autoclosure () -> PathTrie<Scoped>
  ) {
    let prefixedTrie = nestedTrie().prefixed(by: keyPath)
    self.merge(from: prefixedTrie)
  }

  func registerArrayHandlerTrie<ArrayObject: StreamParseableArrayObject>(
    keyPath: WritableKeyPath<Value, ArrayObject>,
    elementTrie: @autoclosure () -> PathTrie<ArrayObject.Element>
  ) {
    self.paths.array = keyPath.appending(path: \.erasedJSONPath)

    let arrayNode = self.ensureArrayChild()
    let elementPrefix = keyPath.appending(path: \.currentElement)
    let prefixedTrie = elementTrie().prefixed(by: elementPrefix)
    arrayNode.merge(from: prefixedTrie)
  }

  func registerDictionaryHandlerTrie<DictionaryObject: StreamParseableDictionaryObject>(
    keyPath: WritableKeyPath<Value, DictionaryObject>,
    valueTrie: @escaping @autoclosure () -> PathTrie<DictionaryObject.Value>
  ) {
    self.paths.dictionary = keyPath.appending(path: \.erasedJSONPath)

    let anyNode = self.ensureAnyObjectChild()
    anyNode.dynamicKeyBuilder = { key in
      let valuePrefix = keyPath.appending(path: \.[unwrapped: key])
      return valueTrie().prefixed(by: valuePrefix)
    }
  }
}
