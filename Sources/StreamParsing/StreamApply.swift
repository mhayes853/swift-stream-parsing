import StreamParsingCore

// Bridging shims for macro generated code. A macro sees only a property type's syntax, so the
// constrained overload does the work, the unconstrained one nothing, and generated code emits
// every field into every apply switch. Dead combinations optimize away: a 100-field struct
// compiled byte-identical to one emitting only the matching fields.

// Each reports what it did: the unconstrained `.unsupported` turns "cannot hold a string" into a
// type mismatch, and a constrained overload forwards its destination's answer, so an inline
// string's overflow reaches the sink as a capacity failure.

@inlinable
@inline(__always)
public func streamApply<T: StreamStringConvertible>(
  _ value: inout T, utf8 bytes: Span<UInt8>
) -> StreamApplyResult {
  value.streamAppend(utf8: bytes)
}

@inlinable
@inline(__always)
public func streamApply(
  _ value: inout StreamString, utf8 bytes: Span<UInt8>, initialCapacity: Int
) -> StreamApplyResult {
  if bytes.isEmpty { value.streamReserve(utf8ByteCount: initialCapacity) }
  return value.streamAppend(utf8: bytes)
}

@_disfavoredOverload
@inlinable
@inline(__always)
public func streamApply<T>(
  _ value: inout T, utf8 bytes: Span<UInt8>, initialCapacity: Int
) -> StreamApplyResult { .unsupported }

@_disfavoredOverload
@inlinable
@inline(__always)
public func streamApply<T>(_ value: inout T, utf8 bytes: Span<UInt8>) -> StreamApplyResult {
  .unsupported
}

@inlinable
@inline(__always)
public func streamApply<T: StreamNumberConvertible>(
  _ value: inout T, bytes: Span<UInt8>, info: NumberInfo
) -> StreamApplyResult {
  guard let parsed = T(streamParsing: bytes, info: info) else { return .unsupported }
  value = parsed
  return .applied
}

@_disfavoredOverload
@inlinable
@inline(__always)
public func streamApply<T>(
  _ value: inout T, bytes: Span<UInt8>, info: NumberInfo
) -> StreamApplyResult {
  .unsupported
}

@inlinable
@inline(__always)
public func streamApply<T: StreamBooleanConvertible>(
  _ value: inout T, boolean: Bool
) -> StreamApplyResult {
  value = T(streamParsingBoolean: boolean)
  return .applied
}

@_disfavoredOverload
@inlinable
@inline(__always)
public func streamApply<T>(_ value: inout T, boolean: Bool) -> StreamApplyResult { .unsupported }

@inlinable
@inline(__always)
public func streamApplyNull<T: StreamNullable>(_ value: inout T) -> StreamApplyResult {
  value = T.streamNullValue()
  return .applied
}

@_disfavoredOverload
@inlinable
@inline(__always)
public func streamApplyNull<T>(_ value: inout T) -> StreamApplyResult { .unsupported }
