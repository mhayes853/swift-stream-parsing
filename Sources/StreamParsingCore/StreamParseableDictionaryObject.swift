public protocol StreamParseableDictionaryObject<Value> {
  associatedtype Value: StreamParseableValue

  subscript(key: String) -> Value? { get set }
}
