import Foundation

/// A recorded chunk stream, one chunk per line: `<delay in microseconds> <hex bytes>`.
///
/// Bytes are hex encoded because a chunk is not required to be valid UTF-8 by itself, and lines
/// starting with `#` are comments. The original chunk boundaries and timing are what make a
/// replay representative, so both are preserved exactly.
public struct Fixture: Sendable, Equatable {
  public var chunks: [StreamChunk]

  public init(chunks: [StreamChunk] = []) {
    self.chunks = chunks
  }
}

extension Fixture {
  public struct MalformedLine: Error, CustomStringConvertible {
    public let number: Int
    public var description: String { "Malformed fixture line \(self.number)." }
  }

  public init(contentsOf url: URL) throws {
    try self.init(parsing: String(contentsOf: url, encoding: .utf8))
  }

  public init(parsing text: String) throws {
    self.init()
    for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
      if line.isEmpty || line.hasPrefix("#") { continue }
      let fields = line.split(separator: " ")
      guard fields.count == 2, let microseconds = Int64(fields[0]), let bytes = Self.bytes(hex: fields[1])
      else { throw MalformedLine(number: offset + 1) }
      self.chunks.append(StreamChunk(bytes: bytes, delay: .microseconds(microseconds)))
    }
  }

  public func serialized(header: String) -> String {
    var text = header.split(separator: "\n").map { "# \($0)\n" }.joined()
    for chunk in self.chunks {
      let components = chunk.delay.components
      let microseconds = components.seconds * 1_000_000 + components.attoseconds / 1_000_000_000_000
      text += "\(microseconds) \(chunk.bytes.map(Self.hex).joined())\n"
    }
    return text
  }

  private static func hex(_ byte: UInt8) -> String {
    let digits = String(byte, radix: 16)
    return byte < 16 ? "0" + digits : digits
  }

  private static func bytes(hex: Substring) -> [UInt8]? {
    let digits = Array(hex.utf8)
    guard digits.count.isMultiple(of: 2) else { return nil }
    var bytes = [UInt8]()
    bytes.reserveCapacity(digits.count / 2)
    for index in stride(from: 0, to: digits.count, by: 2) {
      guard let byte = UInt8(String(decoding: digits[index..<index + 2], as: UTF8.self), radix: 16)
      else { return nil }
      bytes.append(byte)
    }
    return bytes
  }
}

/// Replays a fixture with its recorded pacing, scaled by `speed` (`nil` replays without waiting).
public struct ReplaySource: ChunkSource {
  public var fixture: Fixture
  public var speed: Double?

  public init(fixture: Fixture, speed: Double? = 1) {
    self.fixture = fixture
    self.speed = speed
  }

  public func chunks() -> AsyncThrowingStream<StreamChunk, any Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          for chunk in self.fixture.chunks {
            if let speed = self.speed { try await Task.sleep(for: chunk.delay / speed) }
            continuation.yield(chunk)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
