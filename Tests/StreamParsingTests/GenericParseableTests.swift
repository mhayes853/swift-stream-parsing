import CustomDump
import StreamParsing
import Testing

@testable import StreamParsingCore

// `@StreamParseable` on generic structs. The generated `Partial` has no stored statics, so its
// schema comes from the per-type cache, and a member typed by a generic parameter is routed from
// its schema when the table is built: a known kind stays on the table, anything else is applied
// through its own schema (`StreamFieldKind.delegated`).

// MARK: - Declarations

@StreamParseable
private struct Box<Value: StreamParseable & Equatable>: Equatable {
  var value: Value
  var label: String
}

@StreamParseable
private struct Page<Item: StreamParseable & Equatable>: Equatable {
  var items: [Item]
  var byName: [String: Item]
  var maybeItems: [Item?]
  var featured: Item?
  var cursor: String?
  var count: Int
  var point: Point?
  @StreamParseableIgnored
  var scratch: Item? = nil
}

@StreamParseable
private struct Point: Equatable {
  var x: Double
  var y: Double
}

// Only a phantom: nothing parsed names it, so it needs no constraint.
@StreamParseable
private struct Phantom<Tag>: Equatable {
  var id: Int
}

@StreamParseable(partialMembers: .streamInitialValue)
private struct InitializedBox<Value: StreamParseable & Equatable>: Equatable {
  var value: Value
  var values: [Value]
}

// Internal: a type nested in a private one cannot take the generated members' default access.
struct GenericOuter<Value: StreamParseable & Equatable> {
  // Generic through its context alone.
  @StreamParseable
  struct Inner: Equatable {
    var value: Value
    var n: Int
  }
}

private enum Doubling: StreamCompletedValueConversion {
  typealias Source = Int
  static func convertToValue(_ source: borrowing Source.View) -> Int { source.value * 2 }
  static func convertFromValue(_ value: Int) -> Int { value / 2 }
}

private enum Uppercased: StreamCompletedValueConversion {
  typealias Source = StreamString
  static func convertToValue(_ source: borrowing Source.View) -> String {
    String(source.value).uppercased()
  }
  static func convertFromValue(_ value: String) -> StreamString { StreamString(value.lowercased()) }
}

@StreamParseable
private struct Converted<Value: StreamParseable & Equatable>: Equatable {
  @StreamParseableMember(completedConversion: Doubling.self)
  var doubled: Int = 0
  @StreamParseableMember(completedConversion: Uppercased.self)
  var shout: String? = nil
  var value: Value
}

// A string scalar the table has no layout for, so a generic member of it is `delegated`.
private struct Slug: StreamStringConvertible, StreamParseable, StreamParseableRoot, Equatable {
  typealias Partial = Self
  var text = ""
  static func streamInitialValue() -> Self { Self() }
  mutating func streamAppend(utf8 bytes: Span<UInt8>) -> StreamApplyResult {
    for index in bytes.indices { self.text.unicodeScalars.append(Unicode.Scalar(bytes[index])) }
    return .applied
  }
}

// A number scalar the table has no layout for.
private struct Celsius: StreamNumberConvertible, StreamInitializable, Equatable {
  var degrees: Double
  static func streamInitialValue() -> Self { Self(degrees: 0) }
  init(degrees: Double) { self.degrees = degrees }
  init?(streamParsing bytes: Span<UInt8>, info: NumberInfo) {
    guard let value = Double(streamParsing: bytes, info: info) else { return nil }
    self.degrees = value
  }
}

extension Celsius: StreamParseable, StreamParseableRoot {
  typealias Partial = Self
}

// The conformance the macro cannot add, declared by the host.
extension Box.Partial: Sendable where Value.Partial: Sendable {}

// MARK: - Helpers

private func parsed<Root: StreamParseableRoot>(
  _ json: String, as type: Root.Type, chunk: Int = .max
) throws -> Root {
  var value = Root.streamInitialValue()
  try parsePartial(json, into: &value, chunk: chunk)
  return value
}

private func failure<Root: StreamParseableRoot>(
  _ json: String, as type: Root.Type
) -> StreamSinkFailure.Reason? {
  var value = Root.streamInitialValue()
  return streamFailureReason(json, into: &value)
}

private let chunks = [Int.max, 7, 1]

// MARK: - Tests

@Suite
struct `Generic Parseable Tests` {
  @Test(arguments: chunks)
  func `A known kind behind a generic parameter`(chunk: Int) throws {
    let int = try parsed(#"{"value":3,"label":"x"}"#, as: Box<Int>.Partial.self, chunk: chunk)
    expectNoDifference(Box(int), Box(value: 3, label: "x"))
    let string = try parsed(
      #"{"value":"héllo \"q\"","label":"y"}"#, as: Box<String>.Partial.self, chunk: chunk
    )
    expectNoDifference(Box(string), Box(value: "héllo \"q\"", label: "y"))
    let flag = try parsed(#"{"value":true}"#, as: Box<Bool>.Partial.self, chunk: chunk)
    expectNoDifference(flag.value, true)
  }

  @Test
  func `A known kind is routed by the table`() {
    let entry = Box<Int>.Partial.streamSchema.fieldEntries.unsafelyUnwrapped
    expectNoDifference(entry.pointee.kind, .int)
    expectNoDifference(entry.pointee.isOptional, true)
    let string = Box<String>.Partial.streamSchema.fieldEntries.unsafelyUnwrapped
    expectNoDifference(string.pointee.kind, .streamString)
    let slug = Box<Slug>.Partial.streamSchema.fieldEntries.unsafelyUnwrapped
    expectNoDifference(slug.pointee.kind, .delegated)
    let point = Box<Point>.Partial.streamSchema.fieldEntries.unsafelyUnwrapped
    expectNoDifference(point.pointee.kind, .container)
  }

  @Test(arguments: chunks)
  func `A custom scalar behind a generic parameter is delegated`(chunk: Int) throws {
    let slug = try parsed(#"{"value":"a-b","label":"s"}"#, as: Box<Slug>.Partial.self, chunk: chunk)
    expectNoDifference(Box(slug), Box(value: Slug(text: "a-b"), label: "s"))
    let celsius = try parsed(#"{"value":-4.5}"#, as: Box<Celsius>.Partial.self, chunk: chunk)
    expectNoDifference(celsius.value, Celsius(degrees: -4.5))
  }

  @Test
  func `A delegated member takes null and rejects a mismatch`() throws {
    var value = try parsed(#"{"value":"a","label":"s"}"#, as: Box<Slug>.Partial.self)
    try parsePartial(#"{"value":null}"#, into: &value)
    expectNoDifference(value.value, nil)
    expectNoDifference(value.label.map(String.init), "s")
    expectNoDifference(failure(#"{"value":1}"#, as: Box<Slug>.Partial.self), .typeMismatch)
    expectNoDifference(failure(#"{"value":{}}"#, as: Box<Slug>.Partial.self), .typeMismatch)
    expectNoDifference(failure(#"{"value":"x"}"#, as: Box<Celsius>.Partial.self), .typeMismatch)
    expectNoDifference(failure(#"{"value":"x"}"#, as: Box<Int>.Partial.self), .typeMismatch)
  }

  @Test(arguments: chunks)
  func `An object behind a generic parameter`(chunk: Int) throws {
    let point = try parsed(
      #"{"value":{"x":1,"y":2},"label":"p"}"#, as: Box<Point>.Partial.self, chunk: chunk
    )
    expectNoDifference(Box(point), Box(value: Point(x: 1, y: 2), label: "p"))
    var cleared = point
    try parsePartial(#"{"value":null}"#, into: &cleared)
    #expect(cleared.value == nil)
    let nested = try parsed(
      #"{"value":{"value":7,"label":"in"},"label":"out"}"#, as: Box<Box<Int>>.Partial.self,
      chunk: chunk
    )
    expectNoDifference(Box(nested), Box(value: Box(value: 7, label: "in"), label: "out"))
  }

  @Test(arguments: chunks)
  func `Containers of a generic parameter`(chunk: Int) throws {
    let json = #"""
      {"items":[{"x":1,"y":2},{"x":3,"y":4}],"byName":{"a":{"x":5,"y":6}},
       "maybeItems":[null,{"x":7,"y":8}],"featured":{"x":9,"y":10},"cursor":"c","count":2,
       "point":{"x":0.5,"y":-0.5},"scratch":{"x":0,"y":0}}
      """#
    let page = try parsed(json, as: Page<Point>.Partial.self, chunk: chunk)
    expectNoDifference(
      Page(page),
      Page(
        items: [Point(x: 1, y: 2), Point(x: 3, y: 4)], byName: ["a": Point(x: 5, y: 6)],
        maybeItems: [nil, Point(x: 7, y: 8)], featured: Point(x: 9, y: 10), cursor: "c",
        count: 2, point: Point(x: 0.5, y: -0.5)
      )
    )
    let ints = try parsed(
      #"{"items":[1,2,3],"byName":{"k":4},"maybeItems":[5,null],"featured":6,"count":0}"#,
      as: Page<Int>.Partial.self, chunk: chunk
    )
    expectNoDifference(
      Page(ints),
      Page(
        items: [1, 2, 3], byName: ["k": 4], maybeItems: [5, nil], featured: 6, cursor: nil,
        count: 0, point: nil
      )
    )
    let slugs = try parsed(
      #"{"items":["a"],"byName":{},"maybeItems":[],"featured":"f","count":1}"#,
      as: Page<Slug>.Partial.self, chunk: chunk
    )
    expectNoDifference(slugs.featured, Slug(text: "f"))
    expectNoDifference(slugs.items.map(Array.init), [Slug(text: "a")])
  }

  // A null is the parameter's own: `Box<Int?>` reads it as a present `nil`, as `Codable` does,
  // and an absent member stays absent, so the strict conversion still fails on it.
  @Test(arguments: chunks)
  func `An optional generic parameter`(chunk: Int) throws {
    let value = try parsed(#"{"value":null,"label":"n"}"#, as: Box<Int?>.Partial.self, chunk: chunk)
    expectNoDifference(Box(value), Box(value: nil, label: "n"))
    let present = try parsed(#"{"value":4,"label":"n"}"#, as: Box<Int?>.Partial.self, chunk: chunk)
    expectNoDifference(Box(present), Box(value: 4, label: "n"))
    let absent = try parsed(#"{"label":"n"}"#, as: Box<Int?>.Partial.self, chunk: chunk)
    #expect(Box(absent) == nil)

    let point = try parsed(#"{"value":null,"label":"p"}"#, as: Box<Point?>.Partial.self, chunk: chunk)
    expectNoDifference(Box(point), Box(value: nil, label: "p"))
    var reset = try parsed(#"{"value":{"x":1,"y":2},"label":"p"}"#, as: Box<Point?>.Partial.self)
    expectNoDifference(Box(reset), Box(value: Point(x: 1, y: 2), label: "p"))
    try parsePartial(#"{"value":null}"#, into: &reset)
    expectNoDifference(Box(reset), Box(value: nil, label: "p"))

    let slug = try parsed(#"{"value":null}"#, as: InitializedBox<Slug?>.Partial.self, chunk: chunk)
    expectNoDifference(InitializedBox(slug), InitializedBox(value: nil, values: []))
    let object = try parsed(#"{"value":null}"#, as: InitializedBox<Point?>.Partial.self, chunk: chunk)
    expectNoDifference(InitializedBox(object), InitializedBox(value: nil, values: []))
    expectNoDifference(failure(#"{"value":null}"#, as: InitializedBox<Slug>.Partial.self), .typeMismatch)
  }

  @Test(arguments: chunks)
  func `Initialised members behind a generic parameter`(chunk: Int) throws {
    let initial = InitializedBox<Slug>.Partial()
    expectNoDifference(initial.value, Slug())
    let value = try parsed(
      #"{"value":"s","values":["t","u"]}"#, as: InitializedBox<Slug>.Partial.self, chunk: chunk
    )
    expectNoDifference(
      InitializedBox(value), InitializedBox(value: Slug(text: "s"), values: [Slug(text: "t"), Slug(text: "u")])
    )
    let ints = try parsed(#"{"value":8}"#, as: InitializedBox<Int>.Partial.self, chunk: chunk)
    expectNoDifference(InitializedBox(ints), InitializedBox(value: 8, values: []))
  }

  @Test
  func `A struct nested in a generic type`() throws {
    let inner = try parsed(#"{"value":"v","n":1}"#, as: GenericOuter<Slug>.Inner.Partial.self)
    expectNoDifference(GenericOuter<Slug>.Inner(inner), GenericOuter<Slug>.Inner(value: Slug(text: "v"), n: 1))
  }

  @Test
  func `A phantom parameter`() throws {
    let value = try parsed(#"{"id":5}"#, as: Phantom<Never>.Partial.self)
    expectNoDifference(Phantom<Never>(value), Phantom(id: 5))
  }

  @Test(arguments: chunks)
  func `A converted member in a generic type`(chunk: Int) throws {
    let value = try parsed(
      #"{"doubled":4,"shout":"hey \u00e9","value":1}"#, as: Converted<Int>.Partial.self, chunk: chunk
    )
    expectNoDifference(Converted(value), Converted(doubled: 8, shout: "HEY É", value: 1))
    var cleared = value
    try parsePartial(#"{"shout":null}"#, into: &cleared)
    expectNoDifference(Converted(cleared), Converted(doubled: 8, shout: nil, value: 1))
  }

  @Test
  func `One schema per specialisation`() {
    #expect(Box<Int>.Partial.streamSchema === Box<Int>.Partial.streamSchema)
    #expect(Box<Int>.Partial.streamSchema !== Box<Double>.Partial.streamSchema)
    #expect(Page<Point>.Partial.streamSchema === Page<Point>.Partial.streamSchema)
  }

  @Test
  func `Snapshots from the async sequence`() async throws {
    let input = Array(#"{"value":2,"label":"a"}"#.utf8)
    var last: Box<Int>.Partial?
    for try await partial in input.async.partials(of: Box<Int>.self, from: .json()) {
      last = partial
    }
    expectNoDifference(last.flatMap { Box<Int>(streamPartial: $0) }, Box(value: 2, label: "a"))
  }
}

extension Array where Element == UInt8 {
  fileprivate var async: AsyncStream<UInt8> {
    AsyncStream { continuation in
      for byte in self { continuation.yield(byte) }
      continuation.finish()
    }
  }
}
