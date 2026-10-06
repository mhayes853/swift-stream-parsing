// MARK: - Conversion protocols

extension String: StreamStringConvertible {
  public static func streamInitialValue() -> Self { "" }

  // `String(decoding:)` validates with the stdlib's validator, which drops to a byte at a time at
  // the first non-ASCII byte: nearly every string in the LLM message has one, and that validation
  // was most of the append. From 32 bytes this checks the bytes itself and copies them in unchecked
  // -- an ASCII scan, then the parser's SIMD validator for anything else. Below 32, and for
  // all-ASCII bytes, the stdlib's own ASCII path is as fast as anything here: the validator call
  // costs a fixed ~12 ns (x86_64), so a span of one scalar, as byte-fed input delivers, stays on the
  // decode. Measured on x86_64, ns per one-chunk string, decode / validator / this:
  //
  //   12 B ASCII  37.6 / 49.0 /  37.3     64 B with é   130.1 /  99.1 / 103.0
  //   64 B ASCII  75.4 / 88.9 /  76.9     512 B with é  542.4 / 131.7 / 141.4
  //
  // and the LLM message's strings replayed as the sink delivers them, 814 MB/s -> 2821. The bytes
  // are checked here rather than trusted from the sink, so a caller handing over anything at all
  // still gets a well-formed `String`: what the validator refuses, a sequence cut at the end
  // included, takes the repairing decode as before.
  @discardableResult
  public mutating func streamAppend(utf8 bytes: Span<UInt8>) -> StreamApplyResult {
    // The opening quote's empty span, sent to settle acceptance: there is nothing to append.
    guard !bytes.isEmpty else { return .applied }
    if bytes.count >= 32, #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) {
      let isASCII = bytes.withUnsafeBufferPointer { buffer in
        var bits: UInt8 = 0
        for byte in buffer { bits |= byte }
        return bits < 0x80
      }
      // Known ASCII also spares `String(copying:)` its own scan for the flag.
      if isASCII {
        self.append(contentsOf: String(copying: UTF8Span(unchecked: bytes, isKnownASCII: true)))
        return .applied
      }
      let isValid = bytes.withUnsafeBytes { raw in
        streamValidateUTF8(base: raw.baseAddress!, from: 0, to: raw.count)
      }
      if isValid {
        self.append(contentsOf: String(copying: UTF8Span(unchecked: bytes)))
        return .applied
      }
    }
    bytes.withUnsafeBufferPointer { buffer in
      self += String(decoding: buffer, as: UTF8.self)
    }
    return .applied
  }
}

extension Bool: StreamBooleanConvertible, StreamInitializable {
  public static func streamInitialValue() -> Self { false }

  public init(streamParsingBoolean value: Bool) {
    self = value
  }
}

extension Optional: StreamNullable, StreamInitializable {
  public static func streamNullValue() -> Self { nil }
  public static func streamInitialValue() -> Self { nil }
}

extension Array: StreamInitializable {
  public static func streamInitialValue() -> Self { [] }
}

// Every numeric initial value here is zero, stated once. Not `@inlinable`: a protocol extension
// default specialises for a concrete conformer exactly as a per-type body did.
extension StreamInitializable where Self: AdditiveArithmetic {
  public static func streamInitialValue() -> Self { .zero }
}

// Each picks up the schema its conversion protocol implies, so a bare scalar, array or dictionary
// document parses into the same shapes a field would. `Partial` keeps its `Self` default, so the
// `where Partial == Self` extension supplies the rest.

extension Int: StreamNumberConvertible, StreamInitializable, StreamPartial, StreamParseable {}
extension Int8:
  StreamNumberConvertible, StreamInitializable, StreamPartial, StreamParseable
{}
extension Int16:
  StreamNumberConvertible, StreamInitializable, StreamPartial, StreamParseable
{}
extension Int32:
  StreamNumberConvertible, StreamInitializable, StreamPartial, StreamParseable
{}
extension Int64:
  StreamNumberConvertible, StreamInitializable, StreamPartial, StreamParseable
{}
extension UInt:
  StreamNumberConvertible, StreamInitializable, StreamPartial, StreamParseable
{}
extension UInt8:
  StreamNumberConvertible, StreamInitializable, StreamPartial, StreamParseable
{}
extension UInt16:
  StreamNumberConvertible, StreamInitializable, StreamPartial, StreamParseable
{}
extension UInt32:
  StreamNumberConvertible, StreamInitializable, StreamPartial, StreamParseable
{}
extension UInt64:
  StreamNumberConvertible, StreamInitializable, StreamPartial, StreamParseable
{}
extension Double:
  StreamFastFloatConvertible, StreamInitializable, StreamPartial, StreamParseable
{}
extension Float:
  StreamFastFloatConvertible, StreamInitializable, StreamPartial, StreamParseable
{}
// Match the standard library's availability: Float16 is absent on Intel macOS
// and Mac Catalyst. Its string initializer requires SwiftStdlib 5.3.
#if !((os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64))
  @available(macOS 11.0, iOS 14.0, tvOS 14.0, watchOS 7.0, *)
  extension Float16:
    StreamFastFloatConvertible, StreamInitializable, StreamPartial, StreamParseable
  {}
#endif

// Float80 exists where x86 long double is extended precision. Embedded targets
// expose it only on Linux and Apple platforms, matching the standard library.
#if (arch(i386) || arch(x86_64)) && !(os(Windows) || os(Android))
  #if !hasFeature(Embedded) || os(Linux) || os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
    extension Float80:
      StreamFastFloatConvertible, StreamInitializable, StreamPartial, StreamParseable
    {}
  #endif
#endif

extension String: StreamPartial {}
extension Bool: StreamPartial, StreamParseable {}

// `Array` is a bridging destination, not a parse target: parsing into one writes through a raw
// pointer into a buffer other values may share, which made kept states change after the fact.

extension StreamDictionary: StreamPartial, StreamContainerPartial
where Value: StreamPartial {
  // See `StreamArray.streamSchema`: `@inlinable` so the `enterKey` closure is emitted in the client
  // module with `Value` concrete and `_openValue(forKey:copyingSome:)` specialises. Cached.
  @inlinable
  public static var streamSchema: StreamSchema {
    StreamSchemaCache.shared.schema(for: Self.self) {
      _streamDictionarySchema(Value.self, value: Value.streamDictionaryValueSchema)
    }
  }
}

// A value wider than the `UInt64` accumulator arrives flagged as overflowed with nothing usable,
// so these two re-scan the token rather than narrowing their range to 64 bits.

@available(StreamParsing128BitIntegers, *)
extension Int128:
  StreamNumberConvertible, StreamInitializable, StreamPartial, StreamParseable
{}

@available(StreamParsing128BitIntegers, *)
extension UInt128:
  StreamNumberConvertible, StreamInitializable, StreamPartial, StreamParseable
{}

// MARK: - String

extension String: StreamParseable {
  public typealias Partial = StreamString

  public var streamPartialValue: StreamString {
    StreamString(self)
  }

  // A string is complete at every byte boundary, so the two conversions coincide. Spelled out
  // because the `StreamInitializable` blanket fallback would decode the bytes twice.
  public init?(streamPartial: StreamString) {
    self.init(streamPartial)
  }

  @_disfavoredOverload
  public init(orInitial partial: StreamString) {
    self.init(partial)
  }
}

// MARK: - Array

extension Array: StreamParseable where Element: StreamParseable {
  public typealias Partial = StreamArray<Element.Partial>

  public var streamPartialValue: StreamArray<Element.Partial> {
    StreamArray(self.lazy.map(\.streamPartialValue))
  }

  // An element that cannot be described fails the array: a shorter array reads like a right answer.
  public init?(streamPartial: StreamArray<Element.Partial>) {
    self.init()
    self.reserveCapacity(streamPartial.count)
    for element in streamPartial {
      guard let value = Element(streamPartial: element) else { return nil }
      self.append(value)
    }
  }

  // Member-wise: the blanket fallback would answer `[]` if only the last element was short.
  @_disfavoredOverload
  public init(orInitial partial: StreamArray<Element.Partial>) {
    self.init()
    self.reserveCapacity(partial.count)
    for element in partial {
      self.append(Element(orInitial: element))
    }
  }
}

// MARK: - Dictionary

// A dictionary's partial is a `StreamDictionary`, as the macro emits for a member: `Dictionary`
// relocates values on insertion, leaving no address for a frame to write through.
extension Dictionary: StreamParseable where Key == String, Value: StreamParseable {
  public typealias Partial = StreamDictionary<Value.Partial>

  public var streamPartialValue: StreamDictionary<Value.Partial> {
    var partial = StreamDictionary<Value.Partial>()
    for key in self.keys.sorted() {
      partial.updateValue(self[key]!.streamPartialValue, forKey: key)
    }
    return partial
  }

  public init?(streamPartial: StreamDictionary<Value.Partial>) {
    self.init(minimumCapacity: streamPartial.count)
    for (key, value) in streamPartial {
      guard let value = Value(streamPartial: value) else { return nil }
      self[key] = value
    }
  }

  // Member-wise for the same reason as `Array`: the blanket fallback would answer `[:]`.
  @_disfavoredOverload
  public init(orInitial partial: StreamDictionary<Value.Partial>) {
    self.init(minimumCapacity: partial.count)
    for (key, value) in partial {
      self[key] = Value(orInitial: value)
    }
  }
}

// MARK: - Optional

extension Optional: StreamParseable where Wrapped: StreamParseable {
  public typealias Partial = Wrapped.Partial?

  public var streamPartialValue: Wrapped.Partial? {
    switch self {
    case .none: nil
    case .some(let wrapped): wrapped.streamPartialValue
    }
  }

  // Where absence and incompleteness differ: a member never produced is `nil`, which an optional
  // can represent; one left half formed is neither, so it fails. Nulling `user` because its `id`
  // never arrived would conflate a document that omitted the user with one truncated inside it.
  public init?(streamPartial: Wrapped.Partial?) {
    switch streamPartial {
    case .none:
      self = .none
    case .some(let partial):
      guard let value = Wrapped(streamPartial: partial) else { return nil }
      self = .some(value)
    }
  }

  @_disfavoredOverload
  public init(orInitial partial: Wrapped.Partial?) {
    self = partial.map { Wrapped(orInitial: $0) }
  }
}

// Materializes before delegating, so `Int?` accepts what `Int` accepts and a null still clears it.
// Relies on the offset-zero payload, as the frame entry helpers do.
extension Optional: StreamPartial where Wrapped: StreamPartial {
  // Resolved once and captured: `Wrapped.streamSchema` is computed, so reading it inside allocated
  // a `StreamSchema` per *token*. Cached per wrapped type too, or an `Optional` root rebuilt a
  // dozen closure contexts per `PartialsStream.init`.
  public static var streamSchema: StreamSchema {
    StreamSchemaCache.shared.schema(for: Self.self) { Self._streamOptionalRootSchemaBody() }
  }

  static func _streamOptionalRootSchemaBody() -> StreamSchema {
    let wrapped = Wrapped.streamSchema
    // Propagated, not always wrapped, so a destination that matches no keys still skips the call.
    let delegated: @Sendable (Span<UInt8>) -> Int32 = { key in wrapped.matchField(key) }
    let matchField: (@Sendable (Span<UInt8>) -> Int32)? = wrapped.ignoresKeys ? nil : delegated
    let recognition: (@Sendable (UnsafeMutableRawPointer, StreamFieldID) -> Void)?
    if let recognized = wrapped.onFieldRecognized {
      recognition = { storage, field in
        _streamMaterializeOptional(storage, as: Wrapped.self)
        recognized(storage, field)
      }
    } else {
      recognition = nil
    }
    return StreamSchema(
      shape: wrapped.shape,
      prepareRoot: { storage in
        _streamMaterializeOptional(storage, as: Wrapped.self)
        wrapped.prepareRoot(storage)
      },
      matchField: matchField,
      onFieldRecognized: recognition,
      applyString: { storage, field, bytes in
        _streamMaterializeOptional(storage, as: Wrapped.self)
        return wrapped.applyString(storage, field, bytes)
      },
      applyNumber: { storage, field, bytes, info in
        _streamMaterializeOptional(storage, as: Wrapped.self)
        return wrapped.applyNumber(storage, field, bytes, info)
      },
      applyBoolean: { storage, field, value in
        _streamMaterializeOptional(storage, as: Wrapped.self)
        return wrapped.applyBoolean(storage, field, value)
      },
      // A null clears the optional only when it *is* the destination; over an object it is a
      // field's null. Clearing unconditionally made `[{"name":"a","count":null}]` wipe the whole
      // element of a `StreamArray<Person.Partial?>`, `name` included.
      applyNull: { storage, field in
        guard field != StreamSchema.wholeValueField else {
          storage.assumingMemoryBound(to: Wrapped?.self).pointee = nil
          return .applied
        }
        _streamMaterializeOptional(storage, as: Wrapped.self)
        return wrapped.applyNull(storage, field)
      },
      finishString: wrapped.finishString,
      enterField: { storage, field in
        _streamMaterializeOptional(storage, as: Wrapped.self)
        return wrapped.enterField(storage, field)
      },
      appendElement: { storage, index in
        _streamMaterializeOptional(storage, as: Wrapped.self)
        return wrapped.appendElement(storage, index)
      },
      enterKey: { storage, key in
        _streamMaterializeOptional(storage, as: Wrapped.self)
        return wrapped.enterKey(storage, key)
      },
      elementSchema: wrapped.elementSchema,
      elementStride: wrapped.elementStride,
      elementKind: wrapped.elementKind,
      elementOptional: wrapped.elementOptional,
      // Fixed SIMD arrays keep their cursor in the sink frame and write through the offset-zero
      // payload once `prepareRoot` materializes it.
      leafRoute: wrapped.leafRoute.fixedSIMDLaneCount != 0 || wrapped.leafRoute == .inlineArray
        ? wrapped.leafRoute
        : .generic,
      fixedElementCount: wrapped.fixedElementCount,
      // No materialising closure in front of the table's store: `prepareRoot` materialises the
      // optional root before any frame is pushed over it.
      fields: wrapped.fields,
      completedValue: wrapped.completedValue
    )
  }
}

// The two positions an optional can occupy. A bare optional root has no owner, so `streamSchema`
// above materialises per token. An optional array element's container opened the slot, so this is
// the wrapped closures with only `applyNull` replaced: one schema call per token, the whole 2.4x,
// and a requirement rather than macro sugar so `Array<Int?>` and a `StreamArray<Int?>` root match.
// A dictionary value is the same kind of slot and takes these through the `streamDictionaryValue`
// defaults.
extension Optional where Wrapped: StreamPartial {
  @inlinable
  public static var streamArrayElementSchema: StreamSchema {
    StreamSchemaCache.shared.schema(for: Self.self, usage: .arrayElement) {
      _streamOptionalElementSchema(Wrapped.self, base: Wrapped.streamSchema)
    }
  }

  // Materialised all the way down. For `T?` this is `.some(T.streamInitialValue())`, the same
  // value as ever: only `Optional` overrides the requirement. For `T??` it is `.some(.some(...))`
  // rather than `.some(nil)`, because the element schema writes through the inner optional's
  // payload -- a struct's field table, a vector's lanes -- and a `nil` there has no payload.
  @inlinable
  public static func streamInitialArrayElement() -> Self {
    .some(Wrapped.streamInitialArrayElement())
  }
}

extension Optional: StreamContainerPartial where Wrapped: StreamContainerPartial {
  @inlinable
  public static var streamObjectMemberSchema: StreamSchema {
    Wrapped.streamObjectMemberSchema
  }

  @inlinable
  public static var _streamObjectMemberPrepare: StreamFieldPrepare? {
    { storage, capacity in
      _streamMaterializeOptional(storage, as: Wrapped.self)
      Wrapped._streamObjectMemberPrepare?(storage, capacity)
    }
  }
}
