// The parser -> sink fusion, as a vertical slice: the bulk parse loop with `PartialSink`'s
// routing called at the lex points, and no event records in between. This exists to price the
// record/replay seam before any protocol or architecture commitment -- the composition ledger in
// NEW_ARCHITECTURE.md established that the typed path's cost is the parser's plus the sink's with
// no overlap, and this loop is the measurement of how much of the sink's half is the transport.
//
// What it deliberately is NOT: a parser. It requires the whole document in one chunk, refuses
// escapes and chunk-cut tokens outright (`preconditionFailure`, not an error -- feeding it those
// is a harness bug, not an input condition), and reports errors without the recorded path's
// event-before-error ordering. Every kernel it runs is the real parser's own -- the whitespace
// scan, the string run, the short-integer fast path and the structured number walk, the comma
// fusion -- so a throughput delta against the recorded path prices the seam, not a lexer
// shortcut.
//
// Routing discipline matches the sink's: everything hot flows through pointers and bits, no
// type used here is nested in a generic (see the `ScalarTarget` note in PartialSink.swift), and
// the loop is concrete over a phantom root -- see "The slice's concrete sink" below.

// MARK: - Route cache

// The fused loop's cached view of the sink's top frame, refreshed at every container transition.
// The two routes the slice fuses are the two the plan targets: an object routed through the
// field table (keys matched in place, scalars stored at member offsets) and an array of `Double`
// (a register-resident run into the `StreamArray`). Everything else delegates to the sink's own
// single-token methods, which keeps the loop correct on any document while only the fused routes
// are being priced.
@usableFromInline
enum FusedFrameRoute: UInt8 {
  case other
  case tableObject
  case doubleArray
}

@usableFromInline
struct FusedRouteContext {
  @usableFromInline var route: FusedFrameRoute
  @usableFromInline var frame: UnsafeMutablePointer<BorrowedFrame>?
  @usableFromInline var entries: UnsafePointer<StreamFieldEntry>?
  @usableFromInline var entryCount: Int
  @usableFromInline var keyBytes: UnsafePointer<UInt8>?

  @usableFromInline
  init(
    route: FusedFrameRoute,
    frame: UnsafeMutablePointer<BorrowedFrame>? = nil,
    entries: UnsafePointer<StreamFieldEntry>? = nil,
    entryCount: Int = 0,
    keyBytes: UnsafePointer<UInt8>? = nil
  ) {
    self.route = route
    self.frame = frame
    self.entries = entries
    self.entryCount = entryCount
    self.keyBytes = keyBytes
  }
}


// MARK: - The slice's concrete sink

// The fused loop is deliberately not generic. `PartialSink`'s behavior is entirely
// schema-driven -- `Root` types the root pointer at init and nothing else -- but a generic loop
// compiled unspecialized materializes `PartialSink<Root>` metadata at every sink call site
// (thirteen accessor calls in the first build, one ahead of the per-member number store). A
// phantom root makes every call concrete and direct, keeps one copy of the loop, and prices the
// seam without conflating it with per-root specialization.
public enum FusedSliceRoot {}

@_spi(Benchmarks)
public func makeFusedSliceSink(
  root: UnsafeMutableRawPointer, schema: StreamSchema
) -> PartialSink<FusedSliceRoot> {
  // The pointer is never read at `FusedSliceRoot`; the sink stores it raw and writes through the
  // schema, exactly as it does for a real root.
  PartialSink<FusedSliceRoot>(
    root: root.assumingMemoryBound(to: FusedSliceRoot.self), schema: schema
  )
}

// MARK: - Helpers

// A span over the chunk's own bytes, exactly what `StreamEventBatch.bytes(of:)` hands the sink
// for an `.input` record.
@_lifetime(borrow base)
@inline(__always)
private func fusedSpan(_ base: UnsafeRawPointer, _ from: Int, _ to: Int) -> Span<UInt8> {
  _overrideLifetime(
    Span(
      _unsafeElements: UnsafeBufferPointer(
        start: (base + from).assumingMemoryBound(to: UInt8.self), count: to &- from
      )
    ),
    borrowing: base
  )
}


// `StreamArray.commit`'s body, forced inline for the run: the bulk appender gets `commit`
// inlined by virtue of being a small closure, and the (larger) fused run was paying it as an
// outlined call per number. Kept in lockstep with `StreamArray.commit`.
@inline(__always)
private func fusedCommitDouble(
  _ array: UnsafeMutablePointer<StreamArray<Double>>, _ element: Double
) {
  let blockCapacity = Int(array.pointee.blockCapacityBits)
  let neededCapacity = array.pointee.tail.count &+ 1
  if array.pointee.tail.capacity < neededCapacity {
    let reservation = array.pointee.blocks.isEmpty && array.pointee.tail.isEmpty
      ? StreamArray<Double>.initialTailCapacity
      : blockCapacity
    array.pointee.tail.reserveCapacity(reservation)
  }
  array.pointee.tail.append(element)
  guard array.pointee.tail.count == blockCapacity else { return }
  array.pointee.blocks.append(array.pointee.tail)
  array.pointee.tail = ContiguousArray<Double>()
}

// `emitNumber`'s parse without the record: the same short-integer fast path and the same
// structured walk over sign, integer, fraction and exponent, with the info returned in registers
// instead of written to the event scratch. Kept in lockstep with `JSONParser.emitNumber`; the
// fused loop's numbers must cost what the recorded loop's do.
@inline(__always)
private func fusedNumberInfo(
  base: UnsafeRawPointer, from: Int, to: Int
) throws(JSONParsingError) -> NumberInfo {
  if to &- from <= 8, to >= 8,
    base.load(fromByteOffset: from, as: UInt8.self) != .asciiZero || to &- from == 1,
    let magnitude = streamShortInteger(base: base, from: from, end: to)
  {
    return NumberInfo(
      magnitude: magnitude,
      exponent: 0,
      digitCount: UInt16(truncatingIfNeeded: to &- from),
      flags: []
    )
  }

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
  guard integerDigits > 0 else { try JSONParser.fail(.invalidNumber, byteOffset: to) }
  if integerDigits > 1, base.load(fromByteOffset: integerStart, as: UInt8.self) == .asciiZero {
    try JSONParser.fail(.invalidNumber, byteOffset: to)
  }

  var fractionDigits = 0
  if i < to, base.load(fromByteOffset: i, as: UInt8.self) == .asciiDot {
    flags.insert(.fraction)
    i &+= 1
    let fractionStart = i
    i = streamAccumulateDigits(base: base, from: i, to: to, into: &magnitude)
    fractionDigits = i &- fractionStart
    if fractionDigits == 0 { try JSONParser.fail(.invalidNumber, byteOffset: to) }
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
    if i == exponentStart { try JSONParser.fail(.invalidNumber, byteOffset: to) }
  }

  if i != to { try JSONParser.fail(.invalidNumber, byteOffset: to) }

  let totalDigits = integerDigits &+ fractionDigits
  if totalDigits > 19 { flags.insert(.overflowed) }
  let signedExponent = exponentNegative ? -explicitExponent : explicitExponent
  return NumberInfo(
    magnitude: magnitude,
    exponent: Int16(clamping: Int(signedExponent) &- fractionDigits),
    digitCount: UInt16(truncatingIfNeeded: totalDigits),
    flags: flags
  )
}

// MARK: - Fused entry point

extension JSONParser {
  // Reads the sink's top frame into the loop's cached routing. Fields are read through the frame
  // pointer in place -- binding `schema` to a local would form a strong reference off the
  // `unowned(unsafe)` field, which is a retain per refresh (the `key(_:)` comment in
  // PartialSink.swift).
  @inline(__always)
  static func fusedRouteContext(_ sink: inout PartialSink<FusedSliceRoot>) -> FusedRouteContext {
    guard let top = sink.topFrame else { return FusedRouteContext(route: .other) }
    if top.pointee.schema.shape == .object, top.pointee.schema.keyRouting == .table {
      return FusedRouteContext(
        route: .tableObject,
        frame: top,
        entries: top.pointee.schema.fieldEntries.unsafelyUnwrapped,
        entryCount: top.pointee.schema.fieldCount,
        keyBytes: top.pointee.schema.fieldKeyBytes.unsafelyUnwrapped
      )
    }
    if top.pointee.leafRoute == .arrayDouble {
      return FusedRouteContext(route: .doubleArray, frame: top)
    }
    return FusedRouteContext(route: .other, frame: top)
  }

  // The recorded path's literal error position (`consumeLiteral`): the first byte that diverges
  // from the expected literal, or the document's end when the literal simply runs out.
  @inline(never)
  static func fusedLiteralFailure(
    base: UnsafeRawPointer, at: Int, to n: Int, expected: [UInt8]
  ) throws(JSONParsingError) -> Never {
    var i = at
    var index = 0
    while i < n && index < expected.count {
      if base.load(fromByteOffset: i, as: UInt8.self) != expected[index] {
        try Self.fail(.invalidLiteral, byteOffset: i)
      }
      index &+= 1
      i &+= 1
    }
    try Self.fail(.invalidLiteral, byteOffset: n)
  }

  // The per-token failure read, at the offset `deliverEvents` would have reported: the byte just
  // past the token.
  @inline(__always)
  static func fusedCheck(
    _ sink: inout PartialSink<FusedSliceRoot>, at offset: Int
  ) throws(JSONParsingError) {
    if let failure = sink.streamFailure {
      throw JSONParsingError(reason: .sinkRejectedToken(failure), byteOffset: offset)
    }
  }

  // A matched table member's number: lexed, parsed and stored at the member's offset while the
  // entry is still in a register -- the seam's replacement for two records, two decodes and a
  // `pendingField` round trip. Out of line so the structural loop keeps its registers, the same
  // reason `consumeNumber` is its own function.
  //
  // Returns the cursor and whether the object comma fusion consumed `",<ws>"` up to the next
  // key's opening quote (the `fuseAfterValue` object arm).
  @inline(never)
  static func fusedTableNumber(
    base: UnsafeRawPointer,
    from: Int,
    to n: Int,
    entry: UnsafePointer<StreamFieldEntry>?,
    frame: UnsafeMutablePointer<BorrowedFrame>,
    into sink: inout PartialSink<FusedSliceRoot>
  ) throws(JSONParsingError) -> (cursor: Int, fusedKey: Bool) {
    let end = streamNumberRunEnd(base: base, from: from, to: n)
    guard end < n else {
      preconditionFailure("The fused slice requires the document not to end inside a number.")
    }
    let info = try fusedNumberInfo(base: base, from: from, to: end)
    if let entry {
      let result: StreamApplyResult
      if entry.pointee.kind == .custom {
        result = frame.pointee.schema.applyNumber(
          frame.pointee.storage, entry.pointee.index, fusedSpan(base, from, end), info
        )
      } else {
        result = PartialSink<FusedSliceRoot>.writeTableNumber(
          entry, member: frame.pointee.storage + Int(entry.pointee.offset),
          fusedSpan(base, from, end), info
        )
      }
      if result != .applied {
        sink.recordFailure(PartialSink<FusedSliceRoot>.failureReason(for: result))
        try Self.fusedCheck(&sink, at: end)
      }
    }
    if base.load(fromByteOffset: end, as: UInt8.self) == .asciiComma {
      let next = streamWhitespaceEnd(base: base, from: end &+ 1, to: n)
      if next < n, base.load(fromByteOffset: next, as: UInt8.self) == .asciiQuote {
        return (next, true)
      }
    }
    return (end, false)
  }

  // A run of numbers into an array of `Double`, with the comma fusion inside the run: lex,
  // parse, convert while the info is in registers, commit. Mirrors the bulk
  // `_streamArrayNumberAppender` exactly in its observable effect -- pending drained at the run's
  // start, every value but the last committed, the last left as the array's open element -- so a
  // snapshot between this run and the array's close sees what the recorded path shows.
  @inline(never)
  static func fusedDoubleRun(
    base: UnsafeRawPointer,
    from: Int,
    to n: Int,
    array: UnsafeMutablePointer<StreamArray<Double>>,
    into sink: inout PartialSink<FusedSliceRoot>
  ) throws(JSONParsingError) -> Int {
    array.pointee.drainPending()
    var i = from
    var last = 0.0
    var haveLast = false
    while true {
      let end = streamNumberRunEnd(base: base, from: i, to: n)
      guard end < n else {
        preconditionFailure("The fused slice requires the document not to end inside a number.")
      }
      let info = try fusedNumberInfo(base: base, from: i, to: end)
      guard let value = Double(streamParsing: fusedSpan(base, i, end), info: info) else {
        sink.recordFailure(.typeMismatch)
        try Self.fusedCheck(&sink, at: end)
        return end
      }
      if haveLast { fusedCommitDouble(array, last) }
      last = value
      haveLast = true
      if base.load(fromByteOffset: end, as: UInt8.self) == .asciiComma {
        let next = streamWhitespaceEnd(base: base, from: end &+ 1, to: n)
        if next < n {
          let byte = base.load(fromByteOffset: next, as: UInt8.self)
          if byte == .asciiDash || byte &- .asciiZero < 10 {
            i = next
            continue
          }
        }
      }
      array.pointee.pending = last
      return end
    }
  }

  // A number for a route the slice does not fuse, handed to the sink's own routing. Out of line
  // like `consumeNumber` so the structural loop does not carry the number walk's registers.
  @inline(never)
  static func fusedDelegatedNumber(
    base: UnsafeRawPointer,
    from: Int,
    to n: Int,
    into sink: inout PartialSink<FusedSliceRoot>
  ) throws(JSONParsingError) -> Int {
    let end = streamNumberRunEnd(base: base, from: from, to: n)
    guard end < n else {
      preconditionFailure("The fused slice requires the document not to end inside a number.")
    }
    let info = try fusedNumberInfo(base: base, from: from, to: end)
    sink.number(fusedSpan(base, from, end), info: info)
    try Self.fusedCheck(&sink, at: end)
    return end
  }

  /// The fused slice: one whole document, parsed with the sink's routing at the lex points.
  ///
  /// Benchmarks-only. Requires the entire document in `input`; traps on escapes, on chunk-cut
  /// tokens and on a bare scalar root. See the header comment for what a measurement against
  /// this loop does and does not price.
  @_spi(Benchmarks)
  public mutating func parseFusedDocument(
    _ input: UnsafeBufferPointer<UInt8>,
    into sink: inout PartialSink<FusedSliceRoot>
  ) throws(JSONParsingError) {
    guard let start = input.baseAddress, !input.isEmpty else { return }
    let base = UnsafeRawPointer(start)
    let n = input.count

    var i = 0
    var state = State.value
    var depth = 0
    var containers: UInt64 = 0
    var ctx = FusedRouteContext(route: .other)
    var pendingEntry: UnsafePointer<StreamFieldEntry>? = nil

    while i < n {
      let scanned = streamWhitespaceEndByte(base: base, from: i, to: n)
      i = scanned.end
      if i == n { break }
      let byte = scanned.byte
      let at = i
      i &+= 1

      switch state {
      case .value, .firstValue:
        switch byte {
        case .asciiQuote:
          // A whole string value, delivered as the `.string` record unrolls: begin, one chunk,
          // end. Any refusal inside the triple reports at the content's start, which is where
          // `deliverEvents` reports a rejected `.string` record.
          let run = streamStringRun(base: base, from: i, to: n)
          guard run.end < n, base.load(fromByteOffset: run.end, as: UInt8.self) == .asciiQuote
          else {
            preconditionFailure("The fused slice does not support escaped or chunk-cut strings.")
          }
          try self.validateUTF8IfNeeded(
            base: base, from: i, to: run.end, containsNonASCII: run.containsNonASCII,
            reportAt: nil
          )
          sink.stringBegin()
          try Self.fusedCheck(&sink, at: i)
          if run.end > i {
            sink.stringChunk(fusedSpan(base, i, run.end))
          }
          sink.stringEnd()
          try Self.fusedCheck(&sink, at: i)
          pendingEntry = nil
          i = run.end &+ 1
          state = .afterValue

        case .asciiObjectStart:
          sink.beginObject()
          try Self.fusedCheck(&sink, at: i)
          guard depth < Self.maximumDepth else { try Self.fail(.depthExceeded, byteOffset: at) }
          containers |= 1 &<< Self.shiftAmount(depth)
          depth &+= 1
          state = .firstKey
          pendingEntry = nil
          ctx = Self.fusedRouteContext(&sink)

        case .asciiArrayStart:
          sink.beginArray()
          try Self.fusedCheck(&sink, at: i)
          guard depth < Self.maximumDepth else { try Self.fail(.depthExceeded, byteOffset: at) }
          containers &= ~(1 &<< Self.shiftAmount(depth))
          depth &+= 1
          state = .firstValue
          pendingEntry = nil
          ctx = Self.fusedRouteContext(&sink)

        case .asciiArrayEnd:
          guard state == .firstValue, depth > 0,
            !Self.topIsObject(depth: depth, containers: containers)
          else {
            try Self.fail(.unexpectedToken, byteOffset: at)
          }
          sink.endArray()
          try Self.fusedCheck(&sink, at: i)
          depth &-= 1
          state = depth == 0 ? .done : .afterValue
          pendingEntry = nil
          ctx = Self.fusedRouteContext(&sink)

        case .asciiLowerT:
          guard n &- at >= 4,
            UInt32(littleEndian: base.loadUnaligned(fromByteOffset: at, as: UInt32.self))
              == 0x6575_7274
          else {
            try Self.fusedLiteralFailure(base: base, at: at, to: n, expected: Self.literalBytes[0])
          }
          sink.boolean(true)
          try Self.fusedCheck(&sink, at: at &+ 4)
          pendingEntry = nil
          i = at &+ 4
          state = .afterValue

        case .asciiLowerF:
          guard n &- at >= 5,
            UInt32(littleEndian: base.loadUnaligned(fromByteOffset: at &+ 1, as: UInt32.self))
              == 0x6573_6c61
          else {
            try Self.fusedLiteralFailure(base: base, at: at, to: n, expected: Self.literalBytes[1])
          }
          sink.boolean(false)
          try Self.fusedCheck(&sink, at: at &+ 5)
          pendingEntry = nil
          i = at &+ 5
          state = .afterValue

        case .asciiLowerN:
          guard n &- at >= 4,
            UInt32(littleEndian: base.loadUnaligned(fromByteOffset: at, as: UInt32.self))
              == 0x6c6c_756e
          else {
            try Self.fusedLiteralFailure(base: base, at: at, to: n, expected: Self.literalBytes[2])
          }
          sink.null()
          try Self.fusedCheck(&sink, at: at &+ 4)
          pendingEntry = nil
          i = at &+ 4
          state = .afterValue

        case .asciiDash, .asciiZero ... .asciiNine:
          switch ctx.route {
          case .doubleArray:
            i = try Self.fusedDoubleRun(
              base: base, from: at, to: n,
              array: ctx.frame.unsafelyUnwrapped.pointee.storage
                .assumingMemoryBound(to: StreamArray<Double>.self),
              into: &sink
            )
            state = .afterValue
          case .tableObject:
            let (cursor, fusedKey) = try Self.fusedTableNumber(
              base: base, from: at, to: n,
              entry: pendingEntry, frame: ctx.frame.unsafelyUnwrapped, into: &sink
            )
            pendingEntry = nil
            i = cursor
            state = fusedKey ? .key : .afterValue
          case .other:
            i = try Self.fusedDelegatedNumber(base: base, from: at, to: n, into: &sink)
            pendingEntry = nil
            state = .afterValue
          }

        default:
          try Self.fail(.unexpectedToken, byteOffset: at)
        }

      case .afterValue:
        switch byte {
        case .asciiComma:
          guard depth > 0 else { try Self.fail(.unexpectedToken, byteOffset: at) }
          state = Self.topIsObject(depth: depth, containers: containers) ? .key : .value
        case .asciiArrayEnd:
          guard depth > 0, !Self.topIsObject(depth: depth, containers: containers) else {
            try Self.fail(.unexpectedToken, byteOffset: at)
          }
          sink.endArray()
          try Self.fusedCheck(&sink, at: i)
          depth &-= 1
          state = depth == 0 ? .done : .afterValue
          ctx = Self.fusedRouteContext(&sink)
        case .asciiObjectEnd:
          guard Self.topIsObject(depth: depth, containers: containers) else {
            try Self.fail(.unexpectedToken, byteOffset: at)
          }
          sink.endObject()
          try Self.fusedCheck(&sink, at: i)
          depth &-= 1
          state = depth == 0 ? .done : .afterValue
          ctx = Self.fusedRouteContext(&sink)
        default:
          try Self.fail(.unexpectedToken, byteOffset: at)
        }

      case .key, .firstKey:
        switch byte {
        case .asciiQuote:
          let run = streamStringRun(base: base, from: i, to: n)
          guard run.end < n, base.load(fromByteOffset: run.end, as: UInt8.self) == .asciiQuote
          else {
            preconditionFailure("The fused slice does not support escaped or chunk-cut keys.")
          }
          try self.validateUTF8IfNeeded(
            base: base, from: i, to: run.end, containsNonASCII: run.containsNonASCII,
            reportAt: run.end
          )
          if ctx.route == .tableObject {
            // The key matched while its span is hot, and the entry held in a register for the
            // value that follows. `pendingField` is still written -- a container or delegated
            // value after this key resolves through the sink's own state.
            let field = streamMatchField(
              ctx.entries.unsafelyUnwrapped, count: ctx.entryCount,
              keyBytes: ctx.keyBytes.unsafelyUnwrapped, fusedSpan(base, i, run.end)
            )
            ctx.frame.unsafelyUnwrapped.pointee.pendingField = field
            pendingEntry = field >= 0 ? ctx.entries.unsafelyUnwrapped + Int(field) : nil
          } else {
            sink.key(fusedSpan(base, i, run.end))
            pendingEntry = nil
          }
          i = run.end &+ 1
          state = .afterKey
        case .asciiObjectEnd:
          guard state == .firstKey, Self.topIsObject(depth: depth, containers: containers) else {
            try Self.fail(.unexpectedToken, byteOffset: at)
          }
          sink.endObject()
          try Self.fusedCheck(&sink, at: i)
          depth &-= 1
          state = depth == 0 ? .done : .afterValue
          pendingEntry = nil
          ctx = Self.fusedRouteContext(&sink)
        default:
          try Self.fail(.unexpectedToken, byteOffset: at)
        }

      case .afterKey:
        guard byte == .asciiColon else { try Self.fail(.unexpectedToken, byteOffset: at) }
        state = .value

      case .done:
        try Self.fail(.trailingContent, byteOffset: at)

      case .inString, .inKey, .escape, .unicode, .number, .literal:
        preconditionFailure("The fused slice never enters a per-byte state.")
      }
    }

    // `finish()`'s checks, in its order: a structural state that still expects something is the
    // unexpected-token error, and only then an unclosed container.
    switch state {
    case .value, .firstValue, .key, .firstKey, .afterKey:
      try Self.fail(.unexpectedToken, byteOffset: n)
    case .afterValue, .done:
      break
    case .inString, .inKey, .escape, .unicode, .number, .literal:
      preconditionFailure("The fused slice never enters a per-byte state.")
    }
    guard depth == 0 else { try Self.fail(.unterminatedContainer, byteOffset: n) }
    try Self.fusedCheck(&sink, at: n)
  }
}
