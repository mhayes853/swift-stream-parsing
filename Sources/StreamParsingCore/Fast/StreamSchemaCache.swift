// Template ownership and the per-type schema cache.
//
// Two problems live here, and they are the same problem seen from either end.
//
// A container schema copies each new element from a template it allocated once (see
// `_streamArraySchema`). That template used to be leaked outright, which is correct exactly when
// the schema that captures it is itself immortal -- true for a macro-generated `static let`
// schema, false for a schema built by `StreamArray.streamSchema`, which is a *computed* property
// because a generic type cannot hold a stored static. A stream rooted at a container therefore
// leaked one template per `PartialsStream.init`. `_StreamTemplateStorage` ties the template to
// the schema that captures it: the schema holds the box, the box's `deinit` destroys and frees
// the memory, and the closures still capture nothing but the raw pointer, so the hot path is
// unchanged (no retain/release per element).
//
// The other end is that rebuilding the schema per init is waste in its own right -- a field
// table, a handful of closure contexts and a template allocation for a stream that may parse a
// 200 byte payload. `_streamCachedSchema(for:build:)` builds one per element type per process and
// hands the same object back afterwards, which also restores "one template per type per process"
// for container roots. The accessors stay `@inlinable` so the `build` closure is still emitted in
// the client module with the element type concrete, which is what keeps `_openElement` /
// `_openValue` specialised (measured +10% on GSoC); only the cache probe is non-inlinable.

/// Owns a template value for the lifetime of the schema that copies elements from it.
///
/// The pointer is handed to the schema's closures as a bare `UnsafePointer`, deliberately: a
/// captured class reference would be a load plus, in some closure shapes, a retain/release per
/// element. The schema outlives every parse that borrows it (`PartialSink` holds schemas
/// `unowned(unsafe)`), so the box's lifetime is a strictly wider bound than the pointer's use.
public final class _StreamTemplateStorage: @unchecked Sendable {
  @usableFromInline let pointer: UnsafeMutableRawPointer
  // Type-erased `deinitialize(count: 1)` + `deallocate` for the element type. A closure rather
  // than a generic parameter on the class, so the schema can hold one field of one type.
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
/// Replaces `_streamLeakedTemplate` in the container builders. The value is built once here
/// rather than inside the element closure, because a generic element's `Self()` re-enters the
/// runtime's locking metadata cache per open and returning it by value is a second whole-element
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
  /// Embedded Swift has no metatype identity to key on (and a single-threaded target has nothing
  /// to lock), so the build is not cached there. The template is still owned, so nothing leaks.
  @inlinable
  public func _streamCachedSchema(
    for type: Any.Type,
    build: () -> StreamSchema
  ) -> StreamSchema {
    build()
  }
#else
  /// Returns the process-wide schema for `type`, building it on first ask.
  ///
  /// Not `@inlinable`: the lock and the dictionary stay in this module. The caller's `build`
  /// closure is still formed at the call site with its generic parameters concrete, so the schema
  /// it builds is the specialised one.
  public func _streamCachedSchema(
    for type: Any.Type,
    build: () -> StreamSchema
  ) -> StreamSchema {
    let key = ObjectIdentifier(type)
    if let cached = _streamSchemaCache.value(for: key) { return cached }
    // Built outside the lock: `build` re-enters this function for the element schema of a nested
    // container root (`StreamArray<StreamArray<Int>>`), and a non-recursive lock would deadlock.
    // A race builds twice and one of the two is discarded; the survivor is whichever landed
    // first, so identity stays stable for everyone afterwards.
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
  // Test-only accounting for template lifetimes: `StreamSchemaLifetimeTests` asserts that
  // building and destroying a container-rooted stream N times does not grow the live count.
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
