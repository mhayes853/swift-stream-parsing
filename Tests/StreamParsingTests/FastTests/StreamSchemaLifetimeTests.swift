import Testing

import StreamParsing
@testable import StreamParsingCore

// A container root's schema is a *computed* property (a generic type cannot hold a stored
// static), and `PartialsStream.init` reads it. Two things followed from that and are pinned here:
// the element template the schema captures used to be leaked outright, once per stream init; and
// the whole schema -- field table, closure contexts, template -- used to be rebuilt per init.
@Suite
struct `Stream Schema Lifetime Tests` {
  @Test
  func `Container Root Schema Is Built Once Per Element Type`() {
    #expect(StreamArray<Int>.streamSchema === StreamArray<Int>.streamSchema)
    #expect(StreamDictionary<Int>.streamSchema === StreamDictionary<Int>.streamSchema)
    #expect(Int?.streamSchema === Int?.streamSchema)
  }

  @Test
  func `Distinct Element Types Get Distinct Schemas`() {
    #expect(StreamArray<Int>.streamSchema !== StreamArray<Double>.streamSchema)
    #expect(StreamArray<Int>.streamSchema !== StreamDictionary<Int>.streamSchema)
  }

  @Test
  func `Stream Init Reuses The Cached Schema`() throws {
    let schema = StreamArray<Int>.streamSchema
    // Warms every other allocation the first stream makes, so the count below covers the loop.
    _ = PartialsStream(initialValue: StreamArray<Int>(), from: .json())
    let before = _streamTemplateStorageCounts.total

    let iterations = 200
    for _ in 0..<iterations {
      var stream = PartialsStream(initialValue: StreamArray<Int>(), from: .json())
      try stream.next(Array("[1,2,3]".utf8))
      _ = try stream.finish()
    }

    #expect(StreamArray<Int>.streamSchema === schema)
    // Other suites run concurrently and each new element type they touch allocates one template,
    // so this is a growth-rate assertion rather than an equality: one per init would be 200.
    let allocated = _streamTemplateStorageCounts.total - before
    #expect(allocated * 20 < iterations, "allocated \(allocated) templates over \(iterations) inits")
  }

  @Test
  func `Array Schema Frees Its Template When Released`() {
    weak var box: _StreamTemplateStorage?
    do {
      // Built directly rather than through the cache, so the schema really is released here.
      let schema = _streamArraySchema(Int.self, element: Int.streamElementSchema)
      box = schema.templateOwner
      #expect(box != nil)
    }
    #expect(box == nil)
  }

  @Test
  func `Dictionary Schema Frees Its Template When Released`() {
    weak var box: _StreamTemplateStorage?
    do {
      let schema = _streamDictionarySchema(Int.self, value: Int.streamElementSchema)
      box = schema.templateOwner
      #expect(box != nil)
    }
    #expect(box == nil)
  }

  @Test
  func `Optional Container Schemas Free Their Templates When Released`() {
    weak var arrayBox: _StreamTemplateStorage?
    weak var dictionaryBox: _StreamTemplateStorage?
    do {
      let array = _streamOptionalArraySchema(Int.self, element: Int.streamElementSchema)
      let dictionary = _streamOptionalDictionarySchema(Int.self, value: Int.streamElementSchema)
      arrayBox = array.templateOwner
      dictionaryBox = dictionary.templateOwner
      #expect(arrayBox != nil)
      #expect(dictionaryBox != nil)
    }
    #expect(arrayBox == nil)
    #expect(dictionaryBox == nil)
  }

  @Test
  func `Cached Container Root Still Parses`() throws {
    var stream = PartialsStream(initialValue: StreamDictionary<Int>(), from: .json())
    try stream.next(Array(#"{"a":1,"b":2}"#.utf8))
    let value = try stream.finish()
    #expect(value["a"] == 1)
    #expect(value["b"] == 2)
  }
}
