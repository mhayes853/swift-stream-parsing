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
                  key: "customKeyName2", index: Self.StreamField.name,
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
            StreamParsingCore.StreamParseableObject, Sendable {
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

            // Cached rather than re-evaluated: `Self()` walks every default expression fresh, which
            // for a large nested struct is a long chain of small copies. Every member's own `Partial`
            // is `Sendable` (every leaf and every "Fast" container conforms), which is what makes
            // `Self` itself `Sendable` here and lets the template be a plain `static let`.
            private static let _streamInitialValueTemplate: Self = Self()

            static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
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
            StreamParsingCore.StreamParseableObject, Sendable {
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

            // Cached rather than re-evaluated: `Self()` walks every default expression fresh, which
            // for a large nested struct is a long chain of small copies. Every member's own `Partial`
            // is `Sendable` (every leaf and every "Fast" container conforms), which is what makes
            // `Self` itself `Sendable` here and lets the template be a plain `static let`.
            private static let _streamInitialValueTemplate: Self = Self()

            static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
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
            StreamParsingCore.StreamParseableObject, Sendable {
            typealias Partial = Self

            var age: Int.Partial?

            init(
              age: Int.Partial? = nil
            ) {
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

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
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
          case square
        }
        """
      } expansion: {
        """
        enum Figure {
          @StreamParseableDefault
          case circle
          case square

          var streamPartialValue: Partial {
            switch self {
            case .circle:
              return Partial(circle: StreamParsingCore.StreamEmptyObject())
            case .square:
              return Partial(square: StreamParsingCore.StreamEmptyObject())
            }
          }
        }

        extension Figure: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject, Sendable {
            typealias Partial = Self

            var circle: StreamParsingCore.StreamEmptyObject.Partial?
            var square: StreamParsingCore.StreamEmptyObject.Partial?

            init(
              circle: StreamParsingCore.StreamEmptyObject.Partial? = nil,
              square: StreamParsingCore.StreamEmptyObject.Partial? = nil
            ) {
              self.circle = circle
              self.square = square
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
              let storage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self.storage = storage.assumingMemoryBound(to: Partial.self)
              }

            var circle: StreamParsingCore.StreamEmptyObject.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.circle) else {
                    return nil
                  }
                  return _overrideLifetime(StreamParsingCore.StreamEmptyObject.Partial.streamView(address), borrowing: self)
                }
              }

            var square: StreamParsingCore.StreamEmptyObject.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self.storage.pointee.square) else {
                    return nil
                  }
                  return _overrideLifetime(StreamParsingCore.StreamEmptyObject.Partial.streamView(address), borrowing: self)
                }
              }
            }

            @_lifetime(borrow storage)
            static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let circle: Int32 = 0
              static let square: Int32 = 1
            }

            private static let streamContainerSchema_circle = _streamContainerSchema(for: (StreamParsingCore.StreamEmptyObject.Partial).self)
            private static let streamContainerSchema_square = _streamContainerSchema(for: (StreamParsingCore.StreamEmptyObject.Partial).self)

            static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_656C_6372_6963 where key.count == 6:
                return Self.StreamField.circle
              case 0x0000_6572_6175_7173 where key.count == 6:
                return Self.StreamField.square
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
              case Self.StreamField.square:
                return streamApply(&p.pointee.square, utf8: bytes)
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
              case Self.StreamField.square:
                return streamApply(&p.pointee.square, bytes: bytes, info: info)
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
              case Self.StreamField.square:
                return streamApply(&p.pointee.square, boolean: value)
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
              case Self.StreamField.square:
                return StreamParsing.streamApplyNull(&p.pointee.square)
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
                StreamParsingCore.StreamField(
                  key: "square", index: Self.StreamField.square,
                  route: _streamFieldRoute(&p.pointee.square, schema: Self.streamContainerSchema_square),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.square, in: p)
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
          /// the same document.
          init?(streamPartial partial: Partial) {
            var streamMatched: Self?
            var streamMatches = 0
            if partial.circle != nil {
              streamMatched = .circle
              streamMatches += 1
            }
            if partial.square != nil {
              streamMatched = .square
              streamMatches += 1
            }
            guard streamMatches == 1, let streamMatched else {
              return nil
            }
            self = streamMatched
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
                   ├─ 🛑 @StreamParseable does not support 'Character' as a raw value type. Supported raw types are String and the standard integer and floating point types; an enum with no raw type parses Codable's case-name-keyed object form.
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
        enum Person {
          case name(String)
          case age(Int)
        }
        """
      } diagnostics: {
        """
        @StreamParseable
        enum Person {
             ┬─────
             ╰─ 🛑 @StreamParseable requires an enum to name a fallback case, because 'streamValueOrInitial' has to produce one when the stream produced nothing this type can represent. Mark a case with @StreamParseableDefault, or declare 'StreamInitializable' conformance on 'Person' itself.
          case name(String)
               ┬───────────
               ├─ 🛑 @StreamParseable does not support enum cases with associated values. Case 'name' declares one.
               ╰─ 🛑 @StreamParseable does not support enum cases with associated values. Case 'name' declares one.
          case age(Int)
               ┬───────
               ├─ 🛑 @StreamParseable does not support enum cases with associated values. Case 'age' declares one.
               ╰─ 🛑 @StreamParseable does not support enum cases with associated values. Case 'age' declares one.
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
        ├─ 🛑 @StreamParseable can only be applied to struct or enum declarations.
        ╰─ 🛑 @StreamParseable can only be applied to struct or enum declarations.
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
        ├─ 🛑 @StreamParseable can only be applied to struct or enum declarations.
        ╰─ 🛑 @StreamParseable can only be applied to struct or enum declarations.
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
            StreamParsingCore.StreamParseableObject, Sendable {
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

            // Cached rather than re-evaluated: `Self()` walks every default expression fresh, which
            // for a large nested struct is a long chain of small copies. Every member's own `Partial`
            // is `Sendable` (every leaf and every "Fast" container conforms), which is what makes
            // `Self` itself `Sendable` here and lets the template be a plain `static let`.
            private static let _streamInitialValueTemplate: Self = Self()

            public static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
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

            public static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
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
            StreamParsingCore.StreamParseableObject, Sendable {
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

            // Cached rather than re-evaluated: `Self()` walks every default expression fresh, which
            // for a large nested struct is a long chain of small copies. Every member's own `Partial`
            // is `Sendable` (every leaf and every "Fast" container conforms), which is what makes
            // `Self` itself `Sendable` here and lets the template be a plain `static let`.
            private static let _streamInitialValueTemplate: Self = Self()

            fileprivate static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
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

            fileprivate static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
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
            StreamParsingCore.StreamParseableObject, Sendable {
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

            // Cached rather than re-evaluated: `Self()` walks every default expression fresh, which
            // for a large nested struct is a long chain of small copies. Every member's own `Partial`
            // is `Sendable` (every leaf and every "Fast" container conforms), which is what makes
            // `Self` itself `Sendable` here and lets the template be a plain `static let`.
            private static let _streamInitialValueTemplate: Self = Self()

            public static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
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

            public static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
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
            StreamParsingCore.StreamParseableObject, Sendable {
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

            // Cached rather than re-evaluated: `Self()` walks every default expression fresh, which
            // for a large nested struct is a long chain of small copies. Every member's own `Partial`
            // is `Sendable` (every leaf and every "Fast" container conforms), which is what makes
            // `Self` itself `Sendable` here and lets the template be a plain `static let`.
            private static let _streamInitialValueTemplate: Self = Self()

            public static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
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

            public static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
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

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "blob", index: Self.StreamField.name,
                  route: _streamFieldRoute(&p.pointee.name, schema: Self.streamContainerSchema_name),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.name, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "name2", index: Self.StreamField.name,
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

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "blob", index: Self.StreamField.name,
                  route: _streamFieldRoute(&p.pointee.name, schema: Self.streamContainerSchema_name),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.name, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "name2", index: Self.StreamField.name,
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

            static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "blob", index: Self.StreamField.name,
                  route: _streamFieldRoute(&p.pointee.name, schema: Self.streamContainerSchema_name),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.name, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "name2", index: Self.StreamField.name,
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

  }
}
