#if StreamParsingSwiftCollections
  import BasicContainers
  import Collections

  // MARK: - Deque

  extension Deque: StreamParseable where Element: StreamParseable {
    public typealias Partial = Deque<Element.Partial>
  }

  extension Deque: StreamActionReducer where Element: StreamParseableReducer {}

  extension Deque: StreamParseableReducer where Element: StreamParseableReducer {
    public static func initialReduceableValue() -> Self {
      Self()
    }

    public mutating func reduce(action: StreamAction) throws {
      switch action {
      case .delegateUnkeyed(let index, let action):
        try self[index].reduce(action: action)
      case .appendArrayElement:
        self.append(.initialReduceableValue())
      default:
        throw StreamActionReducerError.unsupportedAction(action)
      }
    }
  }

  // MARK: - BitArray

  extension BitArray: StreamParseable {
    public typealias Partial = Self
  }

  extension BitArray: StreamActionReducer {}

  extension BitArray: StreamParseableReducer {
    public static func initialReduceableValue() -> Self {
      Self()
    }

    public mutating func reduce(action: StreamAction) throws {
      switch action {
      case .delegateUnkeyed(let offset, let nestedAction):
        let index = self.index(self.startIndex, offsetBy: offset)
        try self[index].reduce(action: nestedAction)
      case .appendArrayElement:
        self.append(.initialReduceableValue())
      default:
        throw StreamActionReducerError.unsupportedAction(action)
      }
    }
  }

  // // MARK: - RigidArray

  // extension RigidArray: StreamParseable where Element: StreamParseable & Copyable {
  //   public typealias Partial = RigidArray<Element.Partial>
  // }

  // extension RigidArray: StreamActionReducer where Element: StreamParseableReducer & Copyable {}

  // extension RigidArray: StreamParseableReducer where Element: StreamParseableReducer & Copyable {
  //   public static func initialReduceableValue() -> Self {
  //     Self()
  //   }

  //   public mutating func reduce(action: StreamAction) throws {
  //     switch action {
  //     case .delegateUnkeyed(let offset, let nestedAction):
  //       let index = self.index(self.startIndex, offsetBy: offset)
  //       try self[index].reduce(action: nestedAction)
  //     case .appendArrayElement:
  //       self.append(.initialReduceableValue())
  //     default:
  //       throw StreamActionReducerError.unsupportedAction(action)
  //     }
  //   }
  // }

  // // MARK: - UniqueArray

  // extension UniqueArray: StreamParseable where Element: StreamParseable & Copyable {
  //   public typealias Partial = UniqueArray<Element.Partial>
  // }

  // extension UniqueArray: StreamActionReducer where Element: StreamParseableReducer & Copyable {}

  // extension UniqueArray: StreamParseableReducer where Element: StreamParseableReducer & Copyable
  // {
  //   public static func initialReduceableValue() -> Self {
  //     Self()
  //   }

  //   public mutating func reduce(action: StreamAction) throws {
  //     switch action {
  //     case .delegateUnkeyed(let offset, let nestedAction):
  //       let index = self.index(self.startIndex, offsetBy: offset)
  //       try self[index].reduce(action: nestedAction)
  //     case .appendArrayElement:
  //       self.append(.initialReduceableValue())
  //     default:
  //       throw StreamActionReducerError.unsupportedAction(action)
  //     }
  //   }
  // }

  // MARK: - OrderedDictionary

  extension OrderedDictionary: StreamParseable where Key == String, Value: StreamParseable {
    public typealias Partial = OrderedDictionary<String, Value.Partial>
  }

  extension OrderedDictionary: StreamActionReducer
  where Key == String, Value: StreamParseableReducer {}

  extension OrderedDictionary: StreamParseableReducer
  where Key == String, Value: StreamParseableReducer {
    public static func initialReduceableValue() -> Self {
      Self()
    }

    public mutating func reduce(action: StreamAction) throws {
      switch action {
      case .delegateKeyed(let key, .createObjectValue):
        self[key] = .initialReduceableValue()
      case .delegateKeyed(let key, let action):
        try self[key]?.reduce(action: action)
      default:
        throw StreamActionReducerError.unsupportedAction(action)
      }
    }
  }

  // MARK: - TreeDictionary

  extension TreeDictionary: StreamParseable where Key == String, Value: StreamParseable {
    public typealias Partial = TreeDictionary<String, Value.Partial>
  }

  extension TreeDictionary: StreamActionReducer
  where Key == String, Value: StreamParseableReducer {}

  extension TreeDictionary: StreamParseableReducer
  where Key == String, Value: StreamParseableReducer {
    public static func initialReduceableValue() -> Self {
      Self()
    }

    public mutating func reduce(action: StreamAction) throws {
      switch action {
      case .delegateKeyed(let key, .createObjectValue):
        self[key] = .initialReduceableValue()
      case .delegateKeyed(let key, let action):
        try self[key]?.reduce(action: action)
      default:
        throw StreamActionReducerError.unsupportedAction(action)
      }
    }
  }
#endif
