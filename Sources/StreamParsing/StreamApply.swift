import StreamParsingCore

// Bridging shims for macro generated code.
//
// A macro sees only the syntax of a property's type and cannot know whether `String` accepts
// string content or `Int` accepts numeric content. The constrained overload does the work, the
// unconstrained one does nothing, and Swift ranks the constrained one higher, so generated code
// can emit a field into every apply switch and let overload resolution decide.
//
// Dead combinations optimize away entirely: a 100 field struct emitting every field into every
// switch produced byte identical code to one emitting only the matching fields.
//
// These live here rather than in the core because nothing in the core needs them. The parser
// only speaks to sinks.

// Each reports what it did with the token. The unconstrained overload returning `.unsupported` is
// what turns "this field cannot hold a string" into a reportable type mismatch instead of silence.
// A constrained overload forwards its destination's own answer, which is how an inline string's
// capacity failure reaches the sink as a capacity failure rather than a mismatch.

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
