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

            struct View: ~Copyable, ~Escapable {
              let storage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            var name: String.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.name) else {
                    return nil
                  }
                  return _overrideLifetime(String.Partial.streamView(address), borrowing: self)
                }
              }

            var age: Int.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.age) else {
                    return nil
                  }
                  return _overrideLifetime(Int.Partial.streamView(address), borrowing: self)
                }
              }
            }

            @_lifetime(borrow storage)
            static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let name: Int32 = 0
              static let age: Int32 = 1
            }

            private static let streamContainerSchema_name = _streamContainerSchema(for: (String.Partial).self)
            private static let streamContainerSchema_age = _streamContainerSchema(for: (Int.Partial).self)

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
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, utf8: bytes)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, utf8: bytes)
              default:
                return .unsupported
              }
            }

            static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, bytes: bytes, info: info)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, bytes: bytes, info: info)
              default:
                return .unsupported
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, boolean: value)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, boolean: value)
              default:
                return .unsupported
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return StreamParsing.streamApplyNull(&p.pointee.name)
              case Self.StreamField.age:
                return StreamParsing.streamApplyNull(&p.pointee.age)
              default:
                return .unsupported
              }
            }

            static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return _streamEnterField(&p.pointee.name, containerSchema: Self.streamContainerSchema_name)
              case Self.StreamField.age:
                return _streamEnterField(&p.pointee.age, containerSchema: Self.streamContainerSchema_age)
              default:
                return nil
              }
            }

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "name", index: Self.StreamField.name,
                  route: _streamFieldRoute(&p.pointee.name),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.name, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "age", index: Self.StreamField.age,
                  route: _streamFieldRoute(&p.pointee.age),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.age, in: p)
                ),
              ]
            }

            static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField,
              fields: Self.streamFields
            )
          }

          init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          /// Fails when the stream did not produce a member this type has no way to do without.
          init?(streamPartial partial: Partial) {
            guard
              let name = Self._streamValue({ $0.name
              }, partial.name),
              let age = Self._streamValue({ $0.age
              }, partial.age)
            else {
              return nil
            }
            self.name = name
            self.age = age
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          init(orInitial partial: Partial) {
            self.name = Self._streamValueOrInitial({
                $0.name
              }, partial.name)
            self.age = Self._streamValueOrInitial({
                $0.age
              }, partial.age)
          }

          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
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

            struct View: ~Copyable, ~Escapable {
              let storage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            var name: String.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.name) else {
                    return nil
                  }
                  return _overrideLifetime(String.Partial.streamView(address), borrowing: self)
                }
              }

            var age: Int.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.age) else {
                    return nil
                  }
                  return _overrideLifetime(Int.Partial.streamView(address), borrowing: self)
                }
              }
            }

            @_lifetime(borrow storage)
            static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let name: Int32 = 0
              static let age: Int32 = 1
            }

            private static let streamContainerSchema_name = _streamContainerSchema(for: (String.Partial).self)
            private static let streamContainerSchema_age = _streamContainerSchema(for: (Int.Partial).self)

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
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, utf8: bytes)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, utf8: bytes)
              default:
                return .unsupported
              }
            }

            static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, bytes: bytes, info: info)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, bytes: bytes, info: info)
              default:
                return .unsupported
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, boolean: value)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, boolean: value)
              default:
                return .unsupported
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return StreamParsing.streamApplyNull(&p.pointee.name)
              case Self.StreamField.age:
                return StreamParsing.streamApplyNull(&p.pointee.age)
              default:
                return .unsupported
              }
            }

            static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return _streamEnterField(&p.pointee.name, containerSchema: Self.streamContainerSchema_name)
              case Self.StreamField.age:
                return _streamEnterField(&p.pointee.age, containerSchema: Self.streamContainerSchema_age)
              default:
                return nil
              }
            }

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "customKeyName", index: Self.StreamField.name,
                  route: _streamFieldRoute(&p.pointee.name),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.name, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "age", index: Self.StreamField.age,
                  route: _streamFieldRoute(&p.pointee.age),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.age, in: p)
                ),
              ]
            }

            static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField,
              fields: Self.streamFields
            )
          }

          init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          /// Fails when the stream did not produce a member this type has no way to do without.
          init?(streamPartial partial: Partial) {
            guard
              let name = Self._streamValue({ $0.name
              }, partial.name),
              let age = Self._streamValue({ $0.age
              }, partial.age)
            else {
              return nil
            }
            self.name = name
            self.age = age
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          init(orInitial partial: Partial) {
            self.name = Self._streamValueOrInitial({
                $0.name
              }, partial.name)
            self.age = Self._streamValueOrInitial({
                $0.age
              }, partial.age)
          }

          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
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

            struct View: ~Copyable, ~Escapable {
              let storage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            var name: String.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.name) else {
                    return nil
                  }
                  return _overrideLifetime(String.Partial.streamView(address), borrowing: self)
                }
              }

            var age: Int.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.age) else {
                    return nil
                  }
                  return _overrideLifetime(Int.Partial.streamView(address), borrowing: self)
                }
              }
            }

            @_lifetime(borrow storage)
            static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let name: Int32 = 0
              static let age: Int32 = 1
            }

            private static let streamContainerSchema_name = _streamContainerSchema(for: (String.Partial).self)
            private static let streamContainerSchema_age = _streamContainerSchema(for: (Int.Partial).self)

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
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, utf8: bytes)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, utf8: bytes)
              default:
                return .unsupported
              }
            }

            static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, bytes: bytes, info: info)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, bytes: bytes, info: info)
              default:
                return .unsupported
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, boolean: value)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, boolean: value)
              default:
                return .unsupported
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return StreamParsing.streamApplyNull(&p.pointee.name)
              case Self.StreamField.age:
                return StreamParsing.streamApplyNull(&p.pointee.age)
              default:
                return .unsupported
              }
            }

            static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return _streamEnterField(&p.pointee.name, containerSchema: Self.streamContainerSchema_name)
              case Self.StreamField.age:
                return _streamEnterField(&p.pointee.age, containerSchema: Self.streamContainerSchema_age)
              default:
                return nil
              }
            }

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "customKeyName", index: Self.StreamField.name,
                  route: _streamFieldRoute(&p.pointee.name),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.name, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "customKeyName2", index: Self.StreamField.name,
                  route: _streamFieldRoute(&p.pointee.name),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.name, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "age", index: Self.StreamField.age,
                  route: _streamFieldRoute(&p.pointee.age),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.age, in: p)
                ),
              ]
            }

            static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField,
              fields: Self.streamFields
            )
          }

          init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          /// Fails when the stream did not produce a member this type has no way to do without.
          init?(streamPartial partial: Partial) {
            guard
              let name = Self._streamValue({ $0.name
              }, partial.name),
              let age = Self._streamValue({ $0.age
              }, partial.age)
            else {
              return nil
            }
            self.name = name
            self.age = age
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          init(orInitial partial: Partial) {
            self.name = Self._streamValueOrInitial({
                $0.name
              }, partial.name)
            self.age = Self._streamValueOrInitial({
                $0.age
              }, partial.age)
          }

          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
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

            struct View: ~Copyable, ~Escapable {
              let storage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            var name: String.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.name) else {
                    return nil
                  }
                  return _overrideLifetime(String.Partial.streamView(address), borrowing: self)
                }
              }

            var age: Int.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.age) else {
                    return nil
                  }
                  return _overrideLifetime(Int.Partial.streamView(address), borrowing: self)
                }
              }
            }

            @_lifetime(borrow storage)
            static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let name: Int32 = 0
              static let age: Int32 = 1
            }

            private static let streamContainerSchema_name = _streamContainerSchema(for: (String.Partial).self)
            private static let streamContainerSchema_age = _streamContainerSchema(for: (Int.Partial).self)

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
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, utf8: bytes)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, utf8: bytes)
              default:
                return .unsupported
              }
            }

            static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, bytes: bytes, info: info)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, bytes: bytes, info: info)
              default:
                return .unsupported
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, boolean: value)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, boolean: value)
              default:
                return .unsupported
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return StreamParsing.streamApplyNull(&p.pointee.name)
              case Self.StreamField.age:
                return StreamParsing.streamApplyNull(&p.pointee.age)
              default:
                return .unsupported
              }
            }

            static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return _streamEnterField(&p.pointee.name, containerSchema: Self.streamContainerSchema_name)
              case Self.StreamField.age:
                return _streamEnterField(&p.pointee.age, containerSchema: Self.streamContainerSchema_age)
              default:
                return nil
              }
            }

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "name", index: Self.StreamField.name,
                  route: _streamFieldRoute(&p.pointee.name),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.name, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "age", index: Self.StreamField.age,
                  route: _streamFieldRoute(&p.pointee.age),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.age, in: p)
                ),
              ]
            }

            static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField,
              fields: Self.streamFields
            )
          }

          init(_ partial: Partial) {
            self.init(orInitial: partial)
          }

          /// Fails when the stream did not produce a member this type has no way to do without.
          init?(streamPartial partial: Partial) {
            guard
              let name = Self._streamValue({ $0.name
              }, partial.name),
              let age = Self._streamValue({ $0.age
              }, partial.age)
            else {
              return nil
            }
            self.name = name
            self.age = age
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          init(orInitial partial: Partial) {
            self.name = Self._streamValueOrInitial({
                $0.name
              }, partial.name)
            self.age = Self._streamValueOrInitial({
                $0.age
              }, partial.age)
          }

          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
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

            var name: String.Partial?
            var age: Int.Partial?

            init(
              name: String.Partial? = .streamInitialValue(),
              age: Int.Partial? = .streamInitialValue()
            ) {
              self.name = name
              self.age = age
            }

            static func streamInitialValue() -> Self {
              Self()
            }

            struct View: ~Copyable, ~Escapable {
              let storage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            var name: String.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.name) else {
                    return nil
                  }
                  return _overrideLifetime(String.Partial.streamView(address), borrowing: self)
                }
              }

            var age: Int.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.age) else {
                    return nil
                  }
                  return _overrideLifetime(Int.Partial.streamView(address), borrowing: self)
                }
              }
            }

            @_lifetime(borrow storage)
            static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let name: Int32 = 0
              static let age: Int32 = 1
            }

            private static let streamContainerSchema_name = _streamContainerSchema(for: (String.Partial).self)
            private static let streamContainerSchema_age = _streamContainerSchema(for: (Int.Partial).self)

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
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, utf8: bytes)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, utf8: bytes)
              default:
                return .unsupported
              }
            }

            static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, bytes: bytes, info: info)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, bytes: bytes, info: info)
              default:
                return .unsupported
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, boolean: value)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, boolean: value)
              default:
                return .unsupported
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return StreamParsing.streamApplyNull(&p.pointee.name)
              case Self.StreamField.age:
                return StreamParsing.streamApplyNull(&p.pointee.age)
              default:
                return .unsupported
              }
            }

            static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return _streamEnterField(&p.pointee.name, containerSchema: Self.streamContainerSchema_name)
              case Self.StreamField.age:
                return _streamEnterField(&p.pointee.age, containerSchema: Self.streamContainerSchema_age)
              default:
                return nil
              }
            }

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "name", index: Self.StreamField.name,
                  route: _streamFieldRoute(&p.pointee.name),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.name, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "age", index: Self.StreamField.age,
                  route: _streamFieldRoute(&p.pointee.age),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.age, in: p)
                ),
              ]
            }

            static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField,
              fields: Self.streamFields
            )
          }

          init(_ partial: Partial) {
            self.init(orInitial: partial)
          }

          /// Fails when the stream did not produce a member this type has no way to do without.
          init?(streamPartial partial: Partial) {
            guard
              let name = Self._streamValue({ $0.name
              }, partial.name),
              let age = Self._streamValue({ $0.age
              }, partial.age)
            else {
              return nil
            }
            self.name = name
            self.age = age
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          init(orInitial partial: Partial) {
            self.name = Self._streamValueOrInitial({
                $0.name
              }, partial.name)
            self.age = Self._streamValueOrInitial({
                $0.age
              }, partial.age)
          }

          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
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

            struct View: ~Copyable, ~Escapable {
              let storage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            var age: Int.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.age) else {
                    return nil
                  }
                  return _overrideLifetime(Int.Partial.streamView(address), borrowing: self)
                }
              }
            }

            @_lifetime(borrow storage)
            static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let age: Int32 = 0
            }

            private static let streamContainerSchema_age = _streamContainerSchema(for: (Int.Partial).self)

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
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, utf8: bytes)
              default:
                return .unsupported
              }
            }

            static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, bytes: bytes, info: info)
              default:
                return .unsupported
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, boolean: value)
              default:
                return .unsupported
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.age:
                return StreamParsing.streamApplyNull(&p.pointee.age)
              default:
                return .unsupported
              }
            }

            static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.age:
                return _streamEnterField(&p.pointee.age, containerSchema: Self.streamContainerSchema_age)
              default:
                return nil
              }
            }

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "age", index: Self.StreamField.age,
                  route: _streamFieldRoute(&p.pointee.age),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.age, in: p)
                ),
              ]
            }

            static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField,
              fields: Self.streamFields
            )
          }

          init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          /// Fails when the stream did not produce a member this type has no way to do without.
          init?(streamPartial partial: Partial) {
            guard
              let age = Self._streamValue({ $0.age
              }, partial.age)
            else {
              return nil
            }
            self.age = age
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          init(orInitial partial: Partial) {
            self.age = Self._streamValueOrInitial({
                $0.age
              }, partial.age)
          }

          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
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

            struct View: ~Copyable, ~Escapable {
              let storage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            var stored: String.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.stored) else {
                    return nil
                  }
                  return _overrideLifetime(String.Partial.streamView(address), borrowing: self)
                }
              }
            }

            @_lifetime(borrow storage)
            static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let stored: Int32 = 0
            }

            private static let streamContainerSchema_stored = _streamContainerSchema(for: (String.Partial).self)

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
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.stored:
                return streamApply(&p.pointee.stored, utf8: bytes)
              default:
                return .unsupported
              }
            }

            static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.stored:
                return streamApply(&p.pointee.stored, bytes: bytes, info: info)
              default:
                return .unsupported
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.stored:
                return streamApply(&p.pointee.stored, boolean: value)
              default:
                return .unsupported
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.stored:
                return StreamParsing.streamApplyNull(&p.pointee.stored)
              default:
                return .unsupported
              }
            }

            static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.stored:
                return _streamEnterField(&p.pointee.stored, containerSchema: Self.streamContainerSchema_stored)
              default:
                return nil
              }
            }

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "stored", index: Self.StreamField.stored,
                  route: _streamFieldRoute(&p.pointee.stored),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.stored, in: p)
                ),
              ]
            }

            static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField,
              fields: Self.streamFields
            )
          }

          init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          /// Fails when the stream did not produce a member this type has no way to do without.
          init?(streamPartial partial: Partial) {
            guard
              let stored = Self._streamValue({ $0.stored
              }, partial.stored)
            else {
              return nil
            }
            self.stored = stored
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          init(orInitial partial: Partial) {
            self.stored = Self._streamValueOrInitial({
                $0.stored
              }, partial.stored)
          }

          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
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
      } diagnostics: {
        """
        @StreamParseable
        struct Person {
          var name: String
          @StreamParseableIgnored
          ├─ 🛑 Ignored property 'age' must be optional or have a default value. It is absent from 'Partial', so the generated initializer has nothing to set it from.
          ╰─ 🛑 Ignored property 'age' must be optional or have a default value. It is absent from 'Partial', so the generated initializer has nothing to set it from.
          var age: Int
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
          ├─ 🛑 Ignored property 'name' must be optional or have a default value. It is absent from 'Partial', so the generated initializer has nothing to set it from.
          ├─ 🛑 @StreamParseableMember and @StreamParseableIgnored cannot be applied to the same property.
          ╰─ 🛑 Ignored property 'name' must be optional or have a default value. It is absent from 'Partial', so the generated initializer has nothing to set it from.
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

            struct View: ~Copyable, ~Escapable {
              let storage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            var stored: String.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.stored) else {
                    return nil
                  }
                  return _overrideLifetime(String.Partial.streamView(address), borrowing: self)
                }
              }
            }

            @_lifetime(borrow storage)
            static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let stored: Int32 = 0
            }

            private static let streamContainerSchema_stored = _streamContainerSchema(for: (String.Partial).self)

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
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.stored:
                return streamApply(&p.pointee.stored, utf8: bytes)
              default:
                return .unsupported
              }
            }

            static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.stored:
                return streamApply(&p.pointee.stored, bytes: bytes, info: info)
              default:
                return .unsupported
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.stored:
                return streamApply(&p.pointee.stored, boolean: value)
              default:
                return .unsupported
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.stored:
                return StreamParsing.streamApplyNull(&p.pointee.stored)
              default:
                return .unsupported
              }
            }

            static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.stored:
                return _streamEnterField(&p.pointee.stored, containerSchema: Self.streamContainerSchema_stored)
              default:
                return nil
              }
            }

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "stored", index: Self.StreamField.stored,
                  route: _streamFieldRoute(&p.pointee.stored),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.stored, in: p)
                ),
              ]
            }

            static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField,
              fields: Self.streamFields
            )
          }

          init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          /// Fails when the stream did not produce a member this type has no way to do without.
          init?(streamPartial partial: Partial) {
            guard
              let stored = Self._streamValue({ $0.stored
              }, partial.stored)
            else {
              return nil
            }
            self.stored = stored
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          init(orInitial partial: Partial) {
            self.stored = Self._streamValueOrInitial({
                $0.stored
              }, partial.stored)
          }

          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
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

            struct View: ~Copyable, ~Escapable {
              let storage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            var name: String.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.name) else {
                    return nil
                  }
                  return _overrideLifetime(String.Partial.streamView(address), borrowing: self)
                }
              }

            var age: Int.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.age) else {
                    return nil
                  }
                  return _overrideLifetime(Int.Partial.streamView(address), borrowing: self)
                }
              }
            }

            @_lifetime(borrow storage)
            static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let name: Int32 = 0
              static let age: Int32 = 1
            }

            private static let streamContainerSchema_name = _streamContainerSchema(for: (String.Partial).self)
            private static let streamContainerSchema_age = _streamContainerSchema(for: (Int.Partial).self)

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
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, utf8: bytes)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, utf8: bytes)
              default:
                return .unsupported
              }
            }

            static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, bytes: bytes, info: info)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, bytes: bytes, info: info)
              default:
                return .unsupported
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, boolean: value)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, boolean: value)
              default:
                return .unsupported
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return StreamParsing.streamApplyNull(&p.pointee.name)
              case Self.StreamField.age:
                return StreamParsing.streamApplyNull(&p.pointee.age)
              default:
                return .unsupported
              }
            }

            static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return _streamEnterField(&p.pointee.name, containerSchema: Self.streamContainerSchema_name)
              case Self.StreamField.age:
                return _streamEnterField(&p.pointee.age, containerSchema: Self.streamContainerSchema_age)
              default:
                return nil
              }
            }

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "name", index: Self.StreamField.name,
                  route: _streamFieldRoute(&p.pointee.name),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.name, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "age", index: Self.StreamField.age,
                  route: _streamFieldRoute(&p.pointee.age),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.age, in: p)
                ),
              ]
            }

            static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField,
              fields: Self.streamFields
            )
          }

          init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          /// Fails when the stream did not produce a member this type has no way to do without.
          init?(streamPartial partial: Partial) {
            guard
              let name = Self._streamValue({ $0.name
              }, partial.name),
              let age = Self._streamValue({ $0.age
              }, partial.age)
            else {
              return nil
            }
            self.name = name
            self.age = age
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          init(orInitial partial: Partial) {
            self.name = Self._streamValueOrInitial({
                $0.name
              }, partial.name)
            self.age = Self._streamValueOrInitial({
                $0.age
              }, partial.age)
          }

          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
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
          init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          /// Fails when the stream did not produce a member this type has no way to do without.
          init?(streamPartial partial: Partial) {
            guard
              let name = Self._streamValue({ $0.name
              }, partial.name),
              let age = Self._streamValue({ $0.age
              }, partial.age)
            else {
              return nil
            }
            self.name = name
            self.age = age
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          init(orInitial partial: Partial) {
            self.name = Self._streamValueOrInitial({
                $0.name
              }, partial.name)
            self.age = Self._streamValueOrInitial({
                $0.age
              }, partial.age)
          }

          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
          }
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

            struct View: ~Copyable, ~Escapable {
              let storage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            var name: String.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.name) else {
                    return nil
                  }
                  return _overrideLifetime(String.Partial.streamView(address), borrowing: self)
                }
              }

            var age: Int.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.age) else {
                    return nil
                  }
                  return _overrideLifetime(Int.Partial.streamView(address), borrowing: self)
                }
              }
            }

            @_lifetime(borrow storage)
            static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let name: Int32 = 0
              static let age: Int32 = 1
            }

            private static let streamContainerSchema_name = _streamContainerSchema(for: (String.Partial).self)
            private static let streamContainerSchema_age = _streamContainerSchema(for: (Int.Partial).self)

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
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, utf8: bytes)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, utf8: bytes)
              default:
                return .unsupported
              }
            }

            static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, bytes: bytes, info: info)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, bytes: bytes, info: info)
              default:
                return .unsupported
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, boolean: value)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, boolean: value)
              default:
                return .unsupported
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return StreamParsing.streamApplyNull(&p.pointee.name)
              case Self.StreamField.age:
                return StreamParsing.streamApplyNull(&p.pointee.age)
              default:
                return .unsupported
              }
            }

            static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return _streamEnterField(&p.pointee.name, containerSchema: Self.streamContainerSchema_name)
              case Self.StreamField.age:
                return _streamEnterField(&p.pointee.age, containerSchema: Self.streamContainerSchema_age)
              default:
                return nil
              }
            }

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "name", index: Self.StreamField.name,
                  route: _streamFieldRoute(&p.pointee.name),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.name, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "age", index: Self.StreamField.age,
                  route: _streamFieldRoute(&p.pointee.age),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.age, in: p)
                ),
              ]
            }

            static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField,
              fields: Self.streamFields
            )
          }

          init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          /// Fails when the stream did not produce a member this type has no way to do without.
          init?(streamPartial partial: Partial) {
            guard
              let name = Self._streamValue({ $0.name
              }, partial.name),
              let age = Self._streamValue({ $0.age
              }, partial.age)
            else {
              return nil
            }
            self.name = name
            self.age = age
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          init(orInitial partial: Partial) {
            self.name = Self._streamValueOrInitial({
                $0.name
              }, partial.name)
            self.age = Self._streamValueOrInitial({
                $0.age
              }, partial.age)
          }

          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
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

            public struct View: ~Copyable, ~Escapable {
              public let storage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              public init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            public var name: String.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.name) else {
                    return nil
                  }
                  return _overrideLifetime(String.Partial.streamView(address), borrowing: self)
                }
              }

            public var age: Int.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.age) else {
                    return nil
                  }
                  return _overrideLifetime(Int.Partial.streamView(address), borrowing: self)
                }
              }
            }

            @_lifetime(borrow storage)
            public static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let name: Int32 = 0
              static let age: Int32 = 1
            }

            private static let streamContainerSchema_name = _streamContainerSchema(for: (String.Partial).self)
            private static let streamContainerSchema_age = _streamContainerSchema(for: (Int.Partial).self)

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
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, utf8: bytes)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, utf8: bytes)
              default:
                return .unsupported
              }
            }

            public static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, bytes: bytes, info: info)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, bytes: bytes, info: info)
              default:
                return .unsupported
              }
            }

            public static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, boolean: value)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, boolean: value)
              default:
                return .unsupported
              }
            }

            public static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return StreamParsing.streamApplyNull(&p.pointee.name)
              case Self.StreamField.age:
                return StreamParsing.streamApplyNull(&p.pointee.age)
              default:
                return .unsupported
              }
            }

            public static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return _streamEnterField(&p.pointee.name, containerSchema: Self.streamContainerSchema_name)
              case Self.StreamField.age:
                return _streamEnterField(&p.pointee.age, containerSchema: Self.streamContainerSchema_age)
              default:
                return nil
              }
            }

            public static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "name", index: Self.StreamField.name,
                  route: _streamFieldRoute(&p.pointee.name),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.name, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "age", index: Self.StreamField.age,
                  route: _streamFieldRoute(&p.pointee.age),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.age, in: p)
                ),
              ]
            }

            public static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField,
              fields: Self.streamFields
            )
          }

          public init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          /// Fails when the stream did not produce a member this type has no way to do without.
          public init?(streamPartial partial: Partial) {
            guard
              let name = Self._streamValue({ $0.name
              }, partial.name),
              let age = Self._streamValue({ $0.age
              }, partial.age)
            else {
              return nil
            }
            self.name = name
            self.age = age
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          public init(orInitial partial: Partial) {
            self.name = Self._streamValueOrInitial({
                $0.name
              }, partial.name)
            self.age = Self._streamValueOrInitial({
                $0.age
              }, partial.age)
          }

          public static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
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

            struct View: ~Copyable, ~Escapable {
              let storage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            var name: String.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.name) else {
                    return nil
                  }
                  return _overrideLifetime(String.Partial.streamView(address), borrowing: self)
                }
              }

            var age: Int.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.age) else {
                    return nil
                  }
                  return _overrideLifetime(Int.Partial.streamView(address), borrowing: self)
                }
              }
            }

            @_lifetime(borrow storage)
            static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let name: Int32 = 0
              static let age: Int32 = 1
            }

            private static let streamContainerSchema_name = _streamContainerSchema(for: (String.Partial).self)
            private static let streamContainerSchema_age = _streamContainerSchema(for: (Int.Partial).self)

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
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, utf8: bytes)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, utf8: bytes)
              default:
                return .unsupported
              }
            }

            static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, bytes: bytes, info: info)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, bytes: bytes, info: info)
              default:
                return .unsupported
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, boolean: value)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, boolean: value)
              default:
                return .unsupported
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return StreamParsing.streamApplyNull(&p.pointee.name)
              case Self.StreamField.age:
                return StreamParsing.streamApplyNull(&p.pointee.age)
              default:
                return .unsupported
              }
            }

            static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return _streamEnterField(&p.pointee.name, containerSchema: Self.streamContainerSchema_name)
              case Self.StreamField.age:
                return _streamEnterField(&p.pointee.age, containerSchema: Self.streamContainerSchema_age)
              default:
                return nil
              }
            }

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "name", index: Self.StreamField.name,
                  route: _streamFieldRoute(&p.pointee.name),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.name, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "age", index: Self.StreamField.age,
                  route: _streamFieldRoute(&p.pointee.age),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.age, in: p)
                ),
              ]
            }

            static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField,
              fields: Self.streamFields
            )
          }

          init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          /// Fails when the stream did not produce a member this type has no way to do without.
          init?(streamPartial partial: Partial) {
            guard
              let name = Self._streamValue({ $0.name
              }, partial.name),
              let age = Self._streamValue({ $0.age
              }, partial.age)
            else {
              return nil
            }
            self.name = name
            self.age = age
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          init(orInitial partial: Partial) {
            self.name = Self._streamValueOrInitial({
                $0.name
              }, partial.name)
            self.age = Self._streamValueOrInitial({
                $0.age
              }, partial.age)
          }

          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
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

            fileprivate struct View: ~Copyable, ~Escapable {
              fileprivate let storage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              fileprivate init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            fileprivate var name: String.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.name) else {
                    return nil
                  }
                  return _overrideLifetime(String.Partial.streamView(address), borrowing: self)
                }
              }

            fileprivate var age: Int.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.age) else {
                    return nil
                  }
                  return _overrideLifetime(Int.Partial.streamView(address), borrowing: self)
                }
              }
            }

            @_lifetime(borrow storage)
            fileprivate static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let name: Int32 = 0
              static let age: Int32 = 1
            }

            private static let streamContainerSchema_name = _streamContainerSchema(for: (String.Partial).self)
            private static let streamContainerSchema_age = _streamContainerSchema(for: (Int.Partial).self)

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
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, utf8: bytes)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, utf8: bytes)
              default:
                return .unsupported
              }
            }

            fileprivate static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, bytes: bytes, info: info)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, bytes: bytes, info: info)
              default:
                return .unsupported
              }
            }

            fileprivate static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, boolean: value)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, boolean: value)
              default:
                return .unsupported
              }
            }

            fileprivate static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return StreamParsing.streamApplyNull(&p.pointee.name)
              case Self.StreamField.age:
                return StreamParsing.streamApplyNull(&p.pointee.age)
              default:
                return .unsupported
              }
            }

            fileprivate static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return _streamEnterField(&p.pointee.name, containerSchema: Self.streamContainerSchema_name)
              case Self.StreamField.age:
                return _streamEnterField(&p.pointee.age, containerSchema: Self.streamContainerSchema_age)
              default:
                return nil
              }
            }

            fileprivate static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "name", index: Self.StreamField.name,
                  route: _streamFieldRoute(&p.pointee.name),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.name, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "age", index: Self.StreamField.age,
                  route: _streamFieldRoute(&p.pointee.age),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.age, in: p)
                ),
              ]
            }

            fileprivate static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField,
              fields: Self.streamFields
            )
          }

          fileprivate init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          /// Fails when the stream did not produce a member this type has no way to do without.
          fileprivate init?(streamPartial partial: Partial) {
            guard
              let name = Self._streamValue({ $0.name
              }, partial.name),
              let age = Self._streamValue({ $0.age
              }, partial.age)
            else {
              return nil
            }
            self.name = name
            self.age = age
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          fileprivate init(orInitial partial: Partial) {
            self.name = Self._streamValueOrInitial({
                $0.name
              }, partial.name)
            self.age = Self._streamValueOrInitial({
                $0.age
              }, partial.age)
          }

          fileprivate static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
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

            public struct View: ~Copyable, ~Escapable {
              public let storage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              public init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            public var name: String.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.name) else {
                    return nil
                  }
                  return _overrideLifetime(String.Partial.streamView(address), borrowing: self)
                }
              }

            public var age: Int.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.age) else {
                    return nil
                  }
                  return _overrideLifetime(Int.Partial.streamView(address), borrowing: self)
                }
              }
            }

            @_lifetime(borrow storage)
            public static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let name: Int32 = 0
              static let age: Int32 = 1
            }

            private static let streamContainerSchema_name = _streamContainerSchema(for: (String.Partial).self)
            private static let streamContainerSchema_age = _streamContainerSchema(for: (Int.Partial).self)

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
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, utf8: bytes)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, utf8: bytes)
              default:
                return .unsupported
              }
            }

            public static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, bytes: bytes, info: info)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, bytes: bytes, info: info)
              default:
                return .unsupported
              }
            }

            public static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, boolean: value)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, boolean: value)
              default:
                return .unsupported
              }
            }

            public static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return StreamParsing.streamApplyNull(&p.pointee.name)
              case Self.StreamField.age:
                return StreamParsing.streamApplyNull(&p.pointee.age)
              default:
                return .unsupported
              }
            }

            public static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return _streamEnterField(&p.pointee.name, containerSchema: Self.streamContainerSchema_name)
              case Self.StreamField.age:
                return _streamEnterField(&p.pointee.age, containerSchema: Self.streamContainerSchema_age)
              default:
                return nil
              }
            }

            public static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "name", index: Self.StreamField.name,
                  route: _streamFieldRoute(&p.pointee.name),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.name, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "age", index: Self.StreamField.age,
                  route: _streamFieldRoute(&p.pointee.age),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.age, in: p)
                ),
              ]
            }

            public static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField,
              fields: Self.streamFields
            )
          }

          public init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          /// Fails when the stream did not produce a member this type has no way to do without.
          public init?(streamPartial partial: Partial) {
            guard
              let name = Self._streamValue({ $0.name
              }, partial.name),
              let age = Self._streamValue({ $0.age
              }, partial.age)
            else {
              return nil
            }
            self.name = name
            self.age = age
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          public init(orInitial partial: Partial) {
            self.name = Self._streamValueOrInitial({
                $0.name
              }, partial.name)
            self.age = Self._streamValueOrInitial({
                $0.age
              }, partial.age)
          }

          public static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
          }
        }
        """
      }
    }

    @Test
    func `Handles Optional Members As Single Optionals In Partial`() async throws {
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

            public struct View: ~Copyable, ~Escapable {
              public let storage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              public init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            public var name: String.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.name) else {
                    return nil
                  }
                  return _overrideLifetime(String.Partial.streamView(address), borrowing: self)
                }
              }

            public var age: Int.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.age) else {
                    return nil
                  }
                  return _overrideLifetime(Int.Partial.streamView(address), borrowing: self)
                }
              }
            }

            @_lifetime(borrow storage)
            public static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let name: Int32 = 0
              static let age: Int32 = 1
            }

            private static let streamContainerSchema_name = _streamContainerSchema(for: (String.Partial).self)
            private static let streamContainerSchema_age = _streamContainerSchema(for: (Int.Partial).self)

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
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, utf8: bytes)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, utf8: bytes)
              default:
                return .unsupported
              }
            }

            public static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, bytes: bytes, info: info)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, bytes: bytes, info: info)
              default:
                return .unsupported
              }
            }

            public static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, boolean: value)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, boolean: value)
              default:
                return .unsupported
              }
            }

            public static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return StreamParsing.streamApplyNull(&p.pointee.name)
              case Self.StreamField.age:
                return StreamParsing.streamApplyNull(&p.pointee.age)
              default:
                return .unsupported
              }
            }

            public static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return _streamEnterField(&p.pointee.name, containerSchema: Self.streamContainerSchema_name)
              case Self.StreamField.age:
                return _streamEnterField(&p.pointee.age, containerSchema: Self.streamContainerSchema_age)
              default:
                return nil
              }
            }

            public static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "name", index: Self.StreamField.name,
                  route: _streamFieldRoute(&p.pointee.name),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.name, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "age", index: Self.StreamField.age,
                  route: _streamFieldRoute(&p.pointee.age),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.age, in: p)
                ),
              ]
            }

            public static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField,
              fields: Self.streamFields
            )
          }

          public init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          /// Fails when the stream did not produce a member this type has no way to do without.
          public init?(streamPartial partial: Partial) {
            guard
              let name = Self._streamValue({ $0.name
              }, partial.name),
              let age = Self._streamValue({ $0.age
              }, partial.age)
            else {
              return nil
            }
            self.name = name
            self.age = age
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          public init(orInitial partial: Partial) {
            self.name = Self._streamValueOrInitial({
                $0.name
              }, partial.name)
            self.age = Self._streamValueOrInitial({
                $0.age
              }, partial.age)
          }

          public static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
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

            struct View: ~Copyable, ~Escapable {
              let storage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            var name: String.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.name) else {
                    return nil
                  }
                  return _overrideLifetime(String.Partial.streamView(address), borrowing: self)
                }
              }

            var age: Int.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.age) else {
                    return nil
                  }
                  return _overrideLifetime(Int.Partial.streamView(address), borrowing: self)
                }
              }
            }

            @_lifetime(borrow storage)
            static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let name: Int32 = 0
              static let age: Int32 = 1
            }

            private static let streamContainerSchema_name = _streamContainerSchema(for: (String.Partial).self)
            private static let streamContainerSchema_age = _streamContainerSchema(for: (Int.Partial).self)

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
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, utf8: bytes)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, utf8: bytes)
              default:
                return .unsupported
              }
            }

            static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, bytes: bytes, info: info)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, bytes: bytes, info: info)
              default:
                return .unsupported
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, boolean: value)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, boolean: value)
              default:
                return .unsupported
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return StreamParsing.streamApplyNull(&p.pointee.name)
              case Self.StreamField.age:
                return StreamParsing.streamApplyNull(&p.pointee.age)
              default:
                return .unsupported
              }
            }

            static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return _streamEnterField(&p.pointee.name, containerSchema: Self.streamContainerSchema_name)
              case Self.StreamField.age:
                return _streamEnterField(&p.pointee.age, containerSchema: Self.streamContainerSchema_age)
              default:
                return nil
              }
            }

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "blob", index: Self.StreamField.name,
                  route: _streamFieldRoute(&p.pointee.name),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.name, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "name2", index: Self.StreamField.name,
                  route: _streamFieldRoute(&p.pointee.name),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.name, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "age", index: Self.StreamField.age,
                  route: _streamFieldRoute(&p.pointee.age),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.age, in: p)
                ),
              ]
            }

            static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField,
              fields: Self.streamFields
            )
          }

          init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          /// Fails when the stream did not produce a member this type has no way to do without.
          init?(streamPartial partial: Partial) {
            guard
              let name = Self._streamValue({ $0.name
              }, partial.name),
              let age = Self._streamValue({ $0.age
              }, partial.age)
            else {
              return nil
            }
            self.name = name
            self.age = age
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          init(orInitial partial: Partial) {
            self.name = Self._streamValueOrInitial({
                $0.name
              }, partial.name)
            self.age = Self._streamValueOrInitial({
                $0.age
              }, partial.age)
          }

          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
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

            struct View: ~Copyable, ~Escapable {
              let storage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            var name: String.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.name) else {
                    return nil
                  }
                  return _overrideLifetime(String.Partial.streamView(address), borrowing: self)
                }
              }

            var age: Int.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.age) else {
                    return nil
                  }
                  return _overrideLifetime(Int.Partial.streamView(address), borrowing: self)
                }
              }
            }

            @_lifetime(borrow storage)
            static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let name: Int32 = 0
              static let age: Int32 = 1
            }

            private static let streamContainerSchema_name = _streamContainerSchema(for: (String.Partial).self)
            private static let streamContainerSchema_age = _streamContainerSchema(for: (Int.Partial).self)

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
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, utf8: bytes)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, utf8: bytes)
              default:
                return .unsupported
              }
            }

            static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, bytes: bytes, info: info)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, bytes: bytes, info: info)
              default:
                return .unsupported
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, boolean: value)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, boolean: value)
              default:
                return .unsupported
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return StreamParsing.streamApplyNull(&p.pointee.name)
              case Self.StreamField.age:
                return StreamParsing.streamApplyNull(&p.pointee.age)
              default:
                return .unsupported
              }
            }

            static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return _streamEnterField(&p.pointee.name, containerSchema: Self.streamContainerSchema_name)
              case Self.StreamField.age:
                return _streamEnterField(&p.pointee.age, containerSchema: Self.streamContainerSchema_age)
              default:
                return nil
              }
            }

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "blob", index: Self.StreamField.name,
                  route: _streamFieldRoute(&p.pointee.name),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.name, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "name2", index: Self.StreamField.name,
                  route: _streamFieldRoute(&p.pointee.name),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.name, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "age", index: Self.StreamField.age,
                  route: _streamFieldRoute(&p.pointee.age),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.age, in: p)
                ),
              ]
            }

            static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField,
              fields: Self.streamFields
            )
          }

          init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          /// Fails when the stream did not produce a member this type has no way to do without.
          init?(streamPartial partial: Partial) {
            guard
              let name = Self._streamValue({ $0.name
              }, partial.name),
              let age = Self._streamValue({ $0.age
              }, partial.age)
            else {
              return nil
            }
            self.name = name
            self.age = age
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          init(orInitial partial: Partial) {
            self.name = Self._streamValueOrInitial({
                $0.name
              }, partial.name)
            self.age = Self._streamValueOrInitial({
                $0.age
              }, partial.age)
          }

          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
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

            struct View: ~Copyable, ~Escapable {
              let storage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            var name: String.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.name) else {
                    return nil
                  }
                  return _overrideLifetime(String.Partial.streamView(address), borrowing: self)
                }
              }

            var age: Int.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.age) else {
                    return nil
                  }
                  return _overrideLifetime(Int.Partial.streamView(address), borrowing: self)
                }
              }
            }

            @_lifetime(borrow storage)
            static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let name: Int32 = 0
              static let age: Int32 = 1
            }

            private static let streamContainerSchema_name = _streamContainerSchema(for: (String.Partial).self)
            private static let streamContainerSchema_age = _streamContainerSchema(for: (Int.Partial).self)

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
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, utf8: bytes)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, utf8: bytes)
              default:
                return .unsupported
              }
            }

            static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, bytes: bytes, info: info)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, bytes: bytes, info: info)
              default:
                return .unsupported
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, boolean: value)
              case Self.StreamField.age:
                return streamApply(&p.pointee.age, boolean: value)
              default:
                return .unsupported
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return StreamParsing.streamApplyNull(&p.pointee.name)
              case Self.StreamField.age:
                return StreamParsing.streamApplyNull(&p.pointee.age)
              default:
                return .unsupported
              }
            }

            static func streamEnterField(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamFrame? {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return _streamEnterField(&p.pointee.name, containerSchema: Self.streamContainerSchema_name)
              case Self.StreamField.age:
                return _streamEnterField(&p.pointee.age, containerSchema: Self.streamContainerSchema_age)
              default:
                return nil
              }
            }

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "blob", index: Self.StreamField.name,
                  route: _streamFieldRoute(&p.pointee.name),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.name, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "name2", index: Self.StreamField.name,
                  route: _streamFieldRoute(&p.pointee.name),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.name, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "age", index: Self.StreamField.age,
                  route: _streamFieldRoute(&p.pointee.age),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.age, in: p)
                ),
              ]
            }

            static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField,
              fields: Self.streamFields
            )
          }

          init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          /// Fails when the stream did not produce a member this type has no way to do without.
          init?(streamPartial partial: Partial) {
            guard
              let name = Self._streamValue({ $0.name
              }, partial.name),
              let age = Self._streamValue({ $0.age
              }, partial.age)
            else {
              return nil
            }
            self.name = name
            self.age = age
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          init(orInitial partial: Partial) {
            self.name = Self._streamValueOrInitial({
                $0.name
              }, partial.name)
            self.age = Self._streamValueOrInitial({
                $0.age
              }, partial.age)
          }

          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
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

            struct View: ~Copyable, ~Escapable {
              let storage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            var items: [Item].Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.items) else {
                    return nil
                  }
                  return _overrideLifetime([Item].Partial.streamView(address), borrowing: self)
                }
              }

            var index: StreamParsingCore.StreamDictionary<Item.Partial>.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.index) else {
                    return nil
                  }
                  return _overrideLifetime(StreamParsingCore.StreamDictionary<Item.Partial>.streamView(address), borrowing: self)
                }
              }
            }

            @_lifetime(borrow storage)
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
            ) -> StreamParsingCore.StreamApplyResult {
              switch field {
              default:
                return .unsupported
              }
            }

            static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> StreamParsingCore.StreamApplyResult {
              switch field {
              default:
                return .unsupported
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> StreamParsingCore.StreamApplyResult {
              switch field {
              default:
                return .unsupported
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.items:
                return StreamParsing.streamApplyNull(&p.pointee.items)
              case Self.StreamField.index:
                return StreamParsing.streamApplyNull(&p.pointee.index)
              default:
                return .unsupported
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

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "items", index: Self.StreamField.items,
                  route: _streamFieldRoute(&p.pointee.items),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.items, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "index", index: Self.StreamField.index,
                  route: _streamFieldRoute(&p.pointee.index),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.index, in: p)
                ),
              ]
            }

            static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              enterField: Self.streamEnterField,
              fields: Self.streamFields
            )
          }

          init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          /// Fails when the stream did not produce a member this type has no way to do without.
          init?(streamPartial partial: Partial) {
            guard
              let items = Self._streamValue({ $0.items
              }, partial.items),
              let index = Self._streamValue({ $0.index
              }, partial.index)
            else {
              return nil
            }
            self.items = items
            self.index = index
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          init(orInitial partial: Partial) {
            self.items = Self._streamValueOrInitial({
                $0.items
              }, partial.items)
            self.index = Self._streamValueOrInitial({
                $0.index
              }, partial.index)
          }

          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
          }
        }
        """#
      }
    }

  }
}
