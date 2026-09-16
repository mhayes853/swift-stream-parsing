// MARK: - JSONStreamFormat

/// Describes the parser a stream should drive.
///
/// A parser owns a buffer and is `~Copyable`, so this carries the buffer capacity instead and each
/// stream makes its own parser from it.
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
/// @StreamParseable struct BlogPost { var title: String = "" }
///
/// var stream = PartialsStream(initialValue: BlogPost.Partial(), from: .json())
/// for byte in #"{"title":"DocC"}"#.utf8 {
///   _ = try stream.next(byte)
/// }
/// let final = try stream.finish()
/// ```
public struct PartialsStream<Value: StreamParseableRoot>: ~Copyable {
  // Its own allocation: the sink's frames hold pointers into it, which must survive a move.
  @usableFromInline let storage: UnsafeMutablePointer<Value>

  @usableFromInline
  static func allocateStorage() -> UnsafeMutablePointer<Value> {
    UnsafeMutablePointer<Value>.allocate(capacity: 1)
  }

  @usableFromInline var parser: JSONParser
  @usableFromInline var sink: PartialSink

  @usableFromInline var hasFinished = false
  @usableFromInline var hasParserThrown = false
  // Set only by the consuming `finishValue()`, which leaves the slot uninitialised for `deinit`.
  @usableFromInline var hasTakenStorage = false

  /// The most recent value state emitted by the stream.
  ///
  /// A snapshot: it stays as it was while more bytes arrive, since a copy shares only sealed
  /// storage that is never written again. Reading it still copies the open element at each depth;
  /// ``withView(_:)`` reads without copying.
  @inlinable
  public var current: Value { self.storage.pointee }

  /// Reads the value in place, without copying it.
  ///
  /// The view borrows the stream's storage, so it cannot outlive `body`. Reading a member off it
  /// copies that member and nothing else; use ``current`` to keep a whole state.
  ///
  /// ```swift
  /// try stream.next(byte)
  /// stream.withView { post in
  ///   render(post.title)
  /// }
  /// ```
  public func withView<R>(_ body: (borrowing Value.View) throws -> R) rethrows -> R {
    try body(Value.streamView(UnsafeMutableRawPointer(self.storage)))
  }

  /// Installs a parser for the supplied format and optional initial value state.
  ///
  /// - Parameters:
  ///   - initialValue: The value state to start parsing from.
  ///   - format: The format describing the parser that will consume bytes.
  //
  // Must stay `@inlinable`: the schema has to be built in the client module with `Value` concrete,
  // or container roots reach `_openElement`/`_openValue` through value witnesses (~2.9% of a
  // `StreamDictionary<GSoCProject.Partial>` parse).
  @inlinable
  public init(
    initialValue: Value = Value.streamInitialValue(),
    from format: JSONStreamFormat
  ) {
    let storage = Self.allocateStorage()
    storage.initialize(to: initialValue)
    self.storage = storage
    self.parser = JSONParser(
      bufferCapacity: format.bufferCapacity, windowThreshold: format.windowThreshold
    )
    self.sink = PartialSink(root: storage, schema: Value.streamSchema)
  }

  deinit {
    // After a consuming `finishValue()` the slot is uninitialised, not refilled: refilling costs a
    // template copy plus its destroy per parse.
    if !self.hasTakenStorage { self.storage.deinitialize(count: 1) }
    self.storage.deallocate()
  }

  /// Sends a single byte into the parser.
  ///
  /// Nothing is returned: returning a value costs a snapshot. Read ``current`` or ``withView(_:)``
  /// when a state is needed.
  ///
  /// - Parameter byte: Byte to feed into the parser.
  //
  // Must stay `@inlinable` so `JSONParser.parse` specializes into the caller. Measured: opaque, it
  // was half the wall clock of every byte-fed row and 3% of the bulk rows.
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
  /// ``finish()`` without the snapshot: `finish()` copies the whole tree through its value
  /// witnesses and leaves the original to be destroyed with the stream, while this moves the tree
  /// out bitwise. Use it when the stream is done the moment the value is; on small payloads (a tool
  /// call) the copy is a measurable share of the parse.
  ///
  /// - Returns: The final parsed value.
  @inlinable
  public consuming func finishValue() throws -> Value {
    guard !self.hasParserThrown else { throw StreamParsingError.parserThrows }
    guard !self.hasFinished else { throw StreamParsingError.parserFinished }
    do {
      try self.parser.finish(into: &self.sink)
    } catch {
      self.hasParserThrown = true
      throw error
    }
    // Moved bitwise and `deinit` told so. `discard self` would skip the deinit, but it needs every
    // stored property trivially destroyed, and the parser and sink own buffers.
    let value = self.storage.move()
    self.hasTakenStorage = true
    return value
  }

  /// Completes parsing, returns the final value, and re-arms the stream for the next document.
  ///
  /// The amortizing form of ``finishValue()``: it keeps the parser's buffer, the sink's frame
  /// storage and the value's slot, rewinding their state, so a loop over many small documents of
  /// one schema (a stream of tool calls) pays setup once. The value is still moved out, not copied.
  ///
  /// - Parameter initialValue: The value state the next document starts parsing from.
  /// - Returns: The final parsed value of the document just completed.
  @inlinable
  public mutating func finishValue(
    resettingTo initialValue: Value = Value.streamInitialValue()
  ) throws -> Value {
    guard !self.hasParserThrown else { throw StreamParsingError.parserThrows }
    guard !self.hasFinished else { throw StreamParsingError.parserFinished }
    do {
      try self.parser.finish(into: &self.sink)
    } catch {
      self.hasParserThrown = true
      throw error
    }
    let value = self.storage.move()
    self.storage.initialize(to: initialValue)
    self.parser.reset()
    self.sink.reset()
    return value
  }

  /// Discards whatever state the stream holds and re-arms it for a new document.
  ///
  /// Legal in any state, including after the parser has thrown: a malformed document is recovered
  /// from by resetting and parsing the next one, keeping every allocation.
  ///
  /// - Parameter initialValue: The value state the next document starts parsing from.
  @inlinable
  public mutating func reset(to initialValue: Value = Value.streamInitialValue()) {
    self.storage.pointee = initialValue
    self.parser.reset()
    self.sink.reset()
    self.hasFinished = false
    self.hasParserThrown = false
  }
}
