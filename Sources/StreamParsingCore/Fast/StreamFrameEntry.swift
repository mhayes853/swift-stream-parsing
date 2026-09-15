// These reinterpret a pointer to an `Optional` as a pointer to its payload, relying on
// single-payload enums storing the payload at offset zero. That is an implementation detail, not a
// guarantee, so it lives here and nowhere else; the nested object/array partial sink tests would
// fail rather than corrupt values if a toolchain changed optional layout. (`MemoryLayout.offset(of:)`
// is not an option: it needs a key path, and Embedded Swift rejects key paths.) Underscored because
// only macro-generated code calls these.

// The address of an optional member's payload, or nil when the member has not been written yet.
// A macro-generated accessor turns it into a view with `T.streamView(address)`.
//
// Must return an address, not the view: a generic function returning `Optional<T.View>` (an opaque
// `~Escapable` behind an associated type) crashes PredictableDeadAllocationElimination on Swift
// 6.3. A raw pointer is escapable, so the ~Escapable value is formed in the caller where its type
// is concrete. The caller pays with an `_overrideLifetime`, because raw pointers carry no
// provenance for the borrow checker to chain `@_lifetime(borrow storage)` through two hops.
@inlinable
public func _streamMemberAddress<T: StreamParseableRoot>(
  _ value: UnsafeMutablePointer<T?>
) -> UnsafeMutableRawPointer? {
  value.pointee == nil ? nil : UnsafeMutableRawPointer(value)
}

// The initialized members mode gives non-optional members, which are always present.
@inlinable
public func _streamMemberAddress<T: StreamParseableRoot>(
  _ value: UnsafeMutablePointer<T>
) -> UnsafeMutableRawPointer? {
  UnsafeMutableRawPointer(value)
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
