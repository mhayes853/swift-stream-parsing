#if StreamParsingSwiftCollections
  import Collections
  import BasicContainers
  import CustomDump
  import StreamParsing
  import Testing

  @Suite
  struct `StreamActionReducer+SwiftCollections tests` {
    @Test
    func `Reduces Deque Element For DelegateUnkeyed`() throws {
      var reducer = Deque<Int>()
      try reducer.reduce(action: .appendArrayElement)
      try reducer.reduce(action: .appendArrayElement)
      try reducer.reduce(action: .delegateUnkeyed(index: 1, .setValue(.int(9))))
      expectNoDifference(Array(reducer), [0, 9])
    }

    @Test
    func `Reduces BitArray Element For DelegateUnkeyed`() throws {
      var reducer = BitArray()
      try reducer.reduce(action: .appendArrayElement)
      try reducer.reduce(action: .appendArrayElement)
      try reducer.reduce(action: .delegateUnkeyed(index: 1, .setValue(.boolean(true))))
      expectNoDifference(reducer, [false, true])
    }

    @Test
    func `Reduces OrderedDictionary Value For DelegateKeyed`() throws {
      var reducer = OrderedDictionary<String, Int>()
      let actions: [StreamAction] = [
        .delegateKeyed(key: "first", .createObjectValue),
        .delegateKeyed(key: "first", .setValue(.int(1))),
        .delegateKeyed(key: "second", .createObjectValue),
        .delegateKeyed(key: "second", .setValue(.int(2)))
      ]

      for action in actions {
        try reducer.reduce(action: action)
      }

      let expected: OrderedDictionary<String, Int> = ["first": 1, "second": 2]
      expectNoDifference(reducer, expected)
    }

    @Test
    func `Reduces TreeDictionary Value For DelegateKeyed`() throws {
      var reducer = TreeDictionary<String, Int>()
      let actions: [StreamAction] = [
        .delegateKeyed(key: "first", .createObjectValue),
        .delegateKeyed(key: "first", .setValue(.int(1))),
        .delegateKeyed(key: "second", .createObjectValue),
        .delegateKeyed(key: "second", .setValue(.int(2)))
      ]

      for action in actions {
        try reducer.reduce(action: action)
      }

      let expected: TreeDictionary<String, Int> = ["first": 1, "second": 2]
      expectNoDifference(reducer, expected)
    }
  }
#endif
