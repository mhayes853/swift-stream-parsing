import Testing

import StreamParsing
import StreamParsingCore

@StreamParseable
struct ReentryInner: Equatable {
  var a: Int = 0
  var b: Int = 0
}

@StreamParseable
struct ReentryModel: Equatable {
  var values: [Int] = []
  var nested: ReentryInner = ReentryInner()
  var counts: [String: Int] = [:]
  var name: String = ""
}

extension ReentryInner.Partial: Equatable {}

// What happens when a container is entered a second time.
//
// JSON allows a key to repeat, and a destination that already holds a container has to do
// something with the second one. Nothing in the library said what, and `StreamSchema.enterField`
// claimed to reset the container, which it has never done. These record the answer the code
// actually gives, so that the dictionary rework has something to diverge from.
//
// The answer is the same in all four places: **the second occurrence resumes the container the
// first one built, rather than replacing it.** That is a consequence of entry materialising a
// container only when it is absent, and it is why a repeated key differs from a repeated scalar,
// which does overwrite.
@Suite
struct `Container re-entry tests` {
  private func parse<Root: StreamParseableRoot>(
    _ json: String, as type: Root.Type, chunk: Int = .max
  ) throws -> Root {
    var value = Root.streamInitialValue()
    try parsePartial(json, into: &value, chunk: chunk)
    return value
  }

  // MARK: - Scalars, which are not one rule either

  // A repeated string **concatenates**, because applying a string appends to whatever is already
  // there and a second occurrence is indistinguishable from a second chunk of the first. A
  // repeated number replaces, because applying a number assigns.
  //
  // Recorded rather than endorsed. These are two different answers to the same question and
  // nothing chose either of them deliberately; `"first"` followed by `"second"` reading back as
  // `"firstsecond"` is the kind of thing a caller would report as a bug.
  @Test(arguments: [Int.max, 7, 1])
  func `A repeated string field concatenates`(chunk: Int) throws {
    let model = try self.parse(
      #"{"name":"first","name":"second"}"#, as: ReentryModel.Partial.self, chunk: chunk
    )
    #expect(model.name == "firstsecond")
  }

  @Test(arguments: [Int.max, 7, 1])
  func `A repeated number field replaces`(chunk: Int) throws {
    let inner = try self.parse(#"{"a":1,"a":2}"#, as: ReentryInner.Partial.self, chunk: chunk)
    #expect(inner.a == 2)
  }

  @Test(arguments: [Int.max, 7, 1])
  func `A repeated dictionary key with a string value concatenates`(chunk: Int) throws {
    let values = try self.parse(
      #"{"a":"x","a":"y"}"#, as: StreamDictionary<String>.self, chunk: chunk
    )
    #expect(values["a"] == "xy")
  }

  // MARK: - Object fields

  @Test(arguments: [Int.max, 7, 1])
  func `A repeated array field resumes the array it already has`(chunk: Int) throws {
    let model = try self.parse(
      #"{"values":[1,2],"values":[3]}"#, as: ReentryModel.Partial.self, chunk: chunk
    )
    #expect(model.values == [1, 2, 3], "the second array appends rather than replacing")
  }

  @Test(arguments: [Int.max, 7, 1])
  func `A repeated object field merges into the object it already has`(chunk: Int) throws {
    let model = try self.parse(
      #"{"nested":{"a":1},"nested":{"b":2}}"#, as: ReentryModel.Partial.self, chunk: chunk
    )
    #expect(model.nested == ReentryInner.Partial(a: 1, b: 2), "the second object merges")
  }

  @Test(arguments: [Int.max, 7, 1])
  func `A repeated dictionary field merges into the dictionary it already has`(
    chunk: Int
  ) throws {
    let model = try self.parse(
      #"{"counts":{"a":1},"counts":{"b":2}}"#, as: ReentryModel.Partial.self, chunk: chunk
    )
    #expect(model.counts == ["a": 1, "b": 2], "the second dictionary merges")
  }

  // A field repeated with a value that is a container both times, where the inner key repeats too.
  @Test
  func `A repeated dictionary field with a repeated inner key keeps the last inner value`() throws {
    let model = try self.parse(
      #"{"counts":{"a":1},"counts":{"a":2}}"#, as: ReentryModel.Partial.self
    )
    #expect(model.counts == ["a": 2])
  }

  // MARK: - Dictionary values

  // The case the dictionary rework has to preserve: a repeated key resumes in the slot it already
  // occupies, so its value continues and its position does not move.
  @Test(arguments: [Int.max, 7, 1])
  func `A repeated dictionary key with an array value resumes that array`(chunk: Int) throws {
    let counts = try self.parse(
      #"{"a":[1],"b":[9],"a":[2]}"#, as: StreamDictionary<StreamArray<Int>>.self, chunk: chunk
    )
    #expect(counts.count == 2)
    #expect(counts.keys == ["a", "b"], "the repeated key stays in its original position")
    #expect(counts["a"] == [1, 2])
    #expect(counts["b"] == [9])
  }

  @Test(arguments: [Int.max, 7, 1])
  func `A repeated dictionary key with an object value merges that object`(chunk: Int) throws {
    let objects = try self.parse(
      #"{"x":{"a":1},"x":{"b":2}}"#, as: StreamDictionary<ReentryInner.Partial>.self, chunk: chunk
    )
    #expect(objects.count == 1)
    #expect(objects["x"] == ReentryInner.Partial(a: 1, b: 2))
  }

  @Test(arguments: [Int.max, 7, 1])
  func `A repeated dictionary key with a dictionary value merges that dictionary`(
    chunk: Int
  ) throws {
    let nested = try self.parse(
      #"{"x":{"a":1},"x":{"b":2}}"#,
      as: StreamDictionary<StreamDictionary<Int>>.self,
      chunk: chunk
    )
    #expect(nested["x"] == ["a": 1, "b": 2])
  }

  // A repeated key whose second value is a scalar where the first was a container. The
  // destination matched the key and cannot hold the token, which is a type mismatch rather than
  // an ignorable unknown key, so the parser throws. It is not specific to a repeat — the first
  // occurrence would fail the same way — but it is the case a repeated key most easily produces.
  @Test
  func `A repeated dictionary key that changes to a scalar is a type mismatch`() throws {
    let error = #expect(throws: JSONParsingError.self) {
      try self.parse(#"{"a":[1],"a":5}"#, as: StreamDictionary<StreamArray<Int>>.self)
    }
    guard case .sinkRejectedToken(let failure)? = error?.reason else {
      Issue.record("expected a sink rejection, got \(String(describing: error?.reason))")
      return
    }
    #expect(failure.reason == .typeMismatch)
  }

  // MARK: - A container arriving at a destination that cannot hold it

  // A container is written through the frame its destination resolves to, and that frame used to
  // be pushed without asking whether its shape could hold a container at all. A scalar frame
  // cannot: it ignores keys and applies every token to itself, so an array reaching one wrote
  // every element into it and the last one won.
  //
  // Two of these discarded correctly before the check existed, by accident of resolving to no
  // frame rather than by rejecting one. The rest leaked. `Shape.canHold(container:)` is what makes
  // the answer the same everywhere, and what makes the container kind passed to `enterContainer`
  // load bearing rather than ignored.
  //
  // Discarded, not rejected. A container at a destination that cannot hold it is silent, where a
  // scalar at a destination that cannot hold it throws — see the type mismatch test above. The
  // asymmetry is not chosen: an object field resolves to no frame for a key it does not have and
  // for a scalar field alike, so the two cannot be told apart from here.

  @Test
  func `A container at a scalar root is discarded`() throws {
    #expect(try self.parse("[1,2]", as: Int.self) == 0)
  }

  @Test(arguments: [Int.max, 7, 1])
  func `A container at a scalar object field is discarded`(chunk: Int) throws {
    let inner = try self.parse(#"{"a":1,"a":[2,3]}"#, as: ReentryInner.Partial.self, chunk: chunk)
    #expect(inner.a == 1, "the array's elements must not reach the scalar field")
  }

  @Test(arguments: [Int.max, 7, 1])
  func `A container at a scalar dictionary value is discarded`(chunk: Int) throws {
    let counts = try self.parse(#"{"a":1,"a":[2,3]}"#, as: StreamDictionary<Int>.self, chunk: chunk)
    #expect(counts.count == 1)
    #expect(counts["a"] == 1, "the array's elements must not reach the value")
  }

  // The same case without a repeat, to show it is not about re-entry at all. The key keeps the
  // slot `enterKey` materialised for it, so it is present holding the initial value.
  @Test
  func `A container at a scalar dictionary value on first occurrence keeps the initial value`()
    throws
  {
    let counts = try self.parse(#"{"a":[2,3]}"#, as: StreamDictionary<Int>.self)
    #expect(counts == ["a": 0])
  }

  // An element resolves the same way a dictionary value does, and leaked the same way. The
  // element stays appended holding its initial value, for the same reason the dictionary key
  // stays present: resolving the target is what materialises the slot.
  @Test(arguments: [Int.max, 7, 1])
  func `A container at a scalar array element is discarded`(chunk: Int) throws {
    #expect(try self.parse("[[2,3]]", as: StreamArray<Int>.self, chunk: chunk) == [0])
    #expect(try self.parse(#"[{"a":1}]"#, as: StreamArray<Int>.self, chunk: chunk) == [0])
  }

  // Mismatched container kinds, rather than a container at a scalar. An object reaching an array
  // has no more business there than it does at a scalar, and it used to be entered carrying the
  // array's own schema, so the object's values were appended as elements.
  @Test(arguments: [Int.max, 7, 1])
  func `An object at an array destination is discarded`(chunk: Int) throws {
    let rows = try self.parse(#"[{"a":1}]"#, as: StreamArray<StreamArray<Int>>.self, chunk: chunk)
    #expect(rows == [[]])

    let model = try self.parse(#"{"values":{"a":1}}"#, as: ReentryModel.Partial.self, chunk: chunk)
    #expect(model.values == [], "the object's values must not be appended as elements")

    #expect(try self.parse(#"{"a":1}"#, as: StreamArray<Int>.self, chunk: chunk) == [])
  }

  // The reverse pairing, which discarded correctly already. Pinned so that the check cannot be
  // narrowed to the cases that were broken.
  @Test(arguments: [Int.max, 7, 1])
  func `An array at an object or dictionary destination is discarded`(chunk: Int) throws {
    let model = try self.parse(#"{"nested":[1,2],"counts":[3,4]}"#, as: ReentryModel.Partial.self, chunk: chunk)
    #expect(model.nested == ReentryInner.Partial())
    #expect(model.counts == [:])

    #expect(try self.parse("[1,2]", as: StreamDictionary<Int>.self, chunk: chunk) == [:])

    let objects = try self.parse(
      #"{"x":[1,2]}"#, as: StreamDictionary<ReentryInner.Partial>.self, chunk: chunk
    )
    #expect(objects == ["x": ReentryInner.Partial()])
  }

  // A discarded subtree must not swallow what follows it, which is the thing a frame push/pop
  // imbalance would break.
  @Test(arguments: [Int.max, 7, 1])
  func `A discarded container does not disturb the rest of the document`(chunk: Int) throws {
    let model = try self.parse(
      #"{"name":"x","nested":[1,[2],{"deep":3}],"values":[7],"counts":{"k":1}}"#,
      as: ReentryModel.Partial.self,
      chunk: chunk
    )
    #expect(model.name == "x")
    #expect(model.nested == ReentryInner.Partial())
    #expect(model.values == [7], "the fields after the discarded subtree still parse")
    #expect(model.counts == ["k": 1])
  }

  // MARK: - Array elements

  // Elements are never re-entered, since every element opens a fresh slot. Recorded because it is
  // the property that makes `_openElement` safe to hand out a pointer to.
  @Test(arguments: [Int.max, 7, 1])
  func `Array elements are never re-entered`(chunk: Int) throws {
    let rows = try self.parse(
      "[[1],[2],[3]]", as: StreamArray<StreamArray<Int>>.self, chunk: chunk
    )
    #expect(rows == [[1], [2], [3]])
  }
}
