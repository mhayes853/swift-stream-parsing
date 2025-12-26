// MARK: - StreamParserValue

public indirect enum StreamParserValue {
  case single(StreamedValue)
  case unkeyed(index: Int, Self)
  case keyed(key: String, Self)
}

// MARK: - StreamParser

public protocol StreamParser {
  func next(_ bytes: some Sequence<UInt8>) throws -> StreamParserValue
}
