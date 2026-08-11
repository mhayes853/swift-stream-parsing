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

@inlinable
@inline(__always)
public func streamApply<T: StreamStringConvertible>(_ value: inout T, utf8 bytes: Span<UInt8>) {
  value.streamAppend(utf8: bytes)
}

@inlinable
@inline(__always)
public func streamApply<T>(_ value: inout T, utf8 bytes: Span<UInt8>) {}

@inlinable
@inline(__always)
public func streamApply<T: StreamNumberConvertible>(
  _ value: inout T, bytes: Span<UInt8>, info: NumberInfo
) {
  if let parsed = T(streamParsing: bytes, info: info) { value = parsed }
}

@inlinable
@inline(__always)
public func streamApply<T>(_ value: inout T, bytes: Span<UInt8>, info: NumberInfo) {}

@inlinable
@inline(__always)
public func streamApply<T: StreamBooleanConvertible>(_ value: inout T, boolean: Bool) {
  value = T(streamParsingBoolean: boolean)
}

@inlinable
@inline(__always)
public func streamApply<T>(_ value: inout T, boolean: Bool) {}

@inlinable
@inline(__always)
public func streamApplyNull<T: StreamNullable>(_ value: inout T) {
  value = T.streamNullValue()
}

@inlinable
@inline(__always)
public func streamApplyNull<T>(_ value: inout T) {}
