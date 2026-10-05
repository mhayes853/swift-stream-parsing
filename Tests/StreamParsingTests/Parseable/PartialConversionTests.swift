import CustomDump
import StreamParsing
import Testing

// The inverse direction: `Partial` back to the whole value it describes.
//
// Two conversions, and the difference between them is the whole point. `init?(streamPartial:)`
// declines when the stream did not produce something the type cannot do without;
// `init(orInitial:)` fills those in and keeps whatever did arrive.

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

// `partial` is also the name of the strict initializer's parameter, and it is not the last member,
// so a generated local named after it would shadow the parameter `text` is then read from.
@StreamParseable
private struct Chunk: Equatable {
  var partial: Bool
  var text: String
}

// A lazy member is derived, like a computed one: it is not parsed, and its initializer sets it.
@StreamParseable
private struct WithLazy {
  var id: Int
  lazy var label: String = "#\(id)"
}

// Declared in access-modified extensions with no modifier of their own, so both types (and their
// conformances) take the extension's access, and the generated members have to match it.
public struct AccessOuter {}

public extension AccessOuter {
  @StreamParseable
  struct Inner: Equatable {
    public var x: Int
  }
}

package extension AccessOuter {
  @StreamParseable
  enum Kind: String {
    @StreamParseableDefault
    case a
    case b
  }
}

// Deliberately does not call `finish()`: a truncated document is exactly what the strict
// conversion is there to decline, and finishing would reject it before the conversion saw it.
private func parse<T: StreamParseable>(_ json: String, as type: T.Type) throws -> T.Partial {
  var stream = PartialsStream<T>(from: .json())
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
      Post(streamPartial: partial),
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

    #expect(Post(streamPartial: partial) == nil)
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

    #expect(Post(streamPartial: partial) == nil)
  }

  @Test
  func `Converts An Absent Optional Member To Nil`() throws {
    let partial = Post.Partial(id: 1, body: "hello", tags: [], author: nil, reactions: [:])

    expectNoDifference(Post(streamPartial: partial)?.author, nil)
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

    expectNoDifference(Post(streamPartial: partial)?.author, Author(name: "mh", handle: nil))
  }

  @Test
  func `Declines A Partial Whose Array Element Cannot Be Described`() {
    // A short array is a wrong answer that reads like a right one, so the element takes the
    // whole array down with it rather than being dropped from it.
    let partial = Job.Partial(stage: "nope")

    #expect(Job(streamPartial: partial) == nil)
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
    // Absence is not expressible in this mode, so the total conversion has nothing to default.
    expectNoDifference(
      Counter(orInitial: Counter.Partial()), Counter(hits: 0, label: "", note: nil)
    )
  }

  @Test
  func `Keeps Arrived Members In Initial Value Mode`() {
    var partial = Counter.Partial()
    partial.hits = 4
    partial.note = "seen"

    expectNoDifference(Counter(orInitial: partial), Counter(hits: 4, label: "", note: "seen"))
  }

  // MARK: - Ignored members

  @Test
  func `Sets Ignored Members To Nil Or Their Default`() throws {
    let converted = try #require(WithIgnored(streamPartial: WithIgnored.Partial(id: 3)))

    expectNoDifference(converted, WithIgnored(id: 3, scratch: nil, counted: 7))
  }

  // MARK: - Access

  @Test
  func `Converts Types Declared In Access Modified Extensions`() throws {
    let inner = try parse(#"{"x":4}"#, as: AccessOuter.Inner.self)
    expectNoDifference(AccessOuter.Inner(streamPartial: inner), AccessOuter.Inner(x: 4))
    expectNoDifference(AccessOuter.Kind(streamPartial: StreamString("b")), .b)
  }

  // MARK: - Lazy members

  @Test
  func `Leaves A Lazy Member To Its Initializer`() throws {
    let partial = try parse(#"{"id":3,"label":"x"}"#, as: WithLazy.self)
    var converted = try #require(WithLazy(streamPartial: partial))

    #expect(converted.id == 3)
    #expect(converted.label == "#3")
  }

  // MARK: - Member names

  @Test
  func `Converts A Member Named Like The Initializer Parameter`() throws {
    let partial = try parse(#"{"partial":true,"text":"hi"}"#, as: Chunk.self)

    expectNoDifference(Chunk(streamPartial: partial), Chunk(partial: true, text: "hi"))
    expectNoDifference(
      Chunk(orInitial: Chunk.Partial(partial: nil, text: "hi")),
      Chunk(partial: false, text: "hi")
    )
    #expect(Chunk(streamPartial: Chunk.Partial(partial: true, text: nil)) == nil)
  }

  // MARK: - Library conformances

  @Test
  func `Library Conformances Leave Unapplied Initializers To Their Types`() {
    // `init(orInitial:)` takes the same argument as these types' own `init(_:)`; an unapplied
    // reference has no label to tell them apart, so the library's is disfavored.
    expectNoDifference(Optional(StreamString("s")).map(String.init), "s")
    expectNoDifference([StreamArray([1, 2])].map(Array.init), [[1, 2]])
    expectNoDifference(String(orInitial: StreamString("t")), "t")
    expectNoDifference([Int](orInitial: StreamArray([3])), [3])
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

    expectNoDifference(Post(streamPartial: original.streamPartialValue), original)
  }

  @Test
  func `Round Trips A Value Parsed From Bytes`() throws {
    let json = """
      {"id":9,"body":"body","tags":["x","y"],"author":{"name":"mh"},"reactions":{"up":1}}
      """
    let partial = try parse(json, as: Post.self)

    expectNoDifference(
      Post(streamPartial: partial),
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

    #expect(Post(streamPartial: partial) == nil)
    expectNoDifference(Post(orInitial: partial).id, 9)
  }
}
