public protocol StreamParser {
  mutating func parse(
    bytes: some Sequence<UInt8>,
    into reducer: inout some StreamActionReducer
  ) throws
}
