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

// MARK: - Field entry

// Degrades to nil rather than failing to compile when the field is not a nested object, which
// is what lets the macro emit an entry case for every field without knowing which are.
@inlinable
public func _streamEnterField<T: StreamParseableObject>(_ value: inout T?) -> StreamFrame? {
  _streamEnterOptionalObject(&value)
}

@_disfavoredOverload
@inlinable
public func _streamEnterField<T>(_ value: inout T?) -> StreamFrame? {
  nil
}

// The initialized members mode gives non-optional members, so every entry point needs a
// counterpart that takes the value directly.
@inlinable
public func _streamEnterField<T: StreamParseableObject>(_ value: inout T) -> StreamFrame? {
  _streamEnterObject(&value)
}

@_disfavoredOverload
@inlinable
public func _streamEnterField<T>(_ value: inout T) -> StreamFrame? {
  nil
}

@inlinable
public func _streamEnterArrayField<Element: StreamInitializable>(
  _ value: inout StreamArray<Element>?,
  element: StreamSchema
) -> StreamFrame? {
  _streamEnterOptionalContainer(
    &value,
    initial: StreamArray<Element>(),
    schema: _streamArraySchema(Element.self, element: element)
  )
}

@inlinable
public func _streamEnterArrayField<Element: StreamInitializable>(
  _ value: inout StreamArray<Element>,
  element: StreamSchema
) -> StreamFrame? {
  _streamEnterContainer(&value, schema: _streamArraySchema(Element.self, element: element))
}

@inlinable
public func _streamEnterDictionaryField<Value: StreamInitializable>(
  _ value: inout StreamDictionary<Value>,
  value valueSchema: StreamSchema
) -> StreamFrame? {
  _streamEnterContainer(
    &value, schema: _streamDictionarySchema(Value.self, value: valueSchema)
  )
}

@inlinable
public func _streamEnterDictionaryField<Value: StreamInitializable>(
  _ value: inout StreamDictionary<Value>?,
  value valueSchema: StreamSchema
) -> StreamFrame? {
  _streamEnterOptionalContainer(
    &value,
    initial: StreamDictionary<Value>(),
    schema: _streamDictionarySchema(Value.self, value: valueSchema)
  )
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
