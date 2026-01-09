public protocol StreamParseableArrayObject<Element>: StreamParseableValue {
  associatedtype Element: StreamParseableValue

  subscript(index: Int) -> Element { get set }
  mutating func append(contentsOf sequence: some Sequence<Element>)
}

extension StreamParseableArrayObject {
  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerArrayHandler(\.self)
  }
}
