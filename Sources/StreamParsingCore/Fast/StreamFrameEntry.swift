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

// Both take the schema rather than reading `T.streamSchema`, so the frame borrows a schema the
// parent already owns. Reading it here built one per occurrence for every conformance whose
// `streamSchema` is computed rather than stored, and the frame was its only owner.
@inlinable
public func _streamEnterOptionalObject<T: StreamParseableObject>(
  _ value: inout T?,
  schema: StreamSchema
) -> StreamFrame {
  if value == nil { value = T.streamInitialValue() }
  return withUnsafeMutablePointer(to: &value) {
    StreamFrame(storage: UnsafeMutableRawPointer($0), schema: schema)
  }
}

@inlinable
public func _streamEnterObject<T: StreamParseableObject>(
  _ value: inout T,
  schema: StreamSchema
) -> StreamFrame {
  withUnsafeMutablePointer(to: &value) {
    StreamFrame(storage: UnsafeMutableRawPointer($0), schema: schema)
  }
}

// A view over an optional member, or nil when the member has not been written yet.
//
// The same shape works for every member the macro emits, which is what lets it stay ignorant of
// which ones are objects: a scalar's view is the scalar, so this reads it, while a nested object's
// view is a projection, so this defers. Relies on the offset zero payload layout, like the entry
// helpers above.
@inlinable
public func _streamMemberView<T: StreamParseableRoot>(
  _ value: UnsafeMutablePointer<T?>
) -> T.View? {
  guard value.pointee != nil else { return nil }
  return T.streamView(UnsafeMutableRawPointer(value))
}

// The initialized members mode gives non-optional members, which are always present.
@inlinable
public func _streamMemberView<T: StreamParseableRoot>(
  _ value: UnsafeMutablePointer<T>
) -> T.View? {
  T.streamView(UnsafeMutableRawPointer(value))
}

// Materializes an optional in place so the wrapped type's schema can be applied to the same
// address. Relies on the same offset zero payload layout as the entry helpers above.
@inlinable
public func _streamMaterializeOptional<Wrapped: StreamInitializable>(
  _ storage: UnsafeMutableRawPointer,
  as wrapped: Wrapped.Type
) {
  let pointer = storage.assumingMemoryBound(to: Wrapped?.self)
  if pointer.pointee == nil { pointer.pointee = Wrapped.streamInitialValue() }
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

// Opens an element and returns a frame for it. The frame points at the array's inline pending
// slot, whose address is fixed for the lifetime of the array, so no append at any depth can move
// it. The slot holds one element at a time, which is what makes it a requirement that no write
// straddle a commit: a pointer kept past the next `_openElement` reaches a different element.
@inlinable
public func _streamOpenElement<Element>(
  in array: inout StreamArray<Element>,
  initial: @autoclosure () -> Element,
  schema: StreamSchema
) -> StreamFrame {
  StreamFrame(storage: array._openElement(initial()), schema: schema)
}

@inlinable
public func _streamOpenElement<Element>(
  inOptional array: inout StreamArray<Element>?,
  initial: @autoclosure () -> Element,
  schema: StreamSchema
) -> StreamFrame {
  if array == nil { array = StreamArray<Element>() }
  return _streamOpenElement(in: &array!, initial: initial(), schema: schema)
}

@inlinable
public func _streamEnterDictionaryValue<Value>(
  _ dictionary: inout StreamDictionary<Value>,
  key: Span<UInt8>,
  initial: @autoclosure () -> Value,
  schema: StreamSchema
) -> StreamFrame {
  StreamFrame(
    storage: dictionary._openValue(forKey: key, initial: initial()), schema: schema
  )
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
