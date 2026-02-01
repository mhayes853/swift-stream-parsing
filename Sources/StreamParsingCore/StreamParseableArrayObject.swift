/// An array-like value that can grow as a ``StreamParser`` parses array elements.
public protocol StreamParseableArrayObject<Element>: StreamParseableValue {
  /// The element type stored in the array-like value.
  associatedtype Element: StreamParseableValue

  var count: Int { get }

  subscript(index: Int) -> Element { get set }

  /// Adds more elements as the parser emits them.
  mutating func append(contentsOf sequence: some Sequence<Element>)
}

extension StreamParseableArrayObject {
  public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
    handlers.registerArrayHandler(\.self)
  }
}
