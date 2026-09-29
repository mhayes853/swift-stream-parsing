/// Describes the parser a stream should drive.
///
/// A parser owns a buffer and is `~Copyable`, so this carries the buffer capacity instead and each
/// stream makes its own parser from it.
public struct JSONStreamFormat: Hashable, Sendable {
  /// The capacity of the buffer the parser allocates for keys, numbers and escapes.
  public var bufferCapacity: Int

  public init(bufferCapacity: Int = 4096) {
    self.bufferCapacity = bufferCapacity
  }

  /// Parses JSON.
  ///
  /// - Parameter bufferCapacity: The capacity of the parser's buffer.
  /// - Returns: A format describing a JSON parser.
  public static func json(bufferCapacity: Int = 4096) -> Self {
    Self(bufferCapacity: bufferCapacity)
  }
}
