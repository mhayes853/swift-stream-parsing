import CustomDump
import Testing

import StreamParsing
import StreamParsingCore

@StreamParseable
struct RootUser: Equatable {
  var id: Int = 0
  var name: String = ""
}

extension RootUser.Partial: Equatable {}

// A JSON document is not required to be an object, and the public parsing entry points have
// always accepted a scalar, an array or a dictionary as the destination. The root's shape comes
// from its schema, which a generic caller reaches through StreamParseableRoot rather than
// through the overloads the macro uses, because an overload resolves where it is written.
@Suite
struct `Partial sink root tests` {
  private func parse<Root: StreamParseableRoot>(
    _ json: String, as type: Root.Type, chunk: Int = .max
  ) throws -> Root {
    var value = Root.streamInitialValue()
    try parsePartial(json, into: &value, chunk: chunk)
    return value
  }

  // MARK: - Scalar roots

  @Test(arguments: [Int.max, 7, 1])
  func `A bare string document parses into a string root`(chunk: Int) throws {
    expectNoDifference(try self.parse(#""Blob""#, as: String.self, chunk: chunk), "Blob")
    expectNoDifference(try self.parse(#""""#, as: String.self, chunk: chunk), "")
    expectNoDifference(try self.parse(#""a\nb é€""#, as: String.self, chunk: chunk), "a\nb é€")
  }

  @Test(arguments: [Int.max, 7, 1])
  func `A bare number document parses into a number root`(chunk: Int) throws {
    expectNoDifference(try self.parse("42", as: Int.self, chunk: chunk), 42)
    expectNoDifference(try self.parse("-17", as: Int.self, chunk: chunk), -17)
    expectNoDifference(try self.parse("3.25", as: Double.self, chunk: chunk), 3.25)
    expectNoDifference(try self.parse("-1.5e2", as: Double.self, chunk: chunk), -150)
  }

  @Test
  func `A bare boolean document parses into a boolean root`() throws {
    expectNoDifference(try self.parse("true", as: Bool.self), true)
    expectNoDifference(try self.parse("false", as: Bool.self), false)
  }

  // MARK: - Array roots

  @Test(arguments: [Int.max, 7, 1])
  func `A bare array document parses into an array root`(chunk: Int) throws {
    expectNoDifference(try self.parse("[1,2,3]", as: StreamArray<Int>.self, chunk: chunk), [1, 2, 3])
    expectNoDifference(try self.parse("[]", as: StreamArray<Int>.self, chunk: chunk), [])
    expectNoDifference(try self.parse(#"["a","b"]"#, as: StreamArray<String>.self, chunk: chunk), ["a", "b"])
    expectNoDifference(try self.parse("[true,false]", as: StreamArray<Bool>.self, chunk: chunk), [true, false])
  }

  @Test(arguments: [Int.max, 7, 1])
  func `An array of objects parses at the root`(chunk: Int) throws {
    let users = try self.parse(
      #"[{"id":1,"name":"A"},{"id":2,"name":"B"}]"#,
      as: StreamArray<RootUser.Partial>.self,
      chunk: chunk
    )
    expectNoDifference(users.count, 2)
    expectNoDifference(users.first?.id, 1)
    expectNoDifference(users.first?.name, "A")
    expectNoDifference(users.last?.id, 2)
    expectNoDifference(users.last?.name, "B")
  }

  @Test(arguments: [Int.max, 7, 1])
  func `Nested arrays parse at the root`(chunk: Int) throws {
    let rows = try self.parse("[[1,2],[],[3]]", as: StreamArray<StreamArray<Int>>.self, chunk: chunk)
    expectNoDifference(rows, [[1, 2], [], [3]])
  }

  // MARK: - Optional container roots

  @Test(arguments: [Int.max, 2, 1])
  func `Empty optional container roots materialize`(chunk: Int) throws {
    expectNoDifference(
      try self.parse("[]", as: StreamArray<Int>?.self, chunk: chunk),
      StreamArray<Int>()
    )
    expectNoDifference(
      try self.parse("{}", as: StreamDictionary<Int>?.self, chunk: chunk),
      StreamDictionary<Int>()
    )
    expectNoDifference(
      try self.parse("{}", as: RootUser.Partial?.self, chunk: chunk),
      RootUser.Partial()
    )
    expectNoDifference(
      try self.parse(#"{"unknown":1}"#, as: RootUser.Partial?.self, chunk: chunk),
      RootUser.Partial()
    )
  }

  @Test(arguments: [Int.max, 1])
  func `Nested optional roots materialize every layer`(chunk: Int) throws {
    let expected: StreamArray<Int>?? = StreamArray<Int>()
    expectNoDifference(
      try self.parse("[]", as: StreamArray<Int>??.self, chunk: chunk),
      expected
    )
  }

  @Test(arguments: [Int.max, 2, 1])
  func `Null clears optional container roots`(chunk: Int) throws {
    var array: StreamArray<Int>? = StreamArray([1])
    try parsePartial("null", into: &array, chunk: chunk)
    expectNoDifference(array, nil)

    var dictionary: StreamDictionary<Int>? = StreamDictionary(["a": 1])
    try parsePartial("null", into: &dictionary, chunk: chunk)
    expectNoDifference(dictionary, nil)

    var object: RootUser.Partial? = RootUser.Partial(id: 1, name: "Blob")
    try parsePartial("null", into: &object, chunk: chunk)
    expectNoDifference(object, nil)
  }

  // MARK: - Dictionary roots

  @Test(arguments: [Int.max, 7, 1])
  func `A bare object document parses into a dictionary root`(chunk: Int) throws {
    let counts = try self.parse(
      #"{"b":2,"a":1,"c":3}"#, as: StreamDictionary<Int>.self, chunk: chunk
    )
    expectNoDifference(counts.keys, ["b", "a", "c"])
    expectNoDifference(counts["a"], 1)
    expectNoDifference(counts["b"], 2)
    expectNoDifference(counts["c"], 3)
  }

  @Test
  func `A dictionary root holds objects`() throws {
    let users = try self.parse(
      #"{"first":{"id":1,"name":"A"}}"#,
      as: StreamDictionary<RootUser.Partial>.self
    )
    expectNoDifference(users["first"]?.id, 1)
    expectNoDifference(users["first"]?.name, "A")
  }

  // MARK: - Mismatched roots

  private func failure<Root: StreamParseableRoot>(
    _ json: String, as type: Root.Type
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

  @Test
  func `A container document is rejected by a scalar root`() {
    expectNoDifference(self.failure(#"{"a":"x"}"#, as: String.self), .typeMismatch)
    expectNoDifference(self.failure(#"["x"]"#, as: String.self), .typeMismatch)
    expectNoDifference(self.failure("[1,2]", as: Int.self), .typeMismatch)
  }

  @Test
  func `A scalar document is rejected by a container root`() {
    expectNoDifference(
      self.failure(#""x""#, as: StreamArray<Int>.self),
      .typeMismatch
    )
    expectNoDifference(self.failure("1", as: StreamArray<Int>.self), .typeMismatch)
    expectNoDifference(self.failure("null", as: StreamArray<Int>.self), .typeMismatch)
  }
}
