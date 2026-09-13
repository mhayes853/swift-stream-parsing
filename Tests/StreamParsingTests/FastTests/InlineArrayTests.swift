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
    do {
      _ = try self.parse(json, as: type)
      return nil
    } catch let error as JSONParsingError {
      guard case .sinkRejectedToken(let failure) = error.reason else { return nil }
      return failure.reason
    } catch {
      return nil
    }
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

  // More elements than the arity is bounded storage overflowing, the same failure an inline
  // string reports, and distinct from an array that simply closes short.
  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test(arguments: ["[1,2,3]", "[1,2,3,4]"])
  func `More elements than the arity is a capacity failure`(json: String) {
    expectNoDifference(self.failure(json, as: InlineArray<2, Int>.self), .capacityExceeded)
  }
}
