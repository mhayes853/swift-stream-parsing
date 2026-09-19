/// One delivery of bytes from whatever is producing the JSON. For an LLM this is one token,
/// which may end anywhere: mid-string, mid-escape, or even mid-UTF-8-scalar.
public struct StreamChunk: Sendable, Equatable {
  public var bytes: [UInt8]
  /// The time that passed since the previous chunk (or since the start, for the first chunk).
  public var delay: Duration

  public init(bytes: [UInt8], delay: Duration) {
    self.bytes = bytes
    self.delay = delay
  }
}

/// A producer of JSON chunks. `live` uses an in-process LLM; `replay` uses a recording of one.
public protocol ChunkSource: Sendable {
  func chunks() -> AsyncThrowingStream<StreamChunk, any Error>
}
