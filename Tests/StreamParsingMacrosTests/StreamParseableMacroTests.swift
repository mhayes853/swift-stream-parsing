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
        #"""
        struct Person {
          var name: String
          var age: Int

          var streamPartialValue: Partial {
            Partial(
              name: self.name.streamPartialValue,
              age: self.age.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseableValue,
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

            static func initialParseableValue() -> Self {
              Self()
            }

            static func registerHandlers(
              in handlers: inout some StreamParsingCore.StreamParserHandlers<Self>
            ) {
              handlers.registerKeyedHandler(forKey: "name", \.name)
              handlers.registerKeyedHandler(forKey: "age", \.age)
            }
          }
        }
        """#
      }
    }

    @Test
    func `Custom Member Key`() {
      assertMacro {
        """
        @StreamParseable
        struct Person {
          @StreamParseableMember(key: "customKeyName")
          var name: String
          var age: Int
        }
        """
      } expansion: {
        #"""
        struct Person {
          var name: String
          var age: Int

          var streamPartialValue: Partial {
            Partial(
              name: self.name.streamPartialValue,
              age: self.age.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseableValue,
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

            static func initialParseableValue() -> Self {
              Self()
            }

            static func registerHandlers(
              in handlers: inout some StreamParsingCore.StreamParserHandlers<Self>
            ) {
              handlers.registerKeyedHandler(forKey: "customKeyName", \.name)
              handlers.registerKeyedHandler(forKey: "age", \.age)
            }
          }
        }
        """#
      }
    }

    @Test
    func `StreamParseableMember Applied To Static Property`() {
      assertMacro {
        """
        @StreamParseable
        struct Person {
          @StreamParseableMember(key: "name")
          static var name: String = ""
        }
        """
      } diagnostics: {
        """
        @StreamParseable
        struct Person {
          @StreamParseableMember(key: "name")
          ┬──────────────────────────────────
          ├─ 🛑 Only stored properties are supported.
          ╰─ 🛑 Only stored properties are supported.
          static var name: String = ""
        }
        """
      }
    }

    @Test
    func `StreamParseableMember Applied To Computed Property`() {
      assertMacro {
        """
        @StreamParseable
        struct Person {
          @StreamParseableMember(key: "name")
          var name: String {
            "value"
          }
        }
        """
      } diagnostics: {
        """
        @StreamParseable
        struct Person {
          @StreamParseableMember(key: "name")
          ┬──────────────────────────────────
          ├─ 🛑 Only stored properties are supported.
          ╰─ 🛑 Only stored properties are supported.
          var name: String {
            "value"
          }
        }
        """
      }
    }

    @Test
    func `Missing Stored Property Type Annotation`() {
      assertMacro {
        """
        @StreamParseable
        struct Person {
          var name = "Blob"
          var age: Int
        }
        """
      } diagnostics: {
        """
        @StreamParseable
        struct Person {
          var name = "Blob"
              ┬────────────
              ├─ 🛑 Stored properties must declare an explicit type.
              ╰─ 🛑 Stored properties must declare an explicit type.
          var age: Int
        }
        """
      }
    }

    @Test
    func `Non-String Key Literal`() {
      assertMacro {
        """
        let keyName = "customKeyName"

        @StreamParseable
        struct Person {
          @StreamParseableMember(key: keyName)
          var name: String
          var age: Int
        }
        """
      } diagnostics: {
        """
        let keyName = "customKeyName"

        @StreamParseable
        struct Person {
          @StreamParseableMember(key: keyName)
          ┬───────────────────────────────────
          ├─ 🛑 @StreamParseableMember(key:) requires a string literal.
          ╰─ 🛑 @StreamParseableMember(key:) requires a string literal.
          var name: String
          var age: Int
        }
        """
      }
    }

    @Test
    func `Custom Member Key Names`() {
      assertMacro {
        """
        @StreamParseable
        struct Person {
          @StreamParseableMember(keyNames: ["customKeyName", "customKeyName2"])
          var name: String
          var age: Int
        }
        """
      } expansion: {
        #"""
        struct Person {
          var name: String
          var age: Int

          var streamPartialValue: Partial {
            Partial(
              name: self.name.streamPartialValue,
              age: self.age.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseableValue,
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

            static func initialParseableValue() -> Self {
              Self()
            }

            static func registerHandlers(
              in handlers: inout some StreamParsingCore.StreamParserHandlers<Self>
            ) {
              handlers.registerKeyedHandler(forKey: "customKeyName", \.name)
              handlers.registerKeyedHandler(forKey: "customKeyName2", \.name)
              handlers.registerKeyedHandler(forKey: "age", \.age)
            }
          }
        }
        """#
      }
    }

    @Test
    func `Integer Literal Key`() {
      assertMacro {
        """
        @StreamParseable
        struct Person {
          @StreamParseableMember(key: 1)
          var name: String
          var age: Int
        }
        """
      } diagnostics: {
        """
        @StreamParseable
        struct Person {
          @StreamParseableMember(key: 1)
          ┬─────────────────────────────
          ├─ 🛑 @StreamParseableMember(key:) requires a string literal.
          ╰─ 🛑 @StreamParseableMember(key:) requires a string literal.
          var name: String
          var age: Int
        }
        """
      }
    }

    @Test
    func `Integer Literal Key Names`() {
      assertMacro {
        """
        @StreamParseable
        struct Person {
          @StreamParseableMember(keyNames: [1])
          var name: String
          var age: Int
        }
        """
      } diagnostics: {
        """
        @StreamParseable
        struct Person {
          @StreamParseableMember(keyNames: [1])
          ┬────────────────────────────────────
          ├─ 🛑 @StreamParseableMember(keyNames:) requires a string array literal.
          ╰─ 🛑 @StreamParseableMember(keyNames:) requires a string array literal.
          var name: String
          var age: Int
        }
        """
      }
    }

    @Test
    func `Non-String Key Names Array Literal`() {
      assertMacro {
        """
        let keyNames = ["customKeyName"]

        @StreamParseable
        struct Person {
          @StreamParseableMember(keyNames: keyNames)
          var name: String
          var age: Int
        }
        """
      } diagnostics: {
        """
        let keyNames = ["customKeyName"]

        @StreamParseable
        struct Person {
          @StreamParseableMember(keyNames: keyNames)
          ┬─────────────────────────────────────────
          ├─ 🛑 @StreamParseableMember(keyNames:) requires a string array literal.
          ╰─ 🛑 @StreamParseableMember(keyNames:) requires a string array literal.
          var name: String
          var age: Int
        }
        """
      }
    }

    @Test
    func `Initial Parseable Value Members`() {
      assertMacro {
        """
        @StreamParseable(partialMembers: .initialParseableValue)
        struct Person {
          var name: String
          var age: Int
        }
        """
      } expansion: {
        #"""
        struct Person {
          var name: String
          var age: Int

          var streamPartialValue: Partial {
            Partial(
              name: self.name.streamPartialValue,
              age: self.age.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseableValue,
            StreamParsingCore.StreamParseable {
            typealias Partial = Self

            var name: String.Partial
            var age: Int.Partial

            init(
              name: String.Partial = .initialParseableValue(),
              age: Int.Partial = .initialParseableValue()
            ) {
              self.name = name
              self.age = age
            }

            static func initialParseableValue() -> Self {
              Self()
            }

            static func registerHandlers(
              in handlers: inout some StreamParsingCore.StreamParserHandlers<Self>
            ) {
              handlers.registerKeyedHandler(forKey: "name", \.name)
              handlers.registerKeyedHandler(forKey: "age", \.age)
            }
          }
        }
        """#
      }
    }

    @Test
    func `Initial Parseable Value Members With Optionals`() {
      assertMacro {
        """
        @StreamParseable(partialMembers: .initialParseableValue)
        struct Person {
          var name: String?
          var age: Int?
        }
        """
      } expansion: {
        #"""
        struct Person {
          var name: String?
          var age: Int?

          var streamPartialValue: Partial {
            Partial(
              name: self.name.streamPartialValue,
              age: self.age.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseableValue,
            StreamParsingCore.StreamParseable {
            typealias Partial = Self

            var name: String?.Partial
            var age: Int?.Partial

            init(
              name: String?.Partial = .initialParseableValue(),
              age: Int?.Partial = .initialParseableValue()
            ) {
              self.name = name
              self.age = age
            }

            static func initialParseableValue() -> Self {
              Self()
            }

            static func registerHandlers(
              in handlers: inout some StreamParsingCore.StreamParserHandlers<Self>
            ) {
              handlers.registerKeyedHandler(forKey: "name", \.name)
              handlers.registerKeyedHandler(forKey: "age", \.age)
            }
          }
        }
        """#
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
        #"""
        struct Person {
          static var name: String
          var age: Int

          var streamPartialValue: Partial {
            Partial(
              age: self.age.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseableValue,
            StreamParsingCore.StreamParseable {
            typealias Partial = Self

            var age: Int.Partial?

            init(
              age: Int.Partial? = nil
            ) {
              self.age = age
            }

            static func initialParseableValue() -> Self {
              Self()
            }

            static func registerHandlers(
              in handlers: inout some StreamParsingCore.StreamParserHandlers<Self>
            ) {
              handlers.registerKeyedHandler(forKey: "age", \.age)
            }
          }
        }
        """#
      }
    }

    @Test
    func `Excludes Computed Properties`() {
      assertMacro {
        """
        @StreamParseable
        struct Person {
          var stored: String
          var computed: Int {
            1
          }
        }
        """
      } expansion: {
        #"""
        struct Person {
          var stored: String
          var computed: Int {
            1
          }

          var streamPartialValue: Partial {
            Partial(
              stored: self.stored.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseableValue,
            StreamParsingCore.StreamParseable {
            typealias Partial = Self

            var stored: String.Partial?

            init(
              stored: String.Partial? = nil
            ) {
              self.stored = stored
            }

            static func initialParseableValue() -> Self {
              Self()
            }

            static func registerHandlers(
              in handlers: inout some StreamParsingCore.StreamParserHandlers<Self>
            ) {
              handlers.registerKeyedHandler(forKey: "stored", \.stored)
            }
          }
        }
        """#
      }
    }

    @Test
    func `Ignores Explicitly Ignored Properties`() {
      assertMacro {
        """
        @StreamParseable
        struct Person {
          var name: String
          @StreamParseableIgnored
          var age: Int
        }
        """
      } expansion: {
        #"""
        struct Person {
          var name: String
          var age: Int

          var streamPartialValue: Partial {
            Partial(
              name: self.name.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseableValue,
            StreamParsingCore.StreamParseable {
            typealias Partial = Self

            var name: String.Partial?

            init(
              name: String.Partial? = nil
            ) {
              self.name = name
            }

            static func initialParseableValue() -> Self {
              Self()
            }

            static func registerHandlers(
              in handlers: inout some StreamParsingCore.StreamParserHandlers<Self>
            ) {
              handlers.registerKeyedHandler(forKey: "name", \.name)
            }
          }
        }
        """#
      }
    }

    @Test
    func `Ignores Instance Methods`() {
      assertMacro {
        """
        @StreamParseable
        struct Person {
          var stored: String
          func greet() {}
        }
        """
      } expansion: {
        #"""
        struct Person {
          var stored: String
          func greet() {}

          var streamPartialValue: Partial {
            Partial(
              stored: self.stored.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseableValue,
            StreamParsingCore.StreamParseable {
            typealias Partial = Self

            var stored: String.Partial?

            init(
              stored: String.Partial? = nil
            ) {
              self.stored = stored
            }

            static func initialParseableValue() -> Self {
              Self()
            }

            static func registerHandlers(
              in handlers: inout some StreamParsingCore.StreamParserHandlers<Self>
            ) {
              handlers.registerKeyedHandler(forKey: "stored", \.stored)
            }
          }
        }
        """#
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
        #"""
        struct Person {
          let name: String
          let age: Int

          var streamPartialValue: Partial {
            Partial(
              name: self.name.streamPartialValue,
              age: self.age.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseableValue,
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

            static func initialParseableValue() -> Self {
              Self()
            }

            static func registerHandlers(
              in handlers: inout some StreamParsingCore.StreamParserHandlers<Self>
            ) {
              handlers.registerKeyedHandler(forKey: "name", \.name)
              handlers.registerKeyedHandler(forKey: "age", \.age)
            }
          }
        }
        """#
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
        ├─ 🛑 @StreamParseable can only be applied to struct declarations.
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
        ├─ 🛑 @StreamParseable can only be applied to struct declarations.
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
        ├─ 🛑 @StreamParseable can only be applied to struct declarations.
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

          var streamPartialValue: Partial {
            Partial(
              name: self.name.streamPartialValue,
              age: self.age.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
        }
        """
      }
    }

    @Test
    func `Uses Existing StreamPartialValue Property`() {
      assertMacro {
        """
        @StreamParseable
        struct Person {
          var name: String
          var age: Int

          var streamPartialValue: Partial {
            Partial(
              name: name.streamPartialValue,
              age: age.streamPartialValue
            )
          }
        }
        """
      } expansion: {
        #"""
        struct Person {
          var name: String
          var age: Int

          var streamPartialValue: Partial {
            Partial(
              name: name.streamPartialValue,
              age: age.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseableValue,
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

            static func initialParseableValue() -> Self {
              Self()
            }

            static func registerHandlers(
              in handlers: inout some StreamParsingCore.StreamParserHandlers<Self>
            ) {
              handlers.registerKeyedHandler(forKey: "name", \.name)
              handlers.registerKeyedHandler(forKey: "age", \.age)
            }
          }
        }
        """#
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
        #"""
        public struct Person {
          public var name: String
          public var age: Int

          public var streamPartialValue: Partial {
            Partial(
              name: self.name.streamPartialValue,
              age: self.age.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          public struct Partial: StreamParsingCore.StreamParseableValue,
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

            public static func initialParseableValue() -> Self {
              Self()
            }

            public static func registerHandlers(
              in handlers: inout some StreamParsingCore.StreamParserHandlers<Self>
            ) {
              handlers.registerKeyedHandler(forKey: "name", \.name)
              handlers.registerKeyedHandler(forKey: "age", \.age)
            }
          }
        }
        """#
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
        #"""
        private struct Person {
          var name: String
          var age: Int

          var streamPartialValue: Partial {
            Partial(
              name: self.name.streamPartialValue,
              age: self.age.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseableValue,
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

            static func initialParseableValue() -> Self {
              Self()
            }

            static func registerHandlers(
              in handlers: inout some StreamParsingCore.StreamParserHandlers<Self>
            ) {
              handlers.registerKeyedHandler(forKey: "name", \.name)
              handlers.registerKeyedHandler(forKey: "age", \.age)
            }
          }
        }
        """#
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
        #"""
        fileprivate struct Person {
          var name: String
          var age: Int

          fileprivate var streamPartialValue: Partial {
            Partial(
              name: self.name.streamPartialValue,
              age: self.age.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          fileprivate struct Partial: StreamParsingCore.StreamParseableValue,
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

            fileprivate static func initialParseableValue() -> Self {
              Self()
            }

            fileprivate static func registerHandlers(
              in handlers: inout some StreamParsingCore.StreamParserHandlers<Self>
            ) {
              handlers.registerKeyedHandler(forKey: "name", \.name)
              handlers.registerKeyedHandler(forKey: "age", \.age)
            }
          }
        }
        """#
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
        #"""
        public struct Person {
          private var name: String
          private var age: Int

          public var streamPartialValue: Partial {
            Partial(
              name: self.name.streamPartialValue,
              age: self.age.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          public struct Partial: StreamParsingCore.StreamParseableValue,
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

            public static func initialParseableValue() -> Self {
              Self()
            }

            public static func registerHandlers(
              in handlers: inout some StreamParsingCore.StreamParserHandlers<Self>
            ) {
              handlers.registerKeyedHandler(forKey: "name", \.name)
              handlers.registerKeyedHandler(forKey: "age", \.age)
            }
          }
        }
        """#
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
        #"""
        public struct Person {
          private var name: String?
          private var age: Optional<Int>

          public var streamPartialValue: Partial {
            Partial(
              name: self.name.streamPartialValue,
              age: self.age.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          public struct Partial: StreamParsingCore.StreamParseableValue,
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

            public static func initialParseableValue() -> Self {
              Self()
            }

            public static func registerHandlers(
              in handlers: inout some StreamParsingCore.StreamParserHandlers<Self>
            ) {
              handlers.registerKeyedHandler(forKey: "name", \.name)
              handlers.registerKeyedHandler(forKey: "age", \.age)
            }
          }
        }
        """#
      }
    }
    
    @Test
    func `Merges Multiple Member Macro Applications`() async throws {
      assertMacro {
        """
        @StreamParseable
        struct Person {
          @StreamParseableMember(key: "blob")
          @StreamParseableMember(key: "name2")
          var name: String
          var age: Int
        }
        """
      } expansion: {
        #"""
        struct Person {
          var name: String
          var age: Int

          var streamPartialValue: Partial {
            Partial(
              name: self.name.streamPartialValue,
              age: self.age.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseableValue,
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

            static func initialParseableValue() -> Self {
              Self()
            }

            static func registerHandlers(
              in handlers: inout some StreamParsingCore.StreamParserHandlers<Self>
            ) {
              handlers.registerKeyedHandler(forKey: "blob", \.name)
              handlers.registerKeyedHandler(forKey: "name2", \.name)
              handlers.registerKeyedHandler(forKey: "age", \.age)
            }
          }
        }
        """#
      }
      assertMacro {
        """
        @StreamParseable
        struct Person {
          @StreamParseableMember(keyNames: ["blob"])
          @StreamParseableMember(keyNames: ["name2"])
          var name: String
          var age: Int
        }
        """
      } expansion: {
        #"""
        struct Person {
          var name: String
          var age: Int

          var streamPartialValue: Partial {
            Partial(
              name: self.name.streamPartialValue,
              age: self.age.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseableValue,
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

            static func initialParseableValue() -> Self {
              Self()
            }

            static func registerHandlers(
              in handlers: inout some StreamParsingCore.StreamParserHandlers<Self>
            ) {
              handlers.registerKeyedHandler(forKey: "blob", \.name)
              handlers.registerKeyedHandler(forKey: "name2", \.name)
              handlers.registerKeyedHandler(forKey: "age", \.age)
            }
          }
        }
        """#
      }
      assertMacro {
        """
        @StreamParseable
        struct Person {
          @StreamParseableMember(keyNames: ["blob"])
          @StreamParseableMember(key: "name2")
          var name: String
          var age: Int
        }
        """
      } expansion: {
        #"""
        struct Person {
          var name: String
          var age: Int

          var streamPartialValue: Partial {
            Partial(
              name: self.name.streamPartialValue,
              age: self.age.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseableValue,
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

            static func initialParseableValue() -> Self {
              Self()
            }

            static func registerHandlers(
              in handlers: inout some StreamParsingCore.StreamParserHandlers<Self>
            ) {
              handlers.registerKeyedHandler(forKey: "blob", \.name)
              handlers.registerKeyedHandler(forKey: "name2", \.name)
              handlers.registerKeyedHandler(forKey: "age", \.age)
            }
          }
        }
        """#
      }
    }
  }
}
