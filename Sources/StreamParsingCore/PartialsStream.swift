// MARK: - PartialsStream

/// A convenience typealias for a ``PartialsStream`` for a ``StreamParser``.
public typealias PartialsStreamOf<Parser: StreamParser> = PartialsStream<Parser.Value, Parser>

/// A convenience typealias for a ``PartialsStream`` for a ``StreamParseable`` type.
public typealias PartialsStreamFor<
  Parseable: StreamParseable,
  Parser: StreamParser<Parseable.Partial>
> = PartialsStream<Parseable.Partial, Parser>

/// Drives a ``StreamParser`` and exposes each incremental value state.
///
/// ```swift
/// struct BlogPost: StreamParseable {
///   struct Partial: StreamParseableValue, StreamParseable { ... }
/// }
///
/// var stream = PartialsStream(initialValue: BlogPost.Partial(), from: .json())
/// for byte in "{\"title\":\"DocC\"}".utf8 {
///   _ = try stream.next(byte)
/// }
/// let final = try stream.finish()
/// ```
public struct PartialsStream<Value: StreamParseableValue, Parser: StreamParser<Value>> {
  @usableFromInline
  var parser: Parser

  @usableFromInline
  var _current: Value

  @usableFromInline
  var hasFinished = false

  @usableFromInline
  var hasParserThrown = false

  /// The most recent value state emitted by the stream.
  @inlinable
  public var current: Value {
    self._current
  }

  /// Installs the supplied parser and optional initial value state.
  ///
  /// - Parameters:
  ///   - initialValue: The value state to start parsing from.
  ///   - parser: The parser that will consume bytes.
  @inlinable
  public init(initialValue: Value = .initialParseableValue(), from parser: Parser) {
    var parser = parser
    parser.registerHandlers()
    self.parser = parser
    self._current = initialValue
  }

  /// Sends a single byte into the parser and returns the updated value.
  ///
  /// - Parameter byte: Byte to feed into the parser.
  /// - Returns: The latest parsed value after consuming the byte.
  @inlinable
  @discardableResult
  public mutating func next(_ byte: UInt8) throws -> Value {
    try self.next(CollectionOfOne(byte))
  }

  /// Feeds multiple bytes to the parser and returns the latest value.
  ///
  /// - Parameter bytes: The byte sequence to parse.
  /// - Returns: The latest parsed value after consuming the bytes.
  @inlinable
  @discardableResult
  public mutating func next(_ bytes: some Sequence<UInt8>) throws -> Value {
    guard !self.hasParserThrown else { throw StreamParsingError.parserThrows }

    do {
      try self.parser.parse(bytes: bytes, into: &self._current)
    } catch {
      self.hasParserThrown = true
      throw error
    }

    return self.current
  }

  /// Completes parsing and validates that the stream ended cleanly.
  ///
  /// - Returns: The final parsed value after calling ``finish()``.
  @inlinable
  @discardableResult
  public mutating func finish() throws -> Value {
    guard !self.hasParserThrown else { throw StreamParsingError.parserThrows }
    guard !self.hasFinished else { throw StreamParsingError.parserFinished }
    self.hasFinished = true
    try self.parser.finish(reducer: &self._current)
    return self.current
  }
}

extension PartialsStream: Sendable
where Value: Sendable, Parser: Sendable {}
