// These reinterpret a pointer to an `Optional` as a pointer to its payload, relying on
// single-payload enums storing the payload at offset zero: an implementation detail, so it lives
// here only, and the nested partial sink tests fail rather than corrupt if it changes.
// `MemoryLayout.offset(of:)` needs a key path, which Embedded rejects. Macro-generated code only.

// The payload's address, or nil before the member is written. Returns an address, not the view:
// a generic function returning `Optional<T.View>` crashes PredictableDeadAllocationElimination on
// Swift 6.3, so the view is formed in the caller where its type is concrete (at the price of an
// `_overrideLifetime`, since raw pointers carry no provenance for `@_lifetime`).
@inlinable
public func _streamMemberAddress<T: StreamPartial>(
  _ value: UnsafeMutablePointer<T?>
) -> UnsafeMutableRawPointer? {
  value.pointee == nil ? nil : UnsafeMutableRawPointer(value)
}

// The initialized members mode gives non-optional members, which are always present.
@inlinable
public func _streamMemberAddress<T: StreamPartial>(
  _ value: UnsafeMutablePointer<T>
) -> UnsafeMutableRawPointer? {
  UnsafeMutableRawPointer(value)
}

// Conformed to by `Optional` alone, so a schema builder can ask once, while it builds, whether a
// slot's type is itself optional -- the one case where an opened slot can still be `nil` one level
// down. Never asked per token.
@usableFromInline
protocol _StreamOptionalMarker {}

extension Optional: _StreamOptionalMarker {}

// Materializes an optional in place so the wrapped type's schema applies to the same address.
@inlinable
public func _streamMaterializeOptional<Wrapped: StreamInitializable>(
  _ storage: UnsafeMutableRawPointer,
  as wrapped: Wrapped.Type
) {
  let pointer = storage.assumingMemoryBound(to: Wrapped?.self)
  // Initialized over, not assigned: `nil` owns nothing, and assigning destroyed it out of line for
  // every member opened.
  if pointer.pointee == nil { pointer.initialize(to: Wrapped.streamInitialValue()) }
}

// A single-property wrapper stores it at offset zero, so the wrapped schema applies to the
// wrapper's address; the same class of assumption as above. The size check is a debug tripwire.
@inlinable
public func _streamWrapperSchema<Wrapper, Wrapped: StreamPartial>(
  _ wrapper: Wrapper.Type,
  wrapping wrapped: Wrapped.Type
) -> StreamSchema {
  assert(MemoryLayout<Wrapper>.size == MemoryLayout<Wrapped>.size)
  return Wrapped.streamSchema
}
