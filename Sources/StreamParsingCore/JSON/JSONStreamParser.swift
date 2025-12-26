public struct JSONStreamParser: StreamParser {
  public let configuration: JSONStreamParserConfiguration

  public init(configuration: JSONStreamParserConfiguration = JSONStreamParserConfiguration()) {
    self.configuration = configuration
  }

  public func next(_ bytes: some Sequence<UInt8>) throws -> StreamParserValue {
    .single(.null)
  }
}

extension StreamParser where Self == JSONStreamParser {
  public static var json: Self {
    JSONStreamParser()
  }

  public static func json(configuration: JSONStreamParserConfiguration) -> Self {
    JSONStreamParser(configuration: configuration)
  }
}
