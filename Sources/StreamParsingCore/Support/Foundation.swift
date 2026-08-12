#if StreamParsingFoundation && canImport(Foundation)
  import Foundation

  // MARK: - Data

  // Appends the bytes it is handed. The registration based path rebuilt a String from the whole
  // accumulated value on every write and re-encoded it, which made a long base64 payload
  // quadratic.
  extension Data: StreamStringConvertible, StreamParseableRoot {
    public static func streamInitialValue() -> Self { Data() }

    public mutating func streamAppend(utf8 bytes: Span<UInt8>) {
      bytes.withUnsafeBufferPointer { self.append($0) }
    }

    public mutating func streamReserve(utf8ByteCount: Int) {
      self.reserveCapacity(utf8ByteCount)
    }
  }

  // MARK: - Decimal

  // Built from the accumulated magnitude and decimal exponent, which is what Decimal already
  // stores, so a token inside its range converts exactly. The registration based path went
  // through Double and a hand rolled mantissa loop, losing anything Double could not hold.
  extension Decimal: StreamNumberConvertible, StreamInitializable, StreamParseableRoot {
    public static func streamInitialValue() -> Self { Decimal() }

    public init?(streamParsing bytes: Span<UInt8>, info: NumberInfo) {
      // Decimal's exponent is an Int8 in practice; out of range yields NaN rather than failing,
      // so the bound is checked here instead.
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

  // The one support type that is an object rather than a scalar, so it carries the first hand
  // written schema. The key words are checked against the keys they encode in
  // `Foundation conversion tests`, because writing them by hand is exactly what produced four
  // wrong literals out of nine before the macro took the job over.
  //
  // `phoneticRepresentation` is matched but not entered. PersonNameComponents is eight bytes on
  // Darwin, a single handle to a bridged reference, so every one of its properties is computed.
  // Taking the address of one yields a stack temporary that dies when the inout scope ends, and
  // a frame pointing there dangles. Frames require stored properties, and this type has none, so
  // a nested object under that key is skipped rather than misrouted. A null still clears it.
  //
  // For the same reason each string write is a get, modify and set through the bridge rather
  // than an append. That is quadratic in the length of a name streamed byte by byte, which is
  // the tradeoff for a type that offers no storage to accumulate into.
  extension PersonNameComponents: StreamInitializable, StreamParseableObject {
    public static func streamInitialValue() -> Self { Self() }

    public static var streamSchema: StreamSchema {
      StreamSchema(
        shape: .object,
        matchField: { key in
          switch key.paddedLeadingWord() {
          case 0x614E_796C_696D_6166 where key.count == 10: return 0  // "familyName"
          case 0x6D61_4E6E_6576_6967 where key.count == 9: return 1  // "givenName"
          case 0x614E_656C_6464_696D where key.count == 10: return 2  // "middleName"
          case 0x6665_7250_656D_616E where key.count == 10: return 3  // "namePrefix"
          case 0x6666_7553_656D_616E where key.count == 10: return 4  // "nameSuffix"
          case 0x656D_616E_6B63_696E where key.count == 8: return 5  // "nickname"
          case 0x6369_7465_6E6F_6870 where key.count == 22: return 6  // "phoneticRepresentation"
          default: return -1
          }
        },
        applyString: { storage, field, bytes in
          let p = storage.assumingMemoryBound(to: PersonNameComponents.self)
          switch field {
          case 0: streamAppendPersonName(&p.pointee.familyName, bytes)
          case 1: streamAppendPersonName(&p.pointee.givenName, bytes)
          case 2: streamAppendPersonName(&p.pointee.middleName, bytes)
          case 3: streamAppendPersonName(&p.pointee.namePrefix, bytes)
          case 4: streamAppendPersonName(&p.pointee.nameSuffix, bytes)
          case 5: streamAppendPersonName(&p.pointee.nickname, bytes)
          default: break
          }
        },
        applyNull: { storage, field in
          let p = storage.assumingMemoryBound(to: PersonNameComponents.self)
          switch field {
          case 0: p.pointee.familyName = nil
          case 1: p.pointee.givenName = nil
          case 2: p.pointee.middleName = nil
          case 3: p.pointee.namePrefix = nil
          case 4: p.pointee.nameSuffix = nil
          case 5: p.pointee.nickname = nil
          case 6: p.pointee.phoneticRepresentation = nil
          default: break
          }
        }
      )
    }
  }

  // A top level function rather than a closure, so the schema's members stay non-capturing.
  private func streamAppendPersonName(_ value: inout String?, _ bytes: Span<UInt8>) {
    if value == nil { value = "" }
    value!.streamAppend(utf8: bytes)
  }

  // MARK: - Legacy handler registration

  extension Data: StreamParseable {
    public typealias Partial = Self
  }

  extension Data: StreamParseableValue {
    public static func initialParseableValue() -> Self {
      Self()
    }

    public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
      handlers.registerStringHandler(\.streamParsingStringValue)
    }

    private var streamParsingStringValue: String {
      get { String(decoding: self, as: UTF8.self) }
      set { self = Data(newValue.utf8) }
    }
  }

  // MARK: - Decimal

  extension Decimal: StreamParseable {
    public typealias Partial = Self
  }

  extension Decimal: StreamParseableValue {
    public static func initialParseableValue() -> Self {
      Decimal(0)
    }

    public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
      handlers.registerDoubleHandler(\.streamParsingDoubleValue)
    }

    private var streamParsingDoubleValue: Double {
      get {
        if self.isNaN {
          return Double.nan
        }
        if self.isZero {
          return 0
        }

        var mantissa = self.significand
        let two = Decimal(2)
        var divisor = Decimal(1)
        while divisor <= mantissa {
          divisor *= two
        }
        divisor /= two

        var result = 0.0
        let one = Decimal(1)
        while divisor >= one && !divisor.isZero {
          result *= 2
          if mantissa >= divisor {
            mantissa -= divisor
            result += 1
          }
          divisor /= two
        }

        let factor = digitPow10(self.exponent)
        let scaledResult = result * factor
        return self.sign == .minus ? -scaledResult : scaledResult
      }
      set { self = Decimal(Double(newValue)) }
    }
  }

  extension PersonNameComponents: StreamParseable, StreamParseableValue {
    public typealias Partial = Self

    public static func initialParseableValue() -> Self {
      Self()
    }

    public static func registerHandlers(in handlers: inout some StreamParserHandlers<Self>) {
      handlers.registerKeyedHandler(forKey: "familyName", \.familyName)
      handlers.registerKeyedHandler(forKey: "givenName", \.givenName)
      handlers.registerKeyedHandler(forKey: "middleName", \.middleName)
      handlers.registerKeyedHandler(forKey: "namePrefix", \.namePrefix)
      handlers.registerKeyedHandler(forKey: "nameSuffix", \.nameSuffix)
      handlers.registerKeyedHandler(forKey: "nickname", \.nickname)
      handlers.registerKeyedHandler(forKey: "phoneticRepresentation", \.phoneticRepresentation)
    }
  }
#endif
