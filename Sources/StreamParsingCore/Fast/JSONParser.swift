// MARK: - Error

public struct JSONParsingError: Error, Hashable, Sendable {
  public enum Reason: Hashable, Sendable {
    case unexpectedToken
    case invalidNumber
    case invalidLiteral
    case invalidEscape
    case invalidUTF8
    case unterminatedString
    case unterminatedContainer
    case trailingContent
    case depthExceeded
    case bufferExhausted
    case sinkRejectedToken(StreamSinkFailure)
  }

  public var reason: Reason
  public var byteOffset: Int

  public init(reason: Reason, byteOffset: Int) {
    self.reason = reason
    self.byteOffset = byteOffset
  }
}

// MARK: - JSONParser

public struct JSONParser: ~Copyable {
  // Structural states first, with `done` grouped among them, so `isStructural` is one unsigned
  // compare. `consumeStructuralRun` asks it once per byte; nothing else reads the numeric values.
  @usableFromInline
  enum State: UInt8 {
    case value, firstValue, afterValue, key, firstKey, afterKey, done
    case inString, inKey, escape, unicode, number, literal
    // A sink answered `.skip` at a container open: the subtree is scanned structurally
    // (JSONParserSkip.swift), `skipEndDepth` naming where it ends; the string and escape twins
    // carry a skipped string across a chunk boundary. Past `done` so `isStructural` stays one compare.
    case skipping, skippingString, skippingEscape

    @inlinable
    var isStructural: Bool { self.rawValue <= State.done.rawValue }
  }

  @usableFromInline static let maximumDepth = 64

  // Field order is a cache-line decision: everything a parse touches is in the first 64 bytes, the
  // tail holds deinit-only and window state. Small fields are narrowed, not bit-packed -- packing
  // would make plain stores read-modify-writes and break the fused `strh` for the two flags below.
  @usableFromInline var state = State.value
  // Whether the string being read is a key; the escape and unicode states are shared. `bufferCount
  // > 0` cannot stand in: a key whose first character is an escape has buffered nothing yet.
  @usableFromInline var isKeyToken = false
  @usableFromInline var keyContainsNonASCII = false
  // A string value's opening quote is consumed and its `stringBegin` not yet recorded: the string
  // loop records one whole `string` event if the string completes cleanly, chunks otherwise.
  @usableFromInline var stringBeginPending = false
  @usableFromInline var literalKind: UInt8 = 0
  @usableFromInline var literalIndex: UInt8 = 0
  @usableFromInline var pendingUTF8Count: UInt8 = 0
  @usableFromInline var unicodeRemaining: UInt8 = 0
  // The depth the current skip ends at; a close back to it leaves skip mode. Valid only while
  // `state` is a skipping state, and bounded by `maximumDepth`, so a byte.
  @usableFromInline var skipEndDepth: UInt8 = 0
  // Offset 9 is padding; any new one-byte field belongs there. Measured: anywhere earlier shifts
  // `literalKind`/`literalIndex` to offset 5/6 and the literal path's fused halfword store stops
  // being two-byte aligned -- every `consumeStructuralRun` specialisation turned `strh` into `sturh`.

  // Four hex digits and a surrogate half: sixteen bits each, exactly.
  @usableFromInline var unicodeValue: UInt16 = 0
  @usableFromInline var highSurrogate: UInt16 = 0

  // Split out of `UnsafeMutableBufferPointer` so the capacity sits next to the count the append
  // guard compares it against: one 8-byte load answers both. `init(buffer:)` rejects anything larger.
  @usableFromInline var bufferCount: UInt32 = 0
  @usableFromInline var bufferCapacity: UInt32

  // 1 = object, 0 = array, indexed by depth. Adjacent to `depth` so the run loop's write-back is
  // one `stp` and its entry one `ldp`. Depth past `maximumDepth` is rejected rather than spilled.
  @usableFromInline var containers: UInt64 = 0
  @usableFromInline var depth = 0

  @usableFromInline var bufferBase: UnsafeMutablePointer<UInt8>

  // A UTF-8 sequence straddling a chunk boundary, held little-endian a byte per lane. Nothing is
  // reserved in the buffer for it; the escape scratch is a local in the function that decodes it.
  @usableFromInline var pendingUTF8: UInt64 = 0

  @usableFromInline var consumedByteCount = 0

  // ---- Past the first cache line: nothing below is read by a parse.

  @usableFromInline var ownsBuffer: Bool

  // The structural run's block path (JSONParserBlocks.swift), on by default; off makes the scalar
  // ladder the whole run, which is the oracle `StructuralBlockWalkTests` holds it to. Declared here
  // because the bytes after `ownsBuffer` are padding: anywhere else grows `JSONParser`, which
  // `parse`'s prologue copies by value (measured: two instructions per specialisation).
  @usableFromInline package var blockWalkEnabled = true

  // The walk's verdict on this payload and the consecutive strikes behind it (the gate in
  // JSONParserBlocks.swift), initialised from `blockKernelsAvailable`, which `reset` restores. On
  // x86 the verdict also carries "no AVX2 classifier", so the run's entry test is the availability
  // test. Measured: one packed byte cost `Mesh - bulk` -4.0% against -8.8%; keep two adjacent bytes.
  #if arch(x86_64)
    @usableFromInline package var blockWalkGivenUp = !streamHasAVX2BlockKernels
  #elseif arch(arm64)
    @usableFromInline package var blockWalkGivenUp = false
  #else
    @usableFromInline package var blockWalkGivenUp = true
  #endif
  @usableFromInline package var blockWalkStrikes: UInt8 = 0

  // Whether this CPU has the block classifiers both 64-byte block paths need: the constant `true`
  // on arm64, a byte copied from the process-wide probe once per parser on x86.
  #if arch(x86_64)
    @usableFromInline package var blockKernelsAvailable = streamHasAVX2BlockKernels
  #elseif arch(arm64)
    @inlinable package var blockKernelsAvailable: Bool { true }
  #else
    @inlinable package var blockKernelsAvailable: Bool { false }
  #endif

  // A chunk at least this long takes the windowed path (JSONParserWindow.swift). The window
  // scratch is allocated on first use, so a parser that never sees a large chunk never pays.
  @usableFromInline var windowThreshold: Int
  @usableFromInline var windowScratch: UnsafeMutableRawPointer? = nil
  // Entries per 64-byte block in the last indexed window, and how many windows since. Sparse
  // windows are routed to the dispatcher; see `parseWindowed`.
  @usableFromInline var windowDensity: UInt32 = .max
  @usableFromInline var windowsSinceProbe: UInt32 = 0

  public init(bufferCapacity: Int = 4096, windowThreshold: Int = .max) {
    // `bufferCapacity` is narrowed to `UInt32` below and `capacity &+ scratchByteCount` would wrap
    // on a 32-bit `Int` target. Unsigned so the `Int(UInt32.max)` cannot itself overflow there.
    precondition(
      UInt(bufferCapacity) <= UInt(UInt32.max),
      "JSONParser requires a buffer capacity smaller than 4 GB."
    )
    let capacity = Swift.max(bufferCapacity, 64)
    self.bufferBase = .allocate(capacity: capacity &+ Self.scratchByteCount)
    self.bufferCapacity = UInt32(capacity)
    self.ownsBuffer = true
    self.windowThreshold = windowThreshold
  }

  public init(buffer: UnsafeMutableBufferPointer<UInt8>, windowThreshold: Int = .max) {
    precondition(
      buffer.count >= Self.minimumBufferByteCount,
      "JSONParser requires a caller-supplied buffer of at least \(Self.minimumBufferByteCount) bytes."
    )
    // Unsigned: `Int(UInt32.max)` overflows wherever `Int` is 32 bits (wasm32, embedded targets).
    precondition(
      UInt(buffer.count) <= UInt(UInt32.max),
      "JSONParser requires a caller-supplied buffer smaller than 4 GB."
    )
    self.bufferBase = buffer.baseAddress.unsafelyUnwrapped
    self.bufferCapacity = UInt32(buffer.count &- Self.scratchByteCount)
    self.ownsBuffer = false
    self.windowThreshold = windowThreshold
  }

  deinit {
    if self.ownsBuffer { self.bufferBase.deallocate() }
    self.windowScratch?.deallocate()
  }

  /// Rewinds the parser to its freshly initialized state while keeping its allocations.
  ///
  /// The buffer and the window scratch survive: they are the whole cost of constructing a parser.
  /// Legal in any state, including after a thrown parse.
  public mutating func reset() {
    self.state = .value
    self.containers = 0
    self.depth = 0
    self.bufferCount = 0
    self.unicodeValue = 0
    self.unicodeRemaining = 0
    self.highSurrogate = 0
    self.pendingUTF8 = 0
    self.isKeyToken = false
    self.keyContainsNonASCII = false
    self.stringBeginPending = false
    self.literalKind = 0
    self.literalIndex = 0
    self.skipEndDepth = 0
    self.pendingUTF8Count = 0
    self.consumedByteCount = 0
    self.blockWalkGivenUp = !self.blockKernelsAvailable
    self.blockWalkStrikes = 0
    // Window telemetry describes the previous document's shape; the next may not share it.
    self.windowDensity = .max
    self.windowsSinceProbe = 0
  }

  public var byteOffset: Int { self.consumedByteCount }

  // MARK: Entry points

  @inlinable
  public mutating func parse<Sink: StreamParseSink & ~Copyable>(
    _ input: Span<UInt8>,
    into sink: inout Sink
  ) throws(JSONParsingError) {
    try input.withUnsafeBufferPointer { buffer throws(JSONParsingError) in
      try self.parse(buffer, into: &sink)
    }
  }

  @inlinable
  public mutating func parse<Sink: StreamParseSink & ~Copyable>(
    byte: UInt8,
    into sink: inout Sink
  ) throws(JSONParsingError) {
    // Byte-fed input's one shape: an ordinary ASCII byte inside a string value, which produces
    // exactly one `stringChunk`. Every condition is one the dispatcher would otherwise settle --
    // pending begin, pending UTF-8, pending high surrogate, `"`, `\`, a control byte -- and
    // anything failing falls through unchanged. Measured: `state` first, then the byte's own range.
    if self.state == .inString,
      byte &- .asciiSpace < 0x60, byte != .asciiQuote, byte != .asciiBackslash,
      !self.stringBeginPending, self.pendingUTF8Count == 0, self.highSurrogate == 0
    {
      try self.deliverStringByte(byte, into: &sink)
      return
    }
    var scalar = byte
    try withUnsafePointer(to: &scalar) { pointer throws(JSONParsingError) in
      let base = UnsafeRawPointer(pointer)
      var i = 0
      do throws(JSONParsingError) {
        if self.pendingUTF8Count > 0 {
          i = try self.completePendingUTF8(base: base, count: 1, into: &sink)
        }
        while i < 1 {
          i = try self.dispatchOnce(base: base, from: i, to: 1, into: &sink)
        }
      } catch {
        try self.settlePendingStringBegin(base: base, chunkEnd: 1, into: &sink)
        try self.commitSink(chunkEnd: 1, replacing: error, into: &sink)
      }
      // The byte's pointer does not outlive this closure, so the commit lands before it dies.
      try self.settlePendingStringBegin(base: base, chunkEnd: 1, into: &sink)
      try self.commitSink(chunkEnd: 1, into: &sink)
      self.consumedByteCount &+= 1
    }
  }

  @inlinable
  public mutating func parse<Sink: StreamParseSink & ~Copyable>(
    _ input: UnsafeBufferPointer<UInt8>,
    into sink: inout Sink
  ) throws(JSONParsingError) {
    guard let start = input.baseAddress, !input.isEmpty else { return }
    let base = UnsafeRawPointer(start)
    let n = input.count
    if n >= self.windowThreshold {
      try self.parseWindowed(base: base, count: n, into: &sink)
      return
    }
    do throws(JSONParsingError) {
      try self.parseDispatching(base: base, count: n, into: &sink)
    } catch {
      // The commit lands before the error propagates: everything ahead of the error is the sink's,
      // and a deferring sink's late rejection is earlier in the document and is what gets reported.
      try self.settlePendingStringBegin(base: base, chunkEnd: n, into: &sink)
      try self.commitSink(chunkEnd: n, replacing: error, into: &sink)
    }
    try self.settlePendingStringBegin(base: base, chunkEnd: n, into: &sink)
    try self.commitSink(chunkEnd: n, into: &sink)
    self.consumedByteCount &+= n
  }

  // The bulk loop, split out only so `parse` can wrap it in the flush-on-error handler; forced
  // inline so its layout is what it was when it lived in `parse`.
  @inlinable
  @inline(__always)
  mutating func parseDispatching<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer, count n: Int, into sink: inout Sink
  ) throws(JSONParsingError) {
    var i = 0
    if self.pendingUTF8Count > 0 {
      i = try self.completePendingUTF8(base: base, count: n, into: &sink)
    }

    // The thirteen-case switch lives once, in `dispatchOnce`, which the windowed seam also runs.
    while i < n {
      i = try self.dispatchOnce(base: base, from: i, to: n, into: &sink)
    }
  }

  @inlinable
  public mutating func finish<Sink: StreamParseSink & ~Copyable>(
    into sink: inout Sink
  ) throws(JSONParsingError) {
    switch self.state {
    case .number:
      try self.emitBufferedNumber(into: &sink, reportAt: 0)
      self.state = .done
    case .value, .firstValue, .key, .firstKey, .afterKey:
      throw self.error(.unexpectedToken, at: 0)
    case .inString, .inKey, .escape, .unicode, .skippingString, .skippingEscape:
      throw self.error(.unterminatedString, at: 0)
    case .literal:
      throw self.error(.invalidLiteral, at: 0)
    case .skipping:
      throw self.error(.unterminatedContainer, at: 0)
    case .afterValue, .done:
      break
    }
    // Everything is emitted; the lifetime signal goes out before the structural checks, which
    // deliver nothing new. `.number` above moves to `.done` *before* these can throw, so a second
    // `finish()` after a caught `unterminatedContainer` raises again rather than re-emitting.
    try self.commitSink(chunkEnd: 0, into: &sink)
    if self.depth > 0 { throw self.error(.unterminatedContainer, at: 0) }
    if self.pendingUTF8Count > 0 { throw self.error(.invalidUTF8, at: 0) }
  }

  // MARK: Structural

  // The structural run: the loop stays here while the state stays structural, so a run of structural
  // bytes costs one call rather than a dispatch each. `state`, `depth` and `containers` are run
  // locals written back on every exit. `@inline(never)` with `consumeStructural` folded in; but
  // `checkEmission` still runs per byte, so a rejection stops at its own token (`ErrorOffsetTests`).
  //
  // Two copies of the loop, `blocks` a literal at both call sites. Measured: one shared loop cost
  // `Mesh - bulk` -7.3% and `Canada - bulk` -4.0% from the branch merely being present, and the
  // shared body must be `@_transparent` -- `@inline(__always)` cost 4.0%/2.0% and `@inlinable`
  // 7.4%/4.7% on the identical scalar loop.
  @inlinable
  @inline(never)
  mutating func consumeStructuralRun<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer,
    from: Int,
    to: Int,
    into sink: inout Sink
  ) throws(JSONParsingError) -> Int {
    #if arch(arm64)
      if self.blockWalkEnabled && !self.blockWalkGivenUp {
        return try self.structuralRun(base: base, from: from, to: to, blocks: true, into: &sink)
      }
    #elseif arch(x86_64)
      // `blockWalkGivenUp` also says the CPU lacks the AVX2 classifier, so this is the
      // availability check too. The block copy is a call, not a second inlined body -- measured:
      // both inlined moved `self` out of `r14` and cost `Mesh - bulk` -7.8% against -2.5%.
      if self.blockWalkEnabled && !self.blockWalkGivenUp {
        return try self.consumeStructuralRunBlocks(base: base, from: from, to: to, into: &sink)
      }
    #endif
    return try self.structuralRun(base: base, from: from, to: to, blocks: false, into: &sink)
  }

  #if arch(x86_64)
    // The `blocks: true` copy of the run, on its own (see `consumeStructuralRun`).
    @inlinable
    @inline(never)
    mutating func consumeStructuralRunBlocks<Sink: StreamParseSink & ~Copyable>(
      base: UnsafeRawPointer,
      from: Int,
      to: Int,
      into sink: inout Sink
    ) throws(JSONParsingError) -> Int {
      try self.structuralRun(base: base, from: from, to: to, blocks: true, into: &sink)
    }
  #endif

  @_transparent
  @usableFromInline
  mutating func structuralRun<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer,
    from: Int,
    to: Int,
    blocks: Bool,
    into sink: inout Sink
  ) throws(JSONParsingError) -> Int {
    var i = from
    var state = self.state
    var depth = self.depth
    var containers = self.containers
    defer {
      self.state = state
      self.depth = depth
      self.containers = containers
    }
    while i < to {
      #if arch(arm64) || arch(x86_64)
        // The 64-byte block path (JSONParserBlocks.swift), tried at every token boundary because
        // that is where it is re-entered: anything it will not judge comes back here, and the
        // next block is available once this loop settles that token. `state.isStructural` is not
        // tested -- the loop only reaches its own top in a structural state.
        if blocks, i &+ 64 <= to {
          // Copies scoped to this branch, not the run's own locals: taking the address of `depth`
          // and `containers` makes `var depth = self.depth` address-taken, and the store it
          // becomes lands in the entry block, on every byte-fed call that never gets here.
          var blockState = state
          var blockDepth = depth
          var blockContainers = containers
          defer {
            state = blockState
            depth = blockDepth
            containers = blockContainers
          }
          i = try self.consumeStructuralBlocks(
            base: base, from: i, to: to, state: &blockState, depth: &blockDepth,
            containers: &blockContainers, into: &sink
          )
          // A negative answer is the walk giving up on this payload's shape (the gate in
          // JSONParserBlocks.swift); the index is its bitwise complement. Breaking honours it
          // without the loop holding anything mutable -- the dispatcher re-enters at once.
          if i < 0 {
            i = ~i
            break
          }
          // A block that handed the parse to the skip scanner, the string loop or the number path
          // leaves the run exactly as the step below would have.
          if !blockState.isStructural { break }
        }
      #endif
      // The scan hands back the byte it stopped on, so the dispatch below reads a register instead
      // of reloading the address the scan's one-compare fast path just tested.
      let scanned = streamWhitespaceEndByte(base: base, from: i, to: to)
      i = scanned.end
      if i == to { break }
      let byte = scanned.byte
      i &+= 1
      // A number is the one token whose first byte belongs to the token itself, so the run ends
      // and the byte is handed back for `.number` to re-read.
      if try self.consumeStructural(
        byte, base: base, cursor: &i, to: to, state: &state, depth: &depth,
        containers: &containers, into: &sink
      ) {
        i &-= 1
        break
      }
      if !state.isStructural { break }
    }
    return i
  }

  @inlinable
  @_transparent
  mutating func consumeStructural<Sink: StreamParseSink & ~Copyable>(
    _ byte: UInt8,
    base: UnsafeRawPointer,
    cursor: inout Int,
    to: Int,
    state: inout State,
    depth: inout Int,
    containers: inout UInt64,
    into sink: inout Sink
  ) throws(JSONParsingError) -> Bool {
    let at = cursor &- 1
    // A ladder over the raw value, not a `switch`, which lowers to a jump table and an indirect
    // branch per structural byte. The `State` order makes each rung one unsigned compare.
    let raw = state.rawValue
    // A quote in a value or key state is scanned here, once, ahead of the ladder: the string
    // scanner is the largest thing inlined into this function and keys and string values share
    // one copy. Only a cut token, or one with an escape, sets the per-byte state and leaves.
    if byte == .asciiQuote, raw <= State.firstKey.rawValue, raw != State.afterValue.rawValue {
      let run = streamStringRun(base: base, from: cursor, to: to)
      let closed = run.end < to && base.load(fromByteOffset: run.end, as: UInt8.self) == .asciiQuote
      // A run stopping short of the closing quote leaves the token whole to the per-byte path,
      // which rescans from the opening quote. Measured: handing the scanned prefix on instead cost
      // `twitter` 2% and `Pretty printed users` 3-7%; keep the rescan.
      if raw <= State.firstValue.rawValue {
        self.isKeyToken = false
        guard closed else {
          // The scan stopped inside the chunk, so the byte is a backslash (or a control byte,
          // the same error either way): the escapes decode here rather than the token being
          // handed back and rescanned. `self.state` carries the verdict back.
          if run.end < to {
            cursor = try self.consumeEscapedStringInRun(
              base: base, quoteAt: at, from: cursor, to: to, run: run, into: &sink
            )
            state = self.state
            return false
          }
          // Cut by the chunk end: `consumeStringRun` records the `stringBegin` and takes the token
          // from the opening quote.
          self.stringBeginPending = true
          state = .inString
          return false
        }
        // One whole `string` record, the same event `consumeStringRun` and the windowed walk
        // record for a clean string, with the same rejection point (the opening quote).
        do throws(JSONParsingError) {
          try self.validateUTF8IfNeeded(
            base: base, from: cursor, to: run.end, containsNonASCII: run.containsNonASCII,
            reportAt: nil
          )
        } catch {
          // `stringBegin` precedes the error on the call-per-event path; keep that order.
          try self.record(.stringBegin, start: at, length: 1, end: cursor, base: base, into: &sink)
          try Self.fail(error)
        }
        try self.record(.string, start: cursor, length: run.end &- cursor, end: run.end &+ 1, base: base, into: &sink)
        cursor = run.end &+ 1
        state = .afterValue
        return false
      }
      guard closed else {
        self.isKeyToken = true
        self.bufferCount = 0
        self.keyContainsNonASCII = false
        state = .inKey
        return false
      }
      try self.emitKeyInPlace(
        base: base, from: cursor, to: run.end, containsNonASCII: run.containsNonASCII, into: &sink
      )
      cursor = run.end &+ 1
      state = .afterKey
      return false
    }
    if raw <= State.firstValue.rawValue {
      switch byte {
      case .asciiObjectStart:
        let disposition = try self.recordContainerOpen(object: true, end: cursor, into: &sink)
        guard depth < Self.maximumDepth else { try Self.fail(.depthExceeded, byteOffset: self.consumedByteCount &+ at) }
        Self.pushContainer(object: true, depth: &depth, containers: &containers)
        // A skip leaves the run: the loop's `isStructural` check breaks and the dispatcher
        // re-enters through the skip scanner. For a constant-`.stream` sink the branch folds away.
        if disposition != .stream {
          self.skipEndDepth = UInt8(truncatingIfNeeded: depth &- 1)
          state = .skipping
        } else {
          state = .firstKey
        }
      case .asciiArrayStart:
        let disposition = try self.recordContainerOpen(object: false, end: cursor, into: &sink)
        guard depth < Self.maximumDepth else { try Self.fail(.depthExceeded, byteOffset: self.consumedByteCount &+ at) }
        Self.pushContainer(object: false, depth: &depth, containers: &containers)
        if disposition != .stream {
          self.skipEndDepth = UInt8(truncatingIfNeeded: depth &- 1)
          state = .skipping
        } else {
          state = .firstValue
        }
      case .asciiArrayEnd:
        guard state == .firstValue, !Self.topIsObject(depth: depth, containers: containers) else {
          try Self.fail(.unexpectedToken, byteOffset: self.consumedByteCount &+ at)
        }
        try self.record(.endArray, start: at, length: 1, end: cursor, base: base, into: &sink)
        depth &-= 1
        state = depth == 0 ? .done : .afterValue
      // `"` was taken ahead of the ladder.
      case .asciiLowerT:
        // A literal whole in the chunk is one word compare and an event, so the run carries on to
        // the comma. `.literal` remains for a literal the chunk cuts, which is every byte-fed one.
        if to &- at >= 4,
          UInt32(littleEndian: base.loadUnaligned(fromByteOffset: at, as: UInt32.self))
            == 0x6575_7274
        {
          try self.record(.boolean, start: at, length: 4, end: at &+ 4, extra: 1, base: base, into: &sink)
          cursor = at &+ 4
          state = .afterValue
          return false
        }
        self.startLiteral(kind: 0)
        state = .literal
      case .asciiLowerF:
        if to &- at >= 5,
          UInt32(littleEndian: base.loadUnaligned(fromByteOffset: at &+ 1, as: UInt32.self))
            == 0x6573_6c61
        {
          try self.record(.boolean, start: at, length: 5, end: at &+ 5, base: base, into: &sink)
          cursor = at &+ 5
          state = .afterValue
          return false
        }
        self.startLiteral(kind: 1)
        state = .literal
      case .asciiLowerN:
        if to &- at >= 4,
          UInt32(littleEndian: base.loadUnaligned(fromByteOffset: at, as: UInt32.self))
            == 0x6c6c_756e
        {
          try self.record(.null, start: at, length: 4, end: at &+ 4, base: base, into: &sink)
          cursor = at &+ 4
          state = .afterValue
          return false
        }
        self.startLiteral(kind: 2)
        state = .literal
      case .asciiDash, .asciiZero ... .asciiNine:
        // A number whose terminator is in this chunk is scanned, parsed and emitted here, so the
        // run carries on to the comma. `bufferCount` is zero by construction -- the buffer only
        // holds a token a previous chunk cut, and such a token resumes from `.number` -- so this
        // is `consumeNumber`'s `bufferCount == 0` arm. The run is the fusion, so no fuse here.
        let end = streamNumberRunEnd(base: base, from: at, to: to)
        guard end < to else {
          // The token may continue in the next chunk, so it goes to the per-byte path whole, which
          // buffers it. This is also the path byte-fed input always takes.
          self.resetNumber()
          state = .number
          return true
        }
        try self.emitNumber(base: base, from: at, to: end, into: &sink, reportAt: end)
        cursor = end
        state = .afterValue
        return false
      default:
        try Self.fail(.unexpectedToken, byteOffset: self.consumedByteCount &+ at)
      }

    } else if raw == State.afterValue.rawValue {
      switch byte {
      case .asciiComma:
        guard depth > 0 else { try Self.fail(.unexpectedToken, byteOffset: self.consumedByteCount &+ at) }
        state = Self.topIsObject(depth: depth, containers: containers) ? .key : .value
      case .asciiArrayEnd:
        guard depth > 0, !Self.topIsObject(depth: depth, containers: containers) else {
          try Self.fail(.unexpectedToken, byteOffset: self.consumedByteCount &+ at)
        }
        try self.record(.endArray, start: at, length: 1, end: cursor, base: base, into: &sink)
        depth &-= 1
        state = depth == 0 ? .done : .afterValue
      case .asciiObjectEnd:
        guard Self.topIsObject(depth: depth, containers: containers) else {
          try Self.fail(.unexpectedToken, byteOffset: self.consumedByteCount &+ at)
        }
        try self.record(.endObject, start: at, length: 1, end: cursor, base: base, into: &sink)
        depth &-= 1
        state = depth == 0 ? .done : .afterValue
      default:
        try Self.fail(.unexpectedToken, byteOffset: self.consumedByteCount &+ at)
      }

    } else if raw <= State.firstKey.rawValue {
      switch byte {
      // `"` was taken ahead of the ladder.
      case .asciiObjectEnd:
        guard state == .firstKey, Self.topIsObject(depth: depth, containers: containers) else {
          try Self.fail(.unexpectedToken, byteOffset: self.consumedByteCount &+ at)
        }
        try self.record(.endObject, start: at, length: 1, end: cursor, base: base, into: &sink)
        depth &-= 1
        state = depth == 0 ? .done : .afterValue
      default:
        try Self.fail(.unexpectedToken, byteOffset: self.consumedByteCount &+ at)
      }

    } else if raw == State.afterKey.rawValue {
      guard byte == .asciiColon else { try Self.fail(.unexpectedToken, byteOffset: self.consumedByteCount &+ at) }
      state = .value
    } else if raw == State.done.rawValue {
      try Self.fail(.trailingContent, byteOffset: self.consumedByteCount &+ at)
    } else {
      try Self.fail(.unexpectedToken, byteOffset: self.consumedByteCount &+ at)
    }
    return false
  }


  // A value inside a container is followed by `,` and then the next value's first byte, so taking
  // both leaves nothing structural before the next value and that member's `consumeStructuralRun`
  // call disappears. Arrays too -- measured: objects only cost `canada` -3.8%.
  //
  // A sink that has already failed stops the fusion: correctness, not tuning. `parse` reads the
  // failure once per token with the cursor as the offset, so a fusion that ran first moved the
  // cursor onto the next token first (`[1,2]` refusing numbers reported byte 3 for the `1`).
  @inlinable
  @inline(__always)
  mutating func fuseAfterValue<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer, from: Int, to: Int, into sink: inout Sink
  ) throws(JSONParsingError) -> Int {
    guard self.depth > 0, from < to,
      base.load(fromByteOffset: from, as: UInt8.self) == .asciiComma
    else {
      return from
    }
    let next = streamWhitespaceEnd(base: base, from: from &+ 1, to: to)
    guard next < to else { return from }
    let byte = base.load(fromByteOffset: next, as: UInt8.self)

    if self.topIsObject {
      // The quote is left for the structural run, which reads the key in place and carries on
      // through the colon; entering `.inKey` here would send the key through the buffered path.
      guard byte == .asciiQuote else { return from }
      self.state = .key
      return next
    }

    switch byte {
    case .asciiQuote:
      self.isKeyToken = false
      self.stringBeginPending = true
      self.state = .inString
      return next &+ 1
    case .asciiDash, .asciiZero ... .asciiNine:
      // The first byte of a number belongs to the number, so it is left for `.number` to re-read.
      self.resetNumber()
      self.state = .number
      return next
    default:
      return from
    }
  }

  // MARK: Strings

  // String values only; a key goes through the structural run in place or through `consumeKeyRun`.
  // This is the byte-fed path's per-byte call, and one more live value is a spill on every call.
  @inlinable
  mutating func consumeStringRun<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer,
    from: Int,
    to: Int,
    into sink: inout Sink
  ) throws(JSONParsingError) -> Int {
    var i = from
    let run = streamStringRun(base: base, from: i, to: to)
    if self.stringBeginPending {
      self.stringBeginPending = false
      // The whole string is in this chunk and has no escape: one `string` record, the same
      // event the windowed walk records, with the same rejection point (the opening quote).
      if run.end < to, base.load(fromByteOffset: run.end, as: UInt8.self) == .asciiQuote {
        do throws(JSONParsingError) {
          try self.validateUTF8IfNeeded(
            base: base, from: i, to: run.end, containsNonASCII: run.containsNonASCII,
            reportAt: nil
          )
        } catch {
          // `stringBegin` precedes the error on the call-per-event path; keep that order.
          try self.record(.stringBegin, start: Swift.max(i &- 1, 0), length: 1, end: i, base: base, into: &sink)
          throw error
        }
        try self.record(.string, start: i, length: run.end &- i, end: run.end &+ 1, base: base, into: &sink)
        self.state = .afterValue
        return try self.fuseAfterValue(base: base, from: run.end &+ 1, to: to, into: &sink)
      }
      // The quote may be in the previous chunk; `i` is where its `stringBegin` was read.
      try self.record(.stringBegin, start: Swift.max(i &- 1, 0), length: 1, end: i, base: base, into: &sink)
    }
    return try self.stringRunBody(base: base, from: i, to: to, run: run, into: &sink)
  }

  // The string value body proper, split out of `consumeStringRun` so the structural run can enter
  // it with a scan it already paid for; `@inline(__always)`, so `consumeStringRun` is byte for
  // byte what it was. `run` is the only scan this body makes -- every escape leaves for the tail.
  @inlinable
  @inline(__always)
  mutating func stringRunBody<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer,
    from: Int,
    to: Int,
    run: StreamStringRun,
    into sink: inout Sink
  ) throws(JSONParsingError) -> Int {
    var i = from
    let end = run.end

    if end > i {
      if self.highSurrogate != 0 { throw self.loneHighSurrogateError(reportAt: i) }
      let emitEnd = end == to ? try self.trimmingIncompleteUTF8(base: base, from: i, to: end) : end
      if emitEnd > i {
        try self.validateUTF8IfNeeded(
          base: base,
          from: i,
          to: emitEnd,
          containsNonASCII: run.containsNonASCII,
          reportAt: nil
        )
        try self.record(.stringChunk, start: i, length: emitEnd &- i, end: emitEnd, base: base, into: &sink)
      }
      if emitEnd < end {
        try self.holdPendingUTF8(base: base, from: emitEnd, to: end)
      }
      i = end
    }

    guard i < to else { return i }

    let byte = base.load(fromByteOffset: i, as: UInt8.self)
    let byteAt = i
    i &+= 1
    if byte == .asciiQuote {
      if self.highSurrogate != 0 { throw self.loneHighSurrogateError(reportAt: byteAt) }
      try self.record(.stringEnd, start: byteAt, length: 1, end: i, base: base, into: &sink)
      self.state = .afterValue
      return try self.fuseAfterValue(base: base, from: i, to: to, into: &sink)
    } else if byte == .asciiBackslash {
      // The rest of this value is taken coalesced, out of line: the decode, the surrogate handling
      // and the buffer bookkeeping all leave this function, which cannot afford to grow. A
      // backslash that is the chunk's last byte cannot fuse and is answered here -- measured: the
      // call cost `Twitter escaped - byte by byte` -1.6%. Nothing is buffered yet on this edge.
      guard i < to else {
        self.state = .escape
        return i
      }
      return try self.coalescedEscapedStringTail(base: base, from: i, to: to, into: &sink)
    } else {
      throw self.error(.unterminatedString, at: byteAt)
    }
  }

  // The remainder of a string value from its first escape, coalesced into the parser's buffer and
  // handed over one chunk per buffer-full. Every sink takes this path; chunk boundaries were never
  // promised. Every non-throwing exit flushes, so the per-byte states find nothing buffered.
  //
  // Out of line by force -- measured: spelled inside `stringRunBody` it cost raw llm -52%, gsoc
  // -23%, twitter -15%. The buffered escape arm exists only here, selected by the `coalescing:
  // true` literal; as a runtime flag in `emitScratch` it cost LLM byte-fed 4.9%.
  @inlinable
  @inline(never)
  mutating func coalescedEscapedStringTail<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer, from: Int, to: Int, into sink: inout Sink
  ) throws(JSONParsingError) -> Int {
    var i = from
    // The escape that sent us here, decoded first. A decode that cannot fuse has emitted
    // nothing, so falling back to the per-byte states is the same fall-back the run body made.
    guard
      let fused = try self.fusedEscapeEnd(
        base: base, from: i, to: to, coalescing: true, into: &sink
      )
    else {
      self.state = .escape
      return i
    }
    i = fused
    while true {
      let run = streamStringRun(base: base, from: i, to: to)
      let end = run.end

      if end > i {
        if self.highSurrogate != 0 { throw self.loneHighSurrogateError(reportAt: i) }
        let emitEnd = end == to ? try self.trimmingIncompleteUTF8(base: base, from: i, to: end) : end
        if emitEnd > i {
          try self.validateUTF8IfNeeded(
            base: base, from: i, to: emitEnd, containsNonASCII: run.containsNonASCII, reportAt: nil
          )
          try self.bufferStringRun(
            base: base, from: i, count: emitEnd &- i, end: emitEnd, to: to, into: &sink
          )
        }
        if emitEnd < end {
          try self.holdPendingUTF8(base: base, from: emitEnd, to: end)
        }
        i = end
      }

      guard i < to else {
        try self.flushStringBuffer(into: &sink, end: i)
        return i
      }

      let byte = base.load(fromByteOffset: i, as: UInt8.self)
      let byteAt = i
      i &+= 1
      if byte == .asciiQuote {
        if self.highSurrogate != 0 { throw self.loneHighSurrogateError(reportAt: byteAt) }
        try self.flushStringBuffer(into: &sink, end: byteAt)
        try self.record(.stringEnd, start: byteAt, length: 1, end: i, base: base, into: &sink)
        self.state = .afterValue
        return try self.fuseAfterValue(base: base, from: i, to: to, into: &sink)
      } else if byte == .asciiBackslash {
        if let next = try self.fusedEscapeEnd(
          base: base, from: i, to: to, coalescing: true, into: &sink
        ) {
          i = next
          continue
        }
        try self.flushStringBuffer(into: &sink, end: i)
        self.state = .escape
        return i
      } else {
        throw self.error(.unterminatedString, at: byteAt)
      }
    }
  }

  // A string value whose scan stopped on a backslash with the closing quote still inside the
  // chunk, finished here instead of handed back and rescanned from the opening quote. Out of line
  // by force. The emission sequence is `consumeStringRun`'s byte for byte; anything it cannot
  // finish leaves `self.state` as the out-of-run path would, and the caller copies it back.
  //
  // It must NOT fuse the comma: `fuseAfterValue` reads `self.depth`/`self.containers`, which the
  // structural run holds in registers, so from here they are the stack as of the run's *entry* --
  // a chunk beginning inside an array read the following key as a string value. It declines by
  // zeroing `self.depth`; measured: both more direct spellings cost more (byte-fed typed -5%).
  @inlinable
  @inline(never)
  mutating func consumeEscapedStringInRun<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer,
    quoteAt: Int,
    from: Int,
    to: Int,
    run: StreamStringRun,
    into sink: inout Sink
  ) throws(JSONParsingError) -> Int {
    // The resting state for a token this chunk cuts. Entering from the structural run means
    // nobody has set it yet, and a chunk ending mid-token would otherwise resume structural.
    self.state = .inString
    // Declines `fuseAfterValue` -- see above. The run's write-back restores the real depth.
    self.depth = 0
    try self.record(.stringBegin, start: quoteAt, length: 1, end: from, base: base, into: &sink)
    return try self.stringRunBody(base: base, from: from, to: to, run: run, into: &sink)
  }

  // A key the structural run could not read in place -- closing quote past the chunk, or an escape
  // to decode -- buffered and emitted whole at its closing quote. Byte-fed input sends every key here.
  @inlinable
  @inline(never)
  mutating func consumeKeyRun<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer,
    from: Int,
    to: Int,
    into sink: inout Sink
  ) throws(JSONParsingError) -> Int {
    var i = from
    while true {
      let run = streamStringRun(base: base, from: i, to: to)
      let end = run.end

      if end > i {
        if self.highSurrogate != 0 { throw self.loneHighSurrogateError(reportAt: i) }
        self.keyContainsNonASCII = self.keyContainsNonASCII || run.containsNonASCII
        try self.appendToBuffer(base: base, from: i, count: end &- i, reportAt: i)
        i = end
      }

      guard i < to else { return i }

      let byte = base.load(fromByteOffset: i, as: UInt8.self)
      let byteAt = i
      i &+= 1
      if byte == .asciiQuote {
        if self.highSurrogate != 0 { throw self.loneHighSurrogateError(reportAt: byteAt) }
        try self.emitBufferedKey(into: &sink, reportAt: byteAt)
        self.state = .afterKey
        return i
      } else if byte == .asciiBackslash {
        if let fused = try self.fusedEscapeEnd(
          base: base, from: i, to: to, coalescing: false, into: &sink
        ) {
          i = fused
          continue
        }
        self.state = .escape
        return i
      } else {
        throw self.error(.unterminatedString, at: byteAt)
      }
    }
  }

  // A whole escape present in the chunk, decoded here and its end returned, so the string scan
  // never hands control back. Only escapes with no diagnostic attached fuse: a bad hex digit, a
  // lone surrogate, an unrecognised selector, a pending high surrogate or an escape past the chunk
  // end return nil for the per-byte states. `coalescing` is a literal at every call site.
  @inlinable
  @inline(__always)
  mutating func fusedEscapeEnd<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer, from: Int, to: Int, coalescing: Bool, into sink: inout Sink
  ) throws(JSONParsingError) -> Int? {
    guard self.highSurrogate == 0, from < to else { return nil }
    let selector = base.load(fromByteOffset: from, as: UInt8.self)
    guard selector != .asciiLowerU else {
      if coalescing {
        return try self.coalescedUnicodeEscapeEnd(base: base, from: from, to: to, into: &sink)
      }
      return try self.fusedUnicodeEscapeEnd(base: base, from: from, to: to, into: &sink)
    }
    guard let decoded = streamDecodeSimpleEscape(selector) else { return nil }
    if coalescing {
      // A flush here delivers what was buffered *before* the escape, so it reports one past that
      // chunk's last content byte: the backslash, `from &- 1`.
      try self.bufferStringScratch(UInt64(decoded), count: 1, into: &sink, reportAt: from &- 1)
    } else {
      try self.emitDecoded(byte: decoded, into: &sink, reportAt: from)
    }
    return from &+ 1
  }

  // Out of line: the hex decode and surrogate handling are dead weight in callers whose escapes
  // are all one character. Measured: spelled inline alongside the simple escapes it cost `Fast
  // Escaped string` 18.5%. Two entries over one body, since a literal passed to an
  // `@inline(never)` function is a runtime argument inside it.
  @inlinable
  @inline(never)
  mutating func fusedUnicodeEscapeEnd<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer, from: Int, to: Int, into sink: inout Sink
  ) throws(JSONParsingError) -> Int? {
    try self.unicodeEscapeEnd(base: base, from: from, to: to, coalescing: false, into: &sink)
  }

  @inlinable
  @inline(never)
  mutating func coalescedUnicodeEscapeEnd<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer, from: Int, to: Int, into sink: inout Sink
  ) throws(JSONParsingError) -> Int? {
    try self.unicodeEscapeEnd(base: base, from: from, to: to, coalescing: true, into: &sink)
  }

  @inlinable
  @inline(__always)
  mutating func unicodeEscapeEnd<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer, from: Int, to: Int, coalescing: Bool, into sink: inout Sink
  ) throws(JSONParsingError) -> Int? {
    guard from &+ 5 <= to, let scalar = streamHexQuad(base: base, from: from &+ 1) else {
      return nil
    }
    var value = scalar
    var end = from &+ 5

    if scalar >= .highSurrogateFloor, scalar <= .highSurrogateCeiling {
      // A pair is twelve bytes and must be complete and well formed to fuse; anything else is a
      // diagnostic for the per-byte path. The bounds test is first, so the load stays in the chunk.
      guard end &+ 6 <= to,
        UInt16(littleEndian: base.loadUnaligned(fromByteOffset: end, as: UInt16.self))
          == streamUnicodeEscapePrefix,
        let low = streamHexQuad(base: base, from: end &+ 2),
        low >= .lowSurrogateFloor, low <= .lowSurrogateCeiling
      else {
        return nil
      }
      value =
        .utf8ThreeByteCeiling &+ ((scalar &- .highSurrogateFloor) << 10)
        &+ (low &- .lowSurrogateFloor)
      end &+= 6
    } else if scalar >= .lowSurrogateFloor, scalar <= .lowSurrogateCeiling {
      // A lone low surrogate is a diagnostic, so it goes to the per-byte path.
      return nil
    }

    if coalescing {
      // A flush here delivers everything buffered ahead of this escape, so it reports one past
      // that chunk's last content byte: the backslash, `from &- 1` (as `bufferStringRun` does).
      let encoded = Self.utf8Word(value)
      try self.bufferStringScratch(encoded.word, count: encoded.count, into: &sink, reportAt: from &- 1)
    } else {
      // `emitScratch` reports at `reportAt &+ 1`, so `reportAt` must be the escape's *last* byte
      // -- `end &- 1` for a single escape and a surrogate pair alike; `from` reported 4 (10) early.
      try self.emitScalar(value, into: &sink, reportAt: end &- 1)
    }
    return end
  }

  @inlinable
  mutating func consumeEscape<Sink: StreamParseSink & ~Copyable>(
    _ byte: UInt8,
    at offset: Int,
    into sink: inout Sink
  ) throws(JSONParsingError) {
    if byte == .asciiLowerU {
      self.unicodeValue = 0
      self.unicodeRemaining = 4
      self.state = .unicode
      return
    }
    // A high surrogate must be followed immediately by a low surrogate escape; any other escape
    // severs the pair, and severing it first is what keeps the content in order around it.
    if self.highSurrogate != 0 {
      throw self.loneHighSurrogateError(reportAt: offset &- 1)
    }
    guard let decoded = streamDecodeSimpleEscape(byte) else {
      throw self.error(.invalidEscape, at: offset &- 1)
    }
    try self.emitDecoded(byte: decoded, into: &sink, reportAt: offset &- 1)
    self.state = self.stateAfterEscape
  }

  @inlinable
  mutating func consumeUnicodeDigit<Sink: StreamParseSink & ~Copyable>(
    _ byte: UInt8,
    at offset: Int,
    into sink: inout Sink
  ) throws(JSONParsingError) {
    guard let value = Self.hexValue(byte) else { throw self.error(.invalidEscape, at: offset &- 1) }
    // Four hex digits is sixteen bits, so the accumulator and the pending surrogate are stored
    // narrow; the arithmetic below is the scalar's, which is 21 bits, so it widens once here.
    self.unicodeValue = (self.unicodeValue &<< 4) | UInt16(truncatingIfNeeded: value)
    self.unicodeRemaining &-= 1
    guard self.unicodeRemaining == 0 else { return }

    let scalar = UInt32(self.unicodeValue)
    let pending = UInt32(self.highSurrogate)
    if scalar >= .highSurrogateFloor, scalar <= .highSurrogateCeiling {
      // A second high surrogate would silently replace the pending one, leaving the first lone.
      if pending != 0 {
        throw self.loneHighSurrogateError(reportAt: offset &- 1)
      }
      self.highSurrogate = UInt16(truncatingIfNeeded: scalar)
      self.state = self.stateAfterEscape
      return
    }
    if scalar >= .lowSurrogateFloor, scalar <= .lowSurrogateCeiling, pending == 0 {
      throw self.error(.invalidEscape, at: offset &- 1)
    }
    if scalar >= .lowSurrogateFloor, scalar <= .lowSurrogateCeiling, pending != 0 {
      let combined =
        UInt32.utf8ThreeByteCeiling &+ ((pending &- .highSurrogateFloor) &<< 10)
        &+ (scalar &- .lowSurrogateFloor)
      self.highSurrogate = 0
      try self.emitScalar(combined, into: &sink, reportAt: offset &- 1)
    } else {
      // A pending high surrogate followed by any scalar but a low surrogate is lone.
      if pending != 0 {
        throw self.loneHighSurrogateError(reportAt: offset &- 1)
      }
      try self.emitScalar(scalar, into: &sink, reportAt: offset &- 1)
    }
    self.state = self.stateAfterEscape
  }

  // A high surrogate with no low surrogate after it. Out of line, and returning the error rather
  // than throwing it, so the common path at each of the six call sites is a compare against zero.
  @inlinable
  @inline(never)
  func loneHighSurrogateError(reportAt: Int) -> JSONParsingError {
    self.error(.invalidEscape, at: reportAt)
  }

  @inlinable
  var stateAfterEscape: State {
    self.isKeyToken ? .inKey : .inString
  }

  // MARK: Numbers

  @inlinable
  mutating func resetNumber() {
    self.bufferCount = 0
  }

  // The scan is greedy over the number byte class and the parse is one structured walk over the
  // whole token at its end, so a number is reported exactly once, complete. See NEW_ARCHITECTURE.md.
  @inlinable
  mutating func consumeNumber<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer,
    from: Int,
    to: Int,
    into sink: inout Sink
  ) throws(JSONParsingError) -> Int {
    let end = streamNumberRunEnd(base: base, from: from, to: to)
    if end == to {
      // The token may continue in the next chunk, so its bytes are carried whole; a document
      // that ends inside a number is settled by finish().
      try self.appendToBuffer(base: base, from: from, count: end &- from, reportAt: end)
      return end
    }
    if self.bufferCount == 0 {
      try self.emitNumber(base: base, from: from, to: end, into: &sink, reportAt: end)
    } else {
      try self.appendToBuffer(base: base, from: from, count: end &- from, reportAt: end)
      try self.emitBufferedNumber(into: &sink, reportAt: end)
    }
    self.state = .afterValue
    return try self.fuseAfterValue(base: base, from: end, to: to, into: &sink)
  }

  @inlinable
  mutating func emitBufferedNumber<Sink: StreamParseSink & ~Copyable>(
    into sink: inout Sink, reportAt: Int
  ) throws(JSONParsingError) {
    let count = Int(self.bufferCount)
    try self.emitNumber(
      base: UnsafeRawPointer(self.bufferBase), from: 0, to: count, into: &sink,
      reportAt: reportAt
    )
    self.bufferCount = 0
  }

  // Parses and validates in the same walk: the grammar is the segment order, so a byte the grammar
  // has no place for fails the final position check rather than a tracked flag. LOCKSTEP:
  // `JSONParserShapes.parseNumber` is a deliberate copy of this and `emitGeneralNumber`, including
  // the `to >= 8` guard below, which is what keeps `streamShortInteger`'s backward load in bounds.
  @inlinable
  @inline(__always)
  mutating func emitNumber<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer,
    from: Int,
    to: Int,
    into sink: inout Sink,
    reportAt: Int
  ) throws(JSONParsingError) {
    // The shape four of the seven corpus payloads are mostly made of: an unsigned integer of one
    // to eight digits. The kernel's digit test doubles as the shape test, so this replaces the
    // checks below rather than adding to them.
    if to &- from <= 8, to >= 8,
      base.load(fromByteOffset: from, as: UInt8.self) != .asciiZero || to &- from == 1,
      let magnitude = streamShortInteger(base: base, from: from, end: to)
    {
      try self.recordNumber(
        start: from, length: to &- from, end: reportAt,
        base: base,
        info: NumberInfo(
          magnitude: magnitude,
          exponent: 0,
          digitCount: UInt16(truncatingIfNeeded: to &- from),
          flags: []
        ),
        into: &sink
      )
      return
    }
    try self.emitGeneralNumber(base: base, from: from, to: to, into: &sink, reportAt: reportAt)
  }

  // The rest of the walk -- sign, leading zero, fraction, exponent, the final position check and
  // their error constructions -- out of line. `consumeStructural` must stay folded into the
  // structural run, and inlining the grammar walk there would exceed the loop's inliner budget and
  // un-fold the step, costing a `bl` per structural byte. The eight-digit kernel stays inline.
  @inlinable
  @inline(never)
  mutating func emitGeneralNumber<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer,
    from: Int,
    to: Int,
    into sink: inout Sink,
    reportAt: Int
  ) throws(JSONParsingError) {
    var flags = NumberInfo.Flags()
    var i = from
    if i < to, base.load(fromByteOffset: i, as: UInt8.self) == .asciiDash {
      flags.insert(.negative)
      i &+= 1
    }

    var magnitude: UInt64 = 0
    let integerStart = i
    i = streamAccumulateDigits(base: base, from: i, to: to, into: &magnitude)
    let integerDigits = i &- integerStart
    do {
      guard integerDigits > 0 else { throw self.error(.invalidNumber, at: reportAt) }
      if integerDigits > 1, base.load(fromByteOffset: integerStart, as: UInt8.self) == .asciiZero {
        throw self.error(.invalidNumber, at: reportAt)
      }
    }

    var fractionDigits = 0
    if i < to, base.load(fromByteOffset: i, as: UInt8.self) == .asciiDot {
      flags.insert(.fraction)
      i &+= 1
      let fractionStart = i
      i = streamAccumulateDigits(base: base, from: i, to: to, into: &magnitude)
      fractionDigits = i &- fractionStart
      if fractionDigits == 0 { throw self.error(.invalidNumber, at: reportAt) }
    }

    var explicitExponent: Int32 = 0
    var exponentNegative = false
    if i < to, (base.load(fromByteOffset: i, as: UInt8.self) | 0x20) == .asciiLowerE {
      flags.insert(.exponent)
      i &+= 1
      if i < to {
        let sign = base.load(fromByteOffset: i, as: UInt8.self)
        if sign == .asciiDash {
          exponentNegative = true
          i &+= 1
        } else if sign == .asciiPlus {
          i &+= 1
        }
      }
      let exponentStart = i
      while i < to {
        let digit = base.load(fromByteOffset: i, as: UInt8.self) &- .asciiZero
        guard digit < 10 else { break }
        if explicitExponent < 10_000 {
          explicitExponent = explicitExponent &* 10 &+ Int32(digit)
        }
        i &+= 1
      }
      if i == exponentStart { throw self.error(.invalidNumber, at: reportAt) }
    }

    if i != to { throw self.error(.invalidNumber, at: reportAt) }

    let totalDigits = integerDigits &+ fractionDigits
    if totalDigits > 19 { flags.insert(.overflowed) }
    let signedExponent = exponentNegative ? -explicitExponent : explicitExponent
    let info = NumberInfo(
      magnitude: magnitude,
      exponent: Int16(clamping: Int(signedExponent) &- fractionDigits),
      digitCount: UInt16(truncatingIfNeeded: totalDigits),
      flags: flags
    )
    try self.recordNumber(
      start: from, length: to &- from, end: reportAt, base: base, info: info, into: &sink
    )
  }

  // MARK: Literals

  @usableFromInline
  static let literalBytes: [[UInt8]] = [
    [.asciiLowerT, .asciiLowerR, .asciiLowerU, .asciiLowerE],
    [.asciiLowerF, .asciiLowerA, .asciiLowerL, .asciiLowerS, .asciiLowerE],
    [.asciiLowerN, .asciiLowerU, .asciiLowerL, .asciiLowerL],
  ]

  @inlinable
  mutating func startLiteral(kind: UInt8) {
    self.literalKind = kind
    self.literalIndex = 1
  }

  @inlinable
  mutating func consumeLiteral<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer,
    from: Int,
    to: Int,
    into sink: inout Sink
  ) throws(JSONParsingError) -> Int {
    let expected = Self.literalBytes[Int(self.literalKind)]
    var i = from
    while i < to && Int(self.literalIndex) < expected.count {
      let byte = base.load(fromByteOffset: i, as: UInt8.self)
      if byte != expected[Int(self.literalIndex)] {
        throw self.error(.invalidLiteral, at: i)
      }
      self.literalIndex &+= 1
      i &+= 1
    }
    if Int(self.literalIndex) == expected.count {
      // A literal cut by a chunk began in the previous one; its bytes are never read, so the
      // record names the part of it in this chunk.
      let start = Swift.max(i &- expected.count, 0)
      try self.record(
        self.literalKind == 2 ? .null : .boolean, start: start, length: i &- start, end: i,
        extra: self.literalKind == 0 ? 1 : 0, base: base, into: &sink
      )
      self.state = .afterValue
    }
    return i
  }

  // MARK: Buffer

  @inlinable
  mutating func appendToBuffer(
    base: UnsafeRawPointer, from: Int, count: Int, reportAt: Int
  ) throws(JSONParsingError) {
    guard count > 0 else { return }
    guard Int(self.bufferCount) &+ count <= Int(self.bufferCapacity) else {
      throw self.error(.bufferExhausted, at: reportAt)
    }
    UnsafeMutableRawPointer(self.bufferBase + Int(self.bufferCount))
      .copyMemory(from: base.advanced(by: from), byteCount: count)
    self.bufferCount &+= UInt32(count)
  }

  // MARK: Coalesced string content

  // A run of string content appended to the coalescing buffer; one at least as long as the buffer
  // goes to the sink in place. At most sixteen bytes is one unaligned 16-byte load and store, not
  // a libc `memmove` call. Both slack checks bound it: sixteen readable bytes before `to` in the
  // source, sixteen writable before the end of the allocation (buffer plus scratch) in the target.
  @inlinable
  mutating func bufferStringRun<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer, from: Int, count: Int, end: Int, to: Int, into sink: inout Sink
  ) throws(JSONParsingError) {
    if Int(self.bufferCount) &+ count > Int(self.bufferCapacity) {
      try self.flushStringBuffer(into: &sink, end: from)
      if count >= Int(self.bufferCapacity) {
        try self.record(
          .stringChunk, start: from, length: count, end: end, base: base, into: &sink
        )
        return
      }
    }
    let at = Int(self.bufferCount)
    if count <= 16, to &- from >= 16,
      at &+ 16 <= Int(self.bufferCapacity) &+ Self.scratchByteCount
    {
      UnsafeMutableRawPointer(self.bufferBase + at).storeBytes(
        of: base.loadUnaligned(fromByteOffset: from, as: SIMD16<UInt8>.self),
        as: SIMD16<UInt8>.self
      )
    } else {
      UnsafeMutableRawPointer(self.bufferBase + at)
        .copyMemory(from: base.advanced(by: from), byteCount: count)
    }
    self.bufferCount &+= UInt32(count)
  }

  // One escape's decoded bytes: the whole scratch word in one unaligned 8-byte store. One to four
  // bytes are meaningful; the rest land past `bufferCount` and never past the allocation, since
  // after the capacity check `bufferCount` is at most `capacity - 1` and the reserved
  // `scratchByteCount` sits behind the buffer. Reached only through the `coalescing: true` literal.
  @inlinable
  mutating func bufferStringScratch<Sink: StreamParseSink & ~Copyable>(
    _ word: UInt64, count: Int, into sink: inout Sink, reportAt: Int
  ) throws(JSONParsingError) {
    if Int(self.bufferCount) &+ count > Int(self.bufferCapacity) {
      try self.flushStringBuffer(into: &sink, end: reportAt)
    }
    UnsafeMutableRawPointer(self.bufferBase + Int(self.bufferCount))
      .storeBytes(of: word, as: UInt64.self)
    self.bufferCount &+= UInt32(count)
  }

  // Hands everything coalesced so far to the sink as one chunk, reporting rejection at `end`.
  // Measured: `@inline(__always)` pulled the body into one of the tail's exits and cost `Twitter
  // full - bulk discarding` -1.8% p0; leave it to the optimizer.
  @inlinable
  mutating func flushStringBuffer<Sink: StreamParseSink & ~Copyable>(
    into sink: inout Sink, end: Int
  ) throws(JSONParsingError) {
    let count = Int(self.bufferCount)
    guard count > 0 else { return }
    self.bufferCount = 0
    try self.record(
      .stringChunk, start: 0, length: count, end: end,
      base: UnsafeRawPointer(self.bufferBase), into: &sink
    )
  }

  // A key read whole out of the input: validated in place and handed over as a borrow of the
  // document's own bytes. Every reader stays within the span's count, which is the whole contract.
  @inlinable
  @inline(__always)
  mutating func emitKeyInPlace<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer, from: Int, to: Int, containsNonASCII: Bool, into sink: inout Sink
  ) throws(JSONParsingError) {
    try self.validateUTF8IfNeeded(
      base: base, from: from, to: to, containsNonASCII: containsNonASCII, reportAt: to
    )
    try self.record(.key, start: from, length: to &- from, end: to &+ 1, base: base, into: &sink)
  }

  @inlinable
  mutating func emitBufferedKey<Sink: StreamParseSink & ~Copyable>(
    into sink: inout Sink, reportAt: Int
  ) throws(JSONParsingError) {
    let count = Int(self.bufferCount)
    let base = UnsafeRawPointer(self.bufferBase)
    try self.validateUTF8IfNeeded(
      base: base,
      from: 0,
      to: count,
      containsNonASCII: self.keyContainsNonASCII,
      reportAt: reportAt
    )
    try self.record(
      .key, start: 0, length: count, end: reportAt &+ 1, base: base, into: &sink
    )
    self.bufferCount = 0
    self.keyContainsNonASCII = false
  }

  // MARK: UTF-8

  // Forced inline for byte-fed input: a one-byte chunk ends every string run at `to`, so the string
  // body asks this on every content byte. Measured: left to the optimizer, `consumeStringRun`
  // called it and `LLM message - byte by byte discarding` lost 1.4% every round.
  @inlinable
  @inline(__always)
  mutating func trimmingIncompleteUTF8(
    base: UnsafeRawPointer, from: Int, to: Int
  ) throws(JSONParsingError) -> Int {
    var index = to &- 1
    let lowest = Swift.max(from, to &- 4)
    while index >= lowest {
      let byte = base.load(fromByteOffset: index, as: UInt8.self)
      if byte < .utf8ContinuationFloor { return to }
      if byte >= .utf8TwoByteFloor {
        let needed = Self.sequenceLength(byte)
        let available = to &- index
        return available >= needed ? to : index
      }
      index &-= 1
    }
    return to
  }

  @inlinable
  mutating func holdPendingUTF8(
    base: UnsafeRawPointer, from: Int, to: Int
  ) throws(JSONParsingError) {
    let count = to &- from
    guard count <= 4 else { throw self.error(.invalidUTF8, at: from) }
    // An invalid lead can be rejected before anything is held, which leaves completion with only
    // the second byte constraints to check.
    let lead = base.load(fromByteOffset: from, as: UInt8.self)
    guard lead >= .utf8TwoByteMinimum, lead <= .utf8MaximumLead else {
      throw self.error(.invalidUTF8, at: from)
    }
    // Little-endian, a byte per lane: `completePendingUTF8` appends at lane `have` with a shift
    // rather than a store to a far page.
    var held: UInt64 = 0
    for offset in 0..<count {
      held |= UInt64(base.load(fromByteOffset: from &+ offset, as: UInt8.self)) &<< (8 &* offset)
    }
    self.pendingUTF8 = held
    self.pendingUTF8Count = UInt8(count)
  }

  // Only continuation bytes are taken, and the sequence goes through the same validation a
  // contiguous one would: filling blindly swallowed the next byte, and emitting unvalidated
  // accepted overlongs, encoded surrogates and out-of-range leads.
  @inlinable
  mutating func completePendingUTF8<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer, count n: Int, into sink: inout Sink
  ) throws(JSONParsingError) -> Int {
    var held = self.pendingUTF8
    let leadAt = -Int(self.pendingUTF8Count)
    let lead = UInt8(truncatingIfNeeded: held)
    let needed = Self.sequenceLength(lead)
    var have = Int(self.pendingUTF8Count)
    var i = 0
    while have < needed && i < n {
      let byte = base.load(fromByteOffset: i, as: UInt8.self)
      guard byte >= .utf8ContinuationFloor, byte < .utf8TwoByteFloor else { break }
      held |= UInt64(byte) &<< (8 &* have)
      have &+= 1
      i &+= 1
    }
    self.pendingUTF8 = held
    if have < needed {
      if i == n {
        self.pendingUTF8Count = UInt8(have)
        return n
      }
      // The next byte is not a continuation, so the sequence is truncated.
      throw self.error(.invalidUTF8, at: leadAt)
    }
    self.pendingUTF8Count = 0
    // The fill loop admitted only continuation bytes and the hold rejected invalid leads, so only
    // the second byte's constraints remain -- the contiguous validator's, without its ASCII
    // prescan, which measured 32% of byte-fed non-ASCII throughput.
    if needed > 1 {
      let second = UInt8(truncatingIfNeeded: held &>> 8)
      switch lead {
      case .utf8ThreeByteFloor:
        guard second >= .utf8ThreeByteLowerBound else { throw self.error(.invalidUTF8, at: leadAt) }
      case .utf8SurrogateLead:
        guard second <= .utf8SurrogateCeiling else { throw self.error(.invalidUTF8, at: leadAt) }
      case .utf8FourByteFloor:
        guard second >= .utf8FourByteLowerBound else { throw self.error(.invalidUTF8, at: leadAt) }
      case .utf8MaximumLead:
        guard second <= .utf8MaximumSecond else { throw self.error(.invalidUTF8, at: leadAt) }
      default:
        break
      }
    }
    // A sequence rejoined inside a skipped string is validated and dropped: the skip delivers
    // nothing, and this is the one emission its string scanner shares with the normal path.
    if self.state == .skippingString { return i }
    try self.recordInlineChunk(held, count: needed, end: i, into: &sink)
    return i
  }

  // A lead's length is how many of 0xC0, 0xE0 and 0xF0 it reaches, plus one: three independent
  // `cmp`/`adc` with nothing to predict. A continuation byte reaches none and answers 1, so this
  // agrees with the four-compare ladder on all 256 bytes; `LookupTableTests` pins that.
  @inlinable
  package static func sequenceLength(_ lead: UInt8) -> Int {
    var length = 1
    if lead >= .utf8TwoByteFloor { length &+= 1 }
    if lead >= .utf8ThreeByteFloor { length &+= 1 }
    if lead >= .utf8FourByteFloor { length &+= 1 }
    return length
  }

  // The two guards inline everywhere and settle every ASCII run; a run with a high bit goes out of
  // line to the vector validator. Measured: inlining the validator here too cost byte-fed 2-5%.
  @inlinable
  @inline(__always)
  mutating func validateUTF8IfNeeded(
    base: UnsafeRawPointer,
    from: Int,
    to: Int,
    containsNonASCII: Bool,
    reportAt: Int?
  ) throws(JSONParsingError) {
    guard containsNonASCII else { return }
    try self.validateNonASCIIRun(base: base, from: from, to: to, reportAt: reportAt)
  }

  @inlinable
  @inline(never)
  mutating func validateNonASCIIRun(
    base: UnsafeRawPointer,
    from: Int,
    to: Int,
    reportAt: Int?
  ) throws(JSONParsingError) {
    if streamValidateUTF8(base: base, from: from, to: to) { return }
    var i = from
    while i < to {
      let lead = base.load(fromByteOffset: i, as: UInt8.self)
      if lead < .utf8ContinuationFloor {
        i &+= 1
        continue
      }
      guard lead >= .utf8TwoByteMinimum, lead <= .utf8MaximumLead else { throw self.error(.invalidUTF8, at: reportAt ?? i) }
      let needed = Self.sequenceLength(lead)
      guard i &+ needed <= to else { throw self.error(.invalidUTF8, at: reportAt ?? i) }
      for offset in 1..<needed {
        let continuation = base.load(fromByteOffset: i &+ offset, as: UInt8.self)
        guard continuation >= .utf8ContinuationFloor, continuation < .utf8TwoByteFloor else {
          throw self.error(.invalidUTF8, at: reportAt ?? i)
        }
      }
      let second = base.load(fromByteOffset: i &+ 1, as: UInt8.self)
      switch lead {
      case .utf8ThreeByteFloor:
        guard second >= .utf8ThreeByteLowerBound else { throw self.error(.invalidUTF8, at: reportAt ?? i) }
      case .utf8SurrogateLead:
        guard second <= .utf8SurrogateCeiling else { throw self.error(.invalidUTF8, at: reportAt ?? i) }
      case .utf8FourByteFloor:
        guard second >= .utf8FourByteLowerBound else { throw self.error(.invalidUTF8, at: reportAt ?? i) }
      case .utf8MaximumLead:
        guard second <= .utf8MaximumSecond else { throw self.error(.invalidUTF8, at: reportAt ?? i) }
      default:
        break
      }
      i &+= needed
    }
  }

  // MARK: Emission helpers

  // Eight bytes past `bufferCapacity`, reserved so a decoded escape has a stable address already in
  // memory; four bytes is the most any escape or rejoined sequence needs. Measured: taking the
  // address from a local via `withUnsafeBytes(of:)` cost Twitter escaped -10.1% and LLM -14.2%.
  @usableFromInline static let scratchByteCount = 8

  // A caller-supplied buffer donates its tail to the scratch above, hence this floor.
  @usableFromInline static let minimumBufferByteCount = 16

  // The scratch's address. It sits in the parser's own allocation rather than in the struct, so it
  // is one `ldr` of a hot field and, unlike a stack local, never lands in the caller's frame.
  @inlinable
  @inline(__always)
  var scratchBase: UnsafeMutablePointer<UInt8> {
    self.bufferBase + Int(self.bufferCapacity)
  }

  @inlinable
  mutating func emitScalar<Sink: StreamParseSink & ~Copyable>(
    _ value: UInt32, into sink: inout Sink, reportAt: Int
  ) throws(JSONParsingError) {
    let encoded = Self.utf8Word(value)
    try self.emitScratch(encoded.word, count: encoded.count, into: &sink, reportAt: reportAt)
  }

  // A scalar's UTF-8 encoding assembled little-endian in a register: the low `count` bytes.
  @inlinable
  @inline(__always)
  static func utf8Word(_ value: UInt32) -> (word: UInt64, count: Int) {
    let word: UInt64
    let count: Int
    if value < .utf8OneByteCeiling {
      word = UInt64(value)
      count = 1
    } else if value < .utf8TwoByteCeiling {
      word =
        UInt64(0xC0 | (value >> 6))
        | (UInt64(0x80 | (value & .utf8ContinuationMask)) &<< 8)
      count = 2
    } else if value < .utf8ThreeByteCeiling {
      word =
        UInt64(0xE0 | (value >> 12))
        | (UInt64(0x80 | ((value >> 6) & .utf8ContinuationMask)) &<< 8)
        | (UInt64(0x80 | (value & .utf8ContinuationMask)) &<< 16)
      count = 3
    } else {
      word =
        UInt64(0xF0 | (value >> 18))
        | (UInt64(0x80 | ((value >> 12) & .utf8ContinuationMask)) &<< 8)
        | (UInt64(0x80 | ((value >> 6) & .utf8ContinuationMask)) &<< 16)
        | (UInt64(0x80 | (value & .utf8ContinuationMask)) &<< 24)
      count = 4
    }
    return (word, count)
  }

  @inlinable
  mutating func emitDecoded<Sink: StreamParseSink & ~Copyable>(
    byte: UInt8, into sink: inout Sink, reportAt: Int
  ) throws(JSONParsingError) {
    try self.emitScratch(UInt64(byte), count: 1, into: &sink, reportAt: reportAt)
  }

  @inlinable
  @inline(__always)
  mutating func emitScratch<Sink: StreamParseSink & ~Copyable>(
    _ word: UInt64, count: Int, into sink: inout Sink, reportAt: Int
  ) throws(JSONParsingError) {
    if self.isKeyToken {
      try self.appendScratchToBuffer(word, count: count, reportAt: reportAt)
      return
    }
    // A string value's escape outside `coalescedEscapedStringTail` is its own inline chunk. The
    // tail's escapes never come through here: it asks `fusedEscapeEnd` for the buffered arm by literal.
    try self.recordInlineChunk(word, count: count, end: reportAt &+ 1, into: &sink)
  }

  // The scratch word's low `count` bytes appended to a key being reassembled. Byte stores rather
  // than a `copyMemory` from a stack slot: `count` is one to four and the word is in a register.
  @inlinable
  mutating func appendScratchToBuffer(
    _ word: UInt64, count: Int, reportAt: Int
  ) throws(JSONParsingError) {
    guard Int(self.bufferCount) &+ count <= Int(self.bufferCapacity) else {
      throw self.error(.bufferExhausted, at: reportAt)
    }
    var remaining = word
    var at = Int(self.bufferCount)
    for _ in 0..<count {
      self.bufferBase[at] = UInt8(truncatingIfNeeded: remaining)
      remaining &>>= 8
      at &+= 1
    }
    self.bufferCount &+= UInt32(count)
  }

  // MARK: Container stack

  @inlinable
  @inline(__always)
  var topIsObject: Bool {
    Self.topIsObject(depth: self.depth, containers: self.containers)
  }

  // Set the depth's bit (1 = object, 0 = array) and descend. `@_transparent` for the reason
  // `structuralRun` records; the `depth < maximumDepth` guard stays at each call site.
  @_transparent
  @usableFromInline
  static func pushContainer(object: Bool, depth: inout Int, containers: inout UInt64) {
    let bit: UInt64 = 1 &<< Self.shiftAmount(depth)
    if object { containers |= bit } else { containers &= ~bit }
    depth &+= 1
  }

  // Truncating, not checked: `UInt64(depth)` traps and the optimiser cannot prove `depth` is never
  // negative, so it planted `test`/`js` and a `ud2` block at both container pushes, which also
  // stops the surrounding compares being if-converted. The guard above each use bounds `depth`.
  @inlinable
  @inline(__always)
  static func shiftAmount(_ depth: Int) -> UInt64 {
    UInt64(truncatingIfNeeded: depth)
  }

  // `depth` never exceeds `maximumDepth`, so the masking shift is exact and skips the overshift
  // guard a smart shift carries. False at depth zero, which is what every caller wants there.
  @inlinable
  @inline(__always)
  static func topIsObject(depth: Int, containers: UInt64) -> Bool {
    depth > 0 && (containers &>> UInt64(depth &- 1)) & 1 == 1
  }

  // MARK: Diagnostics

  // Every error reports the absolute offset of the byte it was detected at, so where a document
  // fails does not depend on chunking. Errors found at a token's completion name its final byte.
  @inlinable
  func error(_ reason: JSONParsingError.Reason, at offset: Int) -> JSONParsingError {
    JSONParsingError(reason: reason, byteOffset: self.consumedByteCount &+ offset)
  }

  // The throw itself, out of line. A typed `throw` expands to the error's construction, an OS
  // version test for the weakly linked `swift_willThrowTypedImpl` hook and the call -- 25
  // instructions, nine of them inline in `consumeStructuralRun`. Static, not a method -- measured:
  // as a method every site copied all 160 bytes of `self` onto the stack.
  @inlinable
  @inline(never)
  static func fail(_ reason: JSONParsingError.Reason, byteOffset: Int) throws(JSONParsingError) -> Never {
    throw JSONParsingError(reason: reason, byteOffset: byteOffset)
  }

  @inlinable
  @inline(never)
  static func fail(_ error: JSONParsingError) throws(JSONParsingError) -> Never {
    throw error
  }

  @inlinable
  static func hexValue(_ byte: UInt8) -> UInt32? {
    switch byte {
    case .asciiZero ... .asciiNine: UInt32(byte &- .asciiZero)
    case .asciiLowerA ... .asciiLowerF: UInt32(byte &- .asciiLowerA &+ 10)
    case .asciiUpperA ... .asciiUpperF: UInt32(byte &- .asciiUpperA &+ 10)
    default: nil
    }
  }
}
