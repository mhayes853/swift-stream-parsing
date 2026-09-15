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
            StreamParsingCore.StreamParseableObject, Sendable {
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

            // Cached rather than re-evaluated: `Self()` walks every default expression fresh, which
            // for a large nested struct is a long chain of small copies. Every member's own `Partial`
            // is `Sendable` (every leaf and every "Fast" container conforms), which is what makes
            // `Self` itself `Sendable` here and lets the template be a plain `static let`.
            private static let _streamInitialValueTemplate: Self = Self()

            static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
            }

            struct View: ~Copyable, ~Escapable {
              let _streamStorage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
              }

            var name: String.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.name) else {
                    return nil
                  }
                  return _overrideLifetime(String.Partial.streamView(address), borrowing: self)
                }
              }

            var age: Int.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.age) else {
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

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "name", index: Self.StreamField.name,
                  route: _streamFieldRoute(&p.pointee.name, schema: Self.streamContainerSchema_name),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.name, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "age", index: Self.StreamField.age,
                  route: _streamFieldRoute(&p.pointee.age, schema: Self.streamContainerSchema_age),
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
    func `Custom Member Keys`() {
      assertMacro {
        """
        @StreamParseable
        struct Person {
          @StreamParseableMember(key: "customKeyName")
          var name: String
          @StreamParseableMember(keyNames: ["customKeyName2", "customKeyName3"])
          var nickname: String
          @StreamParseableMember(key: "blob")
          @StreamParseableMember(key: "age2")
          var age: Int
        }
        """
      } expansion: {
        """
        struct Person {
          var name: String
          var nickname: String
          var age: Int

          var streamPartialValue: Partial {
            Partial(
              name: self.name.streamPartialValue,
              nickname: self.nickname.streamPartialValue,
              age: self.age.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject, Sendable {
            typealias Partial = Self

            var name: String.Partial?
            var nickname: String.Partial?
            var age: Int.Partial?

            init(
              name: String.Partial? = nil,
              nickname: String.Partial? = nil,
              age: Int.Partial? = nil
            ) {
              self.name = name
              self.nickname = nickname
              self.age = age
            }

            // Cached rather than re-evaluated: `Self()` walks every default expression fresh, which
            // for a large nested struct is a long chain of small copies. Every member's own `Partial`
            // is `Sendable` (every leaf and every "Fast" container conforms), which is what makes
            // `Self` itself `Sendable` here and lets the template be a plain `static let`.
            private static let _streamInitialValueTemplate: Self = Self()

            static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
            }

            struct View: ~Copyable, ~Escapable {
              let _streamStorage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
              }

            var name: String.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.name) else {
                    return nil
                  }
                  return _overrideLifetime(String.Partial.streamView(address), borrowing: self)
                }
              }

            var nickname: String.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.nickname) else {
                    return nil
                  }
                  return _overrideLifetime(String.Partial.streamView(address), borrowing: self)
                }
              }

            var age: Int.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.age) else {
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
              static let nickname: Int32 = 1
              static let age: Int32 = 2
            }

            private static let streamContainerSchema_name = _streamContainerSchema(for: (String.Partial).self)
            private static let streamContainerSchema_nickname = _streamContainerSchema(for: (String.Partial).self)
            private static let streamContainerSchema_age = _streamContainerSchema(for: (Int.Partial).self)

            static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x654B_6D6F_7473_7563 where key.count == 13 && key.paddedWord(at: 8) == 0x0000_0065_6D61_4E79:
                return Self.StreamField.name
              case 0x654B_6D6F_7473_7563 where key.count == 14 && key.paddedWord(at: 8) == 0x0000_3265_6D61_4E79:
                return Self.StreamField.nickname
              case 0x654B_6D6F_7473_7563 where key.count == 14 && key.paddedWord(at: 8) == 0x0000_3365_6D61_4E79:
                return Self.StreamField.nickname
              case 0x0000_0000_626F_6C62 where key.count == 4:
                return Self.StreamField.age
              case 0x0000_0000_3265_6761 where key.count == 4:
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
              case Self.StreamField.nickname:
                return streamApply(&p.pointee.nickname, utf8: bytes)
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
              case Self.StreamField.nickname:
                return streamApply(&p.pointee.nickname, bytes: bytes, info: info)
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
              case Self.StreamField.nickname:
                return streamApply(&p.pointee.nickname, boolean: value)
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
              case Self.StreamField.nickname:
                return StreamParsing.streamApplyNull(&p.pointee.nickname)
              case Self.StreamField.age:
                return StreamParsing.streamApplyNull(&p.pointee.age)
              default:
                return .unsupported
              }
            }

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "customKeyName", index: Self.StreamField.name,
                  route: _streamFieldRoute(&p.pointee.name, schema: Self.streamContainerSchema_name),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.name, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "customKeyName2", index: Self.StreamField.nickname,
                  route: _streamFieldRoute(&p.pointee.nickname, schema: Self.streamContainerSchema_nickname),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.nickname, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "customKeyName3", index: Self.StreamField.nickname,
                  route: _streamFieldRoute(&p.pointee.nickname, schema: Self.streamContainerSchema_nickname),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.nickname, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "blob", index: Self.StreamField.age,
                  route: _streamFieldRoute(&p.pointee.age, schema: Self.streamContainerSchema_age),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.age, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "age2", index: Self.StreamField.age,
                  route: _streamFieldRoute(&p.pointee.age, schema: Self.streamContainerSchema_age),
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
              let nickname = Self._streamValue({ $0.nickname
              }, partial.nickname),
              let age = Self._streamValue({ $0.age
              }, partial.age)
            else {
              return nil
            }
            self.name = name
            self.nickname = nickname
            self.age = age
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          init(orInitial partial: Partial) {
            self.name = Self._streamValueOrInitial({
                $0.name
              }, partial.name)
            self.nickname = Self._streamValueOrInitial({
                $0.nickname
              }, partial.nickname)
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
          ╰─ 🛑 Static properties are not parsed by @StreamParseable.
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
          ╰─ 🛑 @StreamParseableMember(key:) requires a string literal.
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
          var age: Int?
          var nickname: Optional<String>
        }
        """
      } expansion: {
        """
        struct Person {
          var name: String
          var age: Int?
          var nickname: Optional<String>

          var streamPartialValue: Partial {
            Partial(
              name: self.name.streamPartialValue,
              age: self.age.streamPartialValue,
              nickname: self.nickname.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject, Sendable {
            typealias Partial = Self

            var name: String.Partial
            var age: Int.Partial?
            var nickname: String.Partial?

            init(
              name: String.Partial = .streamInitialValue(),
              age: Int.Partial? = .streamInitialValue(),
              nickname: String.Partial? = .streamInitialValue()
            ) {
              self.name = name
              self.age = age
              self.nickname = nickname
            }

            // Cached rather than re-evaluated: `Self()` walks every default expression fresh, which
            // for a large nested struct is a long chain of small copies. Every member's own `Partial`
            // is `Sendable` (every leaf and every "Fast" container conforms), which is what makes
            // `Self` itself `Sendable` here and lets the template be a plain `static let`.
            private static let _streamInitialValueTemplate: Self = Self()

            static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
            }

            struct View: ~Copyable, ~Escapable {
              let _streamStorage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
              }

            var name: String.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.name) else {
                    return nil
                  }
                  return _overrideLifetime(String.Partial.streamView(address), borrowing: self)
                }
              }

            var age: Int.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.age) else {
                    return nil
                  }
                  return _overrideLifetime(Int.Partial.streamView(address), borrowing: self)
                }
              }

            var nickname: String.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.nickname) else {
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
              static let name: Int32 = 0
              static let age: Int32 = 1
              static let nickname: Int32 = 2
            }

            private static let streamContainerSchema_name = _streamContainerSchema(for: (String.Partial).self)
            private static let streamContainerSchema_age = _streamContainerSchema(for: (Int.Partial).self)
            private static let streamContainerSchema_nickname = _streamContainerSchema(for: (String.Partial).self)

            static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_0000_656D_616E where key.count == 4:
                return Self.StreamField.name
              case 0x0000_0000_0065_6761 where key.count == 3:
                return Self.StreamField.age
              case 0x656D_616E_6B63_696E where key.count == 8:
                return Self.StreamField.nickname
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
              case Self.StreamField.nickname:
                return streamApply(&p.pointee.nickname, utf8: bytes)
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
              case Self.StreamField.nickname:
                return streamApply(&p.pointee.nickname, bytes: bytes, info: info)
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
              case Self.StreamField.nickname:
                return streamApply(&p.pointee.nickname, boolean: value)
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
              case Self.StreamField.nickname:
                return StreamParsing.streamApplyNull(&p.pointee.nickname)
              default:
                return .unsupported
              }
            }

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "name", index: Self.StreamField.name,
                  route: _streamFieldRoute(&p.pointee.name, schema: Self.streamContainerSchema_name),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.name, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "age", index: Self.StreamField.age,
                  route: _streamFieldRoute(&p.pointee.age, schema: Self.streamContainerSchema_age),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.age, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "nickname", index: Self.StreamField.nickname,
                  route: _streamFieldRoute(&p.pointee.nickname, schema: Self.streamContainerSchema_nickname),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.nickname, in: p)
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
              }, partial.age),
              let nickname = Self._streamValue({ $0.nickname
              }, partial.nickname)
            else {
              return nil
            }
            self.name = name
            self.age = age
            self.nickname = nickname
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
            self.nickname = Self._streamValueOrInitial({
                $0.nickname
              }, partial.nickname)
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
          var age: Int?
          var nickname: Optional<String>
        }
        """
      } expansion: {
        """
        struct Person {
          var age: Int?
          var nickname: Optional<String>

          var streamPartialValue: Partial {
            Partial(
              age: self.age.streamPartialValue,
              nickname: self.nickname.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject, Sendable {
            typealias Partial = Self

            var age: Int.Partial?
            var nickname: String.Partial?

            init(
              age: Int.Partial? = nil,
              nickname: String.Partial? = nil
            ) {
              self.age = age
              self.nickname = nickname
            }

            // Cached rather than re-evaluated: `Self()` walks every default expression fresh, which
            // for a large nested struct is a long chain of small copies. Every member's own `Partial`
            // is `Sendable` (every leaf and every "Fast" container conforms), which is what makes
            // `Self` itself `Sendable` here and lets the template be a plain `static let`.
            private static let _streamInitialValueTemplate: Self = Self()

            static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
            }

            struct View: ~Copyable, ~Escapable {
              let _streamStorage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
              }

            var age: Int.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.age) else {
                    return nil
                  }
                  return _overrideLifetime(Int.Partial.streamView(address), borrowing: self)
                }
              }

            var nickname: String.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.nickname) else {
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
              static let age: Int32 = 0
              static let nickname: Int32 = 1
            }

            private static let streamContainerSchema_age = _streamContainerSchema(for: (Int.Partial).self)
            private static let streamContainerSchema_nickname = _streamContainerSchema(for: (String.Partial).self)

            static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_0000_0065_6761 where key.count == 3:
                return Self.StreamField.age
              case 0x656D_616E_6B63_696E where key.count == 8:
                return Self.StreamField.nickname
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
              case Self.StreamField.nickname:
                return streamApply(&p.pointee.nickname, utf8: bytes)
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
              case Self.StreamField.nickname:
                return streamApply(&p.pointee.nickname, bytes: bytes, info: info)
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
              case Self.StreamField.nickname:
                return streamApply(&p.pointee.nickname, boolean: value)
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
              case Self.StreamField.nickname:
                return StreamParsing.streamApplyNull(&p.pointee.nickname)
              default:
                return .unsupported
              }
            }

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "age", index: Self.StreamField.age,
                  route: _streamFieldRoute(&p.pointee.age, schema: Self.streamContainerSchema_age),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.age, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "nickname", index: Self.StreamField.nickname,
                  route: _streamFieldRoute(&p.pointee.nickname, schema: Self.streamContainerSchema_nickname),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.nickname, in: p)
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
              }, partial.age),
              let nickname = Self._streamValue({ $0.nickname
              }, partial.nickname)
            else {
              return nil
            }
            self.age = age
            self.nickname = nickname
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          init(orInitial partial: Partial) {
            self.age = Self._streamValueOrInitial({
                $0.age
              }, partial.age)
            self.nickname = Self._streamValueOrInitial({
                $0.nickname
              }, partial.nickname)
          }

          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
          }
        }
        """
      }
    }

    @Test
    func `Excludes Static, Computed, And Method Members`() {
      assertMacro {
        """
        @StreamParseable
        struct Person {
          var stored: String
          static var name: String
          var computed: Int {
            1
          }
          func greet() {}
        }
        """
      } expansion: {
        """
        struct Person {
          var stored: String
          static var name: String
          var computed: Int {
            1
          }
          func greet() {}

          var streamPartialValue: Partial {
            Partial(
              stored: self.stored.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject, Sendable {
            typealias Partial = Self

            var stored: String.Partial?

            init(
              stored: String.Partial? = nil
            ) {
              self.stored = stored
            }

            // Cached rather than re-evaluated: `Self()` walks every default expression fresh, which
            // for a large nested struct is a long chain of small copies. Every member's own `Partial`
            // is `Sendable` (every leaf and every "Fast" container conforms), which is what makes
            // `Self` itself `Sendable` here and lets the template be a plain `static let`.
            private static let _streamInitialValueTemplate: Self = Self()

            static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
            }

            struct View: ~Copyable, ~Escapable {
              let _streamStorage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
              }

            var stored: String.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.stored) else {
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

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "stored", index: Self.StreamField.stored,
                  route: _streamFieldRoute(&p.pointee.stored, schema: Self.streamContainerSchema_stored),
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
    func `Non Optional Ignored Property Without A Default`() {
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
          ╰─ 🛑 Ignored property 'name' must be optional or have a default value. It is absent from 'Partial', so the generated initializer has nothing to set it from.
          @StreamParseableIgnored
          var name: String
        }
        """
      }
    }

    // MARK: - Enums

    @Test
    func `String Raw Value Enum`() {
      assertMacro {
        """
        @StreamParseable
        enum Broadcast: String {
          @StreamParseableDefault
          case live
          case livestream
        }
        """
      } expansion: {
        """
        enum Broadcast: String {
          @StreamParseableDefault
          case live
          case livestream

          var streamPartialValue: Partial {
            self.rawValue.streamPartialValue
          }
        }

        extension Broadcast: StreamParsingCore.StreamParseable {
          typealias Partial = StreamParsingCore.StreamString

          init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          /// Resolves the case the accumulated raw value names, or the shortest case that value is
          /// still a prefix of.
          ///
          /// A partial string cannot say whether it is finished, so a value that names one case and
          /// is a prefix of a longer one resolves to the shorter and may later be superseded.
          init?(streamPartial partial: Partial) {
            let streamCount = partial.utf8Count
            guard streamCount > 0 else {
              return nil
            }
            switch partial.paddedLeadingWord() {
            case 0x0000_0000_6576_696C where streamCount == 4:
              self = .live
              return
            case 0x6572_7473_6576_696C where streamCount == 10 && partial.paddedWord(at: 8) == 0x0000_0000_0000_6D61:
              self = .livestream
              return
            default:
              break
            }
            if partial.isPrefix(of: "live") {
              self = .live
              return
            }
            if partial.isPrefix(of: "livestream") {
              self = .livestream
              return
            }
            return nil
          }

          /// Falls back to the case marked `@StreamParseableDefault` when the stream did not
          /// produce a value this type can represent.
          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(streamPartial: partial) ?? .live
          }
        }
        """
      }
    }

    @Test
    func `Integer Raw Value Enum`() {
      assertMacro {
        """
        @StreamParseable
        enum Priority: Int {
          @StreamParseableDefault
          case low = 0
          case high = 10
        }
        """
      } expansion: {
        """
        enum Priority: Int {
          @StreamParseableDefault
          case low = 0
          case high = 10

          var streamPartialValue: Partial {
            self.rawValue
          }
        }

        extension Priority: StreamParsingCore.StreamParseable {
          typealias Partial = Int

          init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          /// Fails when the stream produced a raw value no case declares.
          init?(streamPartial partial: Partial) {
            self.init(rawValue: partial)
          }

          /// Falls back to the case marked `@StreamParseableDefault` when the stream did not
          /// produce a value this type can represent.
          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(streamPartial: partial) ?? .low
          }
        }
        """
      }
    }

    @Test
    func `Raw Less Enum Uses The Codable Object Form`() {
      assertMacro {
        """
        @StreamParseable
        enum Figure {
          @StreamParseableDefault
          case circle
        }
        """
      } expansion: {
        """
        enum Figure {
          @StreamParseableDefault
          case circle

          var streamPartialValue: Partial {
            switch self {
            case .circle:
              return Partial(circle: StreamParsingCore.StreamEmptyObject())
            }
          }
        }

        extension Figure: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject, Sendable {
            typealias Partial = Self

            var circle: StreamParsingCore.StreamEmptyObject.Partial?

            init(
              circle: StreamParsingCore.StreamEmptyObject.Partial? = nil
            ) {
              self.circle = circle
            }

            // Cached rather than re-evaluated: `Self()` walks every default expression fresh, which
            // for a large nested struct is a long chain of small copies. Every member's own `Partial`
            // is `Sendable` (every leaf and every "Fast" container conforms), which is what makes
            // `Self` itself `Sendable` here and lets the template be a plain `static let`.
            private static let _streamInitialValueTemplate: Self = Self()

            static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
            }

            struct View: ~Copyable, ~Escapable {
              let _streamStorage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
              }

            var circle: StreamParsingCore.StreamEmptyObject.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.circle) else {
                    return nil
                  }
                  return _overrideLifetime(StreamParsingCore.StreamEmptyObject.Partial.streamView(address), borrowing: self)
                }
              }

          /// One case's borrowed, mid-stream view — or `.unresolved`/`.ambiguous` when zero or more
          /// than one case's key has arrived yet.
          enum ResolvedView: ~Copyable, ~Escapable {
            case unresolved
            case ambiguous
              case circle
            }

            var resolved: ResolvedView {
              @_lifetime(borrow self)
              get {
                var streamMatched = -1
                var streamMatches = 0
              if self._streamStorage.pointee.circle != nil {
                  streamMatched = 0;
                  streamMatches += 1
                }
                guard streamMatches == 1 else {
                  if streamMatches == 0 {
                    return .unresolved
                  }
                  return .ambiguous
                }
                switch streamMatched {
              case 0:
                return .circle
                default:
                  return .unresolved
                }
              }
            }
          }

            @_lifetime(borrow storage)
            static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let circle: Int32 = 0
            }

            private static let streamContainerSchema_circle = _streamContainerSchema(for: (StreamParsingCore.StreamEmptyObject.Partial).self)

            static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_656C_6372_6963 where key.count == 6:
                return Self.StreamField.circle
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
              case Self.StreamField.circle:
                return streamApply(&p.pointee.circle, utf8: bytes)
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
              case Self.StreamField.circle:
                return streamApply(&p.pointee.circle, bytes: bytes, info: info)
              default:
                return .unsupported
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.circle:
                return streamApply(&p.pointee.circle, boolean: value)
              default:
                return .unsupported
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.circle:
                return StreamParsing.streamApplyNull(&p.pointee.circle)
              default:
                return .unsupported
              }
            }

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "circle", index: Self.StreamField.circle,
                  route: _streamFieldRoute(&p.pointee.circle, schema: Self.streamContainerSchema_circle),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.circle, in: p)
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
              fields: Self.streamFields
            )
          }

          init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          /// Fails unless exactly one case's key arrived, matching what `JSONDecoder` accepts for
          /// the same document — and, for a case with associated values, unless that one case's own
          /// payload has everything it needs yet.
          init?(streamPartial partial: Partial) {
            var streamMatched = -1
            var streamMatches = 0
            if partial.circle != nil {
              streamMatched = 0
              streamMatches += 1
            }
            guard streamMatches == 1 else {
              return nil
            }
            switch streamMatched {
            case 0:
              self = .circle
            default:
              return nil
            }
          }

          /// Falls back to the case marked `@StreamParseableDefault` when the stream did not
          /// produce a value this type can represent.
          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(streamPartial: partial) ?? .circle
          }
        }
        """
      }
    }

    @Test
    func `Enum Without A Fallback Case`() {
      assertMacro {
        """
        @StreamParseable
        enum Broadcast: String {
          case live
        }
        """
      } diagnostics: {
        """
        @StreamParseable
        enum Broadcast: String {
             ┬────────
             ╰─ 🛑 @StreamParseable requires an enum to name a fallback case, because 'streamValueOrInitial' has to produce one when the stream produced nothing this type can represent. Mark a case with @StreamParseableDefault, or declare 'StreamInitializable' conformance on 'Broadcast' itself.
          case live
        }
        """
      }
    }

    @Test
    func `Enum With An Unsupported Raw Type`() {
      assertMacro {
        """
        @StreamParseable
        enum Flag: Character {
          @StreamParseableDefault
          case yes = "y"
        }
        """
      } diagnostics: {
        """
        @StreamParseable
        enum Flag: Character {
                   ┬────────
                   ╰─ 🛑 @StreamParseable does not support 'Character' as a raw value type. Supported raw types are String and the standard integer and floating point types; an enum with no raw type parses Codable's case-name-keyed object form.
          @StreamParseableDefault
          case yes = "y"
        }
        """
      }
    }

    @Test
    func `Enum Rejects Partial Members Mode`() {
      assertMacro {
        """
        @StreamParseable(partialMembers: .streamInitialValue)
        enum Figure {
          @StreamParseableDefault
          case circle
        }
        """
      } diagnostics: {
        """
        @StreamParseable(partialMembers: .streamInitialValue)
        ┬────────────────────────────────────────────────────
        ╰─ 🛑 @StreamParseable(partialMembers:) does not apply to an enum. An enum's partial has a fixed shape: absence is what says a case did not arrive, so its members are always optional.
        enum Figure {
          @StreamParseableDefault
          case circle
        }
        """
      }
    }

    @Test
    func `Applied To Enum With Associated Values`() {
      assertMacro {
        """
        @StreamParseable
        enum Note {
          case text(String)
          @StreamParseableDefault
          case empty
        }
        """
      } expansion: {
        """
        enum Note {
          case text(String)
          @StreamParseableDefault
          case empty

          var streamPartialValue: Partial {
            switch self {
            case .text(let _0):
              return Partial(text: TextPayload.Partial(_0: _0.streamPartialValue))
            case .empty:
              return Partial(empty: StreamParsingCore.StreamEmptyObject())
            }
          }
        }

        extension Note: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject, Sendable {
            typealias Partial = Self

            var text: TextPayload.Partial?
            var empty: StreamParsingCore.StreamEmptyObject.Partial?

            init(
              text: TextPayload.Partial? = nil,
              empty: StreamParsingCore.StreamEmptyObject.Partial? = nil
            ) {
              self.text = text
              self.empty = empty
            }

            // Cached rather than re-evaluated: `Self()` walks every default expression fresh, which
            // for a large nested struct is a long chain of small copies. Every member's own `Partial`
            // is `Sendable` (every leaf and every "Fast" container conforms), which is what makes
            // `Self` itself `Sendable` here and lets the template be a plain `static let`.
            private static let _streamInitialValueTemplate: Self = Self()

            static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
            }

            struct View: ~Copyable, ~Escapable {
              let _streamStorage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
              }

            var text: TextPayload.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.text) else {
                    return nil
                  }
                  return _overrideLifetime(TextPayload.Partial.streamView(address), borrowing: self)
                }
              }

            var empty: StreamParsingCore.StreamEmptyObject.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.empty) else {
                    return nil
                  }
                  return _overrideLifetime(StreamParsingCore.StreamEmptyObject.Partial.streamView(address), borrowing: self)
                }
              }

          /// One case's borrowed, mid-stream view — or `.unresolved`/`.ambiguous` when zero or more
          /// than one case's key has arrived yet.
          enum ResolvedView: ~Copyable, ~Escapable {
            case unresolved
            case ambiguous
              case text(TextPayload.Partial.View)
              case empty
            }

            var resolved: ResolvedView {
              @_lifetime(borrow self)
              get {
                var streamMatched = -1
                var streamMatches = 0
              if self._streamStorage.pointee.text != nil {
                  streamMatched = 0;
                  streamMatches += 1
                }
              if self._streamStorage.pointee.empty != nil {
                  streamMatched = 1;
                  streamMatches += 1
                }
                guard streamMatches == 1 else {
                  if streamMatches == 0 {
                    return .unresolved
                  }
                  return .ambiguous
                }
                switch streamMatched {
              case 0:
                guard let streamAddress = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.text)
                else {
                  return .unresolved
                }
                return _overrideLifetime(
                  .text(TextPayload.Partial.streamView(streamAddress)),
                  borrowing: self
                )
              case 1:
                return .empty
                default:
                  return .unresolved
                }
              }
            }
          }

            @_lifetime(borrow storage)
            static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let text: Int32 = 0
              static let empty: Int32 = 1
            }

            private static let streamContainerSchema_text = _streamContainerSchema(for: (TextPayload.Partial).self)
            private static let streamContainerSchema_empty = _streamContainerSchema(for: (StreamParsingCore.StreamEmptyObject.Partial).self)

            static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_0000_7478_6574 where key.count == 4:
                return Self.StreamField.text
              case 0x0000_0079_7470_6D65 where key.count == 5:
                return Self.StreamField.empty
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
              case Self.StreamField.text:
                return streamApply(&p.pointee.text, utf8: bytes)
              case Self.StreamField.empty:
                return streamApply(&p.pointee.empty, utf8: bytes)
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
              case Self.StreamField.text:
                return streamApply(&p.pointee.text, bytes: bytes, info: info)
              case Self.StreamField.empty:
                return streamApply(&p.pointee.empty, bytes: bytes, info: info)
              default:
                return .unsupported
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.text:
                return streamApply(&p.pointee.text, boolean: value)
              case Self.StreamField.empty:
                return streamApply(&p.pointee.empty, boolean: value)
              default:
                return .unsupported
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.text:
                return StreamParsing.streamApplyNull(&p.pointee.text)
              case Self.StreamField.empty:
                return StreamParsing.streamApplyNull(&p.pointee.empty)
              default:
                return .unsupported
              }
            }

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "text", index: Self.StreamField.text,
                  route: _streamFieldRoute(&p.pointee.text, schema: Self.streamContainerSchema_text),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.text, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "empty", index: Self.StreamField.empty,
                  route: _streamFieldRoute(&p.pointee.empty, schema: Self.streamContainerSchema_empty),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.empty, in: p)
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
              fields: Self.streamFields
            )
          }

          enum TextPayload {
              struct Partial: StreamParsingCore.StreamParseable,
                StreamParsingCore.StreamParseableObject, Sendable {
                typealias Partial = Self

                var _0: String.Partial?

                init(
                  _0: String.Partial? = nil
                ) {
                  self._0 = _0
                }

                // Cached rather than re-evaluated: `Self()` walks every default expression fresh, which
                // for a large nested struct is a long chain of small copies. Every member's own `Partial`
                // is `Sendable` (every leaf and every "Fast" container conforms), which is what makes
                // `Self` itself `Sendable` here and lets the template be a plain `static let`.
                private static let _streamInitialValueTemplate: Self = Self()

                static func streamInitialValue() -> Self {
                  Self._streamInitialValueTemplate
                }

                struct View: ~Copyable, ~Escapable {
                  let _streamStorage: UnsafeMutablePointer<Partial>

                  @_lifetime(borrow storage)
                  init(_ storage: UnsafeMutableRawPointer) {
                    self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
                  }

                var _0: String.Partial.View? {
                    @_lifetime(borrow self)
                    get {
                      guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee._0) else {
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
                  static let _0: Int32 = 0
                }

                private static let streamContainerSchema__0 = _streamContainerSchema(for: (String.Partial).self)

                static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
                  switch key.paddedLeadingWord() {
                  case 0x0000_0000_0000_305F where key.count == 2:
                  return Self.StreamField._0
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
                  case Self.StreamField._0:
                  return streamApply(&p.pointee._0, utf8: bytes)
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
                  case Self.StreamField._0:
                  return streamApply(&p.pointee._0, bytes: bytes, info: info)
                  default:
                  return .unsupported
                  }
                }

                static func streamApplyBoolean(
                  _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
                ) -> StreamParsingCore.StreamApplyResult {
                  let p = storage.assumingMemoryBound(to: Self.self)
                  switch field {
                  case Self.StreamField._0:
                  return streamApply(&p.pointee._0, boolean: value)
                  default:
                  return .unsupported
                  }
                }

                static func streamApplyNull(
                  _ storage: UnsafeMutableRawPointer, _ field: Int32
                ) -> StreamParsingCore.StreamApplyResult {
                  let p = storage.assumingMemoryBound(to: Self.self)
                  switch field {
                  case Self.StreamField._0:
                  return StreamParsing.streamApplyNull(&p.pointee._0)
                  default:
                  return .unsupported
                  }
                }

                static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
                  of: Self.self, prototype: Self()
                ) { p in
                  [
                    StreamParsingCore.StreamField(
                      key: "_0", index: Self.StreamField._0,
                      route: _streamFieldRoute(&p.pointee._0, schema: Self.streamContainerSchema__0),
                      offset: StreamParsingCore._streamFieldOffset(&p.pointee._0, in: p)
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
                  fields: Self.streamFields
                )
              }

              struct Value: StreamParsingCore.StreamParseable {
                var _0: String

                typealias Partial = TextPayload.Partial

                var streamPartialValue: Partial {
                  Partial(
                    _0: self._0.streamPartialValue
                  )
                }

                init?(_ partial: Partial) {
                    self.init(streamPartial: partial)
                  }

                  init?(streamPartial partial: Partial) {
                    guard
                      let _0 = Self._streamValue({ $0._0
                    }, partial._0)
                    else {
                      return nil
                    }
                    self._0 = _0
                  }

                  init(orInitial partial: Partial) {
                    self._0 = Self._streamValueOrInitial({
                      $0._0
                    }, partial._0)
                  }

                  static func streamValueOrInitial(from partial: Partial) -> Self {
                    Self(orInitial: partial)
                  }
              }
            }

          init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          /// Fails unless exactly one case's key arrived, matching what `JSONDecoder` accepts for
          /// the same document — and, for a case with associated values, unless that one case's own
          /// payload has everything it needs yet.
          init?(streamPartial partial: Partial) {
            var streamMatched = -1
            var streamMatches = 0
            if partial.text != nil {
              streamMatched = 0
              streamMatches += 1
            }
            if partial.empty != nil {
              streamMatched = 1
              streamMatches += 1
            }
            guard streamMatches == 1 else {
              return nil
            }
            switch streamMatched {
            case 0:
              guard let streamValue = TextPayload.Value(streamPartial: partial.text!)
              else {
                return nil
              }
              self = .text(streamValue._0)
            case 1:
              self = .empty
            default:
              return nil
            }
          }

          /// Falls back to the case marked `@StreamParseableDefault` when the stream did not
          /// produce a value this type can represent.
          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(streamPartial: partial) ?? .empty
          }
        }
        """
      }
    }

    @Test
    func `Applied To Class Or Actor`() {
      assertMacro {
        """
        @StreamParseable
        class Person {
          var name: String
        }
        """
      } diagnostics: {
        """
        @StreamParseable
        ┬───────────────
        ├─ 🛑 @StreamParseable can only be applied to struct or enum declarations.
        ╰─ 🛑 @StreamParseable can only be applied to struct or enum declarations.
        class Person {
          var name: String
        }
        """
      }
      assertMacro {
        """
        @StreamParseable
        actor Person {
          var name: String
        }
        """
      } diagnostics: {
        """
        @StreamParseable
        ┬───────────────
        ├─ 🛑 @StreamParseable can only be applied to struct or enum declarations.
        ╰─ 🛑 @StreamParseable can only be applied to struct or enum declarations.
        actor Person {
          var name: String
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

          var streamPartialValue: Partial {
            Partial(name: name.streamPartialValue)
          }
        }
        """
      } expansion: {
        """
        struct Person {
          var name: String

          var streamPartialValue: Partial {
            Partial(name: name.streamPartialValue)
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject, Sendable {
            typealias Partial = Self

            var name: String.Partial?

            init(
              name: String.Partial? = nil
            ) {
              self.name = name
            }

            // Cached rather than re-evaluated: `Self()` walks every default expression fresh, which
            // for a large nested struct is a long chain of small copies. Every member's own `Partial`
            // is `Sendable` (every leaf and every "Fast" container conforms), which is what makes
            // `Self` itself `Sendable` here and lets the template be a plain `static let`.
            private static let _streamInitialValueTemplate: Self = Self()

            static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
            }

            struct View: ~Copyable, ~Escapable {
              let _streamStorage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
              }

            var name: String.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.name) else {
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
              static let name: Int32 = 0
            }

            private static let streamContainerSchema_name = _streamContainerSchema(for: (String.Partial).self)

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
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, utf8: bytes)
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
              default:
                return .unsupported
              }
            }

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "name", index: Self.StreamField.name,
                  route: _streamFieldRoute(&p.pointee.name, schema: Self.streamContainerSchema_name),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.name, in: p)
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
              }, partial.name)
            else {
              return nil
            }
            self.name = name
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          init(orInitial partial: Partial) {
            self.name = Self._streamValueOrInitial({
                $0.name
              }, partial.name)
          }

          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
          }
        }
        """
      }
    }

    @Test
    func `Access Modifier`() {
      assertMacro {
        """
        @StreamParseable
        public struct Person {
          public var name: String
        }
        """
      } expansion: {
        """
        public struct Person {
          public var name: String

          public var streamPartialValue: Partial {
            Partial(
              name: self.name.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          public struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject, Sendable {
            public typealias Partial = Self

            public var name: String.Partial?

            public init(
              name: String.Partial? = nil
            ) {
              self.name = name
            }

            // Cached rather than re-evaluated: `Self()` walks every default expression fresh, which
            // for a large nested struct is a long chain of small copies. Every member's own `Partial`
            // is `Sendable` (every leaf and every "Fast" container conforms), which is what makes
            // `Self` itself `Sendable` here and lets the template be a plain `static let`.
            private static let _streamInitialValueTemplate: Self = Self()

            public static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
            }

            public struct View: ~Copyable, ~Escapable {
              public let _streamStorage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              public init(_ storage: UnsafeMutableRawPointer) {
                self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
              }

            public var name: String.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.name) else {
                    return nil
                  }
                  return _overrideLifetime(String.Partial.streamView(address), borrowing: self)
                }
              }
            }

            @_lifetime(borrow storage)
            public static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let name: Int32 = 0
            }

            private static let streamContainerSchema_name = _streamContainerSchema(for: (String.Partial).self)

            public static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_0000_656D_616E where key.count == 4:
                return Self.StreamField.name
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
              default:
                return .unsupported
              }
            }

            public static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "name", index: Self.StreamField.name,
                  route: _streamFieldRoute(&p.pointee.name, schema: Self.streamContainerSchema_name),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.name, in: p)
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
              }, partial.name)
            else {
              return nil
            }
            self.name = name
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          public init(orInitial partial: Partial) {
            self.name = Self._streamValueOrInitial({
                $0.name
              }, partial.name)
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
        }
        """
      } expansion: {
        """
        private struct Person {
          var name: String

          var streamPartialValue: Partial {
            Partial(
              name: self.name.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject, Sendable {
            typealias Partial = Self

            var name: String.Partial?

            init(
              name: String.Partial? = nil
            ) {
              self.name = name
            }

            // Cached rather than re-evaluated: `Self()` walks every default expression fresh, which
            // for a large nested struct is a long chain of small copies. Every member's own `Partial`
            // is `Sendable` (every leaf and every "Fast" container conforms), which is what makes
            // `Self` itself `Sendable` here and lets the template be a plain `static let`.
            private static let _streamInitialValueTemplate: Self = Self()

            static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
            }

            struct View: ~Copyable, ~Escapable {
              let _streamStorage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
              }

            var name: String.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.name) else {
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
              static let name: Int32 = 0
            }

            private static let streamContainerSchema_name = _streamContainerSchema(for: (String.Partial).self)

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
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, utf8: bytes)
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
              default:
                return .unsupported
              }
            }

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "name", index: Self.StreamField.name,
                  route: _streamFieldRoute(&p.pointee.name, schema: Self.streamContainerSchema_name),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.name, in: p)
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
              }, partial.name)
            else {
              return nil
            }
            self.name = name
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          init(orInitial partial: Partial) {
            self.name = Self._streamValueOrInitial({
                $0.name
              }, partial.name)
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
        }
        """
      } expansion: {
        """
        fileprivate struct Person {
          var name: String

          fileprivate var streamPartialValue: Partial {
            Partial(
              name: self.name.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          fileprivate struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject, Sendable {
            fileprivate typealias Partial = Self

            fileprivate var name: String.Partial?

            fileprivate init(
              name: String.Partial? = nil
            ) {
              self.name = name
            }

            // Cached rather than re-evaluated: `Self()` walks every default expression fresh, which
            // for a large nested struct is a long chain of small copies. Every member's own `Partial`
            // is `Sendable` (every leaf and every "Fast" container conforms), which is what makes
            // `Self` itself `Sendable` here and lets the template be a plain `static let`.
            private static let _streamInitialValueTemplate: Self = Self()

            fileprivate static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
            }

            fileprivate struct View: ~Copyable, ~Escapable {
              fileprivate let _streamStorage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              fileprivate init(_ storage: UnsafeMutableRawPointer) {
                self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
              }

            fileprivate var name: String.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.name) else {
                    return nil
                  }
                  return _overrideLifetime(String.Partial.streamView(address), borrowing: self)
                }
              }
            }

            @_lifetime(borrow storage)
            fileprivate static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let name: Int32 = 0
            }

            private static let streamContainerSchema_name = _streamContainerSchema(for: (String.Partial).self)

            fileprivate static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_0000_656D_616E where key.count == 4:
                return Self.StreamField.name
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
              default:
                return .unsupported
              }
            }

            fileprivate static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "name", index: Self.StreamField.name,
                  route: _streamFieldRoute(&p.pointee.name, schema: Self.streamContainerSchema_name),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.name, in: p)
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
              }, partial.name)
            else {
              return nil
            }
            self.name = name
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          fileprivate init(orInitial partial: Partial) {
            self.name = Self._streamValueOrInitial({
                $0.name
              }, partial.name)
          }

          fileprivate static func streamValueOrInitial(from partial: Partial) -> Self {
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
            StreamParsingCore.StreamParseableObject, Sendable {
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

            // Cached rather than re-evaluated: `Self()` walks every default expression fresh, which
            // for a large nested struct is a long chain of small copies. Every member's own `Partial`
            // is `Sendable` (every leaf and every "Fast" container conforms), which is what makes
            // `Self` itself `Sendable` here and lets the template be a plain `static let`.
            private static let _streamInitialValueTemplate: Self = Self()

            static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
            }

            struct View: ~Copyable, ~Escapable {
              let _streamStorage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
              }

            var items: [Item].Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.items) else {
                    return nil
                  }
                  return _overrideLifetime([Item].Partial.streamView(address), borrowing: self)
                }
              }

            var index: StreamParsingCore.StreamDictionary<Item.Partial>.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.index) else {
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

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "items", index: Self.StreamField.items,
                  route: _streamFieldRoute(&p.pointee.items, schema: Self.streamContainerSchema_items),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.items, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "index", index: Self.StreamField.index,
                  route: _streamFieldRoute(&p.pointee.index, schema: Self.streamContainerSchema_index),
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

    @Test
    func `Nested Type Extends Its Qualified Name`() {
      assertMacro {
        """
        struct Outer {
          @StreamParseable
          struct Inner {
            var a: Int
          }
        }
        """
      } expansion: {
        """
        struct Outer {
          struct Inner {
            var a: Int

            var streamPartialValue: Partial {
              Partial(
                a: self.a.streamPartialValue
              )
            }
          }
        }

        extension Outer.Inner: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject, Sendable {
            typealias Partial = Self

            var a: Int.Partial?

            init(
              a: Int.Partial? = nil
            ) {
              self.a = a
            }

            // Cached rather than re-evaluated: `Self()` walks every default expression fresh, which
            // for a large nested struct is a long chain of small copies. Every member's own `Partial`
            // is `Sendable` (every leaf and every "Fast" container conforms), which is what makes
            // `Self` itself `Sendable` here and lets the template be a plain `static let`.
            private static let _streamInitialValueTemplate: Self = Self()

            static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
            }

            struct View: ~Copyable, ~Escapable {
              let _streamStorage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
              }

            var a: Int.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.a) else {
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
              static let a: Int32 = 0
            }

            private static let streamContainerSchema_a = _streamContainerSchema(for: (Int.Partial).self)

            static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_0000_0000_0061 where key.count == 1:
                return Self.StreamField.a
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
              case Self.StreamField.a:
                return streamApply(&p.pointee.a, utf8: bytes)
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
              case Self.StreamField.a:
                return streamApply(&p.pointee.a, bytes: bytes, info: info)
              default:
                return .unsupported
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.a:
                return streamApply(&p.pointee.a, boolean: value)
              default:
                return .unsupported
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.a:
                return StreamParsing.streamApplyNull(&p.pointee.a)
              default:
                return .unsupported
              }
            }

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "a", index: Self.StreamField.a,
                  route: _streamFieldRoute(&p.pointee.a, schema: Self.streamContainerSchema_a),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.a, in: p)
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
              fields: Self.streamFields
            )
          }

          init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          /// Fails when the stream did not produce a member this type has no way to do without.
          init?(streamPartial partial: Partial) {
            guard
              let a = Self._streamValue({ $0.a
              }, partial.a)
            else {
              return nil
            }
            self.a = a
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          init(orInitial partial: Partial) {
            self.a = Self._streamValueOrInitial({
                $0.a
              }, partial.a)
          }

          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
          }
        }
        """
      }
    }

    @Test
    func `Generic Type Is Diagnosed`() {
      assertMacro {
        """
        @StreamParseable
        struct Box<T> {
          var value: T
        }
        """
      } diagnostics: {
        """
        @StreamParseable
        struct Box<T> {
                  ┬──
                  ╰─ 🛑 @StreamParseable does not support generic types.
          var value: T
        }
        """
      }
    }

    @Test
    func `Package Access Level`() {
      assertMacro {
        """
        @StreamParseable
        package struct Person {
          package var name: String
        }
        """
      } expansion: {
        """
        package struct Person {
          package var name: String

          package var streamPartialValue: Partial {
            Partial(
              name: self.name.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          package struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject, Sendable {
            package typealias Partial = Self

            package var name: String.Partial?

            package init(
              name: String.Partial? = nil
            ) {
              self.name = name
            }

            // Cached rather than re-evaluated: `Self()` walks every default expression fresh, which
            // for a large nested struct is a long chain of small copies. Every member's own `Partial`
            // is `Sendable` (every leaf and every "Fast" container conforms), which is what makes
            // `Self` itself `Sendable` here and lets the template be a plain `static let`.
            private static let _streamInitialValueTemplate: Self = Self()

            package static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
            }

            package struct View: ~Copyable, ~Escapable {
              package let _streamStorage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              package init(_ storage: UnsafeMutableRawPointer) {
                self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
              }

            package var name: String.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.name) else {
                    return nil
                  }
                  return _overrideLifetime(String.Partial.streamView(address), borrowing: self)
                }
              }
            }

            @_lifetime(borrow storage)
            package static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let name: Int32 = 0
            }

            private static let streamContainerSchema_name = _streamContainerSchema(for: (String.Partial).self)

            package static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_0000_656D_616E where key.count == 4:
                return Self.StreamField.name
              default:
                return -1
              }
            }

            package static func streamApplyString(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, utf8: bytes)
              default:
                return .unsupported
              }
            }

            package static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, bytes: bytes, info: info)
              default:
                return .unsupported
              }
            }

            package static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, boolean: value)
              default:
                return .unsupported
              }
            }

            package static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return StreamParsing.streamApplyNull(&p.pointee.name)
              default:
                return .unsupported
              }
            }

            package static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "name", index: Self.StreamField.name,
                  route: _streamFieldRoute(&p.pointee.name, schema: Self.streamContainerSchema_name),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.name, in: p)
                ),
              ]
            }

            package static let streamSchema = StreamParsingCore.StreamSchema(
              shape: .object,
              matchField: Self.streamMatchField,
              applyString: Self.streamApplyString,
              applyNumber: Self.streamApplyNumber,
              applyBoolean: Self.streamApplyBoolean,
              applyNull: Self.streamApplyNull,
              fields: Self.streamFields
            )
          }

          package init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          /// Fails when the stream did not produce a member this type has no way to do without.
          package init?(streamPartial partial: Partial) {
            guard
              let name = Self._streamValue({ $0.name
              }, partial.name)
            else {
              return nil
            }
            self.name = name
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          package init(orInitial partial: Partial) {
            self.name = Self._streamValueOrInitial({
                $0.name
              }, partial.name)
          }

          package static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
          }
        }
        """
      }
    }

    @Test
    func `Backticked Member Name`() {
      assertMacro {
        """
        @StreamParseable
        struct Person {
          var `class`: Int
        }
        """
      } expansion: {
        """
        struct Person {
          var `class`: Int

          var streamPartialValue: Partial {
            Partial(
              `class`: self.`class`.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject, Sendable {
            typealias Partial = Self

            var `class`: Int.Partial?

            init(
              `class`: Int.Partial? = nil
            ) {
              self.`class` = `class`
            }

            // Cached rather than re-evaluated: `Self()` walks every default expression fresh, which
            // for a large nested struct is a long chain of small copies. Every member's own `Partial`
            // is `Sendable` (every leaf and every "Fast" container conforms), which is what makes
            // `Self` itself `Sendable` here and lets the template be a plain `static let`.
            private static let _streamInitialValueTemplate: Self = Self()

            static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
            }

            struct View: ~Copyable, ~Escapable {
              let _streamStorage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
              }

            var `class`: Int.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.`class`) else {
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
              static let `class`: Int32 = 0
            }

            private static let streamContainerSchema_class = _streamContainerSchema(for: (Int.Partial).self)

            static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_0073_7361_6C63 where key.count == 5:
                return Self.StreamField.`class`
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
              case Self.StreamField.`class`:
                return streamApply(&p.pointee.`class`, utf8: bytes)
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
              case Self.StreamField.`class`:
                return streamApply(&p.pointee.`class`, bytes: bytes, info: info)
              default:
                return .unsupported
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.`class`:
                return streamApply(&p.pointee.`class`, boolean: value)
              default:
                return .unsupported
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.`class`:
                return StreamParsing.streamApplyNull(&p.pointee.`class`)
              default:
                return .unsupported
              }
            }

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "class", index: Self.StreamField.`class`,
                  route: _streamFieldRoute(&p.pointee.`class`, schema: Self.streamContainerSchema_class),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.`class`, in: p)
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
              fields: Self.streamFields
            )
          }

          init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          /// Fails when the stream did not produce a member this type has no way to do without.
          init?(streamPartial partial: Partial) {
            guard
              let `class` = Self._streamValue({ $0.`class`
              }, partial.`class`)
            else {
              return nil
            }
            self.`class` = `class`
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          init(orInitial partial: Partial) {
            self.`class` = Self._streamValueOrInitial({
                $0.`class`
              }, partial.`class`)
          }

          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
          }
        }
        """
      }
    }

    @Test
    func `Backticked Enum Case Name`() {
      assertMacro {
        """
        @StreamParseable
        enum Kind {
          @StreamParseableDefault
          case `default`
        }
        """
      } expansion: {
        """
        enum Kind {
          @StreamParseableDefault
          case `default`

          var streamPartialValue: Partial {
            switch self {
            case .`default`:
              return Partial(`default`: StreamParsingCore.StreamEmptyObject())
            }
          }
        }

        extension Kind: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject, Sendable {
            typealias Partial = Self

            var `default`: StreamParsingCore.StreamEmptyObject.Partial?

            init(
              `default`: StreamParsingCore.StreamEmptyObject.Partial? = nil
            ) {
              self.`default` = `default`
            }

            // Cached rather than re-evaluated: `Self()` walks every default expression fresh, which
            // for a large nested struct is a long chain of small copies. Every member's own `Partial`
            // is `Sendable` (every leaf and every "Fast" container conforms), which is what makes
            // `Self` itself `Sendable` here and lets the template be a plain `static let`.
            private static let _streamInitialValueTemplate: Self = Self()

            static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
            }

            struct View: ~Copyable, ~Escapable {
              let _streamStorage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
              }

            var `default`: StreamParsingCore.StreamEmptyObject.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.`default`) else {
                    return nil
                  }
                  return _overrideLifetime(StreamParsingCore.StreamEmptyObject.Partial.streamView(address), borrowing: self)
                }
              }

          /// One case's borrowed, mid-stream view — or `.unresolved`/`.ambiguous` when zero or more
          /// than one case's key has arrived yet.
          enum ResolvedView: ~Copyable, ~Escapable {
            case unresolved
            case ambiguous
              case `default`
            }

            var resolved: ResolvedView {
              @_lifetime(borrow self)
              get {
                var streamMatched = -1
                var streamMatches = 0
              if self._streamStorage.pointee.`default` != nil {
                  streamMatched = 0;
                  streamMatches += 1
                }
                guard streamMatches == 1 else {
                  if streamMatches == 0 {
                    return .unresolved
                  }
                  return .ambiguous
                }
                switch streamMatched {
              case 0:
                return .`default`
                default:
                  return .unresolved
                }
              }
            }
          }

            @_lifetime(borrow storage)
            static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let `default`: Int32 = 0
            }

            private static let streamContainerSchema_default = _streamContainerSchema(for: (StreamParsingCore.StreamEmptyObject.Partial).self)

            static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0074_6C75_6166_6564 where key.count == 7:
                return Self.StreamField.`default`
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
              case Self.StreamField.`default`:
                return streamApply(&p.pointee.`default`, utf8: bytes)
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
              case Self.StreamField.`default`:
                return streamApply(&p.pointee.`default`, bytes: bytes, info: info)
              default:
                return .unsupported
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.`default`:
                return streamApply(&p.pointee.`default`, boolean: value)
              default:
                return .unsupported
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.`default`:
                return StreamParsing.streamApplyNull(&p.pointee.`default`)
              default:
                return .unsupported
              }
            }

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "default", index: Self.StreamField.`default`,
                  route: _streamFieldRoute(&p.pointee.`default`, schema: Self.streamContainerSchema_default),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.`default`, in: p)
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
              fields: Self.streamFields
            )
          }

          init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          /// Fails unless exactly one case's key arrived, matching what `JSONDecoder` accepts for
          /// the same document — and, for a case with associated values, unless that one case's own
          /// payload has everything it needs yet.
          init?(streamPartial partial: Partial) {
            var streamMatched = -1
            var streamMatches = 0
            if partial.`default` != nil {
              streamMatched = 0
              streamMatches += 1
            }
            guard streamMatches == 1 else {
              return nil
            }
            switch streamMatched {
            case 0:
              self = .`default`
            default:
              return nil
            }
          }

          /// Falls back to the case marked `@StreamParseableDefault` when the stream did not
          /// produce a value this type can represent.
          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(streamPartial: partial) ?? .`default`
          }
        }
        """
      }
    }

    @Test
    func `Immutable Member With A Default Is Ignored`() {
      assertMacro {
        """
        @StreamParseable
        struct Person {
          let a: Int = 5
          var b: String
        }
        """
      } expansion: {
        """
        struct Person {
          let a: Int = 5
          var b: String

          var streamPartialValue: Partial {
            Partial(
              b: self.b.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject, Sendable {
            typealias Partial = Self

            var b: String.Partial?

            init(
              b: String.Partial? = nil
            ) {
              self.b = b
            }

            // Cached rather than re-evaluated: `Self()` walks every default expression fresh, which
            // for a large nested struct is a long chain of small copies. Every member's own `Partial`
            // is `Sendable` (every leaf and every "Fast" container conforms), which is what makes
            // `Self` itself `Sendable` here and lets the template be a plain `static let`.
            private static let _streamInitialValueTemplate: Self = Self()

            static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
            }

            struct View: ~Copyable, ~Escapable {
              let _streamStorage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
              }

            var b: String.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.b) else {
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
              static let b: Int32 = 0
            }

            private static let streamContainerSchema_b = _streamContainerSchema(for: (String.Partial).self)

            static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_0000_0000_0062 where key.count == 1:
                return Self.StreamField.b
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
              case Self.StreamField.b:
                return streamApply(&p.pointee.b, utf8: bytes)
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
              case Self.StreamField.b:
                return streamApply(&p.pointee.b, bytes: bytes, info: info)
              default:
                return .unsupported
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.b:
                return streamApply(&p.pointee.b, boolean: value)
              default:
                return .unsupported
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.b:
                return StreamParsing.streamApplyNull(&p.pointee.b)
              default:
                return .unsupported
              }
            }

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "b", index: Self.StreamField.b,
                  route: _streamFieldRoute(&p.pointee.b, schema: Self.streamContainerSchema_b),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.b, in: p)
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
              fields: Self.streamFields
            )
          }

          init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          /// Fails when the stream did not produce a member this type has no way to do without.
          init?(streamPartial partial: Partial) {
            guard
              let b = Self._streamValue({ $0.b
              }, partial.b)
            else {
              return nil
            }
            self.b = b
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          init(orInitial partial: Partial) {
            self.b = Self._streamValueOrInitial({
                $0.b
              }, partial.b)
          }

          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
          }
        }
        """
      }
    }

    @Test
    func `Multiple Bindings Share One Type Annotation`() {
      assertMacro {
        """
        @StreamParseable
        struct Person {
          var a, b: Int
        }
        """
      } expansion: {
        """
        struct Person {
          var a, b: Int

          var streamPartialValue: Partial {
            Partial(
              a: self.a.streamPartialValue,
              b: self.b.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject, Sendable {
            typealias Partial = Self

            var a: Int.Partial?
            var b: Int.Partial?

            init(
              a: Int.Partial? = nil,
              b: Int.Partial? = nil
            ) {
              self.a = a
              self.b = b
            }

            // Cached rather than re-evaluated: `Self()` walks every default expression fresh, which
            // for a large nested struct is a long chain of small copies. Every member's own `Partial`
            // is `Sendable` (every leaf and every "Fast" container conforms), which is what makes
            // `Self` itself `Sendable` here and lets the template be a plain `static let`.
            private static let _streamInitialValueTemplate: Self = Self()

            static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
            }

            struct View: ~Copyable, ~Escapable {
              let _streamStorage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
              }

            var a: Int.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.a) else {
                    return nil
                  }
                  return _overrideLifetime(Int.Partial.streamView(address), borrowing: self)
                }
              }

            var b: Int.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.b) else {
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
              static let a: Int32 = 0
              static let b: Int32 = 1
            }

            private static let streamContainerSchema_a = _streamContainerSchema(for: (Int.Partial).self)
            private static let streamContainerSchema_b = _streamContainerSchema(for: (Int.Partial).self)

            static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_0000_0000_0061 where key.count == 1:
                return Self.StreamField.a
              case 0x0000_0000_0000_0062 where key.count == 1:
                return Self.StreamField.b
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
              case Self.StreamField.a:
                return streamApply(&p.pointee.a, utf8: bytes)
              case Self.StreamField.b:
                return streamApply(&p.pointee.b, utf8: bytes)
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
              case Self.StreamField.a:
                return streamApply(&p.pointee.a, bytes: bytes, info: info)
              case Self.StreamField.b:
                return streamApply(&p.pointee.b, bytes: bytes, info: info)
              default:
                return .unsupported
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.a:
                return streamApply(&p.pointee.a, boolean: value)
              case Self.StreamField.b:
                return streamApply(&p.pointee.b, boolean: value)
              default:
                return .unsupported
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.a:
                return StreamParsing.streamApplyNull(&p.pointee.a)
              case Self.StreamField.b:
                return StreamParsing.streamApplyNull(&p.pointee.b)
              default:
                return .unsupported
              }
            }

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "a", index: Self.StreamField.a,
                  route: _streamFieldRoute(&p.pointee.a, schema: Self.streamContainerSchema_a),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.a, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "b", index: Self.StreamField.b,
                  route: _streamFieldRoute(&p.pointee.b, schema: Self.streamContainerSchema_b),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.b, in: p)
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
              fields: Self.streamFields
            )
          }

          init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          /// Fails when the stream did not produce a member this type has no way to do without.
          init?(streamPartial partial: Partial) {
            guard
              let a = Self._streamValue({ $0.a
              }, partial.a),
              let b = Self._streamValue({ $0.b
              }, partial.b)
            else {
              return nil
            }
            self.a = a
            self.b = b
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          init(orInitial partial: Partial) {
            self.a = Self._streamValueOrInitial({
                $0.a
              }, partial.a)
            self.b = Self._streamValueOrInitial({
                $0.b
              }, partial.b)
          }

          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
          }
        }
        """
      }
    }

    @Test
    func `Member Named Storage`() {
      assertMacro {
        """
        @StreamParseable
        struct Person {
          var storage: Int
        }
        """
      } expansion: {
        """
        struct Person {
          var storage: Int

          var streamPartialValue: Partial {
            Partial(
              storage: self.storage.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject, Sendable {
            typealias Partial = Self

            var storage: Int.Partial?

            init(
              storage: Int.Partial? = nil
            ) {
              self.storage = storage
            }

            // Cached rather than re-evaluated: `Self()` walks every default expression fresh, which
            // for a large nested struct is a long chain of small copies. Every member's own `Partial`
            // is `Sendable` (every leaf and every "Fast" container conforms), which is what makes
            // `Self` itself `Sendable` here and lets the template be a plain `static let`.
            private static let _streamInitialValueTemplate: Self = Self()

            static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
            }

            struct View: ~Copyable, ~Escapable {
              let _streamStorage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
              }

            var storage: Int.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.storage) else {
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
              static let storage: Int32 = 0
            }

            private static let streamContainerSchema_storage = _streamContainerSchema(for: (Int.Partial).self)

            static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0065_6761_726F_7473 where key.count == 7:
                return Self.StreamField.storage
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
              case Self.StreamField.storage:
                return streamApply(&p.pointee.storage, utf8: bytes)
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
              case Self.StreamField.storage:
                return streamApply(&p.pointee.storage, bytes: bytes, info: info)
              default:
                return .unsupported
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.storage:
                return streamApply(&p.pointee.storage, boolean: value)
              default:
                return .unsupported
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.storage:
                return StreamParsing.streamApplyNull(&p.pointee.storage)
              default:
                return .unsupported
              }
            }

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "storage", index: Self.StreamField.storage,
                  route: _streamFieldRoute(&p.pointee.storage, schema: Self.streamContainerSchema_storage),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.storage, in: p)
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
              fields: Self.streamFields
            )
          }

          init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          /// Fails when the stream did not produce a member this type has no way to do without.
          init?(streamPartial partial: Partial) {
            guard
              let storage = Self._streamValue({ $0.storage
              }, partial.storage)
            else {
              return nil
            }
            self.storage = storage
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          init(orInitial partial: Partial) {
            self.storage = Self._streamValueOrInitial({
                $0.storage
              }, partial.storage)
          }

          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
          }
        }
        """
      }
    }

    @Test
    func `Enum Case Named Like A ResolvedView Sentinel`() {
      assertMacro {
        """
        @StreamParseable
        enum E {
          @StreamParseableDefault
          case unresolved
        }
        """
      } diagnostics: {
        """
        @StreamParseable
        enum E {
          @StreamParseableDefault
          case unresolved
               ┬─────────
               ╰─ 🛑 Case 'unresolved' collides with the generated 'ResolvedView.unresolved' sentinel. Rename the case, or give it a key with @StreamParseableMember.
        }
        """
      }
    }

    @Test
    func `Payload Type Name Collision`() {
      assertMacro {
        """
        @StreamParseable
        enum E {
          @StreamParseableDefault
          case text(String)
          case Text(Int)
        }
        """
      } diagnostics: {
        """
        @StreamParseable
        enum E {
          @StreamParseableDefault
          case text(String)
          case Text(Int)
               ┬────────
               ╰─ 🛑 Case 'Text' generates the payload type 'TextPayload', which another case already generates. Case names that differ only in capitalisation cannot both carry a payload.
        }
        """
      }
    }

    @Test
    func `Qualified String Raw Type`() {
      assertMacro {
        """
        @StreamParseable
        enum Stage: Swift.String {
          @StreamParseableDefault
          case live
        }
        """
      } expansion: {
        """
        enum Stage: Swift.String {
          @StreamParseableDefault
          case live

          var streamPartialValue: Partial {
            self.rawValue.streamPartialValue
          }
        }

        extension Stage: StreamParsingCore.StreamParseable {
          typealias Partial = StreamParsingCore.StreamString

          init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          /// Resolves the case the accumulated raw value names, or the shortest case that value is
          /// still a prefix of.
          ///
          /// A partial string cannot say whether it is finished, so a value that names one case and
          /// is a prefix of a longer one resolves to the shorter and may later be superseded.
          init?(streamPartial partial: Partial) {
            let streamCount = partial.utf8Count
            guard streamCount > 0 else {
              return nil
            }
            switch partial.paddedLeadingWord() {
            case 0x0000_0000_6576_696C where streamCount == 4:
              self = .live
              return
            default:
              break
            }
            if partial.isPrefix(of: "live") {
              self = .live
              return
            }
            return nil
          }

          /// Falls back to the case marked `@StreamParseableDefault` when the stream did not
          /// produce a value this type can represent.
          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(streamPartial: partial) ?? .live
          }
        }
        """
      }
    }

    @Test
    func `Interpolated Key`() {
      assertMacro {
        """
        @StreamParseable
        struct Person {
          @StreamParseableMember(key: "a\\(1)b")
          var name: String
        }
        """
      } diagnostics: {
        #"""
        @StreamParseable
        struct Person {
          @StreamParseableMember(key: "a\(1)b")
          ┬────────────────────────────────────
          ╰─ 🛑 @StreamParseableMember(key:) requires a string literal.
          var name: String
        }
        """#
      } 
    }

    @Test
    func `Empty Key`() {
      assertMacro {
        """
        @StreamParseable
        struct Person {
          @StreamParseableMember(key: "")
          var name: String
        }
        """
      } diagnostics: {
        """
        @StreamParseable
        struct Person {
          @StreamParseableMember(key: "")
          ┬──────────────────────────────
          ╰─ 🛑 @StreamParseableMember(key:) must not be empty.
          var name: String
        }
        """
      }
    }

    @Test
    func `Key And Key Names Together`() {
      assertMacro {
        """
        @StreamParseable
        struct Person {
          @StreamParseableMember(key: "a", keyNames: ["b"])
          var name: String
        }
        """
      } diagnostics: {
        """
        @StreamParseable
        struct Person {
          @StreamParseableMember(key: "a", keyNames: ["b"])
          ┬────────────────────────────────────────────────
          ╰─ 🛑 @StreamParseableMember takes either key: or keyNames:, not both.
          var name: String
        }
        """
      }
    }

    @Test
    func `Duplicate Key Names`() {
      assertMacro {
        """
        @StreamParseable
        struct Person {
          var a: Int
          @StreamParseableMember(key: "a")
          var b: Int
        }
        """
      } diagnostics: {
        """
        @StreamParseable
        struct Person {
          var a: Int
          @StreamParseableMember(key: "a")
          ╰─ 🛑 Key 'a' is already claimed by another property.
          var b: Int
        }
        """
      }
    }

    @Test
    func `Explicit Conformance Is Not Restated`() {
      assertMacro {
        """
        @StreamParseable
        struct Person: StreamParseable {
          var name: String
        }
        """
      } expansion: {
        """
        struct Person: StreamParseable {
          var name: String

          var streamPartialValue: Partial {
            Partial(
              name: self.name.streamPartialValue
            )
          }
        }

        extension Person {
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject, Sendable {
            typealias Partial = Self

            var name: String.Partial?

            init(
              name: String.Partial? = nil
            ) {
              self.name = name
            }

            // Cached rather than re-evaluated: `Self()` walks every default expression fresh, which
            // for a large nested struct is a long chain of small copies. Every member's own `Partial`
            // is `Sendable` (every leaf and every "Fast" container conforms), which is what makes
            // `Self` itself `Sendable` here and lets the template be a plain `static let`.
            private static let _streamInitialValueTemplate: Self = Self()

            static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
            }

            struct View: ~Copyable, ~Escapable {
              let _streamStorage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
              }

            var name: String.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.name) else {
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
              static let name: Int32 = 0
            }

            private static let streamContainerSchema_name = _streamContainerSchema(for: (String.Partial).self)

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
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, utf8: bytes)
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
              default:
                return .unsupported
              }
            }

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "name", index: Self.StreamField.name,
                  route: _streamFieldRoute(&p.pointee.name, schema: Self.streamContainerSchema_name),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.name, in: p)
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
              }, partial.name)
            else {
              return nil
            }
            self.name = name
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          init(orInitial partial: Partial) {
            self.name = Self._streamValueOrInitial({
                $0.name
              }, partial.name)
          }

          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
          }
        }
        """
      }
    }

    @Test
    func `Double Optional Member`() {
      assertMacro {
        """
        @StreamParseable
        struct Person {
          var x: Int??
        }
        """
      } expansion: {
        """
        struct Person {
          var x: Int??

          var streamPartialValue: Partial {
            Partial(
              x: self.x.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject, Sendable {
            typealias Partial = Self

            var x: Int.Partial?

            init(
              x: Int.Partial? = nil
            ) {
              self.x = x
            }

            // Cached rather than re-evaluated: `Self()` walks every default expression fresh, which
            // for a large nested struct is a long chain of small copies. Every member's own `Partial`
            // is `Sendable` (every leaf and every "Fast" container conforms), which is what makes
            // `Self` itself `Sendable` here and lets the template be a plain `static let`.
            private static let _streamInitialValueTemplate: Self = Self()

            static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
            }

            struct View: ~Copyable, ~Escapable {
              let _streamStorage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
              }

            var x: Int.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.x) else {
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
              static let x: Int32 = 0
            }

            private static let streamContainerSchema_x = _streamContainerSchema(for: (Int.Partial).self)

            static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_0000_0000_0078 where key.count == 1:
                return Self.StreamField.x
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
              case Self.StreamField.x:
                return streamApply(&p.pointee.x, utf8: bytes)
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
              case Self.StreamField.x:
                return streamApply(&p.pointee.x, bytes: bytes, info: info)
              default:
                return .unsupported
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.x:
                return streamApply(&p.pointee.x, boolean: value)
              default:
                return .unsupported
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.x:
                return StreamParsing.streamApplyNull(&p.pointee.x)
              default:
                return .unsupported
              }
            }

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "x", index: Self.StreamField.x,
                  route: _streamFieldRoute(&p.pointee.x, schema: Self.streamContainerSchema_x),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.x, in: p)
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
              fields: Self.streamFields
            )
          }

          init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          /// Fails when the stream did not produce a member this type has no way to do without.
          init?(streamPartial partial: Partial) {
            guard
              let x = Self._streamValue({ $0.x
              }, partial.x)
            else {
              return nil
            }
            self.x = x
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          init(orInitial partial: Partial) {
            self.x = Self._streamValueOrInitial({
                $0.x
              }, partial.x)
          }

          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
          }
        }
        """
      }
    }

    @Test
    func `Existing Non Struct Partial`() {
      assertMacro {
        """
        @StreamParseable
        struct Person {
          var name: String

          enum Partial {}
        }
        """
      } expansion: {
        """
        struct Person {
          var name: String

          enum Partial {}

          var streamPartialValue: Partial {
            Partial(
              name: self.name.streamPartialValue
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
              }, partial.name)
            else {
              return nil
            }
            self.name = name
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          init(orInitial partial: Partial) {
            self.name = Self._streamValueOrInitial({
                $0.name
              }, partial.name)
          }

          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
          }
        }
        """
      }
    }

    @Test
    func `Enum With A Non Static Stream Initial Value`() {
      assertMacro {
        """
        @StreamParseable
        enum Stage: String {
          case live

          func streamInitialValue(of x: Int) {}
        }
        """
      } diagnostics: {
        """
        @StreamParseable
        enum Stage: String {
             ┬────
             ╰─ 🛑 @StreamParseable requires an enum to name a fallback case, because 'streamValueOrInitial' has to produce one when the stream produced nothing this type can represent. Mark a case with @StreamParseableDefault, or declare 'StreamInitializable' conformance on 'Stage' itself.
          case live

          func streamInitialValue(of x: Int) {}
        }
        """
      }
    }

    @Test
    func `Unreadable Partial Members Argument`() {
      assertMacro {
        """
        let mode = PartialMembersMode.optional

        @StreamParseable(partialMembers: mode)
        struct Person {
          var name: String
        }
        """
      } diagnostics: {
        """
        let mode = PartialMembersMode.optional

        @StreamParseable(partialMembers: mode)
                                         ┬───
                                         ╰─ 🛑 @StreamParseable(partialMembers:) requires .optional or .streamInitialValue.
        struct Person {
          var name: String
        }
        """
      }
    }

    @Test
    func `Indirect Enum Is Diagnosed`() {
      assertMacro {
        """
        @StreamParseable
        indirect enum E {
          @StreamParseableDefault
          case leaf
          case node(E)
        }
        """
      } diagnostics: {
        """
        @StreamParseable
        indirect enum E {
                      ┬
                      ╰─ 🛑 @StreamParseable does not support indirect enums, because a recursive case's payload would nest 'Partial' inside itself.
          @StreamParseableDefault
          case leaf
          case node(E)
        }
        """
      }
    }

    @Test
    func `Initial Capacity Reaches The Field Table`() {
      assertMacro {
        """
        @StreamParseable
        struct Feed {
          @StreamParseableMember(initialCapacity: 16)
          var items: [Int]
        }
        """
      } expansion: {
        """
        struct Feed {
          var items: [Int]

          var streamPartialValue: Partial {
            Partial(
              items: self.items.streamPartialValue
            )
          }
        }

        extension Feed: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject, Sendable {
            typealias Partial = Self

            var items: [Int].Partial?

            init(
              items: [Int].Partial? = nil
            ) {
              self.items = items
            }

            // Cached rather than re-evaluated: `Self()` walks every default expression fresh, which
            // for a large nested struct is a long chain of small copies. Every member's own `Partial`
            // is `Sendable` (every leaf and every "Fast" container conforms), which is what makes
            // `Self` itself `Sendable` here and lets the template be a plain `static let`.
            private static let _streamInitialValueTemplate: Self = Self()

            static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
            }

            struct View: ~Copyable, ~Escapable {
              let _streamStorage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
              }

            var items: [Int].Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.items) else {
                    return nil
                  }
                  return _overrideLifetime([Int].Partial.streamView(address), borrowing: self)
                }
              }
            }

            @_lifetime(borrow storage)
            static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let items: Int32 = 0
            }

            private static let streamContainerSchema_items = _streamArraySchema(Int.Partial.self, element: _streamSchema(for: Int.Partial.self))

            static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_0073_6D65_7469 where key.count == 5:
                return Self.StreamField.items
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
              default:
                return .unsupported
              }
            }

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "items", index: Self.StreamField.items,
                  route: _streamFieldRoute(&p.pointee.items, schema: Self.streamContainerSchema_items, initialCapacity: 16),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.items, in: p)
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
              }, partial.items)
            else {
              return nil
            }
            self.items = items
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          init(orInitial partial: Partial) {
            self.items = Self._streamValueOrInitial({
                $0.items
              }, partial.items)
          }

          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
          }
        }
        """
      }
    }

    @Test
    func `Excludes A Valid Ignored Property`() {
      assertMacro {
        """
        @StreamParseable
        struct Person {
          var name: String
          @StreamParseableIgnored
          var note: String?
        }
        """
      } expansion: {
        """
        struct Person {
          var name: String
          var note: String?

          var streamPartialValue: Partial {
            Partial(
              name: self.name.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject, Sendable {
            typealias Partial = Self

            var name: String.Partial?

            init(
              name: String.Partial? = nil
            ) {
              self.name = name
            }

            // Cached rather than re-evaluated: `Self()` walks every default expression fresh, which
            // for a large nested struct is a long chain of small copies. Every member's own `Partial`
            // is `Sendable` (every leaf and every "Fast" container conforms), which is what makes
            // `Self` itself `Sendable` here and lets the template be a plain `static let`.
            private static let _streamInitialValueTemplate: Self = Self()

            static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
            }

            struct View: ~Copyable, ~Escapable {
              let _streamStorage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
              }

            var name: String.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.name) else {
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
              static let name: Int32 = 0
            }

            private static let streamContainerSchema_name = _streamContainerSchema(for: (String.Partial).self)

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
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.name:
                return streamApply(&p.pointee.name, utf8: bytes)
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
              default:
                return .unsupported
              }
            }

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "name", index: Self.StreamField.name,
                  route: _streamFieldRoute(&p.pointee.name, schema: Self.streamContainerSchema_name),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.name, in: p)
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
              }, partial.name)
            else {
              return nil
            }
            self.name = name
            self.note = nil
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          init(orInitial partial: Partial) {
            self.name = Self._streamValueOrInitial({
                $0.name
              }, partial.name)
            self.note = nil
          }

          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
          }
        }
        """
      }
    }

  }
}

