import MacroTesting
import Testing

extension BaseTestSuite {
  @Suite struct CompletedValueConversionMacroTests {
    @Test func generatesConversionStorageAndBothDirections() {
      assertStreamParsingMacro {
        """
        @StreamParseable
        public struct Event {
          @StreamParseableMember(keyNames: ["time", "created"], completedConversion: Seconds.self)
          public var createdAt: Date = Date(timeIntervalSince1970: 0)
        }
        """
      } expansion: {
        #"""
        public struct Event {
          public var createdAt: Date = Date(timeIntervalSince1970: 0)

          @inlinable public var streamPartialValue: Partial {
            Partial(
              createdAt: StreamParsingCore.ConvertedPartial<Seconds>(value: self.createdAt)
            )
          }
        }

        extension Event: StreamParsingCore.StreamParseable {
          public struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject, Sendable {
            public typealias Partial = Self

            public var createdAt: StreamParsingCore.ConvertedPartial<Seconds>?

            public init(
              createdAt: StreamParsingCore.ConvertedPartial<Seconds>? = nil
            ) {
              self.createdAt = createdAt
            }

            @usableFromInline static let _streamInitialValueTemplate: Self = Self()

            @inlinable public static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
            }

            #if !hasFeature(Embedded)
            public static var streamObservationFields: [PartialKeyPath<Self>] {
              [\.createdAt]
            }
            #endif

            @frozen public struct View: ~Copyable, ~Escapable {
              public let _streamStorage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              @inlinable public init(_ storage: UnsafeMutableRawPointer) {
                self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
              }

              @inlinable public var createdAt: StreamParsingCore.ConvertedPartial<Seconds>.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.createdAt) else {
                    return nil
                  }
                  return _overrideLifetime(StreamParsingCore.ConvertedPartial<Seconds>.streamView(address), borrowing: self)
                }
              }
            }

            @_lifetime(borrow storage)
            @inlinable public static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
              View(storage)
            }

            @usableFromInline enum StreamField {
              @inlinable static var createdAt: Int32 {
                0
              }
            }

            @inlinable public static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0000_0000_656D_6974 where key.count == 4:
                return Self.StreamField.createdAt
              case 0x0064_6574_6165_7263 where key.count == 7:
                return Self.StreamField.createdAt
              default:
                return -1
              }
            }

            @inlinable public static func streamApplyString(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>
            ) -> StreamParsingCore.StreamApplyResult {
              switch field {

              default:
                return .unsupported
              }
            }

            @inlinable public static func streamApplyNumber(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>, _ info: StreamParsingCore.NumberInfo
            ) -> StreamParsingCore.StreamApplyResult {
              switch field {

              default:
                return .unsupported
              }
            }

            @inlinable public static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> StreamParsingCore.StreamApplyResult {
              switch field {

              default:
                return .unsupported
              }
            }

            @inlinable public static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.createdAt:
                return StreamParsingCore._streamDelegatedApplyNull(&p.pointee.createdAt)
              default:
                return .unsupported
              }
            }

            public static let streamSchema: StreamParsingCore.StreamSchema = {
              let streamFields = StreamParsingCore._streamFields(of: Self.self, prototype: Self()) { p in
                [
                  StreamParsingCore.StreamField(
                    key: "time", index: Self.StreamField.createdAt,
                    route: StreamParsingCore._streamDelegatedFieldRoute(&p.pointee.createdAt),
                    offset: StreamParsingCore._streamFieldOffset(&p.pointee.createdAt, in: p)
                  ),
                  StreamParsingCore.StreamField(
                    key: "created", index: Self.StreamField.createdAt,
                    route: StreamParsingCore._streamDelegatedFieldRoute(&p.pointee.createdAt),
                    offset: StreamParsingCore._streamFieldOffset(&p.pointee.createdAt, in: p)
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
            }()

          }

          @inlinable public init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          public init?(streamPartial partial: Partial) {
            guard
              let createdAt = _streamConvertedValue(partial.createdAt)
            else {
              return nil
            }
            self.createdAt = createdAt
          }

          public init(orInitial partial: Partial) {
            self.createdAt = _streamConvertedValue(partial.createdAt) ?? (Date(timeIntervalSince1970: 0))
          }

          @inlinable public static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
          }
        }
        """#
      }
    }

    @Test func requiresDefaultForNonoptionalConvertedMembers() {
      assertStreamParsingMacro {
        """
        @StreamParseable
        struct Event {
          @StreamParseableMember(completedConversion: Seconds.self)
          var createdAt: Date
        }
        """
      } diagnostics: {
        """
        @StreamParseable
        struct Event {
          @StreamParseableMember(completedConversion: Seconds.self)
          ╰─ 🛑 A nonoptional converted member requires an explicit default for init(orInitial:).
          var createdAt: Date
        }
        """
      }
    }

    @Test func rejectsDuplicateStrategies() {
      assertStreamParsingMacro {
        """
        @StreamParseable
        struct Event {
          @StreamParseableMember(completedConversion: First.self)
          @StreamParseableMember(completedConversion: Second.self)
          var value: Int = 0
        }
        """
      } diagnostics: {
        """
        @StreamParseable
        struct Event {
          @StreamParseableMember(completedConversion: First.self)
          @StreamParseableMember(completedConversion: Second.self)
          ┬───────────────────────────────────────────────────────
          ╰─ 🛑 completedConversion: can only be specified once per property.
          var value: Int = 0
        }
        """
      }
    }

    @Test func rejectsCapacityHintOnConvertedMember() {
      assertStreamParsingMacro {
        """
        @StreamParseable
        struct Event {
          @StreamParseableMember(initialCapacity: 32)
          @StreamParseableMember(completedConversion: Text.self)
          var value: String = ""
        }
        """
      } diagnostics: {
        """
        @StreamParseable
        struct Event {
          @StreamParseableMember(initialCapacity: 32)
          ╰─ 🛑 initialCapacity: is not supported with completedConversion:.
          @StreamParseableMember(completedConversion: Text.self)
          var value: String = ""
        }
        """
      }
    }

    @Test func requiresTypeLiteral() {
      assertStreamParsingMacro {
        """
        @StreamParseable
        struct Event {
          @StreamParseableMember(completedConversion: strategy)
          var value: Int = 0
        }
        """
      } diagnostics: {
        """
        @StreamParseable
        struct Event {
          @StreamParseableMember(completedConversion: strategy)
                                                      ┬───────
                                                      ╰─ 🛑 completedConversion: requires a strategy type followed by .self.
          var value: Int = 0
        }
        """
      }
    }
  }
}
