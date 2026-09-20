#if Foundation && canImport(Foundation)
  import Foundation

  // MARK: - Data

  // Appends the bytes it is handed; a `String` rebuilt per write made long base64 quadratic.
  extension Data: StreamStringConvertible, StreamParseableRoot {
    public static func streamInitialValue() -> Self { Data() }

    @discardableResult
    public mutating func streamAppend(utf8 bytes: Span<UInt8>) -> StreamApplyResult {
      bytes.withUnsafeBufferPointer { self.append($0) }
      return .applied
    }
  }

  // MARK: - Decimal

  // Built from the accumulated magnitude and decimal exponent, which is what `Decimal` stores, so a
  // token inside its range converts exactly rather than through `Double`.
  extension Decimal: StreamNumberConvertible, StreamInitializable, StreamParseableRoot {
    public static func streamInitialValue() -> Self { Decimal() }

    public init?(streamParsing bytes: Span<UInt8>, info: NumberInfo) {
      // `Decimal`'s exponent is effectively `Int8`; out of range yields NaN rather than failing.
      guard !info.flags.contains(.overflowed),
        info.exponent >= -128, info.exponent <= 127
      else {
        guard let fallback = streamParseDecimalFallback(bytes) else { return nil }
        self = fallback
        return
      }

      self = Decimal(
        sign: info.flags.contains(.negative) ? .minus : .plus,
        exponent: Int(info.exponent),
        significand: Decimal(info.magnitude)
      )
    }
  }

  // Reached only by tokens too wide for the accumulator, so the String is not on a hot path.
  private func streamParseDecimalFallback(_ bytes: Span<UInt8>) -> Decimal? {
    // Numeric tokens are ASCII, so a scalar-wise build is exact.
    var text = ""
    text.reserveCapacity(bytes.count)
    for index in 0..<bytes.count {
      text.unicodeScalars.append(Unicode.Scalar(bytes[index]))
    }
    return Decimal(string: text)
  }

  // MARK: - PersonNameComponents

  // The one object-shaped support type, with a hand-written schema; `Foundation conversion tests`
  // check its key words, since four of nine were wrong when written by hand. It is one bridged
  // handle on Darwin, so properties are computed and each string write is a get/modify/set through
  // the bridge; `phoneticRepresentation` is entered with the frame on the parent, like `Tagged`.
  extension PersonNameComponents: StreamInitializable, StreamParseableObject {
    public static func streamInitialValue() -> Self { Self() }

    fileprivate enum StreamField {
      static let familyName: Int32 = 0
      static let givenName: Int32 = 1
      static let middleName: Int32 = 2
      static let namePrefix: Int32 = 3
      static let nameSuffix: Int32 = 4
      static let nickname: Int32 = 5
      static let phoneticRepresentation: Int32 = 6
    }

    public static var streamSchema: StreamSchema {
      StreamSchema(
        shape: .object,
        matchField: streamMatchPersonNameField,
        applyString: { storage, field, bytes in
          let p = storage.assumingMemoryBound(to: PersonNameComponents.self)
          switch field {
          case Self.StreamField.familyName: streamAppendPersonName(&p.pointee.familyName, bytes)
          case Self.StreamField.givenName: streamAppendPersonName(&p.pointee.givenName, bytes)
          case Self.StreamField.middleName: streamAppendPersonName(&p.pointee.middleName, bytes)
          case Self.StreamField.namePrefix: streamAppendPersonName(&p.pointee.namePrefix, bytes)
          case Self.StreamField.nameSuffix: streamAppendPersonName(&p.pointee.nameSuffix, bytes)
          case Self.StreamField.nickname: streamAppendPersonName(&p.pointee.nickname, bytes)
          default: return .unsupported
          }
          return .applied
        },
        applyNull: { storage, field in
          let p = storage.assumingMemoryBound(to: PersonNameComponents.self)
          switch field {
          case Self.StreamField.familyName: p.pointee.familyName = nil
          case Self.StreamField.givenName: p.pointee.givenName = nil
          case Self.StreamField.middleName: p.pointee.middleName = nil
          case Self.StreamField.namePrefix: p.pointee.namePrefix = nil
          case Self.StreamField.nameSuffix: p.pointee.nameSuffix = nil
          case Self.StreamField.nickname: p.pointee.nickname = nil
          case Self.StreamField.phoneticRepresentation: p.pointee.phoneticRepresentation = nil
          default: return .unsupported
          }
          return .applied
        },
        enterField: { storage, field in
          guard field == Self.StreamField.phoneticRepresentation else { return nil }
          let p = storage.assumingMemoryBound(to: PersonNameComponents.self)
          if p.pointee.phoneticRepresentation == nil {
            p.pointee.phoneticRepresentation = PersonNameComponents()
          }
          return StreamFrame(storage: storage, schema: personNamePhoneticSchema)
        }
      )
    }
  }

  // Reached through the parent's storage: each write reads the field out, changes one name and puts
  // it back. Built once, since it captures nothing.
  private let personNamePhoneticSchema = StreamSchema(
    shape: .object,
    // Foundation ignores a phonetic representation's own, so the key falls through as unknown.
    matchField: { key in
      let field = streamMatchPersonNameField(key)
      return field == PersonNameComponents.StreamField.phoneticRepresentation ? -1 : field
    },
    applyString: { storage, field, bytes in
      streamModifyPhonetic(storage, field) { streamAppendPersonName(&$0, bytes) }
    },
    applyNull: { storage, field in
      streamModifyPhonetic(storage, field) { $0 = nil }
    }
  )

  // Top level functions rather than closures, so the schemas' members stay non-capturing.

  private func streamMatchPersonNameField(_ key: Span<UInt8>) -> Int32 {
    typealias StreamField = PersonNameComponents.StreamField
    // The trailing word conditions `StreamParseableMacro.keyMatchGuard` emits for keys past eight
    // bytes. Without them a same-length key sharing the leading word is misrouted, and
    // `phoneticRepresentation` (8 of 22 bytes checked) enters a nested frame.
    switch key.paddedLeadingWord() {
    case 0x614E_796C_696D_6166
    where key.count == 10 && key.paddedWord(at: 8) == 0x0000_0000_0000_656D:
      return StreamField.familyName
    case 0x6D61_4E6E_6576_6967
    where key.count == 9 && key.paddedWord(at: 8) == 0x0000_0000_0000_0065:
      return StreamField.givenName
    case 0x614E_656C_6464_696D
    where key.count == 10 && key.paddedWord(at: 8) == 0x0000_0000_0000_656D:
      return StreamField.middleName
    case 0x6665_7250_656D_616E
    where key.count == 10 && key.paddedWord(at: 8) == 0x0000_0000_0000_7869:
      return StreamField.namePrefix
    case 0x6666_7553_656D_616E
    where key.count == 10 && key.paddedWord(at: 8) == 0x0000_0000_0000_7869:
      return StreamField.nameSuffix
    case 0x656D_616E_6B63_696E where key.count == 8: return StreamField.nickname
    case 0x6369_7465_6E6F_6870
    where key.count == 22 && key.paddedWord(at: 8) == 0x6E65_7365_7270_6552
      && key.paddedWord(at: 16) == 0x0000_6E6F_6974_6174:
      return StreamField.phoneticRepresentation
    default: return -1
    }
  }

  private func streamAppendPersonName(_ value: inout String?, _ bytes: Span<UInt8>) {
    if value == nil { value = "" }
    value!.streamAppend(utf8: bytes)
  }

  private func streamModifyPhonetic(
    _ storage: UnsafeMutableRawPointer,
    _ field: Int32,
    _ body: (inout String?) -> Void
  ) -> StreamApplyResult {
    typealias StreamField = PersonNameComponents.StreamField
    let p = storage.assumingMemoryBound(to: PersonNameComponents.self)
    var phonetic = p.pointee.phoneticRepresentation ?? PersonNameComponents()
    switch field {
    case StreamField.familyName: body(&phonetic.familyName)
    case StreamField.givenName: body(&phonetic.givenName)
    case StreamField.middleName: body(&phonetic.middleName)
    case StreamField.namePrefix: body(&phonetic.namePrefix)
    case StreamField.nameSuffix: body(&phonetic.nameSuffix)
    case StreamField.nickname: body(&phonetic.nickname)
    default: return .unsupported
    }
    p.pointee.phoneticRepresentation = phonetic
    return .applied
  }

  // MARK: - Legacy handler registration

  extension Data: StreamParseable {
    public typealias Partial = Self
  }

  // MARK: - Decimal

  extension Decimal: StreamParseable {
    public typealias Partial = Self
  }

  extension PersonNameComponents: StreamParseable {
    public typealias Partial = Self
  }
#endif
