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

@inlinable
public func _streamSchema<T: StreamNumberConvertible>(for type: T.Type) -> StreamSchema {
  StreamSchema(
    shape: .scalar,
    applyNumber: { storage, _, bytes, info in
      streamApply(&storage.assumingMemoryBound(to: T.self).pointee, bytes: bytes, info: info)
    }
  )
}

@inlinable
public func _streamSchema<T: StreamStringConvertible>(for type: T.Type) -> StreamSchema {
  StreamSchema(
    shape: .scalar,
    applyString: { storage, _, bytes in
      storage.assumingMemoryBound(to: T.self).pointee.streamAppend(utf8: bytes)
    }
  )
}

@inlinable
public func _streamSchema<T: StreamBooleanConvertible>(for type: T.Type) -> StreamSchema {
  StreamSchema(
    shape: .scalar,
    applyBoolean: { storage, _, value in
      storage.assumingMemoryBound(to: T.self).pointee = T(streamParsingBoolean: value)
    }
  )
}

@_disfavoredOverload
@inlinable
public func _streamSchema<T>(for type: T.Type) -> StreamSchema {
  StreamSchema(shape: .scalar)
}

// MARK: - Containers

@inlinable
public func _streamArraySchema<Element: StreamInitializable>(
  _ type: Element.Type,
  element: StreamSchema
) -> StreamSchema {
  StreamSchema(
    shape: .array,
    appendElement: { storage in
      _streamAppendElement(
        to: &storage.assumingMemoryBound(to: [Element].self).pointee,
        initial: Element.streamInitialValue(),
        schema: element
      )
    }
  )
}

@inlinable
public func _streamDictionarySchema<Value: StreamInitializable>(
  _ type: Value.Type,
  value valueSchema: StreamSchema
) -> StreamSchema {
  StreamSchema(
    shape: .dictionary,
    enterKey: { storage, key in
      _streamEnterDictionaryValue(
        &storage.assumingMemoryBound(to: StreamDictionary<Value>.self).pointee,
        key: key,
        initial: Value.streamInitialValue(),
        schema: valueSchema
      )
    }
  )
}

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
  _ value: inout [Element]?,
  element: StreamSchema
) -> StreamFrame? {
  _streamEnterOptionalContainer(
    &value, initial: [], schema: _streamArraySchema(Element.self, element: element)
  )
}

@inlinable
public func _streamEnterArrayField<Element: StreamInitializable>(
  _ value: inout [Element],
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
public func streamApply<T: StreamStringConvertible>(_ value: inout T?, utf8 bytes: Span<UInt8>) {
  if value == nil { value = T.streamInitialValue() }
  value!.streamAppend(utf8: bytes)
}

@inlinable
public func streamApply<T: StreamNumberConvertible>(
  _ value: inout T?, bytes: Span<UInt8>, info: NumberInfo
) {
  if let parsed = T(streamParsing: bytes, info: info) { value = parsed }
}

@inlinable
public func streamApply<T: StreamBooleanConvertible>(_ value: inout T?, boolean: Bool) {
  value = T(streamParsingBoolean: boolean)
}
