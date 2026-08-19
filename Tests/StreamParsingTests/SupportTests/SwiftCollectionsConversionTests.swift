#if StreamParsingSwiftCollections
  import BitCollections
  import DequeModule
  import HashTreeCollections
  import OrderedCollections
  import Testing

  import StreamParsing
  import StreamParsingCore

  @StreamParseable
  struct CollectionsValues: Equatable {
    var counts: [String: Int] = [:]
    var scores: [Int] = []
  }

  @Suite
  struct `SwiftCollections conversion tests` {
    // StreamDictionary exists because a Dictionary can relocate its values on insertion, and it
    // keeps insertion order as a side effect. That is what makes this conversion lossless, and
    // it is the reason OrderedDictionary is the natural destination.
    @Test
    func `OrderedDictionary bridging preserves the order keys arrived in`() throws {
      var value = CollectionsValues.Partial()
      try parsePartial(#"{"counts":{"zebra":1,"apple":2,"mango":3,"apple":4}}"#, into: &value)

      let counts = try #require(value.counts)
      let ordered = OrderedDictionary(counts)
      expectNoDifference(Array(ordered.keys), ["zebra", "apple", "mango"])
      expectNoDifference(ordered["zebra"], 1)
      expectNoDifference(ordered["apple"], 4)
      expectNoDifference(ordered["mango"], 3)
    }

    @Test
    func `OrderedDictionary bridging round trips`() {
      let ordered: OrderedDictionary<String, Int> = ["c": 3, "a": 1, "b": 2]
      let stream = StreamDictionary(ordered)
      expectNoDifference(stream.keys, ["c", "a", "b"])
      expectNoDifference(OrderedDictionary(stream), ordered)
    }

    // TreeDictionary has no order to preserve, so only the contents survive.
    @Test
    func `TreeDictionary bridging carries the contents`() throws {
      var value = CollectionsValues.Partial()
      try parsePartial(#"{"counts":{"a":1,"b":2}}"#, into: &value)

      let tree = TreeDictionary(try #require(value.counts))
      expectNoDifference(tree, ["a": 1, "b": 2])
    }

    @Test
    func `Array members convert to a Deque after parsing`() throws {
      var value = CollectionsValues.Partial()
      try parsePartial(#"{"scores":[3,1,2]}"#, into: &value)
      expectNoDifference(Deque(try #require(value.scores)), [3, 1, 2])
    }

    @Test
    func `Bridged collections start empty`() {
      #expect(Deque<Int>.streamInitialValue().isEmpty)
      #expect(BitArray.streamInitialValue().isEmpty)
      #expect(OrderedDictionary<String, Int>.streamInitialValue().isEmpty)
      #expect(TreeDictionary<String, Int>.streamInitialValue().isEmpty)
    }
  }
#endif
