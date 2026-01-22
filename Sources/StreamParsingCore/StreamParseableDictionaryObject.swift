/// A dictionary-like value that accepts string keys for element lookup as a ``StreamParser``
/// parses object elements.
public protocol StreamParseableDictionaryObject<Value>: StreamParseableValue {
  /// The value type stored by string keys in the dictionary-like value.
  associatedtype Value: StreamParseableValue

  subscript(key: String) -> Value? { get set }
}

extension StreamParseableDictionaryObject {
  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerDictionaryHandler(\.self)
  }
}
