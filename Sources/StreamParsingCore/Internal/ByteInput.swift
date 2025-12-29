enum ByteInput {
  case single(UInt8)
  case sequence(any Sequence<UInt8>)
}
