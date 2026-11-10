/// Copy-initialises `slot` from `template`: one `initializeWithCopy` and nothing else.
///
/// Measured: `initialize(from:count:)` is `swift_arrayInitWithCopy`, a runtime detour worth 7% on
/// CITM's small elements; `initialize(to:)` stages anything loadable on the stack. Past a few
/// refcounted fields that staging is two bitwise copies (template to a temporary, template to the
/// slot) *plus* the value witness's copy of the temporary into a second, dead one -- which is how
/// the retains get done -- so it already pays the witness call the runtime path makes, and the
/// copies on top of it. Measured: 1024 -> 128 bytes is GitHub/GSoC/Qwen structured +4%, Twitter
/// full +3%; 128 -> 48 costs CITM 4% (its 60-92 byte elements prefer the staged copy), so the
/// split stays. The threshold folds per type.
@inlinable
@inline(__always)
public func _streamCopyInitialize<T>(_ slot: UnsafeMutablePointer<T>, from template: UnsafePointer<T>) {
  if MemoryLayout<T>.size > 128 {
    slot.initialize(from: template, count: 1)
  } else {
    slot.initialize(to: template.pointee)
  }
}

/// Copy-initialises `.some` over a slot holding `nil`, from a template that is `.some`: the payload
/// through the payload's own copy, then the tag bytes behind it, if the payload has no spare bits
/// to keep the case in. Copying the `Optional` whole goes through `Optional`'s generic witness,
/// which asks the payload's metadata for the case before reaching the same payload copy. Relies on
/// the payload sitting at offset zero, as `_streamMaterializeOptional` does.
@inlinable
@inline(__always)
public func _streamCopyInitializeSome<T>(
  _ slot: UnsafeMutablePointer<T?>, from template: UnsafePointer<T?>
) {
  let raw = UnsafeMutableRawPointer(slot)
  let source = UnsafeRawPointer(template)
  _streamCopyInitialize(raw.assumingMemoryBound(to: T.self), from: source.assumingMemoryBound(to: T.self))
  // Zero for a payload with extra inhabitants: writing it made the optional `.some`.
  let tagBytes = MemoryLayout<T?>.size &- MemoryLayout<T>.size
  if tagBytes > 0 {
    (raw + MemoryLayout<T>.size).copyMemory(from: source + MemoryLayout<T>.size, byteCount: tagBytes)
  }
}
