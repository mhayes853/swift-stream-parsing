// Entering a nested field needs a pointer to a stored property. The sanctioned way to get one
// is MemoryLayout.offset(of:), which requires a key path, and key paths are rejected outright
// by Embedded Swift. So these reinterpret a pointer to an Optional as a pointer to its payload,
// which relies on single payload enums storing the payload at offset zero.
//
// That is an implementation detail rather than a guarantee, so it lives here and nowhere else.
// The nested object and array cases in the partial sink tests exercise it end to end, so a
// toolchain that changed optional layout would fail those rather than corrupt values silently.
//
// Underscored because nothing outside macro generated code has any reason to call these.

@inlinable
public func _streamEnterOptionalObject<T: StreamParseableObject>(_ value: inout T?) -> StreamFrame {
  if value == nil { value = T.streamInitialValue() }
  return withUnsafeMutablePointer(to: &value) {
    StreamFrame(storage: UnsafeMutableRawPointer($0), schema: T.streamSchema)
  }
}

@inlinable
public func _streamEnterObject<T: StreamParseableObject>(_ value: inout T) -> StreamFrame {
  withUnsafeMutablePointer(to: &value) {
    StreamFrame(storage: UnsafeMutableRawPointer($0), schema: T.streamSchema)
  }
}

// A wrapper with one stored property stores it at offset zero, so the wrapped type's schema can
// be applied to a pointer to the wrapper. Same class of assumption as the optional payload
// access above, which is why it lives here. The size check is a debug build tripwire for a
// wrapper that turns out to carry something else.
@inlinable
public func _streamWrapperSchema<Wrapper, Wrapped: StreamParseableRoot>(
  _ wrapper: Wrapper.Type,
  wrapping wrapped: Wrapped.Type
) -> StreamSchema {
  assert(MemoryLayout<Wrapper>.size == MemoryLayout<Wrapped>.size)
  return Wrapped.streamSchema
}

@inlinable
public func _streamEnterOptionalContainer<T>(
  _ value: inout T?,
  initial: @autoclosure () -> T,
  schema: StreamSchema
) -> StreamFrame {
  if value == nil { value = initial() }
  return withUnsafeMutablePointer(to: &value) {
    StreamFrame(storage: UnsafeMutableRawPointer($0), schema: schema)
  }
}

@inlinable
public func _streamEnterContainer<T>(_ value: inout T, schema: StreamSchema) -> StreamFrame {
  withUnsafeMutablePointer(to: &value) {
    StreamFrame(storage: UnsafeMutableRawPointer($0), schema: schema)
  }
}

// Appends an element and returns a frame for it. The element pointer is only used while this
// element is the innermost open container, so no append can move the buffer under it.
@inlinable
public func _streamAppendElement<Element>(
  to array: inout [Element],
  initial: @autoclosure () -> Element,
  schema: StreamSchema
) -> StreamFrame {
  array.append(initial())
  let index = array.count - 1
  return array.withUnsafeMutableBufferPointer {
    StreamFrame(storage: UnsafeMutableRawPointer($0.baseAddress! + index), schema: schema)
  }
}

@inlinable
public func _streamAppendElement<Element>(
  toOptional array: inout [Element]?,
  initial: @autoclosure () -> Element,
  schema: StreamSchema
) -> StreamFrame {
  if array == nil { array = [] }
  return _streamAppendElement(to: &array!, initial: initial(), schema: schema)
}

@inlinable
public func _streamEnterDictionaryValue<Value>(
  _ dictionary: inout StreamDictionary<Value>,
  key: Span<UInt8>,
  initial: @autoclosure () -> Value,
  schema: StreamSchema
) -> StreamFrame {
  let slot = dictionary._slot(forKey: key, initial: initial())
  return dictionary._withValueStorage(at: slot) {
    StreamFrame(storage: $0, schema: schema)
  }
}

@inlinable
public func _streamEnterDictionaryValue<Value>(
  optional dictionary: inout StreamDictionary<Value>?,
  key: Span<UInt8>,
  initial: @autoclosure () -> Value,
  schema: StreamSchema
) -> StreamFrame {
  if dictionary == nil { dictionary = StreamDictionary<Value>() }
  return _streamEnterDictionaryValue(
    &dictionary!, key: key, initial: initial(), schema: schema
  )
}
