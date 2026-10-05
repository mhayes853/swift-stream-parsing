import MacroTesting
import Testing

extension BaseTestSuite {
  @Suite
  struct `Partial string storage macro tests` {
    @Test
    func `String Leaves Are Stored As String`() {
      assertStreamParsingMacro {
        """
        @StreamParseable(partialStrings: .string)
        struct Message {
          var role: String
          var tags: [String]?
          var grouped: [String: [String?]]
          var count: Int
          @StreamParseableMember(partialStrings: .streamString)
          var content: String
        }
        """
      } expansion: {
        #"""
        struct Message {
          var role: String
          var tags: [String]?
          var grouped: [String: [String?]]
          var count: Int
          var content: String

          var streamPartialValue: Partial {
            Partial(
              role: self.role,
              tags: self.tags.map {
                StreamParsingCore.StreamArray($0)
              },
              grouped: StreamParsingCore.StreamDictionary(self.grouped.mapValues {
                  StreamParsingCore.StreamArray($0)
                }),
              count: self.count.streamPartialValue,
              content: self.content.streamPartialValue
            )
          }
        }

        extension Message: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject, Sendable {
            typealias Partial = Self

            var role: String?
            var tags: StreamParsingCore.StreamArray<String>?
            var grouped: StreamParsingCore.StreamDictionary<StreamParsingCore.StreamArray<String?>>?
            var count: Int.Partial?
            var content: String.Partial?

            init(
              role: String? = nil,
              tags: StreamParsingCore.StreamArray<String>? = nil,
              grouped: StreamParsingCore.StreamDictionary<StreamParsingCore.StreamArray<String?>>? = nil,
              count: Int.Partial? = nil,
              content: String.Partial? = nil
            ) {
              self.role = role
              self.tags = tags
              self.grouped = grouped
              self.count = count
              self.content = content
            }

            private static let _streamInitialValueTemplate: Self = Self()

            static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
            }

            #if !hasFeature(Embedded)
            static var streamObservationFields: [PartialKeyPath<Self>] {
              [\.role, \.tags, \.grouped, \.count, \.content]
            }
            #endif

            struct View: ~Copyable, ~Escapable {
              let _streamStorage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
              }

              var role: String.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.role) else {
                    return nil
                  }
                  return _overrideLifetime(String.streamView(address), borrowing: self)
                }
              }

              var tags: StreamParsingCore.StreamArray<String>.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.tags) else {
                    return nil
                  }
                  return _overrideLifetime(StreamParsingCore.StreamArray<String>.streamView(address), borrowing: self)
                }
              }

              var grouped: StreamParsingCore.StreamDictionary<StreamParsingCore.StreamArray<String?>>.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.grouped) else {
                    return nil
                  }
                  return _overrideLifetime(StreamParsingCore.StreamDictionary<StreamParsingCore.StreamArray<String?>>.streamView(address), borrowing: self)
                }
              }

              var count: Int.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.count) else {
                    return nil
                  }
                  return _overrideLifetime(Int.Partial.streamView(address), borrowing: self)
                }
              }

              var content: String.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.content) else {
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
              static let role: Int32 = 0
              static let tags: Int32 = 1
              static let grouped: Int32 = 2
              static let count: Int32 = 3
              static let content: Int32 = 4
            }

            static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_0000_656C_6F72 where key.count == 4:
                return Self.StreamField.role
              case 0x0000_0000_7367_6174 where key.count == 4:
                return Self.StreamField.tags
              case 0x0064_6570_756F_7267 where key.count == 7:
                return Self.StreamField.grouped
              case 0x0000_0074_6E75_6F63 where key.count == 5:
                return Self.StreamField.count
              case 0x0074_6E65_746E_6F63 where key.count == 7:
                return Self.StreamField.content
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
              case Self.StreamField.role:
                return streamApply(&p.pointee.role, utf8: bytes)
              case Self.StreamField.count:
                return streamApply(&p.pointee.count, utf8: bytes)
              case Self.StreamField.content:
                return streamApply(&p.pointee.content, utf8: bytes)
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
              case Self.StreamField.role:
                return streamApply(&p.pointee.role, bytes: bytes, info: info)
              case Self.StreamField.count:
                return streamApply(&p.pointee.count, bytes: bytes, info: info)
              case Self.StreamField.content:
                return streamApply(&p.pointee.content, bytes: bytes, info: info)
              default:
                return .unsupported
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.role:
                return streamApply(&p.pointee.role, boolean: value)
              case Self.StreamField.count:
                return streamApply(&p.pointee.count, boolean: value)
              case Self.StreamField.content:
                return streamApply(&p.pointee.content, boolean: value)
              default:
                return .unsupported
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.role:
                return StreamParsing.streamApplyNull(&p.pointee.role)
              case Self.StreamField.tags:
                return StreamParsing.streamApplyNull(&p.pointee.tags)
              case Self.StreamField.grouped:
                return StreamParsing.streamApplyNull(&p.pointee.grouped)
              case Self.StreamField.count:
                return StreamParsing.streamApplyNull(&p.pointee.count)
              case Self.StreamField.content:
                return StreamParsing.streamApplyNull(&p.pointee.content)
              default:
                return .unsupported
              }
            }

            private static let streamSchemaEntry = StreamParsingCore.StreamSchemaCache.shared.entry(for: Self.self) {
              let streamObjectMemberSchema_role = _streamObjectMemberSchema(for: (String).self)
              let streamObjectMemberSchema_tags = _streamArraySchema(String.self, element: _streamSchema(for: String.self))
              let streamObjectMemberSchema_grouped = _streamDictionarySchema(StreamParsingCore.StreamArray<String?>.self, value: _streamOptionalArraySchema(String.self, element: _streamSchema(for: String.self)))
              let streamObjectMemberSchema_count = _streamObjectMemberSchema(for: (Int.Partial).self)
              let streamObjectMemberSchema_content = _streamObjectMemberSchema(for: (String.Partial).self)
              let streamFields = StreamParsingCore._streamFields(of: Self.self, prototype: Self()) { p in
                [
                  StreamParsingCore.StreamField(
                    key: "role", index: Self.StreamField.role,
                    route: _streamFieldRoute(&p.pointee.role, schema: streamObjectMemberSchema_role),
                    offset: StreamParsingCore._streamFieldOffset(&p.pointee.role, in: p)
                  ),
                  StreamParsingCore.StreamField(
                    key: "tags", index: Self.StreamField.tags,
                    route: _streamFieldRoute(&p.pointee.tags, schema: streamObjectMemberSchema_tags),
                    offset: StreamParsingCore._streamFieldOffset(&p.pointee.tags, in: p)
                  ),
                  StreamParsingCore.StreamField(
                    key: "grouped", index: Self.StreamField.grouped,
                    route: _streamFieldRoute(&p.pointee.grouped, schema: streamObjectMemberSchema_grouped),
                    offset: StreamParsingCore._streamFieldOffset(&p.pointee.grouped, in: p)
                  ),
                  StreamParsingCore.StreamField(
                    key: "count", index: Self.StreamField.count,
                    route: _streamFieldRoute(&p.pointee.count, schema: streamObjectMemberSchema_count),
                    offset: StreamParsingCore._streamFieldOffset(&p.pointee.count, in: p)
                  ),
                  StreamParsingCore.StreamField(
                    key: "content", index: Self.StreamField.content,
                    route: _streamFieldRoute(&p.pointee.content, schema: streamObjectMemberSchema_content),
                    offset: StreamParsingCore._streamFieldOffset(&p.pointee.content, in: p)
                  ),
                ]
              }
              return StreamParsingCore.StreamSchema(
                shape: .object,
                matchField: Self.streamMatchField,
                applyString: Self.streamApplyString,
                applyNumber: Self.streamApplyNumber,
                applyBoolean: Self.streamApplyBoolean,
                applyNull: Self.streamApplyNull,
                fields: streamFields
              )
            }

            static var streamSchema: StreamParsingCore.StreamSchema {
              Self.streamSchemaEntry.schema
            }

          }

          init?(streamPartial partial: Partial) {
            guard
              let streamValue_role = Self._streamStoredValue({ $0.role
              }, partial.role),
              let streamValue_tags = Self._streamStoredValue({ $0.tags
              }, partial.tags.map { Swift.Array($0)
              }),
              let streamValue_grouped = Self._streamStoredValue({ $0.grouped
              }, partial.grouped.map { Swift.Dictionary($0).mapValues { Swift.Array($0)
                }
              }),
              let streamValue_count = Self._streamValue({ $0.count
              }, partial.count),
              let streamValue_content = Self._streamValue({ $0.content
              }, partial.content)
            else {
              return nil
            }
            self.role = streamValue_role
            self.tags = streamValue_tags
            self.grouped = streamValue_grouped
            self.count = streamValue_count
            self.content = streamValue_content
          }

          init(orInitial partial: Partial) {
            self.role = Self._streamStoredValue({
                $0.role
              }, partial.role, orInitial: "")
            self.tags = Self._streamStoredValue({
                $0.tags
              }, partial.tags.map {
                Swift.Array($0)
              }, orInitial: nil)
            self.grouped = Self._streamStoredValue({
                $0.grouped
              }, partial.grouped.map {
                Swift.Dictionary($0).mapValues {
                  Swift.Array($0)
                }
              }, orInitial: [:])
            self.count = Self._streamValueOrInitial({
                $0.count
              }, partial.count)
            self.content = Self._streamValueOrInitial({
                $0.content
              }, partial.content)
          }
        }
        """#
      }
    }

    @Test
    func `Type Level Storage Requires A Case Name`() {
      assertStreamParsingMacro {
        """
        @StreamParseable(partialStrings: true)
        struct Message {
          var role: String
        }
        """
      } diagnostics: {
        """
        @StreamParseable(partialStrings: true)
                                         ┬───
                                         ╰─ 🛑 @StreamParseable(partialStrings:) requires .streamString or .string.
        struct Message {
          var role: String
        }
        """
      }
    }

    @Test
    func `Member Storage Without A String Leaf Warns`() {
      assertStreamParsingMacro {
        """
        typealias Name = String

        @StreamParseable
        struct Message {
          @StreamParseableMember(partialStrings: .string)
          var name: Name
        }
        """
      } diagnostics: {
        """
        typealias Name = String

        @StreamParseable
        struct Message {
          @StreamParseableMember(partialStrings: .string)
          ┬──────────────────────────────────────────────
          ╰─ ⚠️ partialStrings: has no effect, because 'Name' does not spell String. The macro reads the type as written and cannot see through an alias.
          var name: Name
        }
        """
      } expansion: {
        #"""
        typealias Name = String
        struct Message {
          var name: Name

          var streamPartialValue: Partial {
            Partial(
              name: self.name.streamPartialValue
            )
          }
        }

        extension Message: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject, Sendable {
            typealias Partial = Self

            var name: Name.Partial?

            init(
              name: Name.Partial? = nil
            ) {
              self.name = name
            }

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

              var name: Name.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.name) else {
                    return nil
                  }
                  return _overrideLifetime(Name.Partial.streamView(address), borrowing: self)
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

            private static let streamSchemaEntry = StreamParsingCore.StreamSchemaCache.shared.entry(for: Self.self) {
              let streamObjectMemberSchema_name = _streamObjectMemberSchema(for: (Name.Partial).self)
              let streamFields = StreamParsingCore._streamFields(of: Self.self, prototype: Self()) { p in
                [
                  StreamParsingCore.StreamField(
                    key: "name", index: Self.StreamField.name,
                    route: _streamFieldRoute(&p.pointee.name, schema: streamObjectMemberSchema_name),
                    offset: StreamParsingCore._streamFieldOffset(&p.pointee.name, in: p)
                  ),
                ]
              }
              return StreamParsingCore.StreamSchema(
                shape: .object,
                matchField: Self.streamMatchField,
                applyString: Self.streamApplyString,
                applyNumber: Self.streamApplyNumber,
                applyBoolean: Self.streamApplyBoolean,
                applyNull: Self.streamApplyNull,
                fields: streamFields
              )
            }

            static var streamSchema: StreamParsingCore.StreamSchema {
              Self.streamSchemaEntry.schema
            }

          }

          init?(streamPartial partial: Partial) {
            guard
              let streamValue_name = Self._streamValue({ $0.name
              }, partial.name)
            else {
              return nil
            }
            self.name = streamValue_name
          }

          init(orInitial partial: Partial) {
            self.name = Self._streamValueOrInitial({
                $0.name
              }, partial.name)
          }
        }
        """#
      }
    }

    @Test
    func `Member Storage Cannot Combine With A Completed Conversion`() {
      assertStreamParsingMacro {
        """
        @StreamParseable
        struct Event {
          @StreamParseableMember(completedConversion: Trimmed.self)
          @StreamParseableMember(partialStrings: .string)
          var name: String = ""
        }
        """
      } diagnostics: {
        """
        @StreamParseable
        struct Event {
          @StreamParseableMember(completedConversion: Trimmed.self)
          ╰─ 🛑 partialStrings: is not supported with completedConversion:.
          @StreamParseableMember(partialStrings: .string)
          var name: String = ""
        }
        """
      }
    }

    @Test
    func `Member Storage Can Only Be Specified Once`() {
      assertStreamParsingMacro {
        """
        @StreamParseable
        struct Message {
          @StreamParseableMember(key: "n", partialStrings: .string)
          @StreamParseableMember(partialStrings: .streamString)
          var name: String
        }
        """
      } diagnostics: {
        """
        @StreamParseable
        struct Message {
          @StreamParseableMember(key: "n", partialStrings: .string)
          @StreamParseableMember(partialStrings: .streamString)
          ┬────────────────────────────────────────────────────
          ╰─ 🛑 @StreamParseableMember(partialStrings:) can only be specified once per property.
          var name: String
        }
        """
      }
    }

    @Test
    func `Raw Value Enum Rejects String Storage`() {
      assertStreamParsingMacro {
        """
        @StreamParseable(partialStrings: .string)
        enum Stage: String, StreamInitializable {
          case live
        }
        """
      } diagnostics: {
        """
        @StreamParseable(partialStrings: .string)
                                         ┬──────
                                         ╰─ 🛑 @StreamParseable(partialStrings:) does not apply to an enum with a raw type. Only associated values are stored in a partial, and it has none.
        enum Stage: String, StreamInitializable {
          case live
        }
        """
      }
    }
  }
}
