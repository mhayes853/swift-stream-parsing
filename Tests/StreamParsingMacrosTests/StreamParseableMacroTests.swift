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

          var streamPartialValue: Partial {
            Partial(
              name: self.name.streamPartialValue,
              age: self.age.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject {
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

            static func streamInitialValue() -> Self {
              Self()
            }

            struct View: ~Copyable {
              let storage: UnsafeMutablePointer<Partial>

              init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            var name: String.Partial.View? {
                StreamParsingCore._streamMemberView(&self.storage.pointee.name)
              }

            var age: Int.Partial.View? {
                StreamParsingCore._streamMemberView(&self.storage.pointee.age)
              }
            }

            static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let name: Int32 = 0
              static let age: Int32 = 1
            }

            static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_0000_656D_616E where key.count == 4:
                return Self.StreamField.name
              case 0x0000_0000_0065_6761 where key.count == 3:
                return Self.StreamField.age
              default:
                return -1
              }
            }

            static func streamApplyString(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, utf8: bytes)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, utf8: bytes)
              default:
                return false
              }
            }

            static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, bytes: bytes, info: info)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, bytes: bytes, info: info)
              default:
                return false
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, boolean: value)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, boolean: value)
              default:
                return false
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return StreamParsing.streamApplyNull(&p.pointee.name)
              case Self.StreamField.age:
                return StreamParsing.streamApplyNull(&p.pointee.age)
              default:
                return false
              }
            }

            static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return _streamEnterField(&p.pointee.name)
              case Self.StreamField.age:
                return _streamEnterField(&p.pointee.age)
              default:
                return nil
              }
            }

            static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField
            )
          }
        }
        """
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
        """
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
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject {
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

            static func streamInitialValue() -> Self {
              Self()
            }

            struct View: ~Copyable {
              let storage: UnsafeMutablePointer<Partial>

              init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            var name: String.Partial.View? {
                StreamParsingCore._streamMemberView(&self.storage.pointee.name)
              }

            var age: Int.Partial.View? {
                StreamParsingCore._streamMemberView(&self.storage.pointee.age)
              }
            }

            static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let name: Int32 = 0
              static let age: Int32 = 1
            }

            static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x654B_6D6F_7473_7563 where key.count == 13 && key.paddedWord(at: 8) == 0x0000_0065_6D61_4E79:
                return Self.StreamField.name
              case 0x0000_0000_0065_6761 where key.count == 3:
                return Self.StreamField.age
              default:
                return -1
              }
            }

            static func streamApplyString(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, utf8: bytes)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, utf8: bytes)
              default:
                return false
              }
            }

            static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, bytes: bytes, info: info)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, bytes: bytes, info: info)
              default:
                return false
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, boolean: value)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, boolean: value)
              default:
                return false
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return StreamParsing.streamApplyNull(&p.pointee.name)
              case Self.StreamField.age:
                return StreamParsing.streamApplyNull(&p.pointee.age)
              default:
                return false
              }
            }

            static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return _streamEnterField(&p.pointee.name)
              case Self.StreamField.age:
                return _streamEnterField(&p.pointee.age)
              default:
                return nil
              }
            }

            static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField
            )
          }
        }
        """
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
        """
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
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject {
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

            static func streamInitialValue() -> Self {
              Self()
            }

            struct View: ~Copyable {
              let storage: UnsafeMutablePointer<Partial>

              init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            var name: String.Partial.View? {
                StreamParsingCore._streamMemberView(&self.storage.pointee.name)
              }

            var age: Int.Partial.View? {
                StreamParsingCore._streamMemberView(&self.storage.pointee.age)
              }
            }

            static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let name: Int32 = 0
              static let age: Int32 = 1
            }

            static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x654B_6D6F_7473_7563 where key.count == 13 && key.paddedWord(at: 8) == 0x0000_0065_6D61_4E79:
                return Self.StreamField.name
              case 0x654B_6D6F_7473_7563 where key.count == 14 && key.paddedWord(at: 8) == 0x0000_3265_6D61_4E79:
                return Self.StreamField.name
              case 0x0000_0000_0065_6761 where key.count == 3:
                return Self.StreamField.age
              default:
                return -1
              }
            }

            static func streamApplyString(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, utf8: bytes)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, utf8: bytes)
              default:
                return false
              }
            }

            static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, bytes: bytes, info: info)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, bytes: bytes, info: info)
              default:
                return false
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, boolean: value)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, boolean: value)
              default:
                return false
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return StreamParsing.streamApplyNull(&p.pointee.name)
              case Self.StreamField.age:
                return StreamParsing.streamApplyNull(&p.pointee.age)
              default:
                return false
              }
            }

            static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return _streamEnterField(&p.pointee.name)
              case Self.StreamField.age:
                return _streamEnterField(&p.pointee.age)
              default:
                return nil
              }
            }

            static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField
            )
          }
        }
        """
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
    func `Stream Initial Value Members`() {
      assertMacro {
        """
        @StreamParseable(partialMembers: .streamInitialValue)
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

          var streamPartialValue: Partial {
            Partial(
              name: self.name.streamPartialValue,
              age: self.age.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject {
            typealias Partial = Self

            var name: String.Partial
            var age: Int.Partial

            init(
              name: String.Partial = .streamInitialValue(),
              age: Int.Partial = .streamInitialValue()
            ) {
              self.name = name
              self.age = age
            }

            static func streamInitialValue() -> Self {
              Self()
            }

            struct View: ~Copyable {
              let storage: UnsafeMutablePointer<Partial>

              init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            var name: String.Partial.View? {
                StreamParsingCore._streamMemberView(&self.storage.pointee.name)
              }

            var age: Int.Partial.View? {
                StreamParsingCore._streamMemberView(&self.storage.pointee.age)
              }
            }

            static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let name: Int32 = 0
              static let age: Int32 = 1
            }

            static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_0000_656D_616E where key.count == 4:
                return Self.StreamField.name
              case 0x0000_0000_0065_6761 where key.count == 3:
                return Self.StreamField.age
              default:
                return -1
              }
            }

            static func streamApplyString(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, utf8: bytes)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, utf8: bytes)
              default:
                return false
              }
            }

            static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, bytes: bytes, info: info)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, bytes: bytes, info: info)
              default:
                return false
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, boolean: value)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, boolean: value)
              default:
                return false
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return StreamParsing.streamApplyNull(&p.pointee.name)
              case Self.StreamField.age:
                return StreamParsing.streamApplyNull(&p.pointee.age)
              default:
                return false
              }
            }

            static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return _streamEnterField(&p.pointee.name)
              case Self.StreamField.age:
                return _streamEnterField(&p.pointee.age)
              default:
                return nil
              }
            }

            static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField
            )
          }
        }
        """
      }
    }

    @Test
    func `Stream Initial Value Members With Optionals`() {
      assertMacro {
        """
        @StreamParseable(partialMembers: .streamInitialValue)
        struct Person {
          var name: String?
          var age: Int?
        }
        """
      } expansion: {
        """
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
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject {
            typealias Partial = Self

            var name: String?.Partial
            var age: Int?.Partial

            init(
              name: String?.Partial = .streamInitialValue(),
              age: Int?.Partial = .streamInitialValue()
            ) {
              self.name = name
              self.age = age
            }

            static func streamInitialValue() -> Self {
              Self()
            }

            struct View: ~Copyable {
              let storage: UnsafeMutablePointer<Partial>

              init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            var name: String?.Partial.View? {
                StreamParsingCore._streamMemberView(&self.storage.pointee.name)
              }

            var age: Int?.Partial.View? {
                StreamParsingCore._streamMemberView(&self.storage.pointee.age)
              }
            }

            static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let name: Int32 = 0
              static let age: Int32 = 1
            }

            static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_0000_656D_616E where key.count == 4:
                return Self.StreamField.name
              case 0x0000_0000_0065_6761 where key.count == 3:
                return Self.StreamField.age
              default:
                return -1
              }
            }

            static func streamApplyString(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, utf8: bytes)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, utf8: bytes)
              default:
                return false
              }
            }

            static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, bytes: bytes, info: info)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, bytes: bytes, info: info)
              default:
                return false
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, boolean: value)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, boolean: value)
              default:
                return false
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return StreamParsing.streamApplyNull(&p.pointee.name)
              case Self.StreamField.age:
                return StreamParsing.streamApplyNull(&p.pointee.age)
              default:
                return false
              }
            }

            static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return _streamEnterField(&p.pointee.name)
              case Self.StreamField.age:
                return _streamEnterField(&p.pointee.age)
              default:
                return nil
              }
            }

            static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField
            )
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

          var streamPartialValue: Partial {
            Partial(
              age: self.age.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject {
            typealias Partial = Self

            var age: Int.Partial?

            init(
              age: Int.Partial? = nil
            ) {
              self.age = age
            }

            static func streamInitialValue() -> Self {
              Self()
            }

            struct View: ~Copyable {
              let storage: UnsafeMutablePointer<Partial>

              init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            var age: Int.Partial.View? {
                StreamParsingCore._streamMemberView(&self.storage.pointee.age)
              }
            }

            static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let age: Int32 = 0
            }

            static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_0000_0065_6761 where key.count == 3:
                return Self.StreamField.age
              default:
                return -1
              }
            }

            static func streamApplyString(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, utf8: bytes)
              default:
                return false
              }
            }

            static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, bytes: bytes, info: info)
              default:
                return false
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, boolean: value)
              default:
                return false
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.age:
                return StreamParsing.streamApplyNull(&p.pointee.age)
              default:
                return false
              }
            }

            static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.age:
                return _streamEnterField(&p.pointee.age)
              default:
                return nil
              }
            }

            static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField
            )
          }
        }
        """
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
        """
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
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject {
            typealias Partial = Self

            var stored: String.Partial?

            init(
              stored: String.Partial? = nil
            ) {
              self.stored = stored
            }

            static func streamInitialValue() -> Self {
              Self()
            }

            struct View: ~Copyable {
              let storage: UnsafeMutablePointer<Partial>

              init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            var stored: String.Partial.View? {
                StreamParsingCore._streamMemberView(&self.storage.pointee.stored)
              }
            }

            static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let stored: Int32 = 0
            }

            static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_6465_726F_7473 where key.count == 6:
                return Self.StreamField.stored
              default:
                return -1
              }
            }

            static func streamApplyString(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.stored:
                return streamApply(&p.pointee.stored, utf8: bytes)
              default:
                return false
              }
            }

            static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.stored:
                return streamApply(&p.pointee.stored, bytes: bytes, info: info)
              default:
                return false
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.stored:
                return streamApply(&p.pointee.stored, boolean: value)
              default:
                return false
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.stored:
                return StreamParsing.streamApplyNull(&p.pointee.stored)
              default:
                return false
              }
            }

            static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.stored:
                return _streamEnterField(&p.pointee.stored)
              default:
                return nil
              }
            }

            static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField
            )
          }
        }
        """
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
        """
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
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject {
            typealias Partial = Self

            var name: String.Partial?

            init(
              name: String.Partial? = nil
            ) {
              self.name = name
            }

            static func streamInitialValue() -> Self {
              Self()
            }

            struct View: ~Copyable {
              let storage: UnsafeMutablePointer<Partial>

              init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            var name: String.Partial.View? {
                StreamParsingCore._streamMemberView(&self.storage.pointee.name)
              }
            }

            static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let name: Int32 = 0
            }

            static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_0000_656D_616E where key.count == 4:
                return Self.StreamField.name
              default:
                return -1
              }
            }

            static func streamApplyString(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, utf8: bytes)
              default:
                return false
              }
            }

            static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, bytes: bytes, info: info)
              default:
                return false
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, boolean: value)
              default:
                return false
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return StreamParsing.streamApplyNull(&p.pointee.name)
              default:
                return false
              }
            }

            static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return _streamEnterField(&p.pointee.name)
              default:
                return nil
              }
            }

            static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField
            )
          }
        }
        """
      }
    }

    @Test
    func `StreamParseableMember And StreamParseableIgnored On Same Property`() {
      assertMacro {
        """
        @StreamParseable
        struct Person {
          @StreamParseableMember(key: "name")
          @StreamParseableIgnored
          var name: String
        }
        """
      } diagnostics: {
        """
        @StreamParseable
        struct Person {
          @StreamParseableMember(key: "name")
          ┬──────────────────────────────────
          ├─ 🛑 @StreamParseableMember and @StreamParseableIgnored cannot be applied to the same property.
          ╰─ 🛑 @StreamParseableMember and @StreamParseableIgnored cannot be applied to the same property.
          @StreamParseableIgnored
          var name: String
        }
        """
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
        """
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
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject {
            typealias Partial = Self

            var stored: String.Partial?

            init(
              stored: String.Partial? = nil
            ) {
              self.stored = stored
            }

            static func streamInitialValue() -> Self {
              Self()
            }

            struct View: ~Copyable {
              let storage: UnsafeMutablePointer<Partial>

              init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            var stored: String.Partial.View? {
                StreamParsingCore._streamMemberView(&self.storage.pointee.stored)
              }
            }

            static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let stored: Int32 = 0
            }

            static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_6465_726F_7473 where key.count == 6:
                return Self.StreamField.stored
              default:
                return -1
              }
            }

            static func streamApplyString(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.stored:
                return streamApply(&p.pointee.stored, utf8: bytes)
              default:
                return false
              }
            }

            static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.stored:
                return streamApply(&p.pointee.stored, bytes: bytes, info: info)
              default:
                return false
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.stored:
                return streamApply(&p.pointee.stored, boolean: value)
              default:
                return false
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.stored:
                return StreamParsing.streamApplyNull(&p.pointee.stored)
              default:
                return false
              }
            }

            static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.stored:
                return _streamEnterField(&p.pointee.stored)
              default:
                return nil
              }
            }

            static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField
            )
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

          var streamPartialValue: Partial {
            Partial(
              name: self.name.streamPartialValue,
              age: self.age.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject {
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

            static func streamInitialValue() -> Self {
              Self()
            }

            struct View: ~Copyable {
              let storage: UnsafeMutablePointer<Partial>

              init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            var name: String.Partial.View? {
                StreamParsingCore._streamMemberView(&self.storage.pointee.name)
              }

            var age: Int.Partial.View? {
                StreamParsingCore._streamMemberView(&self.storage.pointee.age)
              }
            }

            static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let name: Int32 = 0
              static let age: Int32 = 1
            }

            static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_0000_656D_616E where key.count == 4:
                return Self.StreamField.name
              case 0x0000_0000_0065_6761 where key.count == 3:
                return Self.StreamField.age
              default:
                return -1
              }
            }

            static func streamApplyString(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, utf8: bytes)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, utf8: bytes)
              default:
                return false
              }
            }

            static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, bytes: bytes, info: info)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, bytes: bytes, info: info)
              default:
                return false
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, boolean: value)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, boolean: value)
              default:
                return false
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return StreamParsing.streamApplyNull(&p.pointee.name)
              case Self.StreamField.age:
                return StreamParsing.streamApplyNull(&p.pointee.age)
              default:
                return false
              }
            }

            static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return _streamEnterField(&p.pointee.name)
              case Self.StreamField.age:
                return _streamEnterField(&p.pointee.age)
              default:
                return nil
              }
            }

            static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField
            )
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
        """
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
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject {
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

            static func streamInitialValue() -> Self {
              Self()
            }

            struct View: ~Copyable {
              let storage: UnsafeMutablePointer<Partial>

              init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            var name: String.Partial.View? {
                StreamParsingCore._streamMemberView(&self.storage.pointee.name)
              }

            var age: Int.Partial.View? {
                StreamParsingCore._streamMemberView(&self.storage.pointee.age)
              }
            }

            static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let name: Int32 = 0
              static let age: Int32 = 1
            }

            static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_0000_656D_616E where key.count == 4:
                return Self.StreamField.name
              case 0x0000_0000_0065_6761 where key.count == 3:
                return Self.StreamField.age
              default:
                return -1
              }
            }

            static func streamApplyString(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, utf8: bytes)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, utf8: bytes)
              default:
                return false
              }
            }

            static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, bytes: bytes, info: info)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, bytes: bytes, info: info)
              default:
                return false
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, boolean: value)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, boolean: value)
              default:
                return false
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return StreamParsing.streamApplyNull(&p.pointee.name)
              case Self.StreamField.age:
                return StreamParsing.streamApplyNull(&p.pointee.age)
              default:
                return false
              }
            }

            static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return _streamEnterField(&p.pointee.name)
              case Self.StreamField.age:
                return _streamEnterField(&p.pointee.age)
              default:
                return nil
              }
            }

            static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField
            )
          }
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

          public var streamPartialValue: Partial {
            Partial(
              name: self.name.streamPartialValue,
              age: self.age.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          public struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject {
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

            public static func streamInitialValue() -> Self {
              Self()
            }

            public struct View: ~Copyable {
              public let storage: UnsafeMutablePointer<Partial>

              public init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            public var name: String.Partial.View? {
                StreamParsingCore._streamMemberView(&self.storage.pointee.name)
              }

            public var age: Int.Partial.View? {
                StreamParsingCore._streamMemberView(&self.storage.pointee.age)
              }
            }

            public static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let name: Int32 = 0
              static let age: Int32 = 1
            }

            public static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_0000_656D_616E where key.count == 4:
                return Self.StreamField.name
              case 0x0000_0000_0065_6761 where key.count == 3:
                return Self.StreamField.age
              default:
                return -1
              }
            }

            public static func streamApplyString(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, utf8: bytes)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, utf8: bytes)
              default:
                return false
              }
            }

            public static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, bytes: bytes, info: info)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, bytes: bytes, info: info)
              default:
                return false
              }
            }

            public static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, boolean: value)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, boolean: value)
              default:
                return false
              }
            }

            public static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return StreamParsing.streamApplyNull(&p.pointee.name)
              case Self.StreamField.age:
                return StreamParsing.streamApplyNull(&p.pointee.age)
              default:
                return false
              }
            }

            public static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return _streamEnterField(&p.pointee.name)
              case Self.StreamField.age:
                return _streamEnterField(&p.pointee.age)
              default:
                return nil
              }
            }

            public static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField
            )
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

          var streamPartialValue: Partial {
            Partial(
              name: self.name.streamPartialValue,
              age: self.age.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject {
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

            static func streamInitialValue() -> Self {
              Self()
            }

            struct View: ~Copyable {
              let storage: UnsafeMutablePointer<Partial>

              init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            var name: String.Partial.View? {
                StreamParsingCore._streamMemberView(&self.storage.pointee.name)
              }

            var age: Int.Partial.View? {
                StreamParsingCore._streamMemberView(&self.storage.pointee.age)
              }
            }

            static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let name: Int32 = 0
              static let age: Int32 = 1
            }

            static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_0000_656D_616E where key.count == 4:
                return Self.StreamField.name
              case 0x0000_0000_0065_6761 where key.count == 3:
                return Self.StreamField.age
              default:
                return -1
              }
            }

            static func streamApplyString(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, utf8: bytes)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, utf8: bytes)
              default:
                return false
              }
            }

            static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, bytes: bytes, info: info)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, bytes: bytes, info: info)
              default:
                return false
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, boolean: value)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, boolean: value)
              default:
                return false
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return StreamParsing.streamApplyNull(&p.pointee.name)
              case Self.StreamField.age:
                return StreamParsing.streamApplyNull(&p.pointee.age)
              default:
                return false
              }
            }

            static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return _streamEnterField(&p.pointee.name)
              case Self.StreamField.age:
                return _streamEnterField(&p.pointee.age)
              default:
                return nil
              }
            }

            static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField
            )
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

          fileprivate var streamPartialValue: Partial {
            Partial(
              name: self.name.streamPartialValue,
              age: self.age.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          fileprivate struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject {
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

            fileprivate static func streamInitialValue() -> Self {
              Self()
            }

            fileprivate struct View: ~Copyable {
              fileprivate let storage: UnsafeMutablePointer<Partial>

              fileprivate init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            fileprivate var name: String.Partial.View? {
                StreamParsingCore._streamMemberView(&self.storage.pointee.name)
              }

            fileprivate var age: Int.Partial.View? {
                StreamParsingCore._streamMemberView(&self.storage.pointee.age)
              }
            }

            fileprivate static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let name: Int32 = 0
              static let age: Int32 = 1
            }

            fileprivate static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_0000_656D_616E where key.count == 4:
                return Self.StreamField.name
              case 0x0000_0000_0065_6761 where key.count == 3:
                return Self.StreamField.age
              default:
                return -1
              }
            }

            fileprivate static func streamApplyString(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, utf8: bytes)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, utf8: bytes)
              default:
                return false
              }
            }

            fileprivate static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, bytes: bytes, info: info)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, bytes: bytes, info: info)
              default:
                return false
              }
            }

            fileprivate static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, boolean: value)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, boolean: value)
              default:
                return false
              }
            }

            fileprivate static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return StreamParsing.streamApplyNull(&p.pointee.name)
              case Self.StreamField.age:
                return StreamParsing.streamApplyNull(&p.pointee.age)
              default:
                return false
              }
            }

            fileprivate static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return _streamEnterField(&p.pointee.name)
              case Self.StreamField.age:
                return _streamEnterField(&p.pointee.age)
              default:
                return nil
              }
            }

            fileprivate static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField
            )
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

          public var streamPartialValue: Partial {
            Partial(
              name: self.name.streamPartialValue,
              age: self.age.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          public struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject {
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

            public static func streamInitialValue() -> Self {
              Self()
            }

            public struct View: ~Copyable {
              public let storage: UnsafeMutablePointer<Partial>

              public init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            public var name: String.Partial.View? {
                StreamParsingCore._streamMemberView(&self.storage.pointee.name)
              }

            public var age: Int.Partial.View? {
                StreamParsingCore._streamMemberView(&self.storage.pointee.age)
              }
            }

            public static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let name: Int32 = 0
              static let age: Int32 = 1
            }

            public static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_0000_656D_616E where key.count == 4:
                return Self.StreamField.name
              case 0x0000_0000_0065_6761 where key.count == 3:
                return Self.StreamField.age
              default:
                return -1
              }
            }

            public static func streamApplyString(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, utf8: bytes)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, utf8: bytes)
              default:
                return false
              }
            }

            public static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, bytes: bytes, info: info)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, bytes: bytes, info: info)
              default:
                return false
              }
            }

            public static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, boolean: value)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, boolean: value)
              default:
                return false
              }
            }

            public static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return StreamParsing.streamApplyNull(&p.pointee.name)
              case Self.StreamField.age:
                return StreamParsing.streamApplyNull(&p.pointee.age)
              default:
                return false
              }
            }

            public static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return _streamEnterField(&p.pointee.name)
              case Self.StreamField.age:
                return _streamEnterField(&p.pointee.age)
              default:
                return nil
              }
            }

            public static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField
            )
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

          public var streamPartialValue: Partial {
            Partial(
              name: self.name.streamPartialValue,
              age: self.age.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          public struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject {
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

            public static func streamInitialValue() -> Self {
              Self()
            }

            public struct View: ~Copyable {
              public let storage: UnsafeMutablePointer<Partial>

              public init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            public var name: String?.Partial.View? {
                StreamParsingCore._streamMemberView(&self.storage.pointee.name)
              }

            public var age: Optional<Int>.Partial.View? {
                StreamParsingCore._streamMemberView(&self.storage.pointee.age)
              }
            }

            public static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let name: Int32 = 0
              static let age: Int32 = 1
            }

            public static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_0000_656D_616E where key.count == 4:
                return Self.StreamField.name
              case 0x0000_0000_0065_6761 where key.count == 3:
                return Self.StreamField.age
              default:
                return -1
              }
            }

            public static func streamApplyString(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, utf8: bytes)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, utf8: bytes)
              default:
                return false
              }
            }

            public static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, bytes: bytes, info: info)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, bytes: bytes, info: info)
              default:
                return false
              }
            }

            public static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, boolean: value)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, boolean: value)
              default:
                return false
              }
            }

            public static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return StreamParsing.streamApplyNull(&p.pointee.name)
              case Self.StreamField.age:
                return StreamParsing.streamApplyNull(&p.pointee.age)
              default:
                return false
              }
            }

            public static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return _streamEnterField(&p.pointee.name)
              case Self.StreamField.age:
                return _streamEnterField(&p.pointee.age)
              default:
                return nil
              }
            }

            public static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField
            )
          }
        }
        """
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
        """
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
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject {
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

            static func streamInitialValue() -> Self {
              Self()
            }

            struct View: ~Copyable {
              let storage: UnsafeMutablePointer<Partial>

              init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            var name: String.Partial.View? {
                StreamParsingCore._streamMemberView(&self.storage.pointee.name)
              }

            var age: Int.Partial.View? {
                StreamParsingCore._streamMemberView(&self.storage.pointee.age)
              }
            }

            static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let name: Int32 = 0
              static let age: Int32 = 1
            }

            static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_0000_626F_6C62 where key.count == 4:
                return Self.StreamField.name
              case 0x0000_0032_656D_616E where key.count == 5:
                return Self.StreamField.name
              case 0x0000_0000_0065_6761 where key.count == 3:
                return Self.StreamField.age
              default:
                return -1
              }
            }

            static func streamApplyString(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, utf8: bytes)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, utf8: bytes)
              default:
                return false
              }
            }

            static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, bytes: bytes, info: info)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, bytes: bytes, info: info)
              default:
                return false
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, boolean: value)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, boolean: value)
              default:
                return false
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return StreamParsing.streamApplyNull(&p.pointee.name)
              case Self.StreamField.age:
                return StreamParsing.streamApplyNull(&p.pointee.age)
              default:
                return false
              }
            }

            static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return _streamEnterField(&p.pointee.name)
              case Self.StreamField.age:
                return _streamEnterField(&p.pointee.age)
              default:
                return nil
              }
            }

            static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField
            )
          }
        }
        """
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
        """
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
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject {
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

            static func streamInitialValue() -> Self {
              Self()
            }

            struct View: ~Copyable {
              let storage: UnsafeMutablePointer<Partial>

              init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            var name: String.Partial.View? {
                StreamParsingCore._streamMemberView(&self.storage.pointee.name)
              }

            var age: Int.Partial.View? {
                StreamParsingCore._streamMemberView(&self.storage.pointee.age)
              }
            }

            static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let name: Int32 = 0
              static let age: Int32 = 1
            }

            static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_0000_626F_6C62 where key.count == 4:
                return Self.StreamField.name
              case 0x0000_0032_656D_616E where key.count == 5:
                return Self.StreamField.name
              case 0x0000_0000_0065_6761 where key.count == 3:
                return Self.StreamField.age
              default:
                return -1
              }
            }

            static func streamApplyString(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, utf8: bytes)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, utf8: bytes)
              default:
                return false
              }
            }

            static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, bytes: bytes, info: info)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, bytes: bytes, info: info)
              default:
                return false
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, boolean: value)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, boolean: value)
              default:
                return false
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return StreamParsing.streamApplyNull(&p.pointee.name)
              case Self.StreamField.age:
                return StreamParsing.streamApplyNull(&p.pointee.age)
              default:
                return false
              }
            }

            static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return _streamEnterField(&p.pointee.name)
              case Self.StreamField.age:
                return _streamEnterField(&p.pointee.age)
              default:
                return nil
              }
            }

            static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField
            )
          }
        }
        """
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
        """
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
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject {
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

            static func streamInitialValue() -> Self {
              Self()
            }

            struct View: ~Copyable {
              let storage: UnsafeMutablePointer<Partial>

              init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            var name: String.Partial.View? {
                StreamParsingCore._streamMemberView(&self.storage.pointee.name)
              }

            var age: Int.Partial.View? {
                StreamParsingCore._streamMemberView(&self.storage.pointee.age)
              }
            }

            static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let name: Int32 = 0
              static let age: Int32 = 1
            }

            static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_0000_626F_6C62 where key.count == 4:
                return Self.StreamField.name
              case 0x0000_0032_656D_616E where key.count == 5:
                return Self.StreamField.name
              case 0x0000_0000_0065_6761 where key.count == 3:
                return Self.StreamField.age
              default:
                return -1
              }
            }

            static func streamApplyString(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, utf8: bytes)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, utf8: bytes)
              default:
                return false
              }
            }

            static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, bytes: bytes, info: info)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, bytes: bytes, info: info)
              default:
                return false
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, boolean: value)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, boolean: value)
              default:
                return false
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> Bool {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return StreamParsing.streamApplyNull(&p.pointee.name)
              case Self.StreamField.age:
                return StreamParsing.streamApplyNull(&p.pointee.age)
              default:
                return false
              }
            }

            static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return _streamEnterField(&p.pointee.name)
              case Self.StreamField.age:
                return _streamEnterField(&p.pointee.age)
              default:
                return nil
              }
            }

            static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField
            )
          }
        }
        """
      }
    }
    @Test
    func `Container Members Only`() {
      assertMacro {
        """
        @StreamParseable
        struct Feed {
          var items: [Item]
          var index: [String: Item]
        }
        """
      } expansion: {
        #"""
        struct Feed {
          var items: [Item]
          var index: [String: Item]

          var streamPartialValue: Partial {
            Partial(
              items: self.items.streamPartialValue,
              index: StreamParsingCore.StreamDictionary(self.index.mapValues(\.streamPartialValue))
            )
          }
        }

        extension Feed: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject {
            typealias Partial = Self

            var items: [Item].Partial?
            var index: StreamParsingCore.StreamDictionary<Item.Partial>?

            init(
              items: [Item].Partial? = nil,
              index: StreamParsingCore.StreamDictionary<Item.Partial>? = nil
            ) {
              self.items = items
              self.index = index
            }

            static func streamInitialValue() -> Self {
              Self()
            }

            struct View: ~Copyable {
              let storage: UnsafeMutablePointer<Partial>

              init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            var items: [Item].Partial.View? {
                StreamParsingCore._streamMemberView(&self.storage.pointee.items)
              }

            var index: StreamParsingCore.StreamDictionary<Item.Partial>.View? {
                StreamParsingCore._streamMemberView(&self.storage.pointee.index)
              }
            }

            static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let items: Int32 = 0
              static let index: Int32 = 1
            }

            private static let streamContainerSchema_items = _streamArraySchema(Item.Partial.self, element: _streamSchema(for: Item.Partial.self))
            private static let streamContainerSchema_index = _streamDictionarySchema(Item.Partial.self, value: _streamSchema(for: Item.Partial.self))

            static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_0073_6D65_7469 where key.count == 5:
                return Self.StreamField.items
              case 0x0000_0078_6564_6E69 where key.count == 5:
                return Self.StreamField.index
              default:
                return -1
              }
            }

            static func streamApplyString(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>
            ) -> Bool {
              switch field {
              default:
                return false
              }
            }

            static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> Bool {
              switch field {
              default:
                return false
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> Bool {
              switch field {
              default:
                return false
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> Bool {
              switch field {
              default:
                return false
              }
            }

            static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.items:
                return _streamEnterContainerField(&p.pointee.items, schema: Self.streamContainerSchema_items)
              case Self.StreamField.index:
                return _streamEnterContainerField(&p.pointee.index, schema: Self.streamContainerSchema_index)
              default:
                return nil
              }
            }

            static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField
            )
          }
        }
        """#
      }
    }

  }
}
