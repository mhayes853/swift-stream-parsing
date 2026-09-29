import CustomDump
import Testing

import StreamParsing
import StreamParsingCore

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
@StreamParseable
private struct InlineArrayChild {
  var id: Int = 0
  var name: String = ""
}

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
@StreamParseable
private struct InlineArrayFields {
  var strings: InlineArray<2, String> = InlineArray(repeating: "")
  var booleans: InlineArray<3, Bool> = InlineArray(repeating: false)
  var numbers: InlineArray<4, Double> = InlineArray(repeating: 0)
  var children: InlineArray<2, InlineArrayChild> = InlineArray { _ in InlineArrayChild() }
}

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
@StreamParseable
private struct OptionalInlineArrayFields {
  var names: InlineArray<2, String?> = InlineArray(repeating: nil)
  var lists: InlineArray<2, [Int]?> = InlineArray(repeating: nil)
}

@Suite
struct `InlineArray parsing tests` {
  private func parse<Root: StreamParseableRoot>(
    _ json: String,
    as type: Root.Type,
    chunk: Int = .max
  ) throws -> Root {
    var value = Root.streamInitialValue()
    try parsePartial(json, into: &value, chunk: chunk)
    return value
  }

  private func failure<Root: StreamParseableRoot>(
    _ json: String,
    as type: Root.Type
  ) -> StreamSinkFailure.Reason? {
    streamFailureReason(json, as: type)
  }

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test(arguments: [Int.max, 7, 1])
  func `Scalar elements parse at fixed indices`(chunk: Int) throws {
    let numbers = try self.parse("[1,-2,3]", as: InlineArray<3, Int>.self, chunk: chunk)
    expectNoDifference(numbers[0], 1)
    expectNoDifference(numbers[1], -2)
    expectNoDifference(numbers[2], 3)

    let booleans = try self.parse(
      "[true,false,true]", as: InlineArray<3, Bool>.self, chunk: chunk
    )
    expectNoDifference(booleans[0], true)
    expectNoDifference(booleans[1], false)
    expectNoDifference(booleans[2], true)

    let strings = try self.parse(
      #"["alpha","beta"]"#, as: InlineArray<2, String>.self, chunk: chunk
    )
    expectNoDifference(strings[0], "alpha")
    expectNoDifference(strings[1], "beta")
  }

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test(arguments: [Int.max, 7, 1])
  func `Objects nested arrays optionals and dictionaries compose`(chunk: Int) throws {
    let children = try self.parse(
      #"[{"id":1,"name":"A"},{"id":2,"name":"B"}]"#,
      as: InlineArray<2, InlineArrayChild.Partial>.self,
      chunk: chunk
    )
    expectNoDifference(children[0].id, 1)
    expectNoDifference(children[0].name, "A")
    expectNoDifference(children[1].id, 2)
    expectNoDifference(children[1].name, "B")

    let nested = try self.parse(
      "[[1,2],[3,4]]", as: InlineArray<2, InlineArray<2, Int>>.self, chunk: chunk
    )
    expectNoDifference(nested[0][0], 1)
    expectNoDifference(nested[0][1], 2)
    expectNoDifference(nested[1][0], 3)
    expectNoDifference(nested[1][1], 4)

    let optional = try self.parse(
      "[1,null,3]", as: InlineArray<3, Int?>.self, chunk: chunk
    )
    expectNoDifference(optional[0], 1)
    expectNoDifference(optional[1], nil)
    expectNoDifference(optional[2], 3)

    let dictionary = try self.parse(
      #"{"a":[1,2]}"#,
      as: StreamDictionary<InlineArray<2, Int>>.self,
      chunk: chunk
    )
    expectNoDifference(dictionary["a"]?[0], 1)
    expectNoDifference(dictionary["a"]?[1], 2)

    let optionalRoot = try self.parse(
      "[5,6]", as: InlineArray<2, Int>?.self, chunk: chunk
    )
    expectNoDifference(optionalRoot?[0], 5)
    expectNoDifference(optionalRoot?[1], 6)
  }

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test
  func `A zero length InlineArray accepts only an empty array`() throws {
    _ = try self.parse("[]", as: InlineArray<0, Int>.self)
    expectNoDifference(self.failure("[1]", as: InlineArray<0, Int>.self), .capacityExceeded)
  }

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test(arguments: [Int.max, 7, 1])
  func `Macro fields resolve InlineArray as a container`(chunk: Int) throws {
    let value = try self.parse(
      #"{"strings":["a","b"],"booleans":[true,false,true],"numbers":[1,2,3,4],"children":[{"id":5,"name":"E"},{"id":6,"name":"F"}]}"#,
      as: InlineArrayFields.Partial.self,
      chunk: chunk
    )
    expectNoDifference(value.strings?[0], "a")
    expectNoDifference(value.strings?[1], "b")
    expectNoDifference(value.booleans?[1], false)
    expectNoDifference(value.numbers?[3], 4)
    expectNoDifference(value.children?[0].id, 5)
    expectNoDifference(value.children?[1].name, "F")
  }

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test(arguments: ["[]", "[1]", "[1,true]", #"[1,"two"]"#, "[1,[]]"])
  func `Short arity and wrong element shapes are rejected`(json: String) {
    expectNoDifference(self.failure(json, as: InlineArray<2, Int>.self), .typeMismatch)
  }

  // The container frame carries the element's inline capacity: without it every inline string in
  // an `InlineArray` is refused with `.capacityExceeded` on its first non-empty chunk.
  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test(arguments: [Int.max, 7, 1])
  func `Inline string elements use the element's capacity`(chunk: Int) throws {
    let strings = try self.parse(
      #"["ab","cd"]"#, as: InlineArray<2, StreamInlineString<16>>.self, chunk: chunk
    )
    expectNoDifference(String(strings[0]), "ab")
    expectNoDifference(String(strings[1]), "cd")
  }

  // The same capacity is what places an optional element's nil tag after the payload rather than
  // on top of its first byte.
  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test(arguments: [Int.max, 7, 1])
  func `Optional inline string elements round trip a null`(chunk: Int) throws {
    let strings = try self.parse(
      #"["ab",null]"#, as: InlineArray<2, StreamInlineString<16>?>.self, chunk: chunk
    )
    expectNoDifference(strings[0].map(String.init), "ab")
    expectNoDifference(strings[1].map(String.init), nil)

    let reversed = try self.parse(
      #"[null,"cd"]"#, as: InlineArray<2, StreamInlineString<16>?>.self, chunk: chunk
    )
    expectNoDifference(reversed[0].map(String.init), nil)
    expectNoDifference(reversed[1].map(String.init), "cd")
  }

  // More elements than the arity is bounded storage overflowing, the same failure an inline
  // string reports, and distinct from an array that simply closes short.
  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test(arguments: ["[1,2,3]", "[1,2,3,4]"])
  func `More elements than the arity is a capacity failure`(json: String) {
    expectNoDifference(self.failure(json, as: InlineArray<2, Int>.self), .capacityExceeded)
  }

  // An `InlineArray` slot exists before the document reaches it, so an optional element starts
  // `nil` and has to be materialised by its first write. A `StreamArray` opens its element `.some`
  // and writes straight through; these slots were written through the same way, into a payload
  // that was not there.
  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test(arguments: [Int.max, 7, 1])
  func `Optional elements are materialised before they are written`(chunk: Int) throws {
    let strings = try self.parse(#"["ab",null]"#, as: InlineArray<2, String?>.self, chunk: chunk)
    expectNoDifference([strings[0], strings[1]], ["ab", nil])

    let streamed = try self.parse(#"["ab","cd"]"#, as: InlineArray<2, StreamString?>.self, chunk: chunk)
    expectNoDifference([streamed[0].map(String.init), streamed[1].map(String.init)], ["ab", "cd"])

    let arrays = try self.parse("[[1],null]", as: InlineArray<2, StreamArray<Int>?>.self, chunk: chunk)
    expectNoDifference([arrays[0].map(Array.init), arrays[1].map(Array.init)], [[1], nil])

    let numbers = try self.parse("[1,null,3]", as: InlineArray<3, Int?>.self, chunk: chunk)
    expectNoDifference([numbers[0], numbers[1], numbers[2]], [1, nil, 3])

    var fields = OptionalInlineArrayFields.Partial()
    try parsePartial(#"{"names":["a",null],"lists":[null,[2,3]]}"#, into: &fields, chunk: chunk)
    expectNoDifference(fields.names.map { [$0[0].map(String.init), $0[1].map(String.init)] }, ["a", nil])
    expectNoDifference(fields.lists.map { [$0[0].map(Array.init), $0[1].map(Array.init)] }, [nil, [2, 3]])
  }

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test
  func `Optional elements the document has not reached yet are nil`() throws {
    var stream = PartialsStream<InlineArray<2, String?>>(from: .json())
    try stream.next(Array(#"["ab","#.utf8))
    expectNoDifference([stream.current[0], stream.current[1]], ["ab", nil])
  }

  // Still open: a fixed-lane element (a SIMD vector, a nested `InlineArray`) is written lane by
  // lane through its stride, with no schema closure to materialise the optional first, so the
  // lanes land in the payload of a `nil`. Materialising at the slot needs a per-element prepare
  // in the sink's indexed open, which is a hot path.
  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test
  func `Optional fixed-lane elements are materialised before they are written`() throws {
    let vectors = try self.parse("[[1,2],null]", as: InlineArray<2, SIMD2<Double>?>.self)
    withKnownIssue("Fixed-lane elements are stored without materialising the optional") {
      expectNoDifference([vectors[0], vectors[1]], [SIMD2(1, 2), nil])
    }
  }
}
