public protocol StreamParser<StreamAction> {
  associatedtype StreamAction

  mutating func parse(
    bytes: some Sequence<UInt8>,
    into reducer: inout some StreamActionReducer<StreamAction>
  ) throws
}
