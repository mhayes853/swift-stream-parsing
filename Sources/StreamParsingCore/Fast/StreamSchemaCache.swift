// Template ownership and the per-type schema cache. A container schema copies each new element
// from a template it allocated once; leaking it is only correct for an immortal schema, which
// `StreamArray.streamSchema` (a computed property) is not, so `_StreamTemplateStorage` ties the
// template to the schema while closures capture only the raw pointer. The accessors stay
// `@inlinable` so `build` specialises in the client module (GSoC +10%); only the probe is not.

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

// MARK: - Per-type schema cache

#if hasFeature(Embedded)
  /// Embedded Swift has no metatype identity to key on, so the build is not cached there. The
  /// template is still owned, so nothing leaks. The generic metatype avoids forming `Any.Type`.
  @inlinable
  public func _streamCachedSchema<T>(
    for type: T.Type,
    build: () -> StreamSchema
  ) -> StreamSchema {
    build()
  }
#else
  /// Returns the process-wide schema for `type`, building it on first ask.
  ///
  /// Not `@inlinable`: the lock and the dictionary stay in this module. `build` is still formed at
  /// the call site with its generic parameters concrete, so the schema is the specialised one.
  public func _streamCachedSchema(
    for type: Any.Type,
    build: () -> StreamSchema
  ) -> StreamSchema {
    let key = ObjectIdentifier(type)
    if let cached = _streamSchemaCache.value(for: key) { return cached }
    // Built outside the lock: `build` re-enters here for a nested container root's element schema,
    // and a non-recursive lock would deadlock. A race builds twice; the first insert wins.
    let built = build()
    return _streamSchemaCache.insert(built, for: key)
  }

  final class _StreamSchemaCache: @unchecked Sendable {
    private let storage = _StreamLock<[ObjectIdentifier: StreamSchema]>([:])

    func value(for key: ObjectIdentifier) -> StreamSchema? {
      self.storage.withLock { $0[key] }
    }

    func insert(_ schema: StreamSchema, for key: ObjectIdentifier) -> StreamSchema {
      self.storage.withLock { storage in
        if let existing = storage[key] { return existing }
        storage[key] = schema
        return schema
      }
    }
  }

  let _streamSchemaCache = _StreamSchemaCache()
#endif

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
