import MacroTesting
import Testing

extension BaseTestSuite {
  @Suite
  struct `StreamParseableMacro tests` {
    @Test
    func `Basic`() {
      assertMacro {
        """
        @StreamParseable
        struct Person {
          var name: String
          var age: Int
        }
        """
      } expansion: {
        """
        struct Person {
          var name: String
          var age: Int
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseableReducer,
            StreamParsingCore.StreamParseable {
            typealias Partial = Self

            var name: String.Partial?
            var age: Int.Partial?

            init(
              name: String.Partial? = nil,
              age: Int.Partial? = nil
            ) {
              self.name = name
              self.age = age
            }

            static func initialReduceableValue() -> Self {
              Self()
            }

            mutating func reduce(action: StreamAction) throws {
              switch action {
              case .delegateKeyed("name", let action):
                try _streamParsingPerformReduce(&self.name, action)
              case .delegateKeyed("age", let action):
                try _streamParsingPerformReduce(&self.age, action)
              case .delegateKeyed:
                break
              default:
                throw StreamParseableError.unsupportedAction(action)
              }
            }
          }
        }
        """
      }
    }

    @Test
    func `Does Not Convert Static`() {
      assertMacro {
        """
        @StreamParseable
        struct Person {
          static var name: String
          var age: Int
        }
        """
      } expansion: {
        """
        struct Person {
          static var name: String
          var age: Int
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseableReducer,
            StreamParsingCore.StreamParseable {
            typealias Partial = Self

            var age: Int.Partial?

            init(
              age: Int.Partial? = nil
            ) {
              self.age = age
            }

            static func initialReduceableValue() -> Self {
              Self()
            }

            mutating func reduce(action: StreamAction) throws {
              switch action {
              case .delegateKeyed("age", let action):
                try _streamParsingPerformReduce(&self.age, action)
              case .delegateKeyed:
                break
              default:
                throw StreamParseableError.unsupportedAction(action)
              }
            }
          }
        }
        """
      }
    }

    @Test
    func `Converts Read-Only Members`() {
      assertMacro {
        """
        @StreamParseable
        struct Person {
          let name: String
          let age: Int
        }
        """
      } expansion: {
        """
        struct Person {
          let name: String
          let age: Int
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseableReducer,
            StreamParsingCore.StreamParseable {
            typealias Partial = Self

            var name: String.Partial?
            var age: Int.Partial?

            init(
              name: String.Partial? = nil,
              age: Int.Partial? = nil
            ) {
              self.name = name
              self.age = age
            }

            static func initialReduceableValue() -> Self {
              Self()
            }

            mutating func reduce(action: StreamAction) throws {
              switch action {
              case .delegateKeyed("name", let action):
                try _streamParsingPerformReduce(&self.name, action)
              case .delegateKeyed("age", let action):
                try _streamParsingPerformReduce(&self.age, action)
              case .delegateKeyed:
                break
              default:
                throw StreamParseableError.unsupportedAction(action)
              }
            }
          }
        }
        """
      }
    }

    @Test
    func `Applied To Enum`() {
      assertMacro {
        """
        @StreamParseable
        enum Person {
          case name(String)
          case age(Int)
        }
        """
      } diagnostics: {
        """
        @StreamParseable
        ┬───────────────
        ╰─ 🛑 @StreamParseable can only be applied to struct declarations.
        enum Person {
          case name(String)
          case age(Int)
        }
        """
      }
    }

    @Test
    func `Applied To Class`() {
      assertMacro {
        """
        @StreamParseable
        class Person {
          var name: String
          var age: Int

          init(name: String, age: Int) {
            self.name = name
            self.age = age
          }
        }
        """
      } diagnostics: {
        """
        @StreamParseable
        ┬───────────────
        ╰─ 🛑 @StreamParseable can only be applied to struct declarations.
        class Person {
          var name: String
          var age: Int

          init(name: String, age: Int) {
            self.name = name
            self.age = age
          }
        }
        """
      }
    }

    @Test
    func `Applied To Actor`() {
      assertMacro {
        """
        @StreamParseable
        actor Person {
          var name: String
          var age: Int

          init(name: String, age: Int) {
            self.name = name
            self.age = age
          }
        }
        """
      } diagnostics: {
        """
        @StreamParseable
        ┬───────────────
        ╰─ 🛑 @StreamParseable can only be applied to struct declarations.
        actor Person {
          var name: String
          var age: Int

          init(name: String, age: Int) {
            self.name = name
            self.age = age
          }
        }
        """
      }
    }

    @Test
    func `Does Not Override Existing Partial Inner Type`() {
      assertMacro {
        """
        @StreamParseable
        struct Person {
          var name: String
          var age: Int

          struct Partial {}
        }
        """
      } expansion: {
        """
        struct Person {
          var name: String
          var age: Int

          struct Partial {}
        }

        extension Person: StreamParsingCore.StreamParseable {
        }
        """
      }
    }

    @Test
    func `Access Modifier`() async throws {
      assertMacro {
        """
        @StreamParseable
        public struct Person {
          public var name: String
          public var age: Int
        }
        """
      } expansion: {
        """
        public struct Person {
          public var name: String
          public var age: Int
        }

        extension Person: StreamParsingCore.StreamParseable {
          public struct Partial: StreamParsingCore.StreamParseableReducer,
            StreamParsingCore.StreamParseable {
            public typealias Partial = Self

            public var name: String.Partial?
            public var age: Int.Partial?

            public init(
              name: String.Partial? = nil,
              age: Int.Partial? = nil
            ) {
              self.name = name
              self.age = age
            }

            public static func initialReduceableValue() -> Self {
              Self()
            }

            public mutating func reduce(action: StreamAction) throws {
              switch action {
              case .delegateKeyed("name", let action):
                try _streamParsingPerformReduce(&self.name, action)
              case .delegateKeyed("age", let action):
                try _streamParsingPerformReduce(&self.age, action)
              case .delegateKeyed:
                break
              default:
                throw StreamParseableError.unsupportedAction(action)
              }
            }
          }
        }
        """
      }
      assertMacro {
        """
        @StreamParseable
        private struct Person {
          var name: String
          var age: Int
        }
        """
      } expansion: {
        """
        private struct Person {
          var name: String
          var age: Int
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseableReducer,
            StreamParsingCore.StreamParseable {
            typealias Partial = Self

            var name: String.Partial?
            var age: Int.Partial?

            init(
              name: String.Partial? = nil,
              age: Int.Partial? = nil
            ) {
              self.name = name
              self.age = age
            }

            static func initialReduceableValue() -> Self {
              Self()
            }

            mutating func reduce(action: StreamAction) throws {
              switch action {
              case .delegateKeyed("name", let action):
                try _streamParsingPerformReduce(&self.name, action)
              case .delegateKeyed("age", let action):
                try _streamParsingPerformReduce(&self.age, action)
              case .delegateKeyed:
                break
              default:
                throw StreamParseableError.unsupportedAction(action)
              }
            }
          }
        }
        """
      }
      assertMacro {
        """
        @StreamParseable
        fileprivate struct Person {
          var name: String
          var age: Int
        }
        """
      } expansion: {
        """
        fileprivate struct Person {
          var name: String
          var age: Int
        }

        extension Person: StreamParsingCore.StreamParseable {
          fileprivate struct Partial: StreamParsingCore.StreamParseableReducer,
            StreamParsingCore.StreamParseable {
            fileprivate typealias Partial = Self

            fileprivate var name: String.Partial?
            fileprivate var age: Int.Partial?

            fileprivate init(
              name: String.Partial? = nil,
              age: Int.Partial? = nil
            ) {
              self.name = name
              self.age = age
            }

            fileprivate static func initialReduceableValue() -> Self {
              Self()
            }

            fileprivate mutating func reduce(action: StreamAction) throws {
              switch action {
              case .delegateKeyed("name", let action):
                try _streamParsingPerformReduce(&self.name, action)
              case .delegateKeyed("age", let action):
                try _streamParsingPerformReduce(&self.age, action)
              case .delegateKeyed:
                break
              default:
                throw StreamParseableError.unsupportedAction(action)
              }
            }
          }
        }
        """
      }
    }

    @Test
    func `Makes Private Members Accessible In Partial`() async throws {
      assertMacro {
        """
        @StreamParseable
        public struct Person {
          private var name: String
          private var age: Int
        }
        """
      } expansion: {
        """
        public struct Person {
          private var name: String
          private var age: Int
        }

        extension Person: StreamParsingCore.StreamParseable {
          public struct Partial: StreamParsingCore.StreamParseableReducer,
            StreamParsingCore.StreamParseable {
            public typealias Partial = Self

            public var name: String.Partial?
            public var age: Int.Partial?

            public init(
              name: String.Partial? = nil,
              age: Int.Partial? = nil
            ) {
              self.name = name
              self.age = age
            }

            public static func initialReduceableValue() -> Self {
              Self()
            }

            public mutating func reduce(action: StreamAction) throws {
              switch action {
              case .delegateKeyed("name", let action):
                try _streamParsingPerformReduce(&self.name, action)
              case .delegateKeyed("age", let action):
                try _streamParsingPerformReduce(&self.age, action)
              case .delegateKeyed:
                break
              default:
                throw StreamParseableError.unsupportedAction(action)
              }
            }
          }
        }
        """
      }
    }

    @Test
    func `Handles Optional Members As Double Optionals In Partial`() async throws {
      assertMacro {
        """
        @StreamParseable
        public struct Person {
          private var name: String?
          private var age: Optional<Int>
        }
        """
      } expansion: {
        """
        public struct Person {
          private var name: String?
          private var age: Optional<Int>
        }

        extension Person: StreamParsingCore.StreamParseable {
          public struct Partial: StreamParsingCore.StreamParseableReducer,
            StreamParsingCore.StreamParseable {
            public typealias Partial = Self

            public var name: String?.Partial?
            public var age: Optional<Int>.Partial?

            public init(
              name: String?.Partial? = nil,
              age: Optional<Int>.Partial? = nil
            ) {
              self.name = name
              self.age = age
            }

            public static func initialReduceableValue() -> Self {
              Self()
            }

            public mutating func reduce(action: StreamAction) throws {
              switch action {
              case .delegateKeyed("name", let action):
                try _streamParsingPerformReduce(&self.name, action)
              case .delegateKeyed("age", let action):
                try _streamParsingPerformReduce(&self.age, action)
              case .delegateKeyed:
                break
              default:
                throw StreamParseableError.unsupportedAction(action)
              }
            }
          }
        }
        """
      }
    }
  }
}
