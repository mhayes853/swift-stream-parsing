import StreamParsing
import Testing

private struct ConvertedPoint: Sendable, Equatable {
  var x: Double
  var y: Double
}
private enum PointConversion: StreamCompletedValueConversion {
  typealias Source = StreamArray<Double>
  enum InvalidPoint: Error { case arity }
  static func convertToValue(_ source: borrowing Source.View) throws(InvalidPoint) -> ConvertedPoint
  {
    guard source.count == 2 else { throw InvalidPoint.arity }
    return ConvertedPoint(x: source[0]!.value, y: source[1]!.value)
  }
  static func convertFromValue(_ value: ConvertedPoint) -> Source { [value.x, value.y] }
}
@StreamParseable
private struct ConvertedGeometry {
  @StreamParseableMember(completedConversion: PointConversion.self)
  var point: ConvertedPoint = ConvertedPoint(x: 0, y: 0)
  @StreamParseableMember(completedConversion: PointConversion.self)
  var optional: ConvertedPoint?
}

@Suite struct CompletedValueDomainTests {
  @Test func destinationNeedsNeitherParseableNorInitializableConformance() throws {
    var stream = PartialsStream<ConvertedGeometry.Partial>(from: .json())
    try stream.next(#"{"point":[1,2],"optional":[3,4]}"#.utf8)
    let partial = try stream.finish()
    let value = try #require(ConvertedGeometry(streamPartial: partial))
    #expect(value.point == ConvertedPoint(x: 1, y: 2))
    #expect(value.optional == ConvertedPoint(x: 3, y: 4))
    let rebuilt = value.streamPartialValue
    #expect(rebuilt.point?.source == [1, 2])
    #expect(rebuilt.optional?.source == [3, 4])
    #expect(ConvertedGeometry(orInitial: .init()).point == ConvertedPoint(x: 0, y: 0))
    #expect(ConvertedGeometry(orInitial: .init()).optional == nil)
  }
}
