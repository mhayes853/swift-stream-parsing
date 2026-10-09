// MARK: - JSONStreamFormat

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

// MARK: - PartialsStream

/// Drives a parser and exposes each incremental value state.
///
/// The stream is generic over the type being parsed, and holds that type's
/// ``StreamParseable/Partial``: the value you read from it, and write back to it, is always a
/// partial.
///
/// ```swift
/// @StreamParseable struct BlogPost { var title: String = "" }
///
/// var stream = PartialsStream<BlogPost>(from: .json())
/// for byte in #"{"title":"DocC"}"#.utf8 {
///   try stream.next(byte)
/// }
/// let post: BlogPost = try stream.finish()
/// ```
///
/// A partial type is itself parseable, with `Partial == Self`, so
/// `PartialsStream<BlogPost.Partial>` names the same storage and behaves identically. Prefer the
/// model type: it is the one you wrote.
public struct PartialsStream<Value: StreamParseable>: ~Copyable {
  // Its own allocation: the sink's frames hold pointers into it, which must survive a move.
  @usableFromInline let storage: UnsafeMutablePointer<Value.Partial>

  @usableFromInline
  static func allocateStorage() -> UnsafeMutablePointer<Value.Partial> {
    UnsafeMutablePointer<Value.Partial>.allocate(capacity: 1)
  }

  @usableFromInline var parser: JSONParser
  @usableFromInline var sink: PartialSink

  @usableFromInline var hasFinished = false
  @usableFromInline var hasParserFailed = false
  // Set only by the consuming `finish()` and `finishPartial()`, which leave the slot uninitialised
  // for `deinit`.
  @usableFromInline var hasTakenStorage = false

  /// The most recent value state emitted by the stream.
  ///
  /// A snapshot: it stays as it was while more bytes arrive, since a copy shares only sealed
  /// storage that is never written again. Reading it still copies the open element at each depth;
  /// ``withView(_:)`` reads without copying.
  @inlinable
  public var current: Value.Partial { self.storage.pointee }

  /// Reads the value in place, without copying it.
  ///
  /// With the `LifetimeView` trait, the view borrows the stream's storage and cannot outlive
  /// `body`. Without the trait this API is unsafe: the view itself is escapable, and callers must
  /// not preserve it or any pointer-backed projection after the callback or across parser mutation.
  /// Reading a member copies that member and nothing else; use ``current`` to keep a whole state.
  ///
  /// ```swift
  /// try stream.next(byte)
  /// stream.withView { post in
  ///   render(post.title)
  /// }
  /// ```
#if !LifetimeView
  @unsafe
#endif
  public func withView<R>(_ body: (borrowing Value.Partial.View) throws -> R) rethrows -> R {
    try body(Value.Partial.streamView(UnsafeMutableRawPointer(self.storage)))
  }

  /// Installs a parser for the supplied format and optional initial value state.
  ///
  /// ```swift
  /// var stream = PartialsStream<BlogPost>(from: .json())
  /// var inferred = PartialsStream(of: BlogPost.self, from: .json())
  /// ```
  ///
  /// - Parameters:
  ///   - type: The type being parsed. Only there to infer `Value`; defaults to it.
  ///   - initialValue: The partial to start parsing from.
  ///   - format: The format describing the parser that will consume bytes.
  //
  // Must stay `@inlinable`: the schema has to be built in the client module with `Value` concrete,
  // or container roots reach `_openElement`/`_openValue` through value witnesses (~2.9% of a
  // `StreamDictionary<GSoCProject.Partial>` parse).
  @inlinable
  public init(
    of type: Value.Type = Value.self,
    initialValue: Value.Partial = Value.Partial.streamInitialValue(),
    from format: JSONStreamFormat
  ) {
    let storage = Self.allocateStorage()
    storage.initialize(to: initialValue)
    self.storage = storage
    self.parser = JSONParser(bufferCapacity: format.bufferCapacity)
    self.sink = PartialSink(
      root: UnsafeMutableRawPointer(storage), schema: Value.Partial.streamSchema
    )
  }

  deinit {
    // After a consuming `finish()` the slot is uninitialised, not refilled: refilling costs a
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
    guard !self.hasParserFailed else { throw StreamParsingError.parserFailed }
    guard !self.hasFinished else { throw StreamParsingError.parserFinished }
    do {
      try self.parser.parse(byte: byte, into: &self.sink)
    } catch {
      self.hasParserFailed = true
      throw error
    }
  }

  /// Feeds multiple bytes to the parser.
  ///
  /// - Parameter bytes: The byte sequence to parse.
  @inlinable
  public mutating func next(_ bytes: some Sequence<UInt8>) throws {
    guard !self.hasParserFailed else { throw StreamParsingError.parserFailed }
    guard !self.hasFinished else { throw StreamParsingError.parserFinished }
    do {
      try self.parse(bytes)
    } catch {
      self.hasParserFailed = true
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

  /// Completes parsing and returns the final value, consuming the stream.
  ///
  /// The final partial is moved out of the stream, not copied, and converted with
  /// ``StreamParseable/init(streamPartial:)``. A type that is its own partial, such as a generated
  /// `Partial` or a scalar, always converts.
  ///
  /// ```swift
  /// var stream = PartialsStream<BlogPost>(from: .json())
  /// try stream.next(bytes)
  /// let post = try stream.finish()
  /// ```
  ///
  /// To keep a document that left members out, finish with ``finishPartial()`` and convert with
  /// ``StreamParseable/init(orInitial:)``.
  ///
  /// - Returns: The final value.
  /// - Throws: The parser's error when the input does not end a document, and
  ///   ``StreamParsingError/incompleteValue`` when the document does not describe a whole value.
  @inlinable
  @discardableResult
  public consuming func finish() throws -> Value {
    guard !self.hasParserFailed else { throw StreamParsingError.parserFailed }
    guard !self.hasFinished else { throw StreamParsingError.parserFinished }
    do {
      try self.parser.finish(into: &self.sink)
    } catch {
      self.hasParserFailed = true
      throw error
    }
    // Moved bitwise and `deinit` told so. `discard self` would skip the deinit, but it needs every
    // stored property trivially destroyed, and the parser and sink own buffers.
    let partial = self.storage.move()
    self.hasTakenStorage = true
    guard let value = Value(streamPartial: partial) else {
      throw StreamParsingError.incompleteValue
    }
    return value
  }

  /// Completes parsing and returns the final partial, consuming the stream.
  ///
  /// The partial is moved out of the stream, not copied: on a small payload (a tool call) a copy
  /// is a measurable share of the parse.
  ///
  /// - Returns: The final partial.
  @inlinable
  public consuming func finishPartial() throws -> Value.Partial {
    guard !self.hasParserFailed else { throw StreamParsingError.parserFailed }
    guard !self.hasFinished else { throw StreamParsingError.parserFinished }
    do {
      try self.parser.finish(into: &self.sink)
    } catch {
      self.hasParserFailed = true
      throw error
    }
    let value = self.storage.move()
    self.hasTakenStorage = true
    return value
  }

  /// Completes parsing and lends the final partial without copying it, consuming the stream.
#if !LifetimeView
  @unsafe
#endif
  public consuming func finishWithView<R>(
    _ body: (borrowing Value.Partial.View) throws -> R
  ) throws -> R {
    try self.finishInPlace()
    return try self.withView(body)
  }

  /// Completes parsing, returns the final partial, and re-arms the stream for the next document.
  ///
  /// The one finish that keeps the stream: it keeps the parser's buffer, the sink's frame storage
  /// and the value's slot, rewinding their state, so a loop over many small documents of one schema
  /// (a stream of tool calls) pays setup once. The partial is still moved out, not copied.
  ///
  /// - Parameter initialValue: The partial the next document starts parsing from.
  /// - Returns: The final partial of the document just completed.
  @inlinable
  public mutating func finishAndReset(
    to initialValue: Value.Partial = Value.Partial.streamInitialValue()
  ) throws -> Value.Partial {
    guard !self.hasParserFailed else { throw StreamParsingError.parserFailed }
    guard !self.hasFinished else { throw StreamParsingError.parserFinished }
    do {
      try self.parser.finish(into: &self.sink)
    } catch {
      self.hasParserFailed = true
      throw error
    }
    let value = self.storage.move()
    self.storage.initialize(to: initialValue)
    self.parser.reset()
    self.sink.reset()
    return value
  }

  // Validates EOF and leaves the final partial in place, for the library's own iterators: they
  // store their stream, so they cannot consume it, and read the final state through `current` or
  // `withView(_:)` afterwards.
  @inlinable
  mutating func finishInPlace() throws {
    guard !self.hasParserFailed else { throw StreamParsingError.parserFailed }
    guard !self.hasFinished else { throw StreamParsingError.parserFinished }
    self.hasFinished = true
    do {
      try self.parser.finish(into: &self.sink)
    } catch {
      self.hasParserFailed = true
      throw error
    }
  }

  /// Discards whatever state the stream holds and re-arms it for a new document.
  ///
  /// Legal in any state, including after the parser has thrown: a malformed document is recovered
  /// from by resetting and parsing the next one, keeping every allocation.
  ///
  /// - Parameter initialValue: The value state the next document starts parsing from.
  @inlinable
  public mutating func reset(to initialValue: Value.Partial = Value.Partial.streamInitialValue()) {
    self.storage.pointee = initialValue
    self.parser.reset()
    self.sink.reset()
    self.hasFinished = false
    self.hasParserFailed = false
  }
}

extension PartialsStream where Value.Partial == Value {
  /// Installs a parser that starts from `initialValue`, inferring the stream's type from it.
  ///
  /// ```swift
  /// var stream = PartialsStream(initialValue: BlogPost.Partial(), from: .json())
  /// ```
  ///
  /// Only a partial can be inferred this way, because a partial is the one type whose own
  /// partial is itself. Write `PartialsStream<BlogPost>(initialValue:from:)` to seed the stream of
  /// a model type.
  ///
  /// - Parameters:
  ///   - initialValue: The partial to start parsing from.
  ///   - format: The format describing the parser that will consume bytes.
  @_disfavoredOverload
  @inlinable
  public init(initialValue: Value, from format: JSONStreamFormat) {
    self.init(of: Value.self, initialValue: initialValue, from: format)
  }
}
