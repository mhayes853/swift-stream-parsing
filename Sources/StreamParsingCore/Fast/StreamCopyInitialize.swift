/// Copy-initialises `slot` from `template`: one `initializeWithCopy` and nothing else.
///
/// Measured: `initialize(from:count:)` is `swift_arrayInitWithCopy`, a runtime detour worth 7% on
/// CITM's small elements; `initialize(to:)` stages anything loadable on the stack. Past a few
/// refcounted fields that staging is two bitwise copies (template to a temporary, template to the
/// slot) *plus* the value witness's copy of the temporary into a second, dead one -- which is how
/// the retains get done -- so it already pays the witness call the runtime path makes, and the
/// copies on top of it. Measured: 1024 -> 128 bytes is GitHub/GSoC/Qwen structured +4%, Twitter
/// full +3%; 128 -> 48 costs CITM 4% (its 60-92 byte elements prefer the staged copy), so the
/// split stays. Between 128 and 1024 bytes the copy is `_streamCopyOut`'s witness call plus one
/// bitwise move, which skips the runtime's checks (Qwen edit/structured, LLM, Twitter +1-2%); past
/// 1024 that move costs more than the checks it saves (Twitter full's 2-11 KB partials -4%), so the
/// runtime path stays there. The thresholds fold per type.
@inlinable
@inline(__always)
public func _streamCopyInitialize<T>(_ slot: UnsafeMutablePointer<T>, from template: UnsafePointer<T>) {
  if MemoryLayout<T>.size > 1024 {
    slot.initialize(from: template, count: 1)
  } else if MemoryLayout<T>.size > 128 {
    #if hasFeature(Embedded)
      // Embedded Swift has no unspecialised generics to call.
      slot.initialize(from: template, count: 1)
    #else
      slot.initialize(to: _streamCopyOut(template))
    #endif
  } else {
    slot.initialize(to: template.pointee)
  }
}

/// `_streamCopyInitialize`'s mid-size case: a tail call into `T`'s `initializeWithCopy` witness, writing
/// the indirect result. The caller then moves it into the slot with one bitwise copy.
///
/// Deliberately unspecialised: specialised, it is the staged copy again, and
/// `initialize(from:count:)` reaches the same witness only through `swift_arrayInitWithCopy`, which
/// asks the metadata for its type descriptor first. It returns rather than writing the slot itself
/// because an unspecialised `slot.initialize(to:)` is a call into the standard library, through a
/// temporary of its own: generic callees are not inlined into unspecialised code.
#if !hasFeature(Embedded)
  @usableFromInline
  @inline(never)
  @_semantics("optimize.sil.specialize.generic.never")
  func _streamCopyOut<T>(_ template: UnsafePointer<T>) -> T {
    template.pointee
  }
#endif

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
