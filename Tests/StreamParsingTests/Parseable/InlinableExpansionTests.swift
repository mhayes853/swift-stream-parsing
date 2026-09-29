import CustomDump
import StreamParsing
import Testing

// Public and package models, so the `@inlinable` expansion is type-checked here: an inlinable body
// may only name public, package or `@usableFromInline` declarations, and nothing else in this
// target is public. The cross-module use itself is `Benchmarks/StreamParsingBenchmarkModels`.

@StreamParseable
public struct InlinablePerson: Equatable {
  public var name: String
  // Internal, so `streamPartialValue` must stay out of line while the rest is inlinable.
  var age: Int
  public private(set) var tags: [String]
}

@StreamParseable
package struct InlinablePackagePerson: Equatable {
  package var name: String
  @usableFromInline var nickname: String?
}

@StreamParseable
public struct InlinableTextBlock: Equatable {
  public var body: String
}

@StreamParseable
public enum InlinableBlock: Equatable {
  @StreamParseableDefault
  case empty
  case text(InlinableTextBlock)
  case image(url: String, width: Int?)
}

@StreamParseable
public enum InlinableStage: String {
  @StreamParseableDefault
  case idle
  case live
}

@StreamParseable
public enum InlinableLevel: Int {
  @StreamParseableDefault
  case low = 0
  case high = 1
}

private func parse<T: StreamParseable>(_ json: String, as type: T.Type) throws -> T.Partial {
  var stream = PartialsStream(initialValue: T.Partial.streamInitialValue(), from: .json())
  try stream.next(Array(json.utf8))
  return stream.current
}

@Suite
struct `Inlinable Expansion Tests` {
  @Test
  func `A public struct with an internal member parses and converts`() throws {
    let partial = try parse(#"{"name":"a","age":3,"tags":["x"]}"#, as: InlinablePerson.self)
    expectNoDifference(
      InlinablePerson(streamPartial: partial),
      InlinablePerson(name: "a", age: 3, tags: ["x"])
    )
    let person = InlinablePerson(name: "b", age: 4, tags: [])
    expectNoDifference(InlinablePerson(streamPartial: person.streamPartialValue), person)
  }

  @Test
  func `A package struct parses and reads through its view`() throws {
    var stream = PartialsStream(initialValue: InlinablePackagePerson.Partial(), from: .json())
    try stream.next(Array(#"{"name":"a","nickname":"b"}"#.utf8))
    stream.withView { partial in
      guard let nickname = partial.nickname else {
        Issue.record("expected a nickname")
        return
      }
      expectNoDifference(String(streamPartial: nickname.value), "b")
    }
    expectNoDifference(
      InlinablePackagePerson(orInitial: stream.current),
      InlinablePackagePerson(name: "a", nickname: "b")
    )
  }

  @Test
  func `Public enums resolve in every lowering`() throws {
    let image = try parse(#"{"image":{"url":"u"}}"#, as: InlinableBlock.self)
    expectNoDifference(InlinableBlock(streamPartial: image), .image(url: "u", width: nil))
    let text = try parse(#"{"text":{"_0":{"body":"hi"}}}"#, as: InlinableBlock.self)
    expectNoDifference(InlinableBlock(streamPartial: text), .text(InlinableTextBlock(body: "hi")))
    expectNoDifference(InlinableBlock.streamValueOrInitial(from: InlinableBlock.Partial()), .empty)
    expectNoDifference(InlinableStage(streamPartial: StreamString("li")), .live)
    expectNoDifference(InlinableLevel.streamValueOrInitial(from: 7), .low)
  }
}
