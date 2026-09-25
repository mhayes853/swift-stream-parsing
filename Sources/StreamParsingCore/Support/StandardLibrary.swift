// MARK: - Conversion protocols

extension String: StreamStringConvertible {
  public static func streamInitialValue() -> Self { "" }

  @discardableResult
  public mutating func streamAppend(utf8 bytes: Span<UInt8>) -> StreamApplyResult {
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

extension Int: StreamNumberConvertible, StreamInitializable, StreamParseableRoot, StreamParseable {}
extension Int8:
  StreamNumberConvertible, StreamInitializable, StreamParseableRoot, StreamParseable
{}
extension Int16:
  StreamNumberConvertible, StreamInitializable, StreamParseableRoot, StreamParseable
{}
extension Int32:
  StreamNumberConvertible, StreamInitializable, StreamParseableRoot, StreamParseable
{}
extension Int64:
  StreamNumberConvertible, StreamInitializable, StreamParseableRoot, StreamParseable
{}
extension UInt:
  StreamNumberConvertible, StreamInitializable, StreamParseableRoot, StreamParseable
{}
extension UInt8:
  StreamNumberConvertible, StreamInitializable, StreamParseableRoot, StreamParseable
{}
extension UInt16:
  StreamNumberConvertible, StreamInitializable, StreamParseableRoot, StreamParseable
{}
extension UInt32:
  StreamNumberConvertible, StreamInitializable, StreamParseableRoot, StreamParseable
{}
extension UInt64:
  StreamNumberConvertible, StreamInitializable, StreamParseableRoot, StreamParseable
{}
extension Double:
  StreamNumberConvertible, StreamInitializable, StreamParseableRoot, StreamParseable
{}
extension Float:
  StreamNumberConvertible, StreamInitializable, StreamParseableRoot, StreamParseable
{}
extension String: StreamParseableRoot {}
extension Bool: StreamParseableRoot, StreamParseable {}

// `Array` is a bridging destination, not a parse target: parsing into one writes through a raw
// pointer into a buffer other values may share, which made kept states change after the fact.

extension StreamDictionary: StreamParseableRoot, StreamContainerPartial
where Value: StreamParseableRoot {
  // See `StreamArray.streamSchema`: `@inlinable` so the `enterKey` closure is emitted in the client
  // module with `Value` concrete and `_openValue(forKey:copyingSome:)` specialises. Cached.
  @inlinable
  public static var streamSchema: StreamSchema {
    _streamCachedSchema(for: Self.self) {
      _streamDictionarySchema(Value.self, value: Value.streamDictionaryValueSchema)
    }
  }
}

// A value wider than the `UInt64` accumulator arrives flagged as overflowed with nothing usable,
// so these two re-scan the token rather than narrowing their range to 64 bits.

@available(StreamParsing128BitIntegers, *)
extension Int128:
  StreamNumberConvertible, StreamInitializable, StreamParseableRoot, StreamParseable
{}

@available(StreamParsing128BitIntegers, *)
extension UInt128:
  StreamNumberConvertible, StreamInitializable, StreamParseableRoot, StreamParseable
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

  public static func streamValueOrInitial(from partial: StreamString) -> String {
    String(partial)
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
  public static func streamValueOrInitial(from partial: StreamArray<Element.Partial>) -> Self {
    var result = Self()
    result.reserveCapacity(partial.count)
    for element in partial {
      result.append(Element.streamValueOrInitial(from: element))
    }
    return result
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
  public static func streamValueOrInitial(from partial: StreamDictionary<Value.Partial>) -> Self {
    var result = Self(minimumCapacity: partial.count)
    for (key, value) in partial {
      result[key] = Value.streamValueOrInitial(from: value)
    }
    return result
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

  public static func streamValueOrInitial(from partial: Wrapped.Partial?) -> Self {
    partial.map(Wrapped.streamValueOrInitial(from:))
  }
}

// Materializes before delegating, so `Int?` accepts what `Int` accepts and a null still clears it.
// Relies on the offset-zero payload, as the frame entry helpers do.
extension Optional: StreamParseableRoot where Wrapped: StreamParseableRoot {
  // Resolved once and captured: `Wrapped.streamSchema` is computed, so reading it inside allocated
  // a `StreamSchema` per *token*. Cached per wrapped type too, or an `Optional` root rebuilt a
  // dozen closure contexts per `PartialsStream.init`.
  public static var streamSchema: StreamSchema {
    _streamCachedSchema(for: Self.self) { Self._streamOptionalRootSchemaBody() }
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
extension Optional where Wrapped: StreamParseableRoot {
  @inlinable
  public static var streamArrayElementSchema: StreamSchema {
    _streamOptionalElementSchema(Wrapped.self, base: Wrapped.streamSchema)
  }

  @inlinable
  public static func streamInitialArrayElement() -> Self { .some(Wrapped.streamInitialValue()) }
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
