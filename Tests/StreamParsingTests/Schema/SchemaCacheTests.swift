import StreamParsing
import Testing

// `StreamSchemaCache` and `@StreamParseable(schemaCache:)`. Suites run concurrently, so every test
// that counts entries owns its cache, and each generated type below is bound to a cache no other
// test counts.

// MARK: - Declarations

private enum TestSchemaCaches {
  static let generated = StreamSchemaCache()
  static let generic = StreamSchemaCache()
  static let enumPayloads = StreamSchemaCache()
  static let midStream = StreamSchemaCache()
}

fileprivate let fileScopedCache = StreamSchemaCache()

@StreamParseable(schemaCache: TestSchemaCaches.generated)
private struct CachedProfile: Equatable {
  var name: String
  var scores: [Int]
}

@StreamParseable(schemaCache: TestSchemaCaches.generic)
private struct CachedBox<Value: StreamParseable & Equatable>: Equatable {
  var value: Value
}

@StreamParseable(schemaCache: TestSchemaCaches.enumPayloads)
private enum CachedEvent: Equatable {
  case message(text: String)
  @StreamParseableDefault
  case none
}

@StreamParseable(schemaCache: TestSchemaCaches.midStream)
private struct CachedDocument: Equatable {
  var title: String
  var tags: [String]
}

// A leading dot resolves, because the argument is coerced to `StreamSchemaCache` in the `Partial`.
@StreamParseable(schemaCache: .shared)
private struct ExplicitlyShared: Equatable {
  var id: Int
}

// A generated `Partial` may name a cache only its file can see.
@StreamParseable(schemaCache: fileScopedCache)
private struct FileScoped: Equatable {
  var id: Int
}

@StreamParseable
private struct DefaultCached: Equatable {
  var id: Int
}

// Counts builds from a `@Sendable` closure; the tests that use it run on one thread.
private final class BuildCounter: @unchecked Sendable {
  var count = 0
}

// MARK: - Tests

@Suite
struct `Schema Cache Tests` {
  @Test
  func `Builds Once And Returns The Same Schema`() {
    let cache = StreamSchemaCache()
    var builds = 0
    let first = cache.schema(for: Int.self) {
      builds += 1
      return StreamSchema(shape: .scalar)
    }
    let second = cache.schema(for: Int.self) {
      builds += 1
      return StreamSchema(shape: .scalar)
    }
    #expect(first === second)
    #expect(builds == 1)
    #expect(cache.count == 1)
  }

  @Test
  func `Keys By Type And Usage`() {
    let cache = StreamSchemaCache()
    let root = cache.schema(for: Int.self) { StreamSchema(shape: .scalar) }
    let element = cache.schema(for: Int.self, usage: .arrayElement) { StreamSchema(shape: .scalar) }
    let value = cache.schema(for: Int.self, usage: .dictionaryValue) { StreamSchema(shape: .scalar) }
    let other = cache.schema(for: Double.self) { StreamSchema(shape: .scalar) }
    #expect(root !== element)
    #expect(root !== value)
    #expect(element !== value)
    #expect(root !== other)
    #expect(cache.count == 4)
    #expect(cache.contains(Int.self, usage: .arrayElement))
    #expect(!cache.contains(Int.self, usage: .objectMember))
  }

  @Test
  func `Removal Makes The Next Read Build Afresh`() {
    let cache = StreamSchemaCache()
    let first = cache.schema(for: Int.self) { StreamSchema(shape: .scalar) }
    _ = cache.schema(for: Double.self) { StreamSchema(shape: .scalar) }

    #expect(cache.removeSchema(for: Int.self) === first)
    #expect(cache.removeSchema(for: Int.self) == nil)
    #expect(!cache.contains(Int.self))
    #expect(cache.count == 1)
    #expect(cache.schema(for: Int.self) { StreamSchema(shape: .scalar) } !== first)

    cache.removeAll()
    #expect(cache.count == 0)
    #expect(!cache.contains(Double.self))
  }

  @Test
  func `An Entry Owns Its Build`() {
    let cache = StreamSchemaCache()
    let builds = BuildCounter()
    let entry = cache.entry(for: Int.self) {
      builds.count += 1
      return StreamSchema(shape: .scalar)
    }
    #expect(cache.count == 0)
    // The first closure for a key is kept; a later one gets the same entry and is dropped.
    #expect(cache.entry(for: Int.self) { fatalError("the first build is kept") } === entry)
    #expect(cache.entry(for: Int.self, usage: .arrayElement) { StreamSchema(shape: .scalar) } !== entry)

    let first = entry.schema
    #expect(entry.schema === first)
    #expect(builds.count == 1)
    // Read by type or through the entry, it is the same schema.
    #expect(cache.schema(for: Int.self) { fatalError("already cached") } === first)
    #expect(cache.contains(Int.self))
    #expect(cache.count == 1)

    // After removal a read by type rebuilds with the entry's closure, not its own.
    #expect(cache.removeSchema(for: Int.self) === first)
    let rebuilt = cache.schema(for: Int.self) { fatalError("the entry's build is used") }
    #expect(rebuilt !== first)
    #expect(builds.count == 2)
    #expect(entry.schema === rebuilt)

    cache.removeAll()
    #expect(cache.count == 0)
  }

  @Test
  func `An Entry Keeps A Schema Read By Type Before It Existed`() {
    let cache = StreamSchemaCache()
    let early = cache.schema(for: Int.self) { StreamSchema(shape: .scalar) }
    let entry = cache.entry(for: Int.self) { fatalError("already cached") }
    #expect(entry.schema === early)
    #expect(cache.count == 1)
  }

  @Test
  func `Separate Caches Hold Separate Schemas`() {
    let a = StreamSchemaCache()
    let b = StreamSchemaCache()
    let fromA = a.schema(for: Int.self) { StreamSchema(shape: .scalar) }
    let fromB = b.schema(for: Int.self) { StreamSchema(shape: .scalar) }
    #expect(fromA !== fromB)
    a.removeAll()
    #expect(b.contains(Int.self))
  }

  @Test
  func `Generated Schemas Default To The Shared Cache`() {
    let schema = DefaultCached.Partial.streamSchema
    #expect(StreamSchemaCache.shared.contains(DefaultCached.Partial.self))
    #expect(DefaultCached.Partial.streamSchema === schema)
    _ = ExplicitlyShared.Partial.streamSchema
    #expect(StreamSchemaCache.shared.contains(ExplicitlyShared.Partial.self))
  }

  @Test
  func `Generated Schemas Use The Named Cache`() throws {
    var value = CachedProfile.Partial.streamInitialValue()
    try parsePartial(#"{"name":"Ada","scores":[1,2]}"#, into: &value)
    #expect(CachedProfile(streamPartial: value) == CachedProfile(name: "Ada", scores: [1, 2]))

    #expect(TestSchemaCaches.generated.contains(CachedProfile.Partial.self))
    #expect(!StreamSchemaCache.shared.contains(CachedProfile.Partial.self))
    // A member's schema belongs to its own type's cache, and the parent's schema owns it.
    #expect(!TestSchemaCaches.generated.contains(StreamArray<Int>.self))
    #expect(TestSchemaCaches.generated.count == 1)

    _ = FileScoped.Partial.streamSchema
    #expect(fileScopedCache.contains(FileScoped.Partial.self))
  }

  @Test
  func `Each Specialisation Of A Generic Type Gets Its Own Entry`() throws {
    var int = CachedBox<Int>.Partial.streamInitialValue()
    try parsePartial(#"{"value":7}"#, into: &int)
    var string = CachedBox<String>.Partial.streamInitialValue()
    try parsePartial(#"{"value":"seven"}"#, into: &string)
    #expect(CachedBox<Int>(streamPartial: int) == CachedBox(value: 7))
    #expect(CachedBox<String>(streamPartial: string) == CachedBox(value: "seven"))

    #expect(TestSchemaCaches.generic.contains(CachedBox<Int>.Partial.self))
    #expect(TestSchemaCaches.generic.contains(CachedBox<String>.Partial.self))
    #expect(TestSchemaCaches.generic.count == 2)
  }

  @Test
  func `An Enum's Partial And Payloads Use The Named Cache`() throws {
    var value = CachedEvent.Partial.streamInitialValue()
    try parsePartial(#"{"message":{"text":"hi"}}"#, into: &value)
    #expect(CachedEvent(streamPartial: value) == .message(text: "hi"))

    #expect(TestSchemaCaches.enumPayloads.contains(CachedEvent.Partial.self))
    #expect(!StreamSchemaCache.shared.contains(CachedEvent.Partial.self))
    // The enum's own `Partial` and the `message` payload's.
    #expect(TestSchemaCaches.enumPayloads.count == 2)
  }

  @Test
  func `Removing Entries Mid Stream Leaves The Stream Its Schemas`() throws {
    var stream = PartialsStream(
      initialValue: CachedDocument.Partial.streamInitialValue(), from: .json()
    )
    let schema = CachedDocument.Partial.streamSchema
    try stream.next(Array(#"{"title":"Stre"#.utf8))
    TestSchemaCaches.midStream.removeAll()
    try stream.next(Array(#"am","tags":["a","b"]}"#.utf8))
    let partial = try stream.finish()
    #expect(
      CachedDocument(streamPartial: partial) == CachedDocument(title: "Stream", tags: ["a", "b"])
    )
    // Rebuilt on the next read, into the same cache.
    #expect(CachedDocument.Partial.streamSchema !== schema)
    #expect(TestSchemaCaches.midStream.count == 1)
  }

  @Test
  func `Library Containers Use The Shared Cache`() {
    let array = StreamArray<Int>.streamSchema
    #expect(StreamSchemaCache.shared.contains(StreamArray<Int>.self))
    #expect(StreamSchemaCache.shared.schema(for: StreamArray<Int>.self) { fatalError() } === array)

    if #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) {
      #expect(InlineArray<3, Int>.streamSchema === InlineArray<3, Int>.streamSchema)
    }
    #expect(SIMD2<Float>.streamSchema === SIMD2<Float>.streamSchema)
    #expect(SIMD4<Int>.streamSchema === SIMD4<Int>.streamSchema)
    #expect(StreamSchemaCache.shared.contains(SIMD2<Float>.self))
  }

  // An optional element's schema differs from its root schema, so the two are cached apart.
  @Test
  func `Optional Caches Its Element Schema Under Its Own Usage`() {
    let element = Int?.streamArrayElementSchema
    #expect(Int?.streamArrayElementSchema === element)
    #expect(Int?.streamDictionaryValueSchema === element)
    #expect(Int?.streamSchema !== element)
    #expect(StreamSchemaCache.shared.contains(Int?.self, usage: .arrayElement))
    #expect(StreamSchemaCache.shared.contains(Int?.self))
  }
}

#if Foundation && canImport(Foundation)
  import Foundation

  extension `Schema Cache Tests` {
    @Test
    func `Person Name Components Read Through Their Entry`() {
      let schema = PersonNameComponents.streamSchema
      #expect(PersonNameComponents.streamSchema === schema)
      #expect(StreamSchemaCache.shared.contains(PersonNameComponents.self))
    }
  }
#endif
