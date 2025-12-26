public struct JSONStreamParser: StreamParser {
  public let configuration: JSONStreamParserConfiguration

  public init(configuration: JSONStreamParserConfiguration = JSONStreamParserConfiguration()) {
    self.configuration = configuration
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
