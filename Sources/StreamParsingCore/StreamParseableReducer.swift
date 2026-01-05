// MARK: - StreamParseableValue

public protocol StreamParseableValue {
  static func initialParseableValue() -> Self
  static func registerHandlers<Handlers: StreamParserHandlers<Self>>(
    in handlers: inout Handlers
  )
}

extension StreamParseableValue where Self: BinaryInteger {
  public static func initialParseableValue() -> Self {
    Self()
  }
}

extension StreamParseableValue where Self: BinaryFloatingPoint {
  public static func initialParseableValue() -> Self {
    .zero
  }
}

// MARK: - StreamParseableArrayObject

public protocol StreamParseableArrayObject<Element> {
  associatedtype Element: StreamParseableValue

  subscript(index: Int) -> Element { get set }

  mutating func append(contentsOf sequence: some Sequence<Element>)
}
