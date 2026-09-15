// swiftlint:disable identifier_name
// Everything here is underscored macro-support API: public because generated code in client
// modules must reach it, underscored because nothing else should.
import StreamParsingCore

// Schema construction for macro generated code.
//
// A macro sees only the syntax of a property's type, so overload pairs resolve the rest: the
// constrained overload does the work, the unconstrained one degrades harmlessly, and Swift ranks
// the constrained one higher.
//
// Overloads resolve where a generic is *written*, not where it is specialized, so a helper generic
// over an unconstrained element cannot pick one on its behalf. Element and value schemas are
// therefore built by `_streamSchema(for:)` at the call site, where the macro wrote a concrete type.

// MARK: - Schema for a concrete type

@inlinable
public func _streamSchema<T: StreamParseableObject>(for type: T.Type) -> StreamSchema {
  T.streamSchema
}

// A fixed-width SIMD value is syntactically a plain generic type to the macro but semantically an
// array-shaped container. Keep this below the object overload so an object, which refines
// `StreamContainerPartial`, continues to use its more specific route.
@_disfavoredOverload
@inlinable
public func _streamSchema<T: StreamContainerPartial>(for type: T.Type) -> StreamSchema {
  T.streamContainerSchema
}

// These delegate to the core's scalar schema constructors, which the root conformances also use,
// so a type cannot be described one way as a field and another way as a root.

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

// The container schema builders live in the core, next to the frame entry helpers they call and
// the root conformances that need them.

// MARK: - Hoisted container schemas

// The schema a field's container entry will install, or nil when the field's storage is not a
// container. The macro calls this once per field into a `private static let`, so the schema exists
// once per `Partial` type and outlives every frame that borrows it — reading `T.streamSchema` in
// the entry instead allocated one per container occurrence, owned only by the frame.
//
// The overload pair mirrors `_streamEnterField`'s: the constrained one fires for exactly the
// storage types whose entry produces a frame, so a nil here means the entry answers nil too.
@inlinable
public func _streamContainerSchema<T: StreamContainerPartial>(for type: T.Type) -> StreamSchema? {
  T.streamContainerSchema
}

@_disfavoredOverload
@inlinable
public func _streamContainerSchema<T>(for type: T.Type) -> StreamSchema? {
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

// What a member's type resolves to for the field table, by the same overload structure
// `streamApply` uses, so a member is classified exactly the way it would have been applied. Two
// overloads per protocol (optional and initialised members modes); every overload takes the field's
// hoisted container schema so the macro emits one call shape, and only the container ones read it.
// The `prepare` closures capture nothing — the capacity arrives from the entry — so after
// specialisation each is a bare function with no context to retain.

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
    .container, optional: true, schema: schema, prepare: _streamOptionalContainerPrepare(T.self)
  )
}

@inlinable
public func _streamFieldRoute<T: StreamParseableObject>(
  _ value: inout T, schema: StreamSchema?
) -> StreamFieldRoute {
  StreamFieldRoute(.container, optional: false, schema: schema, prepare: T._streamContainerPrepare)
}

// The source spelling did not identify a built-in container. Resolve through the actual partial
// storage type instead, which covers aliases, generic spelling and user-defined containers.
@_disfavoredOverload
@inlinable
public func _streamFieldRoute<T: StreamContainerPartial>(
  _ value: inout T?, schema: StreamSchema?
) -> StreamFieldRoute {
  StreamFieldRoute(
    .container, optional: true, schema: schema, prepare: _streamOptionalContainerPrepare(T.self)
  )
}

@_disfavoredOverload
@inlinable
public func _streamFieldRoute<T: StreamContainerPartial>(
  _ value: inout T, schema: StreamSchema?
) -> StreamFieldRoute {
  StreamFieldRoute(.container, optional: false, schema: schema, prepare: T._streamContainerPrepare)
}

// A type none of the protocols above describe: whatever `streamApply` does with it, the table
// does not know, so it stays on the closures.
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

// Materialises an optional container member and then lets the wrapped type prepare its own
// storage, which an `Optional` wrapped in another does.
//
// This builder runs once per schema, so the initial value and the wrapped type's prepare are
// resolved here rather than per container occurrence — `T.streamInitialValue()` inside the closure
// re-entered the runtime's locking generic-metadata caches every time, and a generic type has no
// stored static to cache a template in. The allocation is owned by a `_StreamTemplateStorage` box
// the closure captures purely for its lifetime: `StreamFieldPrepare` is a bare closure typealias,
// so the context is the only place the field table can hold the box, and the body never touches it
// (no retain, no release, no load per call).
//
// The template is the optional already `.some`, and the member is **copy-initialised** from its
// address, not assigned: an assignment destroys the `nil` first and reads the payload through a
// temporary. Initialising over a `nil` is sound because a `nil` optional owns nothing.
@inlinable
public func _streamOptionalContainerPrepare<T: StreamContainerPartial>(
  _ type: T.Type
) -> StreamFieldPrepare {
  let owner = _streamOwnedTemplate(T?.some(T.streamInitialValue()))
  nonisolated(unsafe) let template = owner.address(as: T?.self)
  let inner = T._streamContainerPrepare
  return { [owner] storage, _ in
    // Named so the capture is real: Swift captures only what the body references, and the
    // capture is the whole point -- the box has to die with the closure, not before it.
    _ = owner
    let pointer = storage.assumingMemoryBound(to: T?.self)
    if pointer.pointee == nil {
      _streamCopyInitialize(pointer, from: template)
    }
    inner?(storage, 0)
  }
}

// MARK: - Field routes with a capacity

// Capacity-aware forms are deliberately container-specific. `initialCapacity` is macro-facing
// vocabulary; how each container maps the hint onto its storage remains private to that type.
// The capacity itself travels on the entry, not in the closure, so the closure has no context.

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

// The macro cannot resolve aliases, but overload resolution can: an alias whose partial storage
// is a StreamArray or StreamDictionary selects one of the concrete overloads above. These
// fallbacks keep an annotation on a scalar or object from silently becoming a no-op.
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
