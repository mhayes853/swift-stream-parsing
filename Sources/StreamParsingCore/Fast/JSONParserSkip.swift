import StreamParsingShims

// The skip scanner: from a container open whose sink answered `.skip` to its matching close, the
// only event it delivers. Structural only: brackets matched, depth cap held, strings still reject
// control bytes and invalid UTF-8; token interiors are not checked (the `.skip` contract). The
// per-byte loop is the block path's reference (`SkipBlockScanTests`) and its fallback, keeping
// error offsets byte-identical to a byte-fed parse. NEW_ARCHITECTURE.md, "The skip block scanner".
extension JSONParser {
  // One run, from wherever the skip stands (mid-interior, mid-string, after a cut backslash) to
  // the matching close or the chunk's end. Out of line like the structural run.
  @inlinable
  @inline(never)
  mutating func consumeSkipRun<Sink: StreamParseSink & ~Copyable>(
    base: UnsafeRawPointer,
    from: Int,
    to: Int,
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
    // A chunk cut the string (or its escape): finish the string first, then fall into the
    // structural loop below.
    if state != .skipping {
      guard let end = try self.resumeSkippedString(base: base, from: i, to: to, state: &state)
      else { return to }
      i = end
    }

    #if arch(arm64) || arch(x86_64)
      // The block path is out of line to keep its d8 save out of this prologue, which every
      // byte-fed call inside a skipped subtree pays (measured inlined: byte-fed Twitter escaped
      // discarding -5.1%). `blockKernelsAvailable` (a load on x86) is tested last so a byte-fed
      // call, failing `i &+ 64 <= to`, never reads it.
      if state == .skipping, i &+ 64 <= to, self.blockKernelsAvailable {
        // Copies scoped to this branch, not the run's locals: taking the address of those makes
        // `var depth = self.depth` an address-taken init whose store lands in the entry block, on
        // every byte-fed call that never gets here.
        var blockState = state
        var blockDepth = depth
        var blockContainers = containers
        // Written back on the way out of this scope whatever the exit is, so a throw from the
        // block path leaves the same parser state behind that the scalar loop's own throws do.
        defer {
          state = blockState
          depth = blockDepth
          containers = blockContainers
        }
        i = try self.consumeSkipBlocks(
          base: base, from: i, to: to, state: &blockState, depth: &blockDepth,
          containers: &blockContainers, into: &sink
        )
        // A structural state means the block path delivered the matching close.
        if blockState.isStructural { return i }
        if blockState != .skipping {
          guard
            let end = try self.resumeSkippedString(
              base: base, from: i, to: to, state: &blockState
            )
          else { return to }
          i = end
        }
      }
    #endif

    while i < to {
      let scanned = streamWhitespaceEndByte(base: base, from: i, to: to)
      i = scanned.end
      if i == to { break }
      let byte = scanned.byte
      let at = i
      i &+= 1
      switch byte {
      case .asciiObjectStart:
        guard depth < Self.maximumDepth else {
          try Self.fail(.depthExceeded, byteOffset: self.consumedByteCount &+ at)
        }
        Self.pushContainer(object: true, depth: &depth, containers: &containers)
      case .asciiArrayStart:
        guard depth < Self.maximumDepth else {
          try Self.fail(.depthExceeded, byteOffset: self.consumedByteCount &+ at)
        }
        Self.pushContainer(object: false, depth: &depth, containers: &containers)
      case .asciiObjectEnd:
        guard Self.topIsObject(depth: depth, containers: containers) else {
          try Self.fail(.unexpectedToken, byteOffset: self.consumedByteCount &+ at)
        }
        if depth &- 1 == self.skipEndDepth {
          // The event precedes the depth/state updates, exactly as the structural run orders
          // them, so a failure the check surfaces leaves the same parser state behind.
          try self.record(.endObject, start: at, length: 1, end: i, base: base, into: &sink)
          depth &-= 1
          state = depth == 0 ? .done : .afterValue
          return i
        }
        depth &-= 1
      case .asciiArrayEnd:
        guard depth > 0, !Self.topIsObject(depth: depth, containers: containers) else {
          try Self.fail(.unexpectedToken, byteOffset: self.consumedByteCount &+ at)
        }
        if depth &- 1 == self.skipEndDepth {
          try self.record(.endArray, start: at, length: 1, end: i, base: base, into: &sink)
          depth &-= 1
          state = depth == 0 ? .done : .afterValue
          return i
        }
        depth &-= 1
      case .asciiQuote:
        guard let end = try self.skipStringBody(base: base, from: i, to: to, state: &state) else {
          return to
        }
        i = end
      case .asciiComma, .asciiColon:
        break
      case .asciiDash, .asciiDot, .asciiPlus, .asciiUpperE, .asciiZero ... .asciiNine:
        // The whole byte class in one scan, no grammar walk. `.`, `+` and `E` are here because a
        // number the chunk cut resumes at any byte of its class (`e` is in the letters arm).
        i = streamNumberRunEnd(base: base, from: at, to: to)
      case .asciiLowerA ... .asciiLowerZ:
        // Literal bytes, one at a time: `true` is four cheap iterations, and a skipped interior
        // does not validate the words.
        break
      default:
        try Self.fail(.unexpectedToken, byteOffset: self.consumedByteCount &+ at)
      }
    }
    return to
  }

  #if arch(arm64) || arch(x86_64)
    // MARK: - The block path

    // Settles the block loop's deferred UTF-8 validation and returns the cleared marker. By value,
    // not `inout`: taking `validateFrom`'s address spills it for the whole block loop.
    @inlinable
    @inline(__always)
    mutating func settleValidation(
      base: UnsafeRawPointer, from: Int, to: Int
    ) throws(JSONParsingError) -> Int {
      if from >= 0 {
        try self.validateNonASCIIRun(base: base, from: from, to: to, reportAt: nil)
      }
      return -1
    }

    // Whole 64-byte blocks of the skipped interior; only brackets outside strings are read. Entered
    // outside a string with a whole block ahead. Returns where the scalar loop takes over, `state`
    // naming what the carries say sits there, or the index after the delivered matching close with
    // `state` structural. Out of line for the d8 prologue reason in `consumeSkipRun`.
    @inlinable
    @inline(never)
    mutating func consumeSkipBlocks<Sink: StreamParseSink & ~Copyable>(
      base: UnsafeRawPointer,
      from: Int,
      to: Int,
      state: inout State,
      depth: inout Int,
      containers: inout UInt64,
      into sink: inout Sink
    ) throws(JSONParsingError) -> Int {
      let skipEnd = Int(self.skipEndDepth)
      // Both carries describe the byte at `p`: `inStringCarry` is all ones inside a string, and
      // `endsOddCarry` is one when the byte before `p` was an unescaped backslash. They are
      // updated only after a block is accepted, so a block handed to the scalar loop is handed
      // to it with the state of its *first* byte.
      var inStringCarry: UInt64 = 0
      var endsOddCarry: UInt64 = 0
      // Deferred UTF-8 validation: the first block with a non-ASCII byte since the last settlement,
      // or -1. Settled at the first all-ASCII block -- short-ranged, and safe because a sequence
      // cannot straddle a block with no high bit in it.
      var validateFrom = -1
      var p = from
      while p &+ 64 <= to {
        let classes = stream_parsing_classify_skip_block(
          base.advanced(by: p).assumingMemoryBound(to: UInt8.self), inStringCarry, endsOddCarry
        )
        // Anything unusual is the scalar loop's, from this block's first byte, so the byte an
        // error names is the byte the scalar loop names.
        if classes.needs_scalar != 0 { break }

        if classes.non_ascii != 0 {
          if validateFrom < 0 { validateFrom = p }
        } else {
          validateFrom = try self.settleValidation(base: base, from: validateFrom, to: p)
        }

        var brackets = classes.brackets
        while brackets != 0 {
          let at = p &+ brackets.trailingZeroBitCount
          brackets &= brackets &- 1
          // The byte spells its kind: openers carry bit 1, braces bit 5. One load from a line the
          // classifier just read beats two more movemasks.
          let byte = base.load(fromByteOffset: at, as: UInt8.self)
          let isObject = byte & 0x20 != 0
          if byte & 0x02 != 0 {
            // The cap is checked per open, as the scalar loop checks it, so it reports at the
            // breaching bracket; a per-block popcount verdict costs four instructions every block.
            guard depth < Self.maximumDepth else {
              validateFrom = try self.settleValidation(base: base, from: validateFrom, to: at)
              try Self.fail(.depthExceeded, byteOffset: self.consumedByteCount &+ at)
            }
            Self.pushContainer(object: isObject, depth: &depth, containers: &containers)
          } else {
            guard depth > 0, isObject == Self.topIsObject(depth: depth, containers: containers)
            else {
              // Everything outstanding is earlier in the document than this bracket, so it is
              // reported first — the order a byte-fed parse would have found them in.
              validateFrom = try self.settleValidation(base: base, from: validateFrom, to: at)
              try Self.fail(.unexpectedToken, byteOffset: self.consumedByteCount &+ at)
            }
            if depth &- 1 == skipEnd {
              validateFrom = try self.settleValidation(base: base, from: validateFrom, to: at)
              // The event precedes the depth/state updates, exactly as the structural run orders
              // them, so a failure the check surfaces leaves the same parser state behind.
              try self.record(
                isObject ? .endObject : .endArray,
                start: at, length: 1, end: at &+ 1, base: base, into: &sink
              )
              depth &-= 1
              state = depth == 0 ? .done : .afterValue
              return at &+ 1
            }
            depth &-= 1
          }
        }

        inStringCarry = classes.in_string
        endsOddCarry = classes.ends_odd
        p &+= 64
      }

      // Hand over at `p`, with the state the carries describe. A byte after an unescaped
      // backslash is an escape selector whatever else it is; otherwise the parity says it.
      if endsOddCarry != 0 {
        state = .skippingEscape
      } else if inStringCarry != 0 {
        state = .skippingString
        // A sequence may straddle the handover. Back up to its lead so the scalar loop reads it
        // whole — and so the deferred validation below stops before it, exactly where the string
        // loop's own trim would have.
        p = try self.trimmingIncompleteUTF8(base: base, from: from, to: p)
      }
      validateFrom = try self.settleValidation(base: base, from: validateFrom, to: p)
      return p
    }
  #endif

  // A skipped string the previous chunk (or the block path's handover) left open, finished at
  // `from`: the escape selector first if one is pending, then the body. Returns the index after
  // the closing quote, or nil when the chunk ran out — in which case `state` names where the cut
  // fell and the caller is done with this run.
  @inlinable
  @inline(__always)
  mutating func resumeSkippedString(
    base: UnsafeRawPointer, from: Int, to: Int, state: inout State
  ) throws(JSONParsingError) -> Int? {
    var i = from
    if state == .skippingEscape {
      guard i < to else { return nil }
      // Escape selectors remain unchecked, but a backslash cannot hide a raw control byte.
      let selector = base.load(fromByteOffset: i, as: UInt8.self)
      guard selector >= .asciiSpace else {
        try Self.fail(.unterminatedString, byteOffset: self.consumedByteCount &+ i)
      }
      // Only ASCII selectors can be consumed as one byte. Let the string scanner validate
      // a non-ASCII selector and carry any incomplete sequence across the next boundary.
      if selector < .utf8ContinuationFloor { i &+= 1 }
      state = .skippingString
    }
    guard let end = try self.skipStringBody(base: base, from: i, to: to, state: &state) else {
      return nil
    }
    state = .skipping
    return end
  }

  // The interior of a skipped string, from just past a quote or where the last chunk left off.
  // Returns the index after the closing quote, or nil at the chunk's end with `state` naming the
  // cut. The streaming loop's scanner and UTF-8 checks, minus every emission.
  @inlinable
  mutating func skipStringBody(
    base: UnsafeRawPointer, from: Int, to: Int, state: inout State
  ) throws(JSONParsingError) -> Int? {
    var i = from
    while true {
      let run = streamStringRun(base: base, from: i, to: to)
      if run.end > i {
        let emitEnd =
          run.end == to ? try self.trimmingIncompleteUTF8(base: base, from: i, to: run.end) : run.end
        if emitEnd > i {
          try self.validateUTF8IfNeeded(
            base: base, from: i, to: emitEnd, containsNonASCII: run.containsNonASCII, reportAt: nil
          )
        }
        if emitEnd < run.end {
          try self.holdPendingUTF8(base: base, from: emitEnd, to: run.end)
        }
        i = run.end
      }
      guard i < to else {
        state = .skippingString
        return nil
      }
      let byte = base.load(fromByteOffset: i, as: UInt8.self)
      let byteAt = i
      i &+= 1
      if byte == .asciiQuote {
        return i
      } else if byte == .asciiBackslash {
        guard i < to else {
          state = .skippingEscape
          return nil
        }
        // Match the cross-chunk escape path: selectors are loose, raw controls are not.
        let selector = base.load(fromByteOffset: i, as: UInt8.self)
        guard selector >= .asciiSpace else {
          throw self.error(.unterminatedString, at: i)
        }
        // Leave non-ASCII bytes for the next run's UTF-8 validation instead of hiding
        // a lead or continuation byte behind the backslash.
        if selector < .utf8ContinuationFloor { i &+= 1 }
      } else {
        throw self.error(.unterminatedString, at: byteAt)
      }
    }
  }
}
