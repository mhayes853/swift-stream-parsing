public protocol StreamParseableDictionaryObject<Value>: StreamParseableValue {
  associatedtype Value: StreamParseableValue

  subscript(key: String) -> Value? { get set }
}

extension StreamParseableDictionaryObject {
  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerDictionaryHandler(\.self)
  }
}
