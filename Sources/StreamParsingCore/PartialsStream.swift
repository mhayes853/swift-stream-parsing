// MARK: - JSONStreamFormat

/// Describes the parser a stream should drive.
///
/// A parser owns a buffer and is `~Copyable`, so it cannot be handed around as a value the way
/// the registration based parsers were. This carries the buffer capacity instead, and each stream
/// makes its own parser from it.
public struct JSONStreamFormat: Hashable, Sendable {
  /// The capacity of the buffer the parser allocates for keys, numbers and escapes.
  public var bufferCapacity: Int
  /// Chunks at least this long are parsed by the windowed path; see `JSONParser`.
  public var windowThreshold: Int

  public init(bufferCapacity: Int = 4096, windowThreshold: Int = .max) {
    self.bufferCapacity = bufferCapacity
    self.windowThreshold = windowThreshold
  }

  /// Parses JSON.
  ///
  /// - Parameters:
  ///   - bufferCapacity: The capacity of the parser's buffer.
  ///   - windowThreshold: Chunks at least this long are parsed by the windowed path.
  /// - Returns: A format describing a JSON parser.
  public static func json(bufferCapacity: Int = 4096, windowThreshold: Int = .max) -> Self {
    Self(bufferCapacity: bufferCapacity, windowThreshold: windowThreshold)
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
  @usableFromInline var sink: PartialSink

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
    self.parser = JSONParser(
      bufferCapacity: format.bufferCapacity, windowThreshold: format.windowThreshold
    )
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
    guard !self.hasFinished else { throw StreamParsingError.parserFinished }
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
    guard !self.hasFinished else { throw StreamParsingError.parserFinished }
    do {
      try self.parse(bytes)
    } catch {
      self.hasParserThrown = true
      throw error
    }
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

  /// Completes parsing and returns the final value by taking it from the stream.
  ///
  /// This is ``finish()`` without the snapshot: `finish()` returns ``current``, which copies the
  /// whole tree through its value witnesses and leaves the stream's own copy behind to be
  /// destroyed with the stream. Consuming the stream instead moves the tree out — a bitwise
  /// move, no retains and no destroys — so the value returned is the one the parser built.
  ///
  /// On payloads small enough that per-parse cost matters (a tool call, a structured response),
  /// the snapshot and the doomed original are a measurable share of the whole parse; use this
  /// when the stream is done the moment the value is.
  ///
  /// - Returns: The final parsed value.
  @inlinable
  public consuming func finishValue() throws -> Value {
    guard !self.hasParserThrown else { throw StreamParsingError.parserThrows }
    guard !self.hasFinished else { throw StreamParsingError.parserFinished }
    try self.parser.finish(into: &self.sink)
    // Move rather than read: `storage.move()` transfers the tree bitwise, so no copy is made.
    // The slot is refilled with the empty initial value for the deinit to destroy — a tree of
    // nils, which costs a few outlined destroys instead of a walk over everything that was
    // parsed. (`discard self` would skip even that, but it requires every stored property to be
    // trivially destroyed, and the parser and sink own buffers.)
    let value = self.storage.move()
    self.storage.initialize(to: Value.streamInitialValue())
    return value
  }
}
