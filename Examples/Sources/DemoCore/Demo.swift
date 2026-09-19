import StreamParsing

public enum Demo {
  /// Parses `source` as an `Extraction`, logging the typed partial value after every chunk.
  ///
  /// - Returns: The chunks that were consumed, so a live run can be saved as a fixture.
  @discardableResult
  public static func run(_ source: some ChunkSource, full: Bool = false) async throws -> [StreamChunk] {
    let log = UpdateLog(full: full)
    let recorder = Recorder()

    // This is the whole integration: hand the library an async sequence of byte chunks, and
    // get back a typed snapshot after each one. No chunk has to be valid JSON, or even valid
    // UTF-8, on its own.
    let bytes = source.chunks().map { chunk in
      await recorder.append(chunk)
      await log.received(chunk)
      return chunk.bytes
    }
    var latest = Extraction.Partial()
    for try await update in bytes.partials(of: Extraction.self, from: .json()).updates() {
      await log.parsed(update)
      latest = update.value
    }

    await log.summarize(latest)
    return await recorder.chunks
  }
}

private actor Recorder {
  private(set) var chunks = [StreamChunk]()

  func append(_ chunk: StreamChunk) {
    self.chunks.append(chunk)
  }
}
