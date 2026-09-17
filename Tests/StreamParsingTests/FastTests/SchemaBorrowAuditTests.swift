import CustomDump
import Testing

import StreamParsing
import StreamParsingCore

// The sink borrows the schema a frame carries rather than retaining it, which is sound only while
// every schema outlives the frames that reach it. `StreamSchemaBorrowAudit` is what turns a
// violation into a report instead of a use after free somewhere later, so it has to be shown to
// actually fire — a tripwire that cannot trip is worse than none, because it reads as a guarantee.
//
// Both models below are hand written rather than generated: the macro hoists a nested schema into
// a `private static let`, so it cannot express the mistake.

private struct AuditNested: StreamInitializable, StreamParseableObject {
  var value: Int = 0

  static func streamInitialValue() -> Self { Self() }

  static let streamSchema = StreamSchema(shape: .object)
}

// The mistake: `enterField` builds the nested schema on the spot, so the frame it returns is the
// only thing holding it and the schema dies as soon as the sink lowers the frame.
private struct AuditDangling: StreamInitializable, StreamParseableObject {
  var nested = AuditNested()

  static func streamInitialValue() -> Self { Self() }

  static let streamSchema = StreamSchema(
    shape: .object,
    matchField: { key in key.count == 6 ? 0 : -1 },
    enterField: { storage, _ in
      StreamFrame(storage: storage, schema: StreamSchema(shape: .object))
    }
  )
}

// The same model with the nested schema stored, which is what a correct conformance does.
private let auditNestedSchema = StreamSchema(shape: .object)

private struct AuditDurable: StreamInitializable, StreamParseableObject {
  var nested = AuditNested()

  static func streamInitialValue() -> Self { Self() }

  static let streamSchema = StreamSchema(
    shape: .object,
    matchField: { key in key.count == 6 ? 0 : -1 },
    enterField: { storage, _ in
      StreamFrame(storage: storage, schema: auditNestedSchema)
    }
  )
}

// A nested schema with a durable owner the test can drop on purpose, between documents.
nonisolated(unsafe) private var auditReleasableSchema: StreamSchema? = StreamSchema(shape: .object)

private struct AuditReleasable: StreamInitializable, StreamParseableObject {
  var nested = AuditNested()

  static func streamInitialValue() -> Self { Self() }

  static let streamSchema = StreamSchema(
    shape: .object,
    matchField: { key in key.count == 6 ? 0 : -1 },
    enterField: { storage, _ in
      StreamFrame(storage: storage, schema: auditReleasableSchema.unsafelyUnwrapped)
    }
  )
}

private func parse<Root: StreamParseableRoot>(_ json: String, as type: Root.Type) throws {
  let storage = UnsafeMutablePointer<Root>.allocate(capacity: 1)
  storage.initialize(to: Root.streamInitialValue())
  defer {
    storage.deinitialize(count: 1)
    storage.deallocate()
  }
  var sink = PartialSink(root: storage)
  var parser = JSONParser()
  try Array(json.utf8).withUnsafeBufferPointer { try parser.parse($0, into: &sink) }
  try parser.finish(into: &sink)
}

@Suite("Schema borrow audit tests")
struct SchemaBorrowAuditTests {
  // Observing stderr rather than only the exit status, so this cannot pass on some unrelated
  // crash — which is precisely the failure the audit exists to replace.
  @Test("A schema the frame is the only owner of trips the audit")
  func danglingSchemaTrips() async throws {
    let result = try await #require(
      processExitsWith: .failure,
      observing: [\.standardErrorContent]
    ) {
      try parse(#"{"nested":{"value":1}}"#, as: AuditDangling.self)
    }
    let message = String(decoding: result.standardErrorContent, as: UTF8.self)
    expectNoDifference(message.contains("deallocated while the sink still borrowed it"), true)
  }

  @Test("A schema with a durable owner does not trip the audit")
  func durableSchemaPasses() throws {
    try parse(#"{"nested":{"value":1}}"#, as: AuditDurable.self)
  }

  // `reset()` ends the document, and with it every borrow recorded for it. A schema that was
  // borrowed by the first document and legitimately released afterwards must not trip the
  // tripwire during the second — a false positive, but a `preconditionFailure` all the same.
  @Test("reset clears the borrows the previous document recorded")
  func resetClearsBorrows() async throws {
    await #expect(processExitsWith: .success) {
      let storage = UnsafeMutablePointer<AuditReleasable>.allocate(capacity: 1)
      storage.initialize(to: AuditReleasable.streamInitialValue())
      var sink = PartialSink(root: storage)
      var first = JSONParser()
      try Array(#"{"nested":{"value":1}}"#.utf8).withUnsafeBufferPointer {
        try first.parse($0, into: &sink)
      }
      try first.finish(into: &sink)
      sink.reset()
      auditReleasableSchema = nil
      var second = JSONParser()
      try Array("{}".utf8).withUnsafeBufferPointer { try second.parse($0, into: &sink) }
      try second.finish(into: &sink)
    }
  }
}
