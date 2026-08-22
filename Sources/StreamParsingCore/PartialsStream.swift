// MARK: - JSONStreamFormat

/// Describes the parser a stream should drive.
///
/// A parser owns a buffer and is `~Copyable`, so it cannot be handed around as a value the way
/// the registration based parsers were. This carries the settings instead, and each stream makes
/// its own parser from them.
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

// MARK: - PartialsStream

/// Drives a parser and exposes each incremental value state.
///
/// ```swift
/// @StreamParseable
/// struct BlogPost {
///   var title: String = ""
/// }
///
/// var stream = PartialsStream(initialValue: BlogPost.Partial(), from: .json())
/// for byte in #"{"title":"DocC"}"#.utf8 {
///   _ = try stream.next(byte)
/// }
/// let final = try stream.finish()
/// ```
///
/// The value lives in its own allocation rather than inline. Frames inside the sink hold pointers
/// into it so partials update at every depth as bytes arrive, and those pointers have to survive
/// the stream being moved, which a stored property would not.
public struct PartialsStream<Value: StreamParseableRoot>: ~Copyable {
  @usableFromInline let storage: UnsafeMutablePointer<Value>

  @usableFromInline var parser: JSONParser
  @usableFromInline var sink: PartialSink<Value>

  @usableFromInline var hasFinished = false
  @usableFromInline var hasParserThrown = false

  /// The most recent value state emitted by the stream.
  ///
  /// This is a snapshot, so it stays as it was even as more bytes arrive: every container holds
  /// its open element in an inline slot, so a copy shares only sealed storage that is never
  /// written again. Reading it still copies the open element at each depth; ``withView(_:)``
  /// reads without copying when only part of the value is needed.
  @inlinable
  public var current: Value {
    self.storage.pointee
  }

  /// Reads the value in place, without copying it.
  ///
  /// The view borrows the parser's storage, so it cannot outlive `body`: it is `~Copyable` and
  /// arrives borrowed, which leaves no way to store it. Reading a member off it copies that
  /// member and nothing else, so pulling one field out of a large value costs one field.
  ///
  /// ```swift
  /// try stream.next(byte)
  /// stream.withView { post in
  ///   render(post.title)
  /// }
  /// ```
  ///
  /// Use ``current`` instead to keep a whole state.
  public func withView<R>(_ body: (borrowing Value.View) throws -> R) rethrows -> R {
    try body(Value.streamView(UnsafeMutableRawPointer(self.storage)))
  }

  /// Installs a parser for the supplied format and optional initial value state.
  ///
  /// - Parameters:
  ///   - initialValue: The value state to start parsing from.
  ///   - format: The format describing the parser that will consume bytes.
  public init(
    initialValue: Value = Value.streamInitialValue(),
    from format: JSONStreamFormat
  ) {
    let storage = UnsafeMutablePointer<Value>.allocate(capacity: 1)
    storage.initialize(to: initialValue)
    self.storage = storage
    self.parser = JSONParser(bufferCapacity: format.bufferCapacity)
    self.sink = PartialSink(root: storage, schema: Value.streamSchema)
  }

  deinit {
    self.storage.deinitialize(count: 1)
    self.storage.deallocate()
  }

  /// Sends a single byte into the parser.
  ///
  /// Nothing is returned, because returning a value is the same thing as asking to keep one, and
  /// that costs a snapshot. Read ``current`` or ``withView(_:)`` when a state is actually needed.
  ///
  /// - Parameter byte: Byte to feed into the parser.
  ///
  /// Inlinable because it is not otherwise: `JSONParser.parse` is generic over the sink and
  /// specializes into its caller, and a caller in another module cannot specialize what it cannot
  /// see. Left opaque, one byte through this method costs a call into `StreamParsingCore` and an
  /// unspecialized parse; measured on `LayerOverheadBenchmarks`, that was half the wall clock of
  /// every byte fed row — `Layer Array of structs byte by byte - stream` 325 µs → 151 µs, `Layer
  /// LLM message byte by byte - stream` 68 ms → 38 ms — and 3% of the bulk rows. Both land the
  /// stream exactly on the raw `PartialSink` numbers, so the wrapper's own bookkeeping is free
  /// and this attribute was the whole of its cost.
  @inlinable
  public mutating func next(_ byte: UInt8) throws {
    guard !self.hasParserThrown else { throw StreamParsingError.parserThrows }
    do {
      try self.parser.parse(byte: byte, into: &self.sink)
    } catch {
      self.hasParserThrown = true
      throw error
    }
  }

  /// Feeds multiple bytes to the parser.
  ///
  /// - Parameter bytes: The byte sequence to parse.
  @inlinable
  public mutating func next(_ bytes: some Sequence<UInt8>) throws {
    guard !self.hasParserThrown else { throw StreamParsingError.parserThrows }
    do {
      try self.parse(bytes)
    } catch {
      self.hasParserThrown = true
      throw error
    }
  }

  public mutating func nextSnapshot(_ bytes: some Sequence<UInt8>) throws -> Value {
    try self.next(bytes)
    return self.current
  }

  public mutating func nextSnapshot(_ byte: UInt8) throws -> Value {
    try self.next(byte)
    return self.current
  }

  @usableFromInline
  mutating func parse(_ bytes: some Sequence<UInt8>) throws {
    let parsed: Void? = try bytes.withContiguousStorageIfAvailable { buffer in
      try self.parser.parse(buffer, into: &self.sink)
    }
    guard parsed == nil else { return }
    for byte in bytes {
      try self.parser.parse(byte: byte, into: &self.sink)
    }
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
    do {
      try self.parser.finish(into: &self.sink)
    } catch {
      self.hasParserThrown = true
      throw error
    }
    return self.current
  }
}
