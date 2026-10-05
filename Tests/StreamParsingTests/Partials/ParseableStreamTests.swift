import CustomDump
import StreamParsing
import Testing

@StreamParseable
private struct StreamedPost: Equatable {
  var title: String = ""
  var count: Int = 0
  var tags: [String] = []
}

private func finalPartial<Model: StreamParseable>(
  of type: Model.Type,
  _ json: String
) throws -> Model.Partial {
  var stream = PartialsStream<Model>(from: .json())
  try stream.next(Array(json.utf8))
  return try stream.finish()
}

// A stream is generic over what is parsed, and stores that type's `Partial`. These are the
// spellings that name the model rather than its partial.
@Suite
struct `Parseable stream tests` {
  private static let json = #"{"title":"hi","count":2,"tags":["a","b"]}"#

  @Test
  func `A Stream Over A Model Type Parses Into Its Partial`() throws {
    var stream = PartialsStream<StreamedPost>(from: .json())
    try stream.next(Array(Self.json.utf8))
    let partial: StreamedPost.Partial = try stream.finish()

    expectNoDifference(partial.title, "hi")
    expectNoDifference(partial.count, 2)
    expectNoDifference(
      StreamedPost(streamPartial: partial),
      StreamedPost(title: "hi", count: 2, tags: ["a", "b"])
    )
  }

  @Test
  func `A Stream Infers Its Type From The Model Metatype`() throws {
    var stream = PartialsStream(of: StreamedPost.self, from: .json())
    try stream.next(Array(Self.json.utf8))
    expectNoDifference(try stream.finish().count, 2)
  }

  @Test
  func `A Stream Over A Partial Type Is Still Spelled The Old Way`() throws {
    var inferred = PartialsStream(initialValue: StreamedPost.Partial(), from: .json())
    try inferred.next(Array(Self.json.utf8))
    var explicit = PartialsStream<StreamedPost.Partial>(from: .json())
    try explicit.next(Array(Self.json.utf8))

    let fromInference: StreamedPost.Partial = try inferred.finish()
    let fromExplicit: StreamedPost.Partial = try explicit.finish()
    expectNoDifference(fromInference.title, fromExplicit.title)
    expectNoDifference(fromInference.tags?.count, 2)
  }

  @Test
  func `A Model Stream Starts From A Seeded Partial`() throws {
    var seed = StreamedPost.Partial()
    seed.count = 41
    var stream = PartialsStream<StreamedPost>(initialValue: seed, from: .json())
    try stream.next(Array(#"{"title":"x"}"#.utf8))
    let partial = try stream.finish()

    expectNoDifference(partial.count, 41)
    expectNoDifference(partial.title, "x")
  }

  @Test
  func `A Model Stream Resets To Its Initial Partial`() throws {
    var stream = PartialsStream<StreamedPost>(from: .json())
    try stream.next(Array(Self.json.utf8))
    let first = try stream.finishValue(resettingTo: StreamedPost.Partial())
    try stream.next(Array(#"{"count":9}"#.utf8))
    let second = try stream.finishValue()

    expectNoDifference(first.count, 2)
    expectNoDifference(second.count, 9)
    expectNoDifference(second.title, nil)
  }

  @Test
  func `Scalars And Standard Collections Are Parseable Stream Types`() throws {
    var number = PartialsStream<Int>(from: .json())
    try number.next(Array("12".utf8))
    expectNoDifference(try number.finish(), 12)

    // `[Int]` is parsed into its own partial, a `StreamArray<Int>`.
    var array = PartialsStream<[Int]>(from: .json())
    try array.next(Array("[1,2,3]".utf8))
    let partial: StreamArray<Int> = try array.finish()
    expectNoDifference(Array(partial), [1, 2, 3])
  }

  @Test
  func `A Generic Function Streams Any Parseable Type`() throws {
    let partial = try finalPartial(of: StreamedPost.self, Self.json)
    expectNoDifference(partial.count, 2)
    expectNoDifference(try finalPartial(of: Int.self, "7"), 7)
  }

  @Test
  func `Collecting Partials Accepts A Model Or Its Partial Type`() throws {
    let bytes = Array(Self.json.utf8)
    let fromModel: [StreamedPost.Partial] = try bytes.partials(of: StreamedPost.self, from: .json())
    let fromPartial: [StreamedPost.Partial] = try bytes.partials(
      of: StreamedPost.Partial.self,
      from: .json()
    )
    expectNoDifference(fromModel.count, fromPartial.count)
    expectNoDifference(fromModel.last?.title, fromPartial.last?.title)
  }

  @Test
  func `A Field Path Is Rooted At The Model Type`() throws {
    let path = try ObservedFieldPath<StreamedPost, StreamString>(\.title)
    let legacy = try ObservedFieldPath<StreamedPost.Partial, StreamString>(\.title)
    var fromModel = try Array(Self.json.utf8)
      .partialIterator(of: StreamedPost.self, from: .json())
      .observeField(path)
    var fromPartial = try Array(Self.json.utf8)
      .partialIterator(of: StreamedPost.Partial.self, from: .json())
      .observeField(legacy)

    var lastModel: ObservedField<StreamString>?
    var lastPartial: ObservedField<StreamString>?
    while let update = try fromModel.next() { lastModel = update.value }
    while let update = try fromPartial.next() { lastPartial = update.value }
    expectNoDifference(lastModel, lastPartial)
    expectNoDifference(lastModel, .complete("hi"))
  }

  @Test
  func `A Parser Failure Is Reported Once Then As A Failed Parser`() throws {
    var stream = PartialsStream<StreamedPost>(from: .json())
    #expect(throws: (any Error).self) { try stream.next(Array("}".utf8)) }
    #expect(throws: StreamParsingError.parserFailed) { try stream.next(Array("{}".utf8)) }
  }
}
