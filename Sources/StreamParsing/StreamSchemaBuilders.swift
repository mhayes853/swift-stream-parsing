// swiftlint:disable identifier_name
// Everything here is underscored macro-support API: public because generated code in client
// modules must reach it, underscored because nothing else should.
import StreamParsingCore

// Schema construction for macro generated code.
//
// A macro sees only the syntax of a property's type. It can tell an array from a dictionary from
// a plain identifier, but not whether that identifier is a nested object or something that
// accepts string content. Overload pairs resolve that: the constrained overload does the work,
// the unconstrained one degrades to something harmless, and Swift ranks the constrained one
// higher.
//
// Overloads resolve where a generic is written, not where it is specialized, so a helper that
// is generic over an unconstrained element cannot pick the right one on its behalf. Element and
// value schemas are therefore built by `_streamSchema(for:)` at the call site, where the macro
// has written a concrete type.

// MARK: - Schema for a concrete type

@inlinable
public func _streamSchema<T: StreamParseableObject>(for type: T.Type) -> StreamSchema {
  T.streamSchema
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

// The schema a field's `streamContainerFrame` will install, or nil when the field's storage is
// not a container at all. The macro calls this once per field into a `private static let`, so
// the schema exists exactly once per `Partial` type and outlives every frame that borrows it —
// where reading `T.streamSchema` inside the entry allocated a schema per container occurrence
// whose only owner was the frame itself.
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

// MARK: - Field entry

// Degrades to nil rather than failing to compile when the field is not a nested object, which
// is what lets the macro emit an entry case for every field without knowing which are. Every
// overload takes the hoisted `containerSchema` so the macro can emit one call shape; only the
// `StreamContainerPartial` one reads it.
@inlinable
public func _streamEnterField<T: StreamParseableObject>(
  _ value: inout T?,
  containerSchema: StreamSchema?
) -> StreamFrame? {
  // Non-nil by construction: `_streamContainerSchema(for:)` resolves through
  // `StreamContainerPartial`, which `StreamParseableObject` refines.
  _streamEnterOptionalObject(&value, schema: containerSchema.unsafelyUnwrapped)
}

@_disfavoredOverload
@inlinable
public func _streamEnterField<T>(
  _ value: inout T?,
  containerSchema: StreamSchema?
) -> StreamFrame? {
  nil
}

// The initialized members mode gives non-optional members, so every entry point needs a
// counterpart that takes the value directly.
@inlinable
public func _streamEnterField<T: StreamParseableObject>(
  _ value: inout T,
  containerSchema: StreamSchema?
) -> StreamFrame? {
  _streamEnterObject(&value, schema: containerSchema.unsafelyUnwrapped)
}

// The source spelling did not identify a built-in container. Resolve through the actual partial
// storage type instead, which covers aliases, generic spelling and user-defined containers.
@_disfavoredOverload
@inlinable
public func _streamEnterField<T: StreamContainerPartial>(
  _ value: inout T,
  containerSchema: StreamSchema?
) -> StreamFrame? {
  withUnsafeMutablePointer(to: &value) {
    // Non-nil by construction: `_streamContainerSchema(for:)` resolves its constrained overload
    // for exactly the types that resolve this one.
    T.streamContainerFrame(at: UnsafeMutableRawPointer($0), schema: containerSchema.unsafelyUnwrapped)
  }
}

@_disfavoredOverload
@inlinable
public func _streamEnterField<T>(
  _ value: inout T,
  containerSchema: StreamSchema?
) -> StreamFrame? {
  nil
}

// Takes the field's finished schema rather than its element's, so the schema can be a stored
// static on the generated `Partial` and the entry is a materialize and a frame.
//
// These replaced a pair that took `element:` and built `_streamArraySchema` on every call.
// `enterField` runs once per container occurrence, so that was an allocation per `[` — two with
// the element schema — for a value the type could only ever have one of.
@inlinable
public func _streamEnterContainerField<T: StreamInitializable>(
  _ value: inout T?,
  schema: StreamSchema
) -> StreamFrame? {
  _streamEnterOptionalContainer(&value, initial: T.streamInitialValue(), schema: schema)
}

@inlinable
public func _streamEnterContainerField<T>(
  _ value: inout T,
  schema: StreamSchema
) -> StreamFrame? {
  _streamEnterContainer(&value, schema: schema)
}

// Capacity-aware forms are deliberately container-specific. `initialCapacity` is macro-facing
// vocabulary; how each container maps the hint onto its storage remains private to that type.
@inlinable
public func _streamEnterContainerField<Element>(
  _ value: inout StreamArray<Element>?,
  schema: StreamSchema,
  initialCapacity: Int
) -> StreamFrame? {
  if value != nil { value!.reserveCapacity(initialCapacity) }
  return _streamEnterOptionalContainer(
    &value,
    initial: StreamArray(initialCapacity: initialCapacity),
    schema: schema
  )
}

@inlinable
public func _streamEnterContainerField<Element>(
  _ value: inout StreamArray<Element>,
  schema: StreamSchema,
  initialCapacity: Int
) -> StreamFrame? {
  value.reserveCapacity(initialCapacity)
  return _streamEnterContainer(&value, schema: schema)
}

@inlinable
public func _streamEnterContainerField<Value>(
  _ value: inout StreamDictionary<Value>?,
  schema: StreamSchema,
  initialCapacity: Int
) -> StreamFrame? {
  if value != nil { value!.reserveCapacity(initialCapacity) }
  return _streamEnterOptionalContainer(
    &value,
    initial: StreamDictionary(initialCapacity: initialCapacity),
    schema: schema
  )
}

@inlinable
public func _streamEnterContainerField<Value>(
  _ value: inout StreamDictionary<Value>,
  schema: StreamSchema,
  initialCapacity: Int
) -> StreamFrame? {
  value.reserveCapacity(initialCapacity)
  return _streamEnterContainer(&value, schema: schema)
}

// MARK: - Optional aware scalar application

// Partial members are optional, so a value has to exist before it can be appended to.
@inlinable
public func streamApply<T: StreamStringConvertible>(
  _ value: inout T?, utf8 bytes: Span<UInt8>
) -> Bool {
  if value == nil { value = T.streamInitialValue() }
  value!.streamAppend(utf8: bytes)
  return true
}

@inlinable
public func streamApply<T: StreamNumberConvertible>(
  _ value: inout T?, bytes: Span<UInt8>, info: NumberInfo
) -> Bool {
  guard let parsed = T(streamParsing: bytes, info: info) else { return false }
  value = parsed
  return true
}

@inlinable
public func streamApply<T: StreamBooleanConvertible>(_ value: inout T?, boolean: Bool) -> Bool {
  value = T(streamParsingBoolean: boolean)
  return true
}
