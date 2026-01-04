// MARK: - StreamParseableReducer

public protocol StreamParseableReducer {
  static func initialReduceableValue() -> Self
  static func registerSchema(into parser: some StreamParser)
}

// MARK: - Default Initial Values

extension StreamParseableReducer where Self: BinaryInteger {
  public static func initialReduceableValue() -> Self {
    Self()
  }
}

extension StreamParseableReducer where Self: BinaryFloatingPoint {
  public static func initialReduceableValue() -> Self {
    .zero
  }
}

extension StreamParseableReducer {
  public static func registerSchema(into parser: some StreamParser) {
  }
}
