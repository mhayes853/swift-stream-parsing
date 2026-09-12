import StreamParsingShims

// The skip scanner: what runs between a container open whose sink answered `.skip` and its
// matching close. The interior is scanned *structurally* — brackets tracked in the same
// `depth`/`containers` registers the structural run uses (so a `[` closed by `}` is still
// rejected, and the depth cap still holds), strings skipped with control bytes still rejected
// and UTF-8 still validated — but token interiors are not re-checked: numbers are their byte
// class, escape selectors are not decoded, literals are loose letters, and commas and
// colons are not positionally validated. That trade is the entire point: no key matching, no
// number parse, no escape decode, no sink call per token — and it is documented on
// `StreamContainerDisposition.skip`. simdjson's On Demand makes the same one for skipped
// values.
//
// The scanner delivers exactly one thing: the matching `endObject`/`endArray` call, at the
// close bracket, with the same failure-check offset the streaming path uses. That is the
// advisory contract's other half — a sink that answered `.skip` still sees its container
// close, so a `PartialSink` pops the ignored frame it pushed at the open.
//
// On arm64 the interior is scanned 64 bytes at a time (`stream_parsing_classify_skip_block`,
// StreamParsingShims.h) and the per-byte loop below is what runs at the edges: it is the
// reference the block path is held to by `SkipBlockScanTests`, and the fallback for every byte
// the block path will not judge, which is what keeps the error offsets byte-identical to a
// byte-fed parse.
extension JSONParser {
  // One run, from wherever the skip stands — mid-interior, mid-string, or one byte after a
  // backslash the chunk cut — to the matching close or the chunk's end. Out of line like the
  // structural run, and for the same reason: it owns its registers, and `parse` stays a thin
  // dispatcher.
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

    #if arch(arm64)
      // The 64-byte block path, out of line on purpose: it hoists the classifier's tables and
      // splats into callee-saved vector registers, and a `d8` save in *this* function's prologue
      // would be paid by every byte-fed call that lands inside a skipped subtree, where the
      // block loop cannot run at all. Measured: -5.1% on `Real Twitter escaped - byte by byte
      // discarding` with the loop inlined here. The scalar entry keeps its original frame.
      if state == .skipping, i &+ 64 <= to {
        // The `inout`s are copies scoped to this branch, not the run's own locals: taking the
        // address of `depth` and `containers` themselves would make `var depth = self.depth` an
        // address-taken initialisation, and the store it becomes lands in the entry block —
        // one more store on every byte-fed call that never reaches this branch. The copies are
        // three register moves on the path that does.
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
        // The block path delivered the matching close: it left a structural state behind, which
        // none of the three skipping states is.
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
        containers |= 1 &<< Self.shiftAmount(depth)
        depth &+= 1
      case .asciiArrayStart:
        guard depth < Self.maximumDepth else {
          try Self.fail(.depthExceeded, byteOffset: self.consumedByteCount &+ at)
        }
        containers &= ~(1 &<< Self.shiftAmount(depth))
        depth &+= 1
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
        // The whole byte class in one scan; the grammar walk over it is what the skip omits.
        // `.`, `+` and `E` are here because a number the chunk cut resumes at any byte of its
        // class — the scanner keeps no cross-chunk number state, it just scans the class again.
        // (`e` is covered by the letters arm below.)
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

  #if arch(arm64)
    // MARK: - The block path
    //
    // Whole 64-byte blocks of the skipped interior, classified at once
    // (`stream_parsing_classify_skip_block`, StreamParsingShims.h). Only the brackets outside
    // strings are visited; every other byte of the interior — string content, escape selectors,
    // numbers, literals, whitespace, commas, colons — is settled by the masks and never read.
    //
    // Entered outside a string with at least one whole block ahead. Returns where the scalar
    // loop takes over, with `state` naming what the carries say sits there — or, when the
    // matching close was found and delivered, the index after it, with `state` structural.
    //
    // Out of line, and not by inheritance from its caller: this is where the classifier's two
    // tables, four splats and the carryless-multiply operand get hoisted, and hoisting into
    // `d8` puts a save/restore pair and a bigger frame in whatever function's prologue owns the
    // loop. Inlined into `consumeSkipRun` that prologue is paid by every byte-fed call that
    // lands in a skipped subtree, which can never execute a block. That cost was measured:
    // `Real Twitter escaped - byte by byte discarding` -5.1% p0.
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
      // UTF-8 validation is deferred: the start of the first block since the last settlement
      // that held a non-ASCII byte, or -1 when nothing is outstanding. Settling per block would
      // call the validator on every string; settling never would validate the whole subtree at
      // its close, far out of cache. Settling at the first all-ASCII block is both short-ranged
      // and safe — a sequence cannot straddle a block with no high bit in it.
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
        } else if validateFrom >= 0 {
          try self.validateNonASCIIRun(base: base, from: validateFrom, to: p, reportAt: nil)
          validateFrom = -1
        }

        var brackets = classes.brackets
        while brackets != 0 {
          let at = p &+ brackets.trailingZeroBitCount
          brackets &= brackets &- 1
          // The four bracket bytes spell their own kinds: '[' 0x5B and '{' 0x7B carry bit 1 and
          // the closers do not, and the braces carry bit 5 where the square brackets do not. One
          // byte load out of a line the classifier just read beats two more movemasks over the
          // whole block.
          let byte = base.load(fromByteOffset: at, as: UInt8.self)
          let isObject = byte & 0x20 != 0
          if byte & 0x02 != 0 {
            // The cap is checked per open, exactly where the scalar loop checks it, so it
            // reports at the bracket that breaches it. Deriving the same verdict per block takes
            // a popcount, which is a general-register value crossing to the vector unit and
            // back: four instructions on every block to save one predicted compare on the
            // brackets that are actually there.
            guard depth < Self.maximumDepth else {
              if validateFrom >= 0 {
                try self.validateNonASCIIRun(base: base, from: validateFrom, to: at, reportAt: nil)
              }
              try Self.fail(.depthExceeded, byteOffset: self.consumedByteCount &+ at)
            }
            if isObject {
              containers |= 1 &<< Self.shiftAmount(depth)
            } else {
              containers &= ~(1 &<< Self.shiftAmount(depth))
            }
            depth &+= 1
          } else {
            guard depth > 0, isObject == Self.topIsObject(depth: depth, containers: containers)
            else {
              // Everything outstanding is earlier in the document than this bracket, so it is
              // reported first — the order a byte-fed parse would have found them in.
              if validateFrom >= 0 {
                try self.validateNonASCIIRun(base: base, from: validateFrom, to: at, reportAt: nil)
              }
              try Self.fail(.unexpectedToken, byteOffset: self.consumedByteCount &+ at)
            }
            if depth &- 1 == skipEnd {
              if validateFrom >= 0 {
                try self.validateNonASCIIRun(base: base, from: validateFrom, to: at, reportAt: nil)
              }
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
      if validateFrom >= 0 {
        try self.validateNonASCIIRun(base: base, from: validateFrom, to: p, reportAt: nil)
      }
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

  // The interior of a string being skipped, from just past a quote (or wherever the previous
  // chunk left off). Returns the index after the closing quote, or nil at the chunk's end with
  // `state` naming where the cut fell. The same scanner and the same UTF-8 machinery the
  // streaming string loop uses — a control byte and invalid UTF-8 are rejected in a skipped
  // string exactly as in a delivered one — minus every emission.
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
