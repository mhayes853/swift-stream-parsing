public protocol StreamParseableArrayObject<Element> {
  associatedtype Element: StreamParseableValue

  subscript(index: Int) -> Element { get set }
  mutating func append(contentsOf sequence: some Sequence<Element>)
}
