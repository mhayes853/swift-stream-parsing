// swiftlint:disable identifier_name
// Everything here is underscored macro-support API: public because generated code in client
// modules must reach it, underscored because nothing else should.
import StreamParsingCore

// Schema construction for macro generated code. A macro sees only a property type's syntax, so
// overload pairs resolve the rest: the constrained overload works, the unconstrained one degrades
// harmlessly. Overloads resolve where a generic is *written*, so element and value schemas are
// built by `_streamSchema(for:)` at the call site, where the macro wrote a concrete type.

// MARK: - Schema for a concrete type

@inlinable
public func _streamSchema<T: StreamParseableObject>(for type: T.Type) -> StreamSchema {
  T.streamSchema
}

// A fixed-width SIMD value is syntactically a generic type but semantically an array-shaped
// container.
@_disfavoredOverload
@inlinable
public func _streamSchema<T: StreamContainerPartial>(for type: T.Type) -> StreamSchema {
  T.streamObjectMemberSchema
}

// Delegates to the core's scalar constructors, which root conformances also use, so a type cannot
// be described one way as a field and another as a root.

@inlinable
public func _streamSchema<T: StreamNumberConvertible>(for type: T.Type) -> StreamSchema {
  _streamNumberSchema(T.self)
}

@inlinable
public func _streamSchema<T: StreamStringConvertible>(for type: T.Type) -> StreamSchema {
  _streamStringSchema(T.self)
}

@inlinable
public func _streamSchema<T: StreamBooleanConvertible>(for type: T.Type) -> StreamSchema {
  _streamBooleanSchema(T.self)
}

@_disfavoredOverload
@inlinable
public func _streamSchema<T>(for type: T.Type) -> StreamSchema {
  StreamSchema(shape: .scalar)
}

// The container schema builders live in the core, beside the frame entry helpers they call.

// MARK: - Hoisted container schemas

// The schema a field's container entry installs, or nil for non-container storage. The macro
// calls this once per field per schema build, and the field table owns the result, so it outlives
// every frame that borrows it; reading `T.streamSchema` in the entry allocated one per container
// occurrence. The overload
// pair mirrors `_streamEnterField`'s, so nil here means the entry answers nil too.
@inlinable
public func _streamObjectMemberSchema<T: StreamContainerPartial>(for type: T.Type) -> StreamSchema? {
  T.streamObjectMemberSchema
}

@_disfavoredOverload
@inlinable
public func _streamObjectMemberSchema<T>(for type: T.Type) -> StreamSchema? {
  nil
}

// MARK: - Optional aware scalar application

// Partial members are optional, so a value has to exist before it can be appended to.
@inlinable
public func streamApply<T: StreamStringConvertible>(
  _ value: inout T?, utf8 bytes: Span<UInt8>
) -> StreamApplyResult {
  if value == nil { value = T.streamInitialValue() }
  return value!.streamAppend(utf8: bytes)
}

@inlinable
public func streamApply(
  _ value: inout StreamString?, utf8 bytes: Span<UInt8>, initialCapacity: Int
) -> StreamApplyResult {
  if value == nil { value = StreamString() }
  if bytes.isEmpty { value!.streamReserve(utf8ByteCount: initialCapacity) }
  return value!.streamAppend(utf8: bytes)
}

@inlinable
public func streamApply<T: StreamNumberConvertible>(
  _ value: inout T?, bytes: Span<UInt8>, info: NumberInfo
) -> StreamApplyResult {
  guard let parsed = T(streamParsing: bytes, info: info) else { return .unsupported }
  value = parsed
  return .applied
}

@inlinable
public func streamApply<T: StreamBooleanConvertible>(
  _ value: inout T?, boolean: Bool
) -> StreamApplyResult {
  value = T(streamParsingBoolean: boolean)
  return .applied
}

// MARK: - Field routes

// What a member's type resolves to for the field table, by `streamApply`'s overload structure, so
// classification matches application. Two overloads per protocol (optional and initialised
// modes), all taking the hoisted container schema so the macro emits one call shape. The
// `prepare` closures capture nothing; the capacity arrives from the entry.

@inlinable
public func _streamFieldRoute<T: StreamStringConvertible>(
  _ value: inout T?, schema: StreamSchema?
) -> StreamFieldRoute {
  _streamStringFieldRoute(T.self, optional: true)
}

@inlinable
public func _streamFieldRoute<T: StreamStringConvertible>(
  _ value: inout T, schema: StreamSchema?
) -> StreamFieldRoute {
  _streamStringFieldRoute(T.self, optional: false)
}

@inlinable
public func _streamFieldRoute<T: StreamNumberConvertible>(
  _ value: inout T?, schema: StreamSchema?
) -> StreamFieldRoute {
  StreamFieldRoute(_streamNumberFieldKind(T.self), optional: true)
}

@inlinable
public func _streamFieldRoute<T: StreamNumberConvertible>(
  _ value: inout T, schema: StreamSchema?
) -> StreamFieldRoute {
  StreamFieldRoute(_streamNumberFieldKind(T.self), optional: false)
}

@inlinable
public func _streamFieldRoute<T: StreamBooleanConvertible>(
  _ value: inout T?, schema: StreamSchema?
) -> StreamFieldRoute {
  StreamFieldRoute(_streamBooleanFieldKind(T.self), optional: true)
}

@inlinable
public func _streamFieldRoute<T: StreamBooleanConvertible>(
  _ value: inout T, schema: StreamSchema?
) -> StreamFieldRoute {
  StreamFieldRoute(_streamBooleanFieldKind(T.self), optional: false)
}

@inlinable
public func _streamFieldRoute<T: StreamParseableObject>(
  _ value: inout T?, schema: StreamSchema?
) -> StreamFieldRoute {
  StreamFieldRoute(
    .container, optional: true, schema: schema, prepare: _streamOptionalPrepare(T.self, then: T._streamObjectMemberPrepare)
  )
}

@inlinable
public func _streamFieldRoute<T: StreamParseableObject>(
  _ value: inout T, schema: StreamSchema?
) -> StreamFieldRoute {
  StreamFieldRoute(.container, optional: false, schema: schema, prepare: T._streamObjectMemberPrepare)
}

// No built-in container spelling: resolve through the actual partial storage type, which covers
// aliases, generic spelling and user-defined containers.
@_disfavoredOverload
@inlinable
public func _streamFieldRoute<T: StreamContainerPartial>(
  _ value: inout T?, schema: StreamSchema?
) -> StreamFieldRoute {
  StreamFieldRoute(
    .container, optional: true, schema: schema, prepare: _streamOptionalPrepare(T.self, then: T._streamObjectMemberPrepare)
  )
}

@_disfavoredOverload
@inlinable
public func _streamFieldRoute<T: StreamContainerPartial>(
  _ value: inout T, schema: StreamSchema?
) -> StreamFieldRoute {
  StreamFieldRoute(.container, optional: false, schema: schema, prepare: T._streamObjectMemberPrepare)
}

// A type none of the protocols describe stays on the closures.
@_disfavoredOverload
@inlinable
public func _streamFieldRoute<T>(_ value: inout T?, schema: StreamSchema?) -> StreamFieldRoute {
  StreamFieldRoute(.custom, optional: true)
}

@_disfavoredOverload
@inlinable
public func _streamFieldRoute<T>(_ value: inout T, schema: StreamSchema?) -> StreamFieldRoute {
  StreamFieldRoute(.custom, optional: false)
}

// MARK: - Field routes with a capacity

// Capacity-aware forms are container-specific: each container maps the hint onto its own storage.
// The capacity travels on the entry, so the closure has no context.

@inlinable
public func _streamFieldRoute(
  _ value: inout StreamString?, schema: StreamSchema?, initialCapacity: Int
) -> StreamFieldRoute {
  StreamFieldRoute(.streamString, optional: true, capacity: initialCapacity)
}

@inlinable
public func _streamFieldRoute(
  _ value: inout StreamString, schema: StreamSchema?, initialCapacity: Int
) -> StreamFieldRoute {
  StreamFieldRoute(.streamString, optional: false, capacity: initialCapacity)
}

@inlinable
public func _streamFieldRoute<Element>(
  _ value: inout StreamArray<Element>?, schema: StreamSchema?, initialCapacity: Int
) -> StreamFieldRoute {
  StreamFieldRoute(
    .container, optional: true, capacity: initialCapacity, schema: schema,
    prepare: { storage, capacity in
      let pointer = storage.assumingMemoryBound(to: StreamArray<Element>?.self)
      if pointer.pointee == nil {
        pointer.pointee = StreamArray(initialCapacity: Int(capacity))
      } else {
        pointer.pointee!.reserveCapacity(Int(capacity))
      }
    }
  )
}

@inlinable
public func _streamFieldRoute<Element>(
  _ value: inout StreamArray<Element>, schema: StreamSchema?, initialCapacity: Int
) -> StreamFieldRoute {
  StreamFieldRoute(
    .container, optional: false, capacity: initialCapacity, schema: schema,
    prepare: { storage, capacity in
      storage.assumingMemoryBound(to: StreamArray<Element>.self).pointee
        .reserveCapacity(Int(capacity))
    }
  )
}

@inlinable
public func _streamFieldRoute<Value>(
  _ value: inout StreamDictionary<Value>?, schema: StreamSchema?, initialCapacity: Int
) -> StreamFieldRoute {
  StreamFieldRoute(
    .container, optional: true, capacity: initialCapacity, schema: schema,
    prepare: { storage, capacity in
      let pointer = storage.assumingMemoryBound(to: StreamDictionary<Value>?.self)
      if pointer.pointee == nil {
        pointer.pointee = StreamDictionary(initialCapacity: Int(capacity))
      } else {
        pointer.pointee!.reserveCapacity(Int(capacity))
      }
    }
  )
}

@inlinable
public func _streamFieldRoute<Value>(
  _ value: inout StreamDictionary<Value>, schema: StreamSchema?, initialCapacity: Int
) -> StreamFieldRoute {
  StreamFieldRoute(
    .container, optional: false, capacity: initialCapacity, schema: schema,
    prepare: { storage, capacity in
      storage.assumingMemoryBound(to: StreamDictionary<Value>.self).pointee
        .reserveCapacity(Int(capacity))
    }
  )
}

// An inline string is a string, but its capacity is its type's `N`, so a hint could only be
// ignored: a larger one reads as raising the bound, which it would not. Rejected with the reason
// rather than by the fallback below, whose message says strings are supported.
@available(
  *, unavailable,
  message: "StreamInlineString<N> has a fixed capacity of N bytes; remove @StreamParseableMember(initialCapacity:) or change N."
)
public func _streamFieldRoute<let capacity: Int>(
  _ value: inout StreamInlineString<capacity>?, schema: StreamSchema?, initialCapacity: Int
) -> StreamFieldRoute {
  StreamFieldRoute(.custom, optional: true)
}

@available(
  *, unavailable,
  message: "StreamInlineString<N> has a fixed capacity of N bytes; remove @StreamParseableMember(initialCapacity:) or change N."
)
public func _streamFieldRoute<let capacity: Int>(
  _ value: inout StreamInlineString<capacity>, schema: StreamSchema?, initialCapacity: Int
) -> StreamFieldRoute {
  StreamFieldRoute(.custom, optional: false)
}

// Overload resolution sees through aliases the macro cannot: an alias of a `StreamArray` or
// `StreamDictionary` partial selects a concrete overload above. These fallbacks keep an annotation
// on a scalar or object from silently becoming a no-op.
@available(
  *, unavailable,
  message: "@StreamParseableMember(initialCapacity:) is only supported on array, dictionary, and string properties."
)
@_disfavoredOverload
public func _streamFieldRoute<T>(
  _ value: inout T?, schema: StreamSchema?, initialCapacity: Int
) -> StreamFieldRoute {
  StreamFieldRoute(.custom, optional: true)
}

@available(
  *, unavailable,
  message: "@StreamParseableMember(initialCapacity:) is only supported on array, dictionary, and string properties."
)
@_disfavoredOverload
public func _streamFieldRoute<T>(
  _ value: inout T, schema: StreamSchema?, initialCapacity: Int
) -> StreamFieldRoute {
  StreamFieldRoute(.custom, optional: false)
}
