public protocol StreamPartial {
  init()

  mutating func next(value: StreamParserValue) throws
}
