// Entering a nested field needs a pointer to a stored property. The sanctioned way to get one
// is MemoryLayout.offset(of:), which requires a key path, and key paths are rejected outright
// by Embedded Swift. So these reinterpret a pointer to an Optional as a pointer to its payload,
// which relies on single payload enums storing the payload at offset zero.
//
// That is an implementation detail rather than a guarantee, so it lives here and nowhere else,
// and StreamOptionalLayoutTests verifies it holds for the shapes the macro generates. Generated
// code calls these rather than open coding the reinterpretation.

@inlinable
public func streamEnterOptionalObject<T: StreamParseableObject>(_ value: inout T?) -> StreamFrame {
  if value == nil { value = T.streamInitialValue() }
  return withUnsafeMutablePointer(to: &value) {
    StreamFrame(storage: UnsafeMutableRawPointer($0), schema: T.streamSchema)
  }
}

@inlinable
public func streamEnterObject<T: StreamParseableObject>(_ value: inout T) -> StreamFrame {
  withUnsafeMutablePointer(to: &value) {
    StreamFrame(storage: UnsafeMutableRawPointer($0), schema: T.streamSchema)
  }
}

@inlinable
public func streamEnterOptionalContainer<T>(
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
public func streamEnterContainer<T>(_ value: inout T, schema: StreamSchema) -> StreamFrame {
  withUnsafeMutablePointer(to: &value) {
    StreamFrame(storage: UnsafeMutableRawPointer($0), schema: schema)
  }
}

// Appends an element and returns a frame for it. The element pointer is only used while this
// element is the innermost open container, so no append can move the buffer under it.
@inlinable
public func streamAppendElement<Element>(
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
public func streamAppendElement<Element>(
  toOptional array: inout [Element]?,
  initial: @autoclosure () -> Element,
  schema: StreamSchema
) -> StreamFrame {
  if array == nil { array = [] }
  return streamAppendElement(to: &array!, initial: initial(), schema: schema)
}
