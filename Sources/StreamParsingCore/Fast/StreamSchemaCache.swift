// Schemas are built once per type and usage and then shared: `PartialsStream.init` reads
// `streamSchema`, and so does every parent schema build, and a generic type cannot hold its schema
// in a stored static. The read is the only per-stream cost; nothing reads a schema per token.
//
// Each type and usage has one `Entry`. A concrete type keeps its entry in a `static let`, so its
// read is a lock round trip and a load. Reading it by type instead also hashes the key and probes
// the table: 85 ns a stream over a `static let` on the flat-struct model, 5-10% of a 120-byte
// document, where the entry read measures level with the `static let` (`Setup` rows). One lock
// guards every cache's table and every entry, so an entry needs no reference back to its cache;
// each holds the lock itself, because reaching the global costs a `swift_once` call per read.

#if hasFeature(Embedded)
  import Synchronization
#endif

/// Built schemas, keyed by the type each one describes and the ``StreamSchema/Usage`` it serves.
///
/// A conformance chooses its cache in its own schema requirement; the parser never looks one up.
/// `@StreamParseable` uses ``shared`` unless its `schemaCache:` argument names another instance.
/// A generic type reads its schema by type; a concrete type can keep its ``Entry`` in a
/// `static let`, which skips the lookup:
///
/// ```swift
/// extension Pair: StreamParseableRoot where A: StreamParseableRoot, B: StreamParseableRoot {
///   static var streamSchema: StreamSchema {
///     StreamSchemaCache.shared.schema(for: Self.self) {
///       StreamSchema(shape: .object, ...)
///     }
///   }
/// }
///
/// extension Point: StreamParseableRoot {
///   private static let schemaEntry = StreamSchemaCache.shared.entry(for: Self.self)
///   static var streamSchema: StreamSchema {
///     Self.schemaEntry.schema { StreamSchema(shape: .object, ...) }
///   }
/// }
/// ```
///
/// Pass `Self.self`. The key is the only thing tying a schema to the layout its closures write
/// through, so a schema cached under another type's key is applied to storage it does not describe.
///
/// Every schema a parse uses is owned by that parse: the stream holds its root schema, and each
/// schema holds its children. Removing an entry's schema therefore never affects a stream in
/// flight; the next read builds a fresh one. It also frees nothing that a cached parent still
/// holds, so ``removeAll()`` is what releases a family of related schemas.
///
/// Embedded Swift has no metatype identity to key on. There a read by type builds every time, an
/// ``Entry`` still keeps what it builds, and removal does nothing.
public final class StreamSchemaCache: @unchecked Sendable {
  /// The process-wide cache, used by `@StreamParseable` and the library's own conformances.
  public static let shared = StreamSchemaCache()

  #if !hasFeature(Embedded)
    @usableFromInline
    struct Key: Hashable, Sendable {
      let type: ObjectIdentifier
      let usage: StreamSchema.Usage

      @usableFromInline
      init(type: ObjectIdentifier, usage: StreamSchema.Usage) {
        self.type = type
        self.usage = usage
      }
    }

    // Guarded by `lock`. Entries are never removed, only emptied: a `static let` may hold one, and
    // a second entry for the same key would cache beside it, unseen by `count` and `removeAll()`.
    private var entries: [Key: Entry] = [:]
    // `_streamSchemaCacheLock`, held so a read does not call `swift_once` to reach the global.
    private let lock = _streamSchemaCacheLock
  #endif

  /// Creates an empty cache.
  public init() {}

  /// The schema cached for `type` in `usage`, building and storing it with `build` if there is none.
  ///
  /// `build` runs outside the cache's lock, because a schema build reads its members' schemas,
  /// which may be cached here too. Two threads that miss at once both build, and the first to
  /// finish is the one every caller gets. So `build` may run more than once -- and on Embedded
  /// Swift it runs on every call -- and must have no side effects. It must not read the schema
  /// it is building.
  ///
  /// Only the lookup is out of line: `build` is formed at the call site, where its generic
  /// parameters are concrete, so the schema it builds is specialised.
  @inlinable
  public func schema<T: StreamParseableRoot>(
    for type: T.Type,
    usage: StreamSchema.Usage = .root,
    build: () -> StreamSchema
  ) -> StreamSchema {
    #if hasFeature(Embedded)
      build()
    #else
      self.schema(for: Key(type: ObjectIdentifier(type), usage: usage), build: build)
    #endif
  }

  /// The entry holding `type`'s schema for `usage`, for a concrete type to keep in a `static let`.
  ///
  /// Reading through the entry skips the lookup by type; the entry is still this cache's, so
  /// ``count``, ``contains(_:usage:)`` and removal see what it holds.
  public func entry<T: StreamParseableRoot>(
    for type: T.Type,
    usage: StreamSchema.Usage = .root
  ) -> Entry {
    #if hasFeature(Embedded)
      Entry()
    #else
      let key = Key(type: ObjectIdentifier(type), usage: usage)
      return self.lock.withLock { _ in self.entry(for: key) }
    #endif
  }

  /// Whether a schema is cached for `type` in `usage`.
  public func contains<T: StreamParseableRoot>(
    _ type: T.Type,
    usage: StreamSchema.Usage = .root
  ) -> Bool {
    #if hasFeature(Embedded)
      false
    #else
      let key = Key(type: ObjectIdentifier(type), usage: usage)
      return self.lock.withLock { _ in self.entries[key]?.schema != nil }
    #endif
  }

  /// Removes the schema cached for `type` in `usage`, returning it.
  ///
  /// A stream already running keeps its schemas; the next read builds a fresh one.
  @discardableResult
  public func removeSchema<T: StreamParseableRoot>(
    for type: T.Type,
    usage: StreamSchema.Usage = .root
  ) -> StreamSchema? {
    #if hasFeature(Embedded)
      nil
    #else
      let key = Key(type: ObjectIdentifier(type), usage: usage)
      return self.lock.withLock { _ in
        guard let entry = self.entries[key] else { return nil }
        defer { entry.schema = nil }
        return entry.schema
      }
    #endif
  }

  /// Removes every cached schema. Streams already running keep theirs.
  public func removeAll() {
    #if !hasFeature(Embedded)
      // Released after the lock is dropped: a schema's deinit runs its children's and templates'.
      _ = self.lock.withLock { _ in
        var removed: [StreamSchema] = []
        for entry in self.entries.values {
          if let schema = entry.schema { removed.append(schema) }
          entry.schema = nil
        }
        return removed
      }
    #endif
  }

  /// The number of cached schemas.
  public var count: Int {
    #if hasFeature(Embedded)
      0
    #else
      self.lock.withLock { _ in
        self.entries.values.reduce(0) { $0 + ($1.schema == nil ? 0 : 1) }
      }
    #endif
  }

  #if !hasFeature(Embedded)
    // Caller holds the lock.
    private func entry(for key: Key) -> Entry {
      if let entry = self.entries[key] { return entry }
      let entry = Entry()
      self.entries[key] = entry
      return entry
    }

    // A hit touches only the schema: handing the entry out too cost a retain and release, 50 ns a
    // read on `StreamArray<Int>`.
    @usableFromInline
    func schema(for key: Key, build: () -> StreamSchema) -> StreamSchema {
      if let cached = self.lock.withLock({ _ in self.entries[key]?.schema }) {
        return cached
      }
      let built = build()
      return self.lock.withLock { _ in self.entry(for: key).storeLocked(built) }
    }
  #endif
}

extension StreamSchemaCache {
  /// One type's schema for one usage in a ``StreamSchemaCache``.
  ///
  /// Made by ``StreamSchemaCache/entry(for:usage:)``, for a concrete type to keep in a
  /// `static let`: reading through it costs a lock round trip, where a read by type also hashes.
  public final class Entry: @unchecked Sendable {
    #if hasFeature(Embedded)
      // Published once and never released: removal does nothing on Embedded.
      private let published = Atomic<UnsafeRawPointer?>(nil)
    #else
      // Guarded by `lock`.
      var schema: StreamSchema?
      // See `StreamSchemaCache.lock`.
      private let lock = _streamSchemaCacheLock
    #endif

    init() {}

    /// The schema this entry holds, building and storing it with `build` if there is none.
    ///
    /// The same contract as ``StreamSchemaCache/schema(for:usage:build:)``: `build` may run more
    /// than once, must have no side effects, and must not read the schema it is building.
    public func schema(build: () -> StreamSchema) -> StreamSchema {
      #if hasFeature(Embedded)
        if let pointer = self.published.load(ordering: .acquiring) {
          return Unmanaged<StreamSchema>.fromOpaque(pointer).takeUnretainedValue()
        }
        return self.store(build())
      #else
        if let cached = self.lock.withLock({ _ in self.schema }) { return cached }
        return self.store(build())
      #endif
    }

    // The first schema stored wins; a racing build's is dropped.
    func store(_ built: StreamSchema) -> StreamSchema {
      #if hasFeature(Embedded)
        let retained = UnsafeRawPointer(Unmanaged.passRetained(built).toOpaque())
        let (exchanged, original) = self.published.compareExchange(
          expected: nil, desired: retained, ordering: .acquiringAndReleasing
        )
        if exchanged { return built }
        Unmanaged<StreamSchema>.fromOpaque(retained).release()
        return Unmanaged<StreamSchema>.fromOpaque(original.unsafelyUnwrapped).takeUnretainedValue()
      #else
        self.lock.withLock { _ in self.storeLocked(built) }
      #endif
    }

    #if !hasFeature(Embedded)
      // Caller holds the lock.
      func storeLocked(_ built: StreamSchema) -> StreamSchema {
        if let existing = self.schema { return existing }
        self.schema = built
        return built
      }
    #endif
  }
}

#if !hasFeature(Embedded)
  // Guards every cache's entries and every entry's schema. Held only to read or swap a reference;
  // builds run outside it.
  let _streamSchemaCacheLock = _StreamLock(())
#endif
