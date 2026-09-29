import CustomDump
import StreamParsing
import Testing

// The inverse direction: `Partial` back to the whole value it describes.
//
// Two conversions, and the difference between them is the whole point. `init?(_:)` declines when
// the stream did not produce something the type cannot do without; `init(orInitial:)` fills those
// in and keeps whatever did arrive.

@StreamParseable
private struct Author: Equatable {
  var name: String
  var handle: String?
}

@StreamParseable
private struct Post: Equatable {
  var id: Int
  var body: String
  var tags: [String]
  var author: Author?
  var reactions: [String: Int]
}

@StreamParseable(partialMembers: .streamInitialValue)
private struct Counter: Equatable {
  var hits: Int
  var label: String
  var note: String?
}

private enum Stage: String, StreamParseable, StreamInitializable {
  case unknown
  case live

  typealias Partial = StreamString

  static func streamInitialValue() -> Stage { .unknown }
}

@StreamParseable
private struct Job: Equatable {
  var stage: Stage
}

@StreamParseable
private struct WithIgnored: Equatable {
  var id: Int

  @StreamParseableIgnored
  var scratch: String?

  @StreamParseableIgnored
  var counted: Int = 7
}

// Deliberately does not call `finish()`: a truncated document is exactly what the strict
// conversion is there to decline, and finishing would reject it before the conversion saw it.
private func parse<T: StreamParseable>(_ json: String, as type: T.Type) throws -> T.Partial {
  var stream = PartialsStream(initialValue: T.Partial.streamInitialValue(), from: .json())
  for byte in Array(json.utf8) {
    try stream.next(byte)
  }
  return stream.current
}

@Suite
struct `Partial Conversion Tests` {

  // MARK: - Strict

  @Test
  func `Converts A Complete Partial`() throws {
    let partial = Post.Partial(
      id: 1,
      body: "hello",
      tags: ["a", "b"],
      author: Author.Partial(name: "mh", handle: "@mh"),
      reactions: ["up": 2]
    )

    expectNoDifference(
      Post(partial),
      Post(
        id: 1,
        body: "hello",
        tags: ["a", "b"],
        author: Author(name: "mh", handle: "@mh"),
        reactions: ["up": 2]
      )
    )
  }

  @Test
  func `Declines A Partial Missing A Required Member`() {
    let partial = Post.Partial(id: 1, body: nil, tags: ["a"], author: nil, reactions: [:])

    #expect(Post(partial) == nil)
  }

  @Test
  func `Declines A Partial Whose Nested Object Is Half Formed`() {
    // `author` is optional, so its *absence* converts. Its presence in a state the type cannot
    // describe does not: reporting a document that omitted the author and one that truncated
    // inside it as the same `nil` would lose the distinction the parser went to the trouble of
    // keeping.
    let partial = Post.Partial(
      id: 1,
      body: "hello",
      tags: [],
      author: Author.Partial(name: nil, handle: "@mh"),
      reactions: [:]
    )

    #expect(Post(partial) == nil)
  }

  @Test
  func `Converts An Absent Optional Member To Nil`() throws {
    let partial = Post.Partial(id: 1, body: "hello", tags: [], author: nil, reactions: [:])

    expectNoDifference(Post(partial)?.author, nil)
  }

  @Test
  func `Converts An Optional Member Whose Own Optional Member Is Absent`() throws {
    let partial = Post.Partial(
      id: 1,
      body: "hello",
      tags: [],
      author: Author.Partial(name: "mh", handle: nil),
      reactions: [:]
    )

    expectNoDifference(Post(partial)?.author, Author(name: "mh", handle: nil))
  }

  @Test
  func `Declines A Partial Whose Array Element Cannot Be Described`() {
    // A short array is a wrong answer that reads like a right one, so the element takes the
    // whole array down with it rather than being dropped from it.
    let partial = Job.Partial(stage: "nope")

    #expect(Job(partial) == nil)
  }

  // MARK: - Or initial

  @Test
  func `Fills Absent Members With Their Initial Values`() {
    expectNoDifference(
      Post(orInitial: Post.Partial()),
      Post(id: 0, body: "", tags: [], author: nil, reactions: [:])
    )
  }

  @Test
  func `Keeps The Members That Did Arrive`() {
    // The distinguishing property: this is member-wise, so a partial carrying an `id` and nothing
    // else keeps that `id` rather than defaulting the whole value.
    let partial = Post.Partial(id: 7, body: nil, tags: nil, author: nil, reactions: nil)

    expectNoDifference(
      Post(orInitial: partial),
      Post(id: 7, body: "", tags: [], author: nil, reactions: [:])
    )
  }

  @Test
  func `Fills A Nested Object Rather Than Nulling It`() {
    let partial = Post.Partial(
      id: 1,
      body: "hello",
      tags: [],
      author: Author.Partial(name: nil, handle: nil),
      reactions: [:]
    )

    expectNoDifference(Post(orInitial: partial).author, Author(name: "", handle: nil))
  }

  @Test
  func `Leaves A Declared Optional Absent Rather Than Defaulting It`() {
    // `handle` is declared optional, so absence is representable and the fallback must not fire.
    // `name` is not, so it does.
    expectNoDifference(
      Author(orInitial: Author.Partial()),
      Author(name: "", handle: nil)
    )
  }

  @Test
  func `Falls Back To An Enums Named Default`() {
    expectNoDifference(Job(orInitial: Job.Partial(stage: "nope")).stage, .unknown)
    expectNoDifference(Job(orInitial: Job.Partial(stage: "live")).stage, .live)
  }

  // MARK: - Members mode

  @Test
  func `Converts Without Failing When Members Start At Their Initial Values`() {
    // Absence is not expressible in this mode, so the unlabelled initializer is the total one.
    expectNoDifference(Counter(Counter.Partial()), Counter(hits: 0, label: "", note: nil))
  }

  @Test
  func `Keeps Arrived Members In Initial Value Mode`() {
    var partial = Counter.Partial()
    partial.hits = 4
    partial.note = "seen"

    expectNoDifference(Counter(partial), Counter(hits: 4, label: "", note: "seen"))
  }

  // MARK: - Ignored members

  @Test
  func `Sets Ignored Members To Nil Or Their Default`() throws {
    let converted = try #require(WithIgnored(WithIgnored.Partial(id: 3)))

    expectNoDifference(converted, WithIgnored(id: 3, scratch: nil, counted: 7))
  }

  // MARK: - Round trip

  @Test
  func `Round Trips Through The Partial`() throws {
    let original = Post(
      id: 9,
      body: "body",
      tags: ["x", "y"],
      author: Author(name: "mh", handle: nil),
      reactions: ["up": 1, "down": 2]
    )

    expectNoDifference(Post(original.streamPartialValue), original)
  }

  @Test
  func `Round Trips A Value Parsed From Bytes`() throws {
    let json = """
      {"id":9,"body":"body","tags":["x","y"],"author":{"name":"mh"},"reactions":{"up":1}}
      """
    let partial = try parse(json, as: Post.self)

    expectNoDifference(
      Post(partial),
      Post(
        id: 9,
        body: "body",
        tags: ["x", "y"],
        author: Author(name: "mh", handle: nil),
        reactions: ["up": 1]
      )
    )
  }

  @Test
  func `Declines A Value Parsed From Truncated Bytes`() throws {
    let partial = try parse(#"{"id":9,"body":"bo"#, as: Post.self)

    #expect(Post(partial) == nil)
    expectNoDifference(Post(orInitial: partial).id, 9)
  }
}
