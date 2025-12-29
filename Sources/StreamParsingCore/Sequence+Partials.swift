// MARK: - PartialsSequence

extension Sequence where Element == UInt8 {
  public func partials<Parseable: StreamParseable, Parser: StreamParser>(
    of parseable: Parseable.Type,
    from parser: Parser
  ) throws -> [Parseable.Partial] where Parseable.Partial.StreamAction == Parser.StreamAction {
    var stream = PartialsStream(of: Parseable.self, from: parser)
    var partials = [Parseable.Partial]()
    partials.reserveCapacity(self.underestimatedCount)
    for bytes in self {
      partials.append(try stream.next(bytes))
    }
    return partials
  }
}

extension Sequence where Element: Sequence<UInt8> {
  public func partials<Parseable: StreamParseable, Parser: StreamParser>(
    of parseable: Parseable.Type,
    from parser: Parser
  ) throws -> [Parseable.Partial] where Parseable.Partial.StreamAction == Parser.StreamAction {
    var stream = PartialsStream(of: Parseable.self, from: parser)
    var partials = [Parseable.Partial]()
    partials.reserveCapacity(self.underestimatedCount)
    for bytes in self {
      partials.append(try stream.next(bytes))
    }
    return partials
  }
}
