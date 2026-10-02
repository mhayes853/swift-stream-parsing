import MacroTesting
import Testing

extension BaseTestSuite {
  @Suite
  struct `Key decoding strategy tests` {
    @Test
    func `Built-In Strategy Converts Keys During Expansion`() {
      assertStreamParsingMacro {
        """
        @StreamParseable(keyDecodingStrategy: .convertFromSnakeCase)
        struct Tweet {
          var userID: Int
          @StreamParseableMember(key: "full_text")
          var text: String
        }
        """
      } expansion: {
        #"""
        struct Tweet {
          var userID: Int
          var text: String

          var streamPartialValue: Partial {
            Partial(
              userID: self.userID.streamPartialValue,
              text: self.text.streamPartialValue
            )
          }
        }

        extension Tweet: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject, Sendable {
            typealias Partial = Self

            var userID: Int.Partial?
            var text: String.Partial?

            init(
              userID: Int.Partial? = nil,
              text: String.Partial? = nil
            ) {
              self.userID = userID
              self.text = text
            }

            private static let _streamInitialValueTemplate: Self = Self()

            static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
            }

            #if !hasFeature(Embedded)
            static var streamObservationFields: [PartialKeyPath<Self>] {
              [\.userID, \.text]
            }
            #endif

            struct View: ~Copyable, ~Escapable {
              let _streamStorage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
              }

              var userID: Int.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.userID) else {
                    return nil
                  }
                  return _overrideLifetime(Int.Partial.streamView(address), borrowing: self)
                }
              }

              var text: String.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.text) else {
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
              static let userID: Int32 = 0
              static let text: Int32 = 1
            }

            static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x0064_695F_7265_7375 where key.count == 7:
                return Self.StreamField.userID
              case 0x7865_745F_6C6C_7566 where key.count == 9 && key.paddedWord(at: 8) == 0x0000_0000_0000_0074:
                return Self.StreamField.text
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
              case Self.StreamField.userID:
                return streamApply(&p.pointee.userID, utf8: bytes)
              case Self.StreamField.text:
                return streamApply(&p.pointee.text, utf8: bytes)
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
              case Self.StreamField.userID:
                return streamApply(&p.pointee.userID, bytes: bytes, info: info)
              case Self.StreamField.text:
                return streamApply(&p.pointee.text, bytes: bytes, info: info)
              default:
                return .unsupported
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.userID:
                return streamApply(&p.pointee.userID, boolean: value)
              case Self.StreamField.text:
                return streamApply(&p.pointee.text, boolean: value)
              default:
                return .unsupported
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.userID:
                return StreamParsing.streamApplyNull(&p.pointee.userID)
              case Self.StreamField.text:
                return StreamParsing.streamApplyNull(&p.pointee.text)
              default:
                return .unsupported
              }
            }

            private static let streamSchemaEntry = StreamParsingCore.StreamSchemaCache.shared.entry(for: Self.self) {
              let streamObjectMemberSchema_userID = _streamObjectMemberSchema(for: (Int.Partial).self)
              let streamObjectMemberSchema_text = _streamObjectMemberSchema(for: (String.Partial).self)
              let streamFields = StreamParsingCore._streamFields(of: Self.self, prototype: Self()) { p in
                [
                  StreamParsingCore.StreamField(
                    key: "user_id", index: Self.StreamField.userID,
                    route: _streamFieldRoute(&p.pointee.userID, schema: streamObjectMemberSchema_userID),
                    offset: StreamParsingCore._streamFieldOffset(&p.pointee.userID, in: p)
                  ),
                  StreamParsingCore.StreamField(
                    key: "full_text", index: Self.StreamField.text,
                    route: _streamFieldRoute(&p.pointee.text, schema: streamObjectMemberSchema_text),
                    offset: StreamParsingCore._streamFieldOffset(&p.pointee.text, in: p)
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

          init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          init?(streamPartial partial: Partial) {
            guard
              let streamValue_userID = Self._streamValue({ $0.userID
              }, partial.userID),
              let streamValue_text = Self._streamValue({ $0.text
              }, partial.text)
            else {
              return nil
            }
            self.userID = streamValue_userID
            self.text = streamValue_text
          }

          init(orInitial partial: Partial) {
            self.userID = Self._streamValueOrInitial({
                $0.userID
              }, partial.userID)
            self.text = Self._streamValueOrInitial({
                $0.text
              }, partial.text)
          }

          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
          }
        }
        """#
      }
    }

    @Test
    func `Custom Strategy Converts Keys When The Schema Is Built`() {
      assertStreamParsingMacro {
        """
        @StreamParseable(keyDecodingStrategy: .custom { "x_" + $0 })
        struct Request {
          var requestID: String
          @StreamParseableMember(key: "id")
          var identifier: Int
        }
        """
      } expansion: {
        #"""
        struct Request {
          var requestID: String
          var identifier: Int

          var streamPartialValue: Partial {
            Partial(
              requestID: self.requestID.streamPartialValue,
              identifier: self.identifier.streamPartialValue
            )
          }
        }

        extension Request: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject, Sendable {
            typealias Partial = Self

            var requestID: String.Partial?
            var identifier: Int.Partial?

            init(
              requestID: String.Partial? = nil,
              identifier: Int.Partial? = nil
            ) {
              self.requestID = requestID
              self.identifier = identifier
            }

            private static let _streamInitialValueTemplate: Self = Self()

            static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
            }

            #if !hasFeature(Embedded)
            static var streamObservationFields: [PartialKeyPath<Self>] {
              [\.requestID, \.identifier]
            }
            #endif

            struct View: ~Copyable, ~Escapable {
              let _streamStorage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
              }

              var requestID: String.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.requestID) else {
                    return nil
                  }
                  return _overrideLifetime(String.Partial.streamView(address), borrowing: self)
                }
              }

              var identifier: Int.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.identifier) else {
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
              static let requestID: Int32 = 0
              static let identifier: Int32 = 1
            }

            static func streamApplyString(
              _ storage: UnsafeMutableRawPointer, _ field: Int32,
              _ bytes: Span<UInt8>
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.requestID:
                return streamApply(&p.pointee.requestID, utf8: bytes)
              case Self.StreamField.identifier:
                return streamApply(&p.pointee.identifier, utf8: bytes)
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
              case Self.StreamField.requestID:
                return streamApply(&p.pointee.requestID, bytes: bytes, info: info)
              case Self.StreamField.identifier:
                return streamApply(&p.pointee.identifier, bytes: bytes, info: info)
              default:
                return .unsupported
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.requestID:
                return streamApply(&p.pointee.requestID, boolean: value)
              case Self.StreamField.identifier:
                return streamApply(&p.pointee.identifier, boolean: value)
              default:
                return .unsupported
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.requestID:
                return StreamParsing.streamApplyNull(&p.pointee.requestID)
              case Self.StreamField.identifier:
                return StreamParsing.streamApplyNull(&p.pointee.identifier)
              default:
                return .unsupported
              }
            }

            private static let streamSchemaEntry = StreamParsingCore.StreamSchemaCache.shared.entry(for: Self.self) {
              let streamObjectMemberSchema_requestID = _streamObjectMemberSchema(for: (String.Partial).self)
              let streamObjectMemberSchema_identifier = _streamObjectMemberSchema(for: (Int.Partial).self)
              let streamKeyDecodingStrategy = (.custom {
                  "x_" + $0
                } as StreamParsing.StreamKeyDecodingStrategy)
              let streamFields = StreamParsingCore._streamFields(of: Self.self, prototype: Self()) { p in
                [
                  StreamParsingCore.StreamField(
                    key: streamKeyDecodingStrategy.key(for: "requestID"), index: Self.StreamField.requestID,
                    route: _streamFieldRoute(&p.pointee.requestID, schema: streamObjectMemberSchema_requestID),
                    offset: StreamParsingCore._streamFieldOffset(&p.pointee.requestID, in: p)
                  ),
                  StreamParsingCore.StreamField(
                    key: "id", index: Self.StreamField.identifier,
                    route: _streamFieldRoute(&p.pointee.identifier, schema: streamObjectMemberSchema_identifier),
                    offset: StreamParsingCore._streamFieldOffset(&p.pointee.identifier, in: p)
                  ),
                ]
              }
              return StreamParsingCore.StreamSchema(
                shape: .object,
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

          init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          init?(streamPartial partial: Partial) {
            guard
              let streamValue_requestID = Self._streamValue({ $0.requestID
              }, partial.requestID),
              let streamValue_identifier = Self._streamValue({ $0.identifier
              }, partial.identifier)
            else {
              return nil
            }
            self.requestID = streamValue_requestID
            self.identifier = streamValue_identifier
          }

          init(orInitial partial: Partial) {
            self.requestID = Self._streamValueOrInitial({
                $0.requestID
              }, partial.requestID)
            self.identifier = Self._streamValueOrInitial({
                $0.identifier
              }, partial.identifier)
          }

          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
          }
        }
        """#
      }
    }

    @Test
    func `Built-In Strategy Converts Enum Case Names And Labels`() {
      assertStreamParsingMacro {
        """
        @StreamParseable(keyDecodingStrategy: .convertFromSnakeCase)
        enum Activity {
          @StreamParseableDefault
          case unknownActivity
          case userJoined(userName: String, Int)
        }
        """
      } expansion: {
        #"""
        enum Activity {
          @StreamParseableDefault
          case unknownActivity
          case userJoined(userName: String, Int)

          var streamPartialValue: Partial {
            switch self {
            case .unknownActivity:
              return Partial(unknownActivity: StreamParsingCore.StreamEmptyObject())
            case .userJoined(let userName, let _1):
              return Partial(userJoined: UserJoinedPayload.Partial(userName: userName.streamPartialValue, _1: _1.streamPartialValue))
            }
          }
        }

        extension Activity: StreamParsingCore.StreamParseable {
          struct Partial: StreamParsingCore.StreamParseable,
            StreamParsingCore.StreamParseableObject, Sendable {
            typealias Partial = Self

            var unknownActivity: StreamParsingCore.StreamEmptyObject.Partial?
            var userJoined: UserJoinedPayload.Partial?

            init(
              unknownActivity: StreamParsingCore.StreamEmptyObject.Partial? = nil,
              userJoined: UserJoinedPayload.Partial? = nil
            ) {
              self.unknownActivity = unknownActivity
              self.userJoined = userJoined
            }

            private static let _streamInitialValueTemplate: Self = Self()

            static func streamInitialValue() -> Self {
              Self._streamInitialValueTemplate
            }

            #if !hasFeature(Embedded)
            static var streamObservationFields: [PartialKeyPath<Self>] {
              [\.unknownActivity, \.userJoined]
            }
            #endif

            struct View: ~Copyable, ~Escapable {
              let _streamStorage: UnsafeMutablePointer<Partial>

              @_lifetime(borrow storage)
              init(_ storage: UnsafeMutableRawPointer) {
                self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
              }

              var unknownActivity: StreamParsingCore.StreamEmptyObject.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.unknownActivity) else {
                    return nil
                  }
                  return _overrideLifetime(StreamParsingCore.StreamEmptyObject.Partial.streamView(address), borrowing: self)
                }
              }

              var userJoined: UserJoinedPayload.Partial.View? {
                @_lifetime(borrow self)
                get {
                  guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.userJoined) else {
                    return nil
                  }
                  return _overrideLifetime(UserJoinedPayload.Partial.streamView(address), borrowing: self)
                }
              }

              enum ResolvedView: ~Copyable, ~Escapable {
                case unresolved
                case ambiguous
                case unknownActivity
                case userJoined(UserJoinedPayload.Partial.View)
              }

              var resolved: ResolvedView {
                @_lifetime(borrow self)
                get {
                  var streamMatched = -1
                  var streamMatches = 0
                  if self._streamStorage.pointee.unknownActivity != nil {
                    streamMatched = 0
                    streamMatches += 1
                  }
                  if self._streamStorage.pointee.userJoined != nil {
                    streamMatched = 1
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
                    return .unknownActivity
                  case 1:
                    guard let streamAddress = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.userJoined) else {
                      return .unresolved
                    }
                    return _overrideLifetime(.userJoined(UserJoinedPayload.Partial.streamView(streamAddress)), borrowing: self)
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
              static let unknownActivity: Int32 = 0
              static let userJoined: Int32 = 1
            }

            static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
              switch key.paddedLeadingWord() {
              case 0x5F6E_776F_6E6B_6E75 where key.count == 16 && key.paddedWord(at: 8) == 0x7974_6976_6974_6361:
                return Self.StreamField.unknownActivity
              case 0x696F_6A5F_7265_7375 where key.count == 11 && key.paddedWord(at: 8) == 0x0000_0000_0064_656E:
                return Self.StreamField.userJoined
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
              case Self.StreamField.unknownActivity:
                return streamApply(&p.pointee.unknownActivity, utf8: bytes)
              case Self.StreamField.userJoined:
                return streamApply(&p.pointee.userJoined, utf8: bytes)
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
              case Self.StreamField.unknownActivity:
                return streamApply(&p.pointee.unknownActivity, bytes: bytes, info: info)
              case Self.StreamField.userJoined:
                return streamApply(&p.pointee.userJoined, bytes: bytes, info: info)
              default:
                return .unsupported
              }
            }

            static func streamApplyBoolean(
              _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.unknownActivity:
                return streamApply(&p.pointee.unknownActivity, boolean: value)
              case Self.StreamField.userJoined:
                return streamApply(&p.pointee.userJoined, boolean: value)
              default:
                return .unsupported
              }
            }

            static func streamApplyNull(
              _ storage: UnsafeMutableRawPointer, _ field: Int32
            ) -> StreamParsingCore.StreamApplyResult {
              let p = storage.assumingMemoryBound(to: Self.self)
              switch field {
              case Self.StreamField.unknownActivity:
                return StreamParsing.streamApplyNull(&p.pointee.unknownActivity)
              case Self.StreamField.userJoined:
                return StreamParsing.streamApplyNull(&p.pointee.userJoined)
              default:
                return .unsupported
              }
            }

            private static let streamSchemaEntry = StreamParsingCore.StreamSchemaCache.shared.entry(for: Self.self) {
              let streamObjectMemberSchema_unknownActivity = _streamObjectMemberSchema(for: (StreamParsingCore.StreamEmptyObject.Partial).self)
              let streamObjectMemberSchema_userJoined = _streamObjectMemberSchema(for: (UserJoinedPayload.Partial).self)
              let streamFields = StreamParsingCore._streamFields(of: Self.self, prototype: Self()) { p in
                [
                  StreamParsingCore.StreamField(
                    key: "unknown_activity", index: Self.StreamField.unknownActivity,
                    route: _streamFieldRoute(&p.pointee.unknownActivity, schema: streamObjectMemberSchema_unknownActivity),
                    offset: StreamParsingCore._streamFieldOffset(&p.pointee.unknownActivity, in: p)
                  ),
                  StreamParsingCore.StreamField(
                    key: "user_joined", index: Self.StreamField.userJoined,
                    route: _streamFieldRoute(&p.pointee.userJoined, schema: streamObjectMemberSchema_userJoined),
                    offset: StreamParsingCore._streamFieldOffset(&p.pointee.userJoined, in: p)
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

          enum UserJoinedPayload {
            struct Partial: StreamParsingCore.StreamParseable,
              StreamParsingCore.StreamParseableObject, Sendable {
              typealias Partial = Self

              var userName: String.Partial?
              var _1: Int.Partial?

              init(
                userName: String.Partial? = nil,
                _1: Int.Partial? = nil
              ) {
                self.userName = userName
                self._1 = _1
              }

              private static let _streamInitialValueTemplate: Self = Self()

              static func streamInitialValue() -> Self {
                Self._streamInitialValueTemplate
              }

              #if !hasFeature(Embedded)
              static var streamObservationFields: [PartialKeyPath<Self>] {
                [\.userName, \._1]
              }
              #endif

              struct View: ~Copyable, ~Escapable {
                let _streamStorage: UnsafeMutablePointer<Partial>

                @_lifetime(borrow storage)
                init(_ storage: UnsafeMutableRawPointer) {
                  self._streamStorage = storage.assumingMemoryBound(to: Partial.self)
                }

                var userName: String.Partial.View? {
                  @_lifetime(borrow self)
                  get {
                    guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee.userName) else {
                      return nil
                    }
                    return _overrideLifetime(String.Partial.streamView(address), borrowing: self)
                  }
                }

                var _1: Int.Partial.View? {
                  @_lifetime(borrow self)
                  get {
                    guard let address = StreamParsingCore._streamMemberAddress(&self._streamStorage.pointee._1) else {
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
                static let userName: Int32 = 0
                static let _1: Int32 = 1
              }

              static func streamMatchField(_ key: Span<UInt8>) -> Int32 {
                switch key.paddedLeadingWord() {
                case 0x6D61_6E5F_7265_7375 where key.count == 9 && key.paddedWord(at: 8) == 0x0000_0000_0000_0065:
                  return Self.StreamField.userName
                case 0x0000_0000_0000_315F where key.count == 2:
                  return Self.StreamField._1
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
                case Self.StreamField.userName:
                  return streamApply(&p.pointee.userName, utf8: bytes)
                case Self.StreamField._1:
                  return streamApply(&p.pointee._1, utf8: bytes)
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
                case Self.StreamField.userName:
                  return streamApply(&p.pointee.userName, bytes: bytes, info: info)
                case Self.StreamField._1:
                  return streamApply(&p.pointee._1, bytes: bytes, info: info)
                default:
                  return .unsupported
                }
              }

              static func streamApplyBoolean(
                _ storage: UnsafeMutableRawPointer, _ field: Int32, _ value: Bool
              ) -> StreamParsingCore.StreamApplyResult {
                let p = storage.assumingMemoryBound(to: Self.self)
                switch field {
                case Self.StreamField.userName:
                  return streamApply(&p.pointee.userName, boolean: value)
                case Self.StreamField._1:
                  return streamApply(&p.pointee._1, boolean: value)
                default:
                  return .unsupported
                }
              }

              static func streamApplyNull(
                _ storage: UnsafeMutableRawPointer, _ field: Int32
              ) -> StreamParsingCore.StreamApplyResult {
                let p = storage.assumingMemoryBound(to: Self.self)
                switch field {
                case Self.StreamField.userName:
                  return StreamParsing.streamApplyNull(&p.pointee.userName)
                case Self.StreamField._1:
                  return StreamParsing.streamApplyNull(&p.pointee._1)
                default:
                  return .unsupported
                }
              }

              private static let streamSchemaEntry = StreamParsingCore.StreamSchemaCache.shared.entry(for: Self.self) {
                let streamObjectMemberSchema_userName = _streamObjectMemberSchema(for: (String.Partial).self)
                let streamObjectMemberSchema__1 = _streamObjectMemberSchema(for: (Int.Partial).self)
                let streamFields = StreamParsingCore._streamFields(of: Self.self, prototype: Self()) { p in
                  [
                    StreamParsingCore.StreamField(
                      key: "user_name", index: Self.StreamField.userName,
                      route: _streamFieldRoute(&p.pointee.userName, schema: streamObjectMemberSchema_userName),
                      offset: StreamParsingCore._streamFieldOffset(&p.pointee.userName, in: p)
                    ),
                    StreamParsingCore.StreamField(
                      key: "_1", index: Self.StreamField._1,
                      route: _streamFieldRoute(&p.pointee._1, schema: streamObjectMemberSchema__1),
                      offset: StreamParsingCore._streamFieldOffset(&p.pointee._1, in: p)
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

            struct Value: StreamParsingCore.StreamParseable {
              var userName: String
              var _1: Int

              typealias Partial = UserJoinedPayload.Partial

              var streamPartialValue: Partial {
                Partial(
                  userName: self.userName.streamPartialValue,
                  _1: self._1.streamPartialValue
                )
              }

              init?(_ partial: Partial) {
                self.init(streamPartial: partial)
              }

              init?(streamPartial partial: Partial) {
                guard
                  let streamValue_userName = Self._streamValue({ $0.userName
                  }, partial.userName),
                  let streamValue__1 = Self._streamValue({ $0._1
                  }, partial._1)
                else {
                  return nil
                }
                self.userName = streamValue_userName
                self._1 = streamValue__1
              }

              init(orInitial partial: Partial) {
                self.userName = Self._streamValueOrInitial({
                    $0.userName
                  }, partial.userName)
                self._1 = Self._streamValueOrInitial({
                    $0._1
                  }, partial._1)
              }

              static func streamValueOrInitial(from partial: Partial) -> Self {
                Self(orInitial: partial)
              }
            }
          }

          init?(_ partial: Partial) {
            self.init(streamPartial: partial)
          }

          init?(streamPartial partial: Partial) {
            var streamMatched = -1
            var streamMatches = 0
            if partial.unknownActivity != nil {
              streamMatched = 0
              streamMatches += 1
            }
            if partial.userJoined != nil {
              streamMatched = 1
              streamMatches += 1
            }
            guard streamMatches == 1 else {
              return nil
            }
            switch streamMatched {
            case 0:
              self = .unknownActivity
            case 1:
              guard let streamValue = UserJoinedPayload.Value(streamPartial: partial.userJoined!) else {
                return nil
              }
              self = .userJoined(userName: streamValue.userName, streamValue._1)
            default:
              return nil
            }
          }

          init(orInitial partial: Partial) {
            self = Self(streamPartial: partial) ?? .unknownActivity
          }

          static func streamValueOrInitial(from partial: Partial) -> Self {
            Self(orInitial: partial)
          }
        }
        """#
      }
    }

    @Test
    func `Converted Keys That Collide`() {
      assertStreamParsingMacro {
        """
        @StreamParseable(keyDecodingStrategy: .convertFromSnakeCase)
        struct Payload {
          var fooBar: Int
          var foo_bar: Int
          @StreamParseableMember(key: "user_id")
          var identifier: Int
          var userID: Int
        }
        """
      } diagnostics: {
        """
        @StreamParseable(keyDecodingStrategy: .convertFromSnakeCase)
        struct Payload {
          var fooBar: Int
          var foo_bar: Int
          ┬───────────────
          ╰─ 🛑 Key 'foo_bar' is already claimed by another property.
          @StreamParseableMember(key: "user_id")
          var identifier: Int
          var userID: Int
          ┬──────────────
          ╰─ 🛑 Key 'user_id' (converted from 'userID') is already claimed by another property.
        }
        """
      }
    }

    @Test
    func `Converted Enum Names And Labels That Collide`() {
      assertStreamParsingMacro {
        """
        @StreamParseable(keyDecodingStrategy: .convertFromSnakeCase)
        enum Activity {
          @StreamParseableDefault
          case userJoined
          case user_joined
          case moved(fromIndex: Int, from_index: Int)
        }
        """
      } diagnostics: {
        """
        @StreamParseable(keyDecodingStrategy: .convertFromSnakeCase)
        enum Activity {
          @StreamParseableDefault
          case userJoined
          case user_joined
               ┬──────────
               ╰─ 🛑 Name 'user_joined' is already claimed by another case.
          case moved(fromIndex: Int, from_index: Int)
               ┬─────────────────────────────────────
               ╰─ 🛑 Key 'from_index' is already claimed by another associated value.
        }
        """
      }
    }

    @Test
    func `Key Decoding Strategy On A Raw Value Enum`() {
      assertStreamParsingMacro {
        """
        @StreamParseable(keyDecodingStrategy: .convertFromSnakeCase)
        enum Stage: String {
          @StreamParseableDefault
          case inProgress
        }
        """
      } diagnostics: {
        """
        @StreamParseable(keyDecodingStrategy: .convertFromSnakeCase)
                                              ┬────────────────────
                                              ╰─ 🛑 @StreamParseable(keyDecodingStrategy:) does not apply to an enum with a raw type. Its cases are read from values, not keys; write the raw value the stream sends.
        enum Stage: String {
          @StreamParseableDefault
          case inProgress
        }
        """
      }
    }
  }
}
