import CustomDump
import Testing

@testable import StreamParsingCore

// The sink borrows the schema a frame carries rather than retaining it, which is sound only while
// every schema outlives the frames that reach it. A hand-written `enterField` used to hand the
// schema over, so one built on the spot died under the sink; it now names one of the entering
// schema's `children`, which that schema owns. These pin the three ways a frame can name a schema.
//
// Hand written rather than generated: the macro routes containers through field tables and never
// emits `enterField`.

private struct FrameChild {
  var value = 0
}

private func frameValueMatcher(_ key: Span<UInt8>) -> Int32 {
  key.count == 5 ? 0 : -1
}

// The child schema is built inline, where the parent's `children` is its only owner: the shape
// that used to be a use-after-free when the frame carried the schema itself.
private struct FrameParent: StreamInitializable, StreamParseableObject {
  var nested = FrameChild()

  static func streamInitialValue() -> Self { Self() }

  static let streamSchema = StreamSchema(
    shape: .object,
    matchField: { key in key.count == 6 ? 0 : -1 },
    enterField: { storage, field in
      guard field == 0 else { return nil }
      let offset = MemoryLayout<FrameParent>.offset(of: \.nested).unsafelyUnwrapped
      return StreamFrame(storage: storage + offset, child: 0)
    },
    children: [
      StreamSchema(
        shape: .object,
        matchField: frameValueMatcher,
        applyNumber: { storage, field, bytes, info in
          guard field == 0, let value = Int(streamParsing: bytes, info: info) else {
            return .unsupported
          }
          storage.assumingMemoryBound(to: FrameChild.self).pointee.value = value
          return .applied
        }
      )
    ]
  )
}

// Names a child the schema does not have.
private struct FrameMissingChild: StreamInitializable, StreamParseableObject {
  var nested = FrameChild()

  static func streamInitialValue() -> Self { Self() }

  static let streamSchema = StreamSchema(
    shape: .object,
    matchField: { key in key.count == 6 ? 0 : -1 },
    enterField: { storage, _ in StreamFrame(storage: storage, child: 1) },
    children: [StreamSchema(shape: .object)]
  )
}

// A node whose `next` member is another node, entered at the same storage, so every level of
// `{"next":{"next":...}}` writes `depth` into the one value.
private struct FrameNode: StreamInitializable, StreamParseableObject {
  var depth = 0

  static func streamInitialValue() -> Self { Self() }

  static let streamSchema = StreamSchema(
    shape: .object,
    matchField: { key in key.count == 4 ? 0 : -1 },
    enterField: { storage, field in
      guard field == 0 else { return nil }
      storage.assumingMemoryBound(to: FrameNode.self).pointee.depth += 1
      return StreamFrame(storage: storage, child: StreamFrame.reentering)
    },
    children: [FrameParent.streamSchema]
  )
}

private func parse<Root: StreamPartial>(_ json: String, as type: Root.Type) throws -> Root {
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
  if let failure = sink.streamFailure { throw failure }
  return storage.pointee
}

private func bits(_ schema: StreamSchema) -> UnsafeRawPointer {
  UnsafeRawPointer(Unmanaged.passUnretained(schema).toOpaque())
}

@Suite
struct StreamFrameTests {
  @Test
  func `A frame writes through a child its parent owns`() throws {
    let parsed = try parse(#"{"nested":{"value":7}}"#, as: FrameParent.self)
    expectNoDifference(parsed.nested.value, 7)
  }

  @Test
  func `A frame naming a child the schema does not have stops the program`() async {
    await #expect(processExitsWith: .failure) {
      _ = try parse(#"{"nested":{"value":7}}"#, as: FrameMissingChild.self)
    }
  }

  @Test
  func `A reentering frame writes through the schema that returned it`() throws {
    let parsed = try parse(#"{"next":{"next":{"next":{}}}}"#, as: FrameNode.self)
    expectNoDifference(parsed.depth, 3)
  }

  // An optional wrapper forwards `enterField`, so the frames it returns are the wrapped schema's:
  // their positions are in its `children`, and reentering names it rather than the wrapper, which
  // would materialise an optional at storage that need not be one.
  @Test
  func `An optional wrapper resolves frames against the schema it wraps`() throws {
    let wrapped = FrameNode.streamSchema
    let storage = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
    defer { storage.deallocate() }
    let reentering = StreamFrame(storage: storage, child: StreamFrame.reentering)
    let first = StreamFrame(storage: storage, child: 0)
    for wrapper in [FrameNode?.streamSchema, FrameNode?.streamArrayElementSchema] {
      #expect(wrapper !== wrapped)
      #expect(wrapper.childSchemaBits(reentering) == bits(wrapped))
      #expect(wrapper.childSchemaBits(first) == bits(FrameParent.streamSchema))
    }
    #expect(
      FrameNode??.streamArrayElementSchema.childSchemaBits(reentering) == bits(wrapped)
    )
  }

  @Test
  func `A reentering frame under an optional root keeps writing the wrapped value`() throws {
    let parsed = try parse(#"{"next":{"next":{}}}"#, as: FrameNode?.self)
    expectNoDifference(parsed?.depth, 2)
  }
}
