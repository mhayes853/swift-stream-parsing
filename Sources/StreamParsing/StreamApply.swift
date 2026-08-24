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

// Each returns whether it applied the token. The unconstrained overload returning false is what
// turns "this field cannot hold a string" into a reportable type mismatch instead of silence.

@inlinable
@inline(__always)
public func streamApply<T: StreamStringConvertible>(
  _ value: inout T, utf8 bytes: Span<UInt8>
) -> Bool {
  value.streamAppend(utf8: bytes)
  return true
}

@inlinable
@inline(__always)
public func streamApply(
  _ value: inout StreamString, utf8 bytes: Span<UInt8>, initialCapacity: Int
) -> Bool {
  if bytes.isEmpty { value.streamReserve(utf8ByteCount: initialCapacity) }
  value.streamAppend(utf8: bytes)
  return true
}

@_disfavoredOverload
@inlinable
@inline(__always)
public func streamApply<T>(
  _ value: inout T, utf8 bytes: Span<UInt8>, initialCapacity: Int
) -> Bool { false }

@_disfavoredOverload
@inlinable
@inline(__always)
public func streamApply<T>(_ value: inout T, utf8 bytes: Span<UInt8>) -> Bool { false }

@inlinable
@inline(__always)
public func streamApply<T: StreamNumberConvertible>(
  _ value: inout T, bytes: Span<UInt8>, info: NumberInfo
) -> Bool {
  guard let parsed = T(streamParsing: bytes, info: info) else { return false }
  value = parsed
  return true
}

@_disfavoredOverload
@inlinable
@inline(__always)
public func streamApply<T>(_ value: inout T, bytes: Span<UInt8>, info: NumberInfo) -> Bool {
  false
}

@inlinable
@inline(__always)
public func streamApply<T: StreamBooleanConvertible>(_ value: inout T, boolean: Bool) -> Bool {
  value = T(streamParsingBoolean: boolean)
  return true
}

@_disfavoredOverload
@inlinable
@inline(__always)
public func streamApply<T>(_ value: inout T, boolean: Bool) -> Bool { false }

@inlinable
@inline(__always)
public func streamApplyNull<T: StreamNullable>(_ value: inout T) -> Bool {
  value = T.streamNullValue()
  return true
}

@_disfavoredOverload
@inlinable
@inline(__always)
public func streamApplyNull<T>(_ value: inout T) -> Bool { false }
