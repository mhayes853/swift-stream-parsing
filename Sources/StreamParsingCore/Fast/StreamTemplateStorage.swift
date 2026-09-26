// Template ownership. A container schema copies each new element from a template it allocated
// once; leaking it is only correct for an immortal schema, which a cached schema is not (a
// `StreamSchemaCache` entry can be removed), so `_StreamTemplateStorage` ties the template to the
// schema while closures capture only the raw pointer.

/// Owns a template value for the lifetime of the schema that copies elements from it.
///
/// Handed to the schema's closures as a bare `UnsafePointer`: a captured class reference would be
/// a load and, in some closure shapes, a retain/release per element. The schema outlives every
/// parse that borrows it (`PartialSink` holds schemas `unowned(unsafe)`).
public final class _StreamTemplateStorage: @unchecked Sendable {
  @usableFromInline let pointer: UnsafeMutableRawPointer
  // Type-erased destroy and deallocate: a closure rather than a generic parameter on the class.
  @usableFromInline let destroy: @Sendable (UnsafeMutableRawPointer) -> Void

  @usableFromInline
  init(
    pointer: UnsafeMutableRawPointer,
    destroy: @escaping @Sendable (UnsafeMutableRawPointer) -> Void
  ) {
    self.pointer = pointer
    self.destroy = destroy
    #if DEBUG && !hasFeature(Embedded)
      _streamTemplateCounters.opened()
    #endif
  }

  deinit {
    self.destroy(self.pointer)
    #if DEBUG && !hasFeature(Embedded)
      _streamTemplateCounters.closed()
    #endif
  }
}

/// Allocates a template value at a stable address, owned by the returned box.
///
/// Built once here rather than in the element closure: a generic element's `Self()` re-enters the
/// runtime's locking metadata cache per open, and returning it by value is a second whole-element
/// copy.
@inlinable
public func _streamOwnedTemplate<T>(_ value: T) -> _StreamTemplateStorage {
  let template = UnsafeMutablePointer<T>.allocate(capacity: 1)
  template.initialize(to: value)
  return _StreamTemplateStorage(pointer: UnsafeMutableRawPointer(template)) { raw in
    let typed = raw.assumingMemoryBound(to: T.self)
    typed.deinitialize(count: 1)
    typed.deallocate()
  }
}

extension _StreamTemplateStorage {
  /// The template, typed. The builders bind this to a local and capture *that*, never `self`.
  @inlinable
  public func address<T>(as type: T.Type) -> UnsafePointer<T> {
    UnsafePointer(self.pointer.assumingMemoryBound(to: T.self))
  }
}

#if DEBUG && !hasFeature(Embedded)
  // Test-only: `StreamSchemaLifetimeTests` asserts repeated streams do not grow the live count.
  final class _StreamTemplateCounters: @unchecked Sendable {
    private let counts = _StreamLock((live: 0, total: 0))

    func opened() {
      self.counts.withLock {
        $0.live += 1
        $0.total += 1
      }
    }
    func closed() { self.counts.withLock { $0.live -= 1 } }
    var value: (live: Int, total: Int) { self.counts.withLock { $0 } }
  }

  let _streamTemplateCounters = _StreamTemplateCounters()

  /// Templates currently allocated, and templates allocated since process start. Debug only.
  public var _streamTemplateStorageCounts: (live: Int, total: Int) { _streamTemplateCounters.value }
#endif
