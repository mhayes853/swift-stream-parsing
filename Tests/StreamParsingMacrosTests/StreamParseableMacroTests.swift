import MacroTesting
import Testing

extension BaseTestSuite {
  @Suite
  struct `StreamParseableMacro tests` {
    @Test
    func `Basic`() {
      assertStreamParsingMacro {
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

            #if !hasFeature(Embedded)
            static var streamObservationFields: [PartialKeyPath<Self>] {
              [\.name, \.age]
            }
            #endif

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
        """#
      }
    }

    @Test
    func `Custom Member Keys`() {
      assertStreamParsingMacro {
        """
        @StreamParseable
        struct Person {
          @StreamParseableMember(key: "customKeyName")
          @StreamParseableMember(key: "name2")
          var name: String
          @StreamParseableMember(keyNames: ["a", "b"])
          var nickname: String
        }
        """
      } expansion: {
        #"""
        struct Person {
          var name: String
          var nickname: String

          var streamPartialValue: Partial {
            Partial(
              name: self.name.streamPartialValue,
              nickname: self.nickname.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject, Sendable {
            typealias Partial = Self

            var name: String.Partial?
            var nickname: String.Partial?

            init(
              name: String.Partial? = nil,
              nickname: String.Partial? = nil
            ) {
              self.name = name
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

            #if !hasFeature(Embedded)
            static var streamObservationFields: [PartialKeyPath<Self>] {
              [\.name, \.nickname]
            }
            #endif

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
            }

            @_lifetime(borrow storage)
            static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            private enum StreamField {
              static let name: Int32 = 0
              static let nickname: Int32 = 1
            }

            private static let streamContainerSchema_name = _streamContainerSchema(for: (String.Partial).self)
            private static let streamContainerSchema_nickname = _streamContainerSchema(for: (String.Partial).self)

            static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x654B_6D6F_7473_7563 where key.count == 13 && key.paddedWord(at: 8) == 0x0000_0065_6D61_4E79:
                return Self.StreamField.name
              case 0x0000_0032_656D_616E where key.count == 5:
                return Self.StreamField.name
              case 0x0000_0000_0000_0061 where key.count == 1:
                return Self.StreamField.nickname
              case 0x0000_0000_0000_0062 where key.count == 1:
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
                  key: "customKeyName", index: Self.StreamField.name,
                  route: _streamFieldRoute(&p.pointee.name, schema: Self.streamContainerSchema_name),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.name, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "name2", index: Self.StreamField.name,
                  route: _streamFieldRoute(&p.pointee.name, schema: Self.streamContainerSchema_name),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.name, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "a", index: Self.StreamField.nickname,
                  route: _streamFieldRoute(&p.pointee.nickname, schema: Self.streamContainerSchema_nickname),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.nickname, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "b", index: Self.StreamField.nickname,
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
              let name = Self._streamValue({ $0.name
              }, partial.name),
              let nickname = Self._streamValue({ $0.nickname
              }, partial.nickname)
            else {
              return nil
            }
            self.name = name
            self.nickname = nickname
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
          }

          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
          }
        }
        """#
      }
    }

    @Test
    func `StreamParseableMember Applied To Static Property`() {
      assertStreamParsingMacro {
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
      assertStreamParsingMacro {
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
      assertStreamParsingMacro {
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
      assertStreamParsingMacro {
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
      assertStreamParsingMacro {
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
      assertStreamParsingMacro {
        """
        @StreamParseable(partialMembers: .streamInitialValue)
        struct Person {
          var name: String
          var age: Int?
        }
        """
      } expansion: {
        #"""
        struct Person {
          var name: String
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

            var name: String.Partial
            var age: Int.Partial?

            init(
              name: String.Partial = .streamInitialValue(),
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

            #if !hasFeature(Embedded)
            static var streamObservationFields: [PartialKeyPath<Self>] {
              [\.name, \.age]
            }
            #endif

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
        """#
      }
      assertStreamParsingMacro {
        """
        @StreamParseable
        struct Person {
          var nickname: Optional<String>
        }
        """
      } expansion: {
        #"""
        struct Person {
          var nickname: Optional<String>

          var streamPartialValue: Partial {
            Partial(
              nickname: self.nickname.streamPartialValue
            )
          }
        }

        extension Person: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject, Sendable {
            typealias Partial = Self

            var nickname: String.Partial?

            init(
              nickname: String.Partial? = nil
            ) {
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

            #if !hasFeature(Embedded)
            static var streamObservationFields: [PartialKeyPath<Self>] {
              [\.nickname]
            }
            #endif

            struct View: ~Copyable, ~Escapable {
              let _streamStorage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
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
              static let nickname: Int32 = 0
            }

            private static let streamContainerSchema_nickname = _streamContainerSchema(for: (String.Partial).self)

            static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
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
              let nickname = Self._streamValue({ $0.nickname
              }, partial.nickname)
            else {
              return nil
            }
            self.nickname = nickname
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          init(orInitial partial: Partial) {
            self.nickname = Self._streamValueOrInitial({
                $0.nickname
              }, partial.nickname)
          }

          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
          }
        }
        """#
      }
    }

    @Test
    func `Excludes Static, Computed, And Method Members`() {
      assertStreamParsingMacro {
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
        #"""
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

            #if !hasFeature(Embedded)
            static var streamObservationFields: [PartialKeyPath<Self>] {
              [\.stored]
            }
            #endif

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
        """#
      }
    }

    @Test
    func `Non Optional Ignored Property Without A Default`() {
      assertStreamParsingMacro {
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
      assertStreamParsingMacro {
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
      assertStreamParsingMacro {
        """
        @StreamParseable
        enum Broadcast: Swift.String {
          @StreamParseableDefault
          case live
          case livestream
          case `default`
        }
        """
      } expansion: {
        """
        enum Broadcast: Swift.String {
          @StreamParseableDefault
          case live
          case livestream
          case `default`

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
            case 0x0074_6C75_6166_6564 where streamCount == 7:
              self = .`default`
              return
            default:
              break
            }
            if partial.isPrefix(of: "live") {
              self = .live
              return
            }
            if partial.isPrefix(of: "default") {
              self = .`default`
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
      assertStreamParsingMacro {
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
      assertStreamParsingMacro {
        """
        @StreamParseable
        enum Figure {
          @StreamParseableDefault
          case circle
        }
        """
      } expansion: {
        #"""
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

            #if !hasFeature(Embedded)
            static var streamObservationFields: [PartialKeyPath<Self>] {
              [\.circle]
            }
            #endif

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
        """#
      }
    }

    @Test
    func `Enum Without A Fallback Case`() {
      assertStreamParsingMacro {
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
      assertStreamParsingMacro {
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
      assertStreamParsingMacro {
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
      assertStreamParsingMacro {
        """
        @StreamParseable
        enum Note {
          case `default`(String)
          @StreamParseableDefault
          case `class`
        }
        """
      } expansion: {
        #"""
        enum Note {
          case `default`(String)
          @StreamParseableDefault
          case `class`

          var streamPartialValue: Partial {
            switch self {
            case .`default`(let _0):
              return Partial(`default`: DefaultPayload.Partial(_0: _0.streamPartialValue))
            case .`class`:
              return Partial(`class`: StreamParsingCore.StreamEmptyObject())
            }
          }
        }

        extension Note: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject, Sendable {
            typealias Partial = Self

            var `default`: DefaultPayload.Partial?
            var `class`: StreamParsingCore.StreamEmptyObject.Partial?

            init(
              `default`: DefaultPayload.Partial? = nil,
              `class`: StreamParsingCore.StreamEmptyObject.Partial? = nil
            ) {
              self.`default` = `default`
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

            #if !hasFeature(Embedded)
            static var streamObservationFields: [PartialKeyPath<Self>] {
              [\.`default`, \.`class`]
            }
            #endif

            struct View: ~Copyable, ~Escapable {
              let _streamStorage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
              }

            var `default`: DefaultPayload.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.`default`) else {
                    return nil
                  }
                  return _overrideLifetime(DefaultPayload.Partial.streamView(address), borrowing: self)
                }
              }

            var `class`: StreamParsingCore.StreamEmptyObject.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.`class`) else {
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
              case `default`(DefaultPayload.Partial.View)
              case `class`
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
              if self._streamStorage.pointee.`class` != nil {
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
                guard let streamAddress = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.`default`)
                else {
                  return .unresolved
                }
                return _overrideLifetime(
                  .`default`(DefaultPayload.Partial.streamView(streamAddress)),
                  borrowing: self
                )
              case 1:
                return .`class`
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
              static let `class`: Int32 = 1
            }

            private static let streamContainerSchema_default = _streamContainerSchema(for: (DefaultPayload.Partial).self)
            private static let streamContainerSchema_class = _streamContainerSchema(for: (StreamParsingCore.StreamEmptyObject.Partial).self)

            static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0074_6C75_6166_6564 where key.count == 7:
                return Self.StreamField.`default`
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
              case Self.StreamField.`default`:
                return streamApply(&p.pointee.`default`, utf8: bytes)
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
              case Self.StreamField.`default`:
                return streamApply(&p.pointee.`default`, bytes: bytes, info: info)
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
              case Self.StreamField.`default`:
                return streamApply(&p.pointee.`default`, boolean: value)
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
              case Self.StreamField.`default`:
                return StreamParsing.streamApplyNull(&p.pointee.`default`)
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
                  key: "default", index: Self.StreamField.`default`,
                  route: _streamFieldRoute(&p.pointee.`default`, schema: Self.streamContainerSchema_default),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.`default`, in: p)
                ),
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

          enum DefaultPayload {
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

                #if !hasFeature(Embedded)
                static var streamObservationFields: [PartialKeyPath<Self>] {
                  [\._0]
                }
                #endif

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

                typealias Partial = DefaultPayload.Partial

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
            if partial.`default` != nil {
              streamMatched = 0
              streamMatches += 1
            }
            if partial.`class` != nil {
              streamMatched = 1
              streamMatches += 1
            }
            guard streamMatches == 1 else {
              return nil
            }
            switch streamMatched {
            case 0:
              guard let streamValue = DefaultPayload.Value(streamPartial: partial.`default`!)
              else {
                return nil
              }
              self = .`default`(streamValue._0)
            case 1:
              self = .`class`
            default:
              return nil
            }
          }

          /// Falls back to the case marked `@StreamParseableDefault` when the stream did not
          /// produce a value this type can represent.
          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(streamPartial: partial) ?? .`class`
          }
        }
        """#
      }
    }

    @Test
    func `Applied To Class Or Actor`() {
      assertStreamParsingMacro {
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
      assertStreamParsingMacro {
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
      assertStreamParsingMacro {
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
      assertStreamParsingMacro {
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
        #"""
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

            #if !hasFeature(Embedded)
            static var streamObservationFields: [PartialKeyPath<Self>] {
              [\.name]
            }
            #endif

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
        """#
      }
    }

    @Test
    func `Access Modifier`() {
      assertStreamParsingMacro {
        """
        @StreamParseable
        public struct Person {
          public var name: String
        }
        """
      } expansion: {
        #"""
        public struct Person {
          public var name: String

          @inlinable public var streamPartialValue: Partial {
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
            @usableFromInline static let _streamInitialValueTemplate: Self = Self()

            @inlinable public static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
            }

            #if !hasFeature(Embedded)
            public static var streamObservationFields: [PartialKeyPath<Self>] {
              [\.name]
            }
            #endif

            @frozen public struct View: ~Copyable, ~Escapable {
              public let _streamStorage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              @inlinable public init(_ storage: UnsafeMutableRawPointer) {
                self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
              }

            @inlinable public var name: String.Partial.View? {
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
            @inlinable public static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            @usableFromInline enum StreamField {
              @inlinable static var name: Int32 {
                0
              }
            }

            private static let streamContainerSchema_name = _streamContainerSchema(for: (String.Partial).self)

            @inlinable public static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_0000_656D_616E where key.count == 4:
                return Self.StreamField.name
              default:
                return -1
              }
            }

            @inlinable public static func streamApplyString(
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

            @inlinable public static func streamApplyNumber(
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

            @inlinable public static func streamApplyBoolean(
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

            @inlinable public static func streamApplyNull(
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

          @inlinable public init?(_ partial: Partial) {
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

          @inlinable public static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
          }
        }
        """#
      }
      assertStreamParsingMacro {
        """
        @StreamParseable
        private struct Person {
          var name: String
        }
        """
      } expansion: {
        #"""
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

            #if !hasFeature(Embedded)
            static var streamObservationFields: [PartialKeyPath<Self>] {
              [\.name]
            }
            #endif

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
        """#
      }
      assertStreamParsingMacro {
        """
        @StreamParseable
        fileprivate struct Person {
          var name: String
        }
        """
      } expansion: {
        #"""
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

            #if !hasFeature(Embedded)
            fileprivate static var streamObservationFields: [PartialKeyPath<Self>] {
              [\.name]
            }
            #endif

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
        """#
      }
    }

    // One internal member is enough to keep `streamPartialValue`, the only member that reads the
    // type's own properties, out of line. Everything on `Partial` stays inlinable.
    @Test
    func `Public Type With An Internal Member`() {
      assertStreamParsingMacro {
        """
        @StreamParseable
        public struct Person {
          public var name: String
          var age: Int
        }
        """
      } expansion: {
        #"""
        public struct Person {
          public var name: String
          var age: Int

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
            @usableFromInline static let _streamInitialValueTemplate: Self = Self()

            @inlinable public static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
            }

            #if !hasFeature(Embedded)
            public static var streamObservationFields: [PartialKeyPath<Self>] {
              [\.name, \.age]
            }
            #endif

            @frozen public struct View: ~Copyable, ~Escapable {
              public let _streamStorage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              @inlinable public init(_ storage: UnsafeMutableRawPointer) {
                self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
              }

            @inlinable public var name: String.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.name) else {
                    return nil
                  }
                  return _overrideLifetime(String.Partial.streamView(address), borrowing: self)
                }
              }

            @inlinable public var age: Int.Partial.View? {
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
            @inlinable public static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            @usableFromInline enum StreamField {
              @inlinable static var name: Int32 {
                0
              }
              @inlinable static var age: Int32 {
                1
              }
            }

            private static let streamContainerSchema_name = _streamContainerSchema(for: (String.Partial).self)
            private static let streamContainerSchema_age = _streamContainerSchema(for: (Int.Partial).self)

            @inlinable public static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_0000_656D_616E where key.count == 4:
                return Self.StreamField.name
              case 0x0000_0000_0065_6761 where key.count == 3:
                return Self.StreamField.age
              default:
                return -1
              }
            }

            @inlinable public static func streamApplyString(
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

            @inlinable public static func streamApplyNumber(
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

            @inlinable public static func streamApplyBoolean(
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

            @inlinable public static func streamApplyNull(
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

          @inlinable public init?(_ partial: Partial) {
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

          @inlinable public static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
          }
        }
        """#
      }
    }

    // `@usableFromInline` and a narrower setter do not block it: only the getter is read.
    @Test
    func `Public Type With Usable From Inline And Private Set Members`() {
      assertStreamParsingMacro {
        """
        @StreamParseable
        public struct Person {
          @usableFromInline var name: String
          public private(set) var age: Int
        }
        """
      } expansion: {
        #"""
        public struct Person {
          @usableFromInline var name: String
          public private(set) var age: Int

          @inlinable public var streamPartialValue: Partial {
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
            @usableFromInline static let _streamInitialValueTemplate: Self = Self()

            @inlinable public static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
            }

            #if !hasFeature(Embedded)
            public static var streamObservationFields: [PartialKeyPath<Self>] {
              [\.name, \.age]
            }
            #endif

            @frozen public struct View: ~Copyable, ~Escapable {
              public let _streamStorage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              @inlinable public init(_ storage: UnsafeMutableRawPointer) {
                self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
              }

            @inlinable public var name: String.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.name) else {
                    return nil
                  }
                  return _overrideLifetime(String.Partial.streamView(address), borrowing: self)
                }
              }

            @inlinable public var age: Int.Partial.View? {
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
            @inlinable public static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            @usableFromInline enum StreamField {
              @inlinable static var name: Int32 {
                0
              }
              @inlinable static var age: Int32 {
                1
              }
            }

            private static let streamContainerSchema_name = _streamContainerSchema(for: (String.Partial).self)
            private static let streamContainerSchema_age = _streamContainerSchema(for: (Int.Partial).self)

            @inlinable public static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_0000_656D_616E where key.count == 4:
                return Self.StreamField.name
              case 0x0000_0000_0065_6761 where key.count == 3:
                return Self.StreamField.age
              default:
                return -1
              }
            }

            @inlinable public static func streamApplyString(
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

            @inlinable public static func streamApplyNumber(
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

            @inlinable public static func streamApplyBoolean(
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

            @inlinable public static func streamApplyNull(
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

          @inlinable public init?(_ partial: Partial) {
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

          @inlinable public static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
          }
        }
        """#
      }
    }

    @Test
    func `Public String Raw Value Enum Is Inlinable`() {
      assertStreamParsingMacro {
        """
        @StreamParseable
        public enum Stage: String {
          @StreamParseableDefault
          case idle
          case live
        }
        """
      } expansion: {
        """
        public enum Stage: String {
          @StreamParseableDefault
          case idle
          case live

          @inlinable public var streamPartialValue: Partial {
            self.rawValue.streamPartialValue
          }
        }

        extension Stage: StreamParsingCore.StreamParseable {
          public typealias Partial = StreamParsingCore.StreamString

          @inlinable public init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          /// Resolves the case the accumulated raw value names, or the shortest case that value is
          /// still a prefix of.
          ///
          /// A partial string cannot say whether it is finished, so a value that names one case and
          /// is a prefix of a longer one resolves to the shorter and may later be superseded.
          @inlinable public init?(streamPartial partial: Partial) {
            let streamCount = partial.utf8Count
            guard streamCount > 0 else {
              return nil
            }
            switch partial.paddedLeadingWord() {
            case 0x0000_0000_656C_6469 where streamCount == 4:
              self = .idle
              return
            case 0x0000_0000_6576_696C where streamCount == 4:
              self = .live
              return
            default:
              break
            }
            if partial.isPrefix(of: "idle") {
              self = .idle
              return
            }
            if partial.isPrefix(of: "live") {
              self = .live
              return
            }
            return nil
          }

          /// Falls back to the case marked `@StreamParseableDefault` when the stream did not
          /// produce a value this type can represent.
          @inlinable public static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(streamPartial: partial) ?? .idle
          }
        }
        """
      }
    }

    // `streamPartialValue` switches over the enum, which is an error in inlinable code under
    // library evolution, so it alone stays out of line.
    @Test
    func `Public Raw Less Enum Is Inlinable Except streamPartialValue`() {
      assertStreamParsingMacro {
        """
        @StreamParseable
        public enum Shape {
          @StreamParseableDefault
          case circle
          case square
        }
        """
      } expansion: {
        #"""
        public enum Shape {
          @StreamParseableDefault
          case circle
          case square

          public var streamPartialValue: Partial {
            switch self {
            case .circle:
              return Partial(circle: StreamParsingCore.StreamEmptyObject())
            case .square:
              return Partial(square: StreamParsingCore.StreamEmptyObject())
            }
          }
        }

        extension Shape: StreamParsingCore.StreamParseable {
          public struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject, Sendable {
            public typealias Partial = Self

            public var circle: StreamParsingCore.StreamEmptyObject.Partial?
            public var square: StreamParsingCore.StreamEmptyObject.Partial?

            public init(
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
            @usableFromInline static let _streamInitialValueTemplate: Self = Self()

            @inlinable public static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
            }

            #if !hasFeature(Embedded)
            public static var streamObservationFields: [PartialKeyPath<Self>] {
              [\.circle, \.square]
            }
            #endif

            @frozen public struct View: ~Copyable, ~Escapable {
              public let _streamStorage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              @inlinable public init(_ storage: UnsafeMutableRawPointer) {
                self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
              }

            @inlinable public var circle: StreamParsingCore.StreamEmptyObject.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.circle) else {
                    return nil
                  }
                  return _overrideLifetime(StreamParsingCore.StreamEmptyObject.Partial.streamView(address), borrowing: self)
                }
              }

            @inlinable public var square: StreamParsingCore.StreamEmptyObject.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.square) else {
                    return nil
                  }
                  return _overrideLifetime(StreamParsingCore.StreamEmptyObject.Partial.streamView(address), borrowing: self)
                }
              }

          /// One case's borrowed, mid-stream view — or `.unresolved`/`.ambiguous` when zero or more
          /// than one case's key has arrived yet.
          public enum ResolvedView: ~Copyable, ~Escapable {
            case unresolved
            case ambiguous
              case circle
              case square
            }

            @inlinable public var resolved: ResolvedView {
              @_lifetime(borrow self)
              get {
                var streamMatched = -1
                var streamMatches = 0
              if self._streamStorage.pointee.circle != nil {
                  streamMatched = 0;
                  streamMatches += 1
                }
              if self._streamStorage.pointee.square != nil {
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
                return .circle
              case 1:
                return .square
                default:
                  return .unresolved
                }
              }
            }
          }

            @_lifetime(borrow storage)
            @inlinable public static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            @usableFromInline enum StreamField {
              @inlinable static var circle: Int32 {
                0
              }
              @inlinable static var square: Int32 {
                1
              }
            }

            private static let streamContainerSchema_circle = _streamContainerSchema(for: (StreamParsingCore.StreamEmptyObject.Partial).self)
            private static let streamContainerSchema_square = _streamContainerSchema(for: (StreamParsingCore.StreamEmptyObject.Partial).self)

            @inlinable public static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_656C_6372_6963 where key.count == 6:
                return Self.StreamField.circle
              case 0x0000_6572_6175_7173 where key.count == 6:
                return Self.StreamField.square
              default:
                return -1
              }
            }

            @inlinable public static func streamApplyString(
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

            @inlinable public static func streamApplyNumber(
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

            @inlinable public static func streamApplyBoolean(
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

            @inlinable public static func streamApplyNull(
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

            public static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
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

          @inlinable public init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          /// Fails unless exactly one case's key arrived, matching what `JSONDecoder` accepts for
          /// the same document — and, for a case with associated values, unless that one case's own
          /// payload has everything it needs yet.
          @inlinable public init?(streamPartial partial: Partial) {
            var streamMatched = -1
            var streamMatches = 0
            if partial.circle != nil {
              streamMatched = 0
              streamMatches += 1
            }
            if partial.square != nil {
              streamMatched = 1
              streamMatches += 1
            }
            guard streamMatches == 1 else {
              return nil
            }
            switch streamMatched {
            case 0:
              self = .circle
            case 1:
              self = .square
            default:
              return nil
            }
          }

          /// Falls back to the case marked `@StreamParseableDefault` when the stream did not
          /// produce a value this type can represent.
          @inlinable public static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(streamPartial: partial) ?? .circle
          }
        }
        """#
      }
    }

    @Test
    func `Container Members Only`() {
      assertStreamParsingMacro {
        """
        @StreamParseable
        struct Feed {
          @StreamParseableMember(initialCapacity: 16)
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

            #if !hasFeature(Embedded)
            static var streamObservationFields: [PartialKeyPath<Self>] {
              [\.items, \.index]
            }
            #endif

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
                  route: _streamFieldRoute(&p.pointee.items, schema: Self.streamContainerSchema_items, initialCapacity: 16),
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
    func `Generic Type Is Diagnosed`() {
      assertStreamParsingMacro {
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
    func `Nested Package Struct With Awkward Members`() {
      assertStreamParsingMacro {
        """
        struct Outer {
          @StreamParseable
          package struct Inner {
            package var `class`, storage: Int
            package var x: Int??
            package let k: Int = 5
            @StreamParseableIgnored
            package var note: String?
          }
        }
        """
      } expansion: {
        #"""
        struct Outer {
          package struct Inner {
            package var `class`, storage: Int
            package var x: Int??
            package let k: Int = 5
            package var note: String?

            @inlinable package var streamPartialValue: Partial {
              Partial(
                `class`: self.`class`.streamPartialValue,
                storage: self.storage.streamPartialValue,
                x: self.x.streamPartialValue
              )
            }
          }
        }

        extension Outer.Inner: StreamParsingCore.StreamParseable {
          package struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject, Sendable {
            package typealias Partial = Self

            package var `class`: Int.Partial?
            package var storage: Int.Partial?
            package var x: Int.Partial?

            package init(
              `class`: Int.Partial? = nil,
              storage: Int.Partial? = nil,
              x: Int.Partial? = nil
            ) {
              self.`class` = `class`
              self.storage = storage
              self.x = x
            }

            // Cached rather than re-evaluated: `Self()` walks every default expression fresh, which
            // for a large nested struct is a long chain of small copies. Every member's own `Partial`
            // is `Sendable` (every leaf and every "Fast" container conforms), which is what makes
            // `Self` itself `Sendable` here and lets the template be a plain `static let`.
            @usableFromInline static let _streamInitialValueTemplate: Self = Self()

            @inlinable package static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
            }

            #if !hasFeature(Embedded)
            package static var streamObservationFields: [PartialKeyPath<Self>] {
              [\.`class`, \.storage, \.x]
            }
            #endif

            @frozen package struct View: ~Copyable, ~Escapable {
              package let _streamStorage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              @inlinable package init(_ storage: UnsafeMutableRawPointer) {
                self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
              }

            @inlinable package var `class`: Int.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.`class`) else {
                    return nil
                  }
                  return _overrideLifetime(Int.Partial.streamView(address), borrowing: self)
                }
              }

            @inlinable package var storage: Int.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.storage) else {
                    return nil
                  }
                  return _overrideLifetime(Int.Partial.streamView(address), borrowing: self)
                }
              }

            @inlinable package var x: Int.Partial.View? {
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
            @inlinable package static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            @usableFromInline enum StreamField {
              @inlinable static var `class`: Int32 {
                0
              }
              @inlinable static var storage: Int32 {
                1
              }
              @inlinable static var x: Int32 {
                2
              }
            }

            private static let streamContainerSchema_class = _streamContainerSchema(for: (Int.Partial).self)
            private static let streamContainerSchema_storage = _streamContainerSchema(for: (Int.Partial).self)
            private static let streamContainerSchema_x = _streamContainerSchema(for: (Int.Partial).self)

            @inlinable package static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_0073_7361_6C63 where key.count == 5:
                return Self.StreamField.`class`
              case 0x0065_6761_726F_7473 where key.count == 7:
                return Self.StreamField.storage
              case 0x0000_0000_0000_0078 where key.count == 1:
                return Self.StreamField.x
              default:
                return -1
              }
            }

            @inlinable package static func streamApplyString(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.`class`:
                return streamApply(&p.pointee.`class`, utf8: bytes)
              case Self.StreamField.storage:
                return streamApply(&p.pointee.storage, utf8: bytes)
              case Self.StreamField.x:
                return streamApply(&p.pointee.x, utf8: bytes)
              default:
                return .unsupported
              }
            }

            @inlinable package static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.`class`:
                return streamApply(&p.pointee.`class`, bytes: bytes, info: info)
              case Self.StreamField.storage:
                return streamApply(&p.pointee.storage, bytes: bytes, info: info)
              case Self.StreamField.x:
                return streamApply(&p.pointee.x, bytes: bytes, info: info)
              default:
                return .unsupported
              }
            }

            @inlinable package static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.`class`:
                return streamApply(&p.pointee.`class`, boolean: value)
              case Self.StreamField.storage:
                return streamApply(&p.pointee.storage, boolean: value)
              case Self.StreamField.x:
                return streamApply(&p.pointee.x, boolean: value)
              default:
                return .unsupported
              }
            }

            @inlinable package static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.`class`:
                return StreamParsing.streamApplyNull(&p.pointee.`class`)
              case Self.StreamField.storage:
                return StreamParsing.streamApplyNull(&p.pointee.storage)
              case Self.StreamField.x:
                return StreamParsing.streamApplyNull(&p.pointee.x)
              default:
                return .unsupported
              }
            }

            package static let streamFields: [StreamParsingCore.StreamField] = StreamParsingCore._streamFields(
              of: Self.self, prototype: Self()
            ) { p in
              [
                StreamParsingCore.StreamField(
                  key: "class", index: Self.StreamField.`class`,
                  route: _streamFieldRoute(&p.pointee.`class`, schema: Self.streamContainerSchema_class),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.`class`, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "storage", index: Self.StreamField.storage,
                  route: _streamFieldRoute(&p.pointee.storage, schema: Self.streamContainerSchema_storage),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.storage, in: p)
                ),
                StreamParsingCore.StreamField(
                  key: "x", index: Self.StreamField.x,
                  route: _streamFieldRoute(&p.pointee.x, schema: Self.streamContainerSchema_x),
                  offset: StreamParsingCore._streamFieldOffset(&p.pointee.x, in: p)
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

          @inlinable package init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          /// Fails when the stream did not produce a member this type has no way to do without.
          package init?(streamPartial partial: Partial) {
            guard
              let `class` = Self._streamValue({ $0.`class`
              }, partial.`class`),
              let storage = Self._streamValue({ $0.storage
              }, partial.storage),
              let x = Self._streamValue({ $0.x
              }, partial.x)
            else {
              return nil
            }
            self.`class` = `class`
            self.storage = storage
            self.x = x
            self.note = nil
          }

          /// Fills members the stream did not produce with their initial values, keeping the ones
          /// it did.
          package init(orInitial partial: Partial) {
            self.`class` = Self._streamValueOrInitial({
                $0.`class`
              }, partial.`class`)
            self.storage = Self._streamValueOrInitial({
                $0.storage
              }, partial.storage)
            self.x = Self._streamValueOrInitial({
                $0.x
              }, partial.x)
            self.note = nil
          }

          @inlinable package static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
          }
        }
        """#
      }
    }

    @Test
    func `Enum Case Named Like A ResolvedView Sentinel`() {
      assertStreamParsingMacro {
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
      assertStreamParsingMacro {
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
    func `Interpolated Key`() {
      assertStreamParsingMacro {
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
      assertStreamParsingMacro {
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
      assertStreamParsingMacro {
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
      assertStreamParsingMacro {
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
    func `Existing Partial And Stated Conformance`() {
      assertStreamParsingMacro {
        """
        @StreamParseable
        struct Person: StreamParseable {
          var name: String

          enum Partial {}
        }
        """
      } expansion: {
        """
        struct Person: StreamParseable {
          var name: String

          enum Partial {}

          var streamPartialValue: Partial {
            Partial(
              name: self.name.streamPartialValue
            )
          }
        }

        extension Person {
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
      assertStreamParsingMacro {
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
      assertStreamParsingMacro {
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
      assertStreamParsingMacro {
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
    func `Self Referential Payloads Are Diagnosed`() {
      assertStreamParsingMacro {
        """
        @StreamParseable
        enum Tree {
          @StreamParseableDefault
          case leaf
          case node([Tree])
          case pair(Tree?, Int)
          case named(children: [String: Tree], parent: Optional<Self>)
          case kind(Tree.Kind)
        }
        """
      } diagnostics: {
        """
        @StreamParseable
        enum Tree {
          @StreamParseableDefault
          case leaf
          case node([Tree])
                    ┬─────
                    ╰─ 🛑 Case 'node' has a payload that contains 'Tree' itself. @StreamParseable does not support recursive enums, because the generated 'Partial' would contain itself.
          case pair(Tree?, Int)
                    ┬────
                    ╰─ 🛑 Case 'pair' has a payload that contains 'Tree' itself. @StreamParseable does not support recursive enums, because the generated 'Partial' would contain itself.
          case named(children: [String: Tree], parent: Optional<Self>)
                                                       ┬─────────────
                               │                       ╰─ 🛑 Case 'named' has a payload that contains 'Tree' itself. @StreamParseable does not support recursive enums, because the generated 'Partial' would contain itself.
                               ┬─────────────
                               ╰─ 🛑 Case 'named' has a payload that contains 'Tree' itself. @StreamParseable does not support recursive enums, because the generated 'Partial' would contain itself.
          case kind(Tree.Kind)
        }
        """
      }
    }

    @Test
    func `Qualified Self Reference Is Diagnosed In A Nested Enum`() {
      assertStreamParsingMacro {
        """
        struct Outer {
          @StreamParseable
          enum Tree {
            @StreamParseableDefault
            case leaf
            case node(Outer.Tree)
          }
        }
        """
      } diagnostics: {
        """
        struct Outer {
          @StreamParseable
          enum Tree {
            @StreamParseableDefault
            case leaf
            case node(Outer.Tree)
                      ┬─────────
                      ╰─ 🛑 Case 'node' has a payload that contains 'Tree' itself. @StreamParseable does not support recursive enums, because the generated 'Partial' would contain itself.
          }
        }
        """
      }
    }

  }
}


