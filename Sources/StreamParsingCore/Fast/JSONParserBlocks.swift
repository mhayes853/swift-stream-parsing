#if arch(arm64)
  import StreamParsingShims

  // The structural run's 64-byte block path: the same walk `consumeStructural` performs one byte
  // at a time, driven by three masks instead of a whitespace scan and a per-byte ladder
  // (`stream_parsing_classify_structural_block`, StreamParsingShims.h).
  //
  // What it deletes, per block, is: the whitespace scan that precedes every token (whitespace is
  // simply absent from `starts`, so "the next token" is one `rbit`/`clz`), the string scan that
  // precedes every key and string value (the extent is the pair of quote bits, and the escape
  // test is an AND over the backslash mask), and the per-string high-bit reduction
  // (`containsNonASCII` becomes the block's own flag, and the ~99% of blocks with no high byte in
  // them never call the validator at all).
  //
  // What it does *not* change is anything observable. Every arm below restates the corresponding
  // arm of `consumeStructural`: the same events with the same spans, the same failure checks at
  // the same offsets, the same error reasons at the same bytes. Anything the masks cannot settle
  // -- a string whose closing quote is in the next block, a key with an escape in it, a literal
  // that does not match whole, a number the chunk cuts, a block holding any byte the ladder would
  // judge differently -- is handed back to the scalar loop at the byte where it starts, with the
  // parser state untouched, so the code that reports it today is still the code that reports it.
  //
  // Out of line by force, exactly as `consumeSkipBlocks` is and for the same measured reason:
  // this is where the classifier's two tables and four splats get hoisted, and hoisting into
  // `d8` puts a save/restore pair in the prologue of whatever function owns the loop.
  // `consumeStructuralRun`'s prologue is the one every byte-fed token pays, and it must not grow.
  extension JSONParser {
    // Entered from the top of `consumeStructuralRun`'s loop with a structural state, no token in
    // flight and at least one whole block ahead. Returns the index where the scalar loop resumes,
    // with `state`, `depth` and `containers` written back through the `inout`s.
    //
    // Every block is classified with *zero* carries, which is what makes the grid free to move:
    // the walk only ever consumes tokens that finish inside the block it is looking at, so the
    // byte after the last one is outside any string and outside any backslash run. When a token
    // ends past the block's end -- a number or a literal spanning the edge -- the grid simply
    // realigns to the token's end and carries on, which costs one classification and keeps the
    // carry invariant. A string that does not close inside its block is the one shape that cannot
    // be realigned onto, so it goes back to the scalar loop whole.
    @inlinable
    @inline(never)
    mutating func consumeStructuralBlocks<Sink: StreamParseSink & ~Copyable>(
      base: UnsafeRawPointer,
      from: Int,
      to: Int,
      state: inout State,
      depth: inout Int,
      containers: inout UInt64,
      into sink: inout Sink
    ) throws(JSONParsingError) -> Int {
      var p = from
      // The grid moves with the tokens rather than staying anchored to `from`, and the carries
      // are therefore always zero: the walk finishes every token it starts, so the byte after the
      // last one is outside every string and every backslash run, and a block may be classified
      // from there with nothing carried in. When a token ends past the block that started it --
      // a string, a long number, a literal on the edge -- the grid re-anchors at its end.
      //
      // The anchored alternative (fixed grid, real carries, a cursor masking off the bits it had
      // passed) was built and measured, and it is much worse where it matters: it classifies the
      // interior of every long string, which is 91% of `GSoC 2018` and 99% of `LLM message` --
      // +15%/-3% became -9%/-20% on those two. Re-anchoring skips those bytes entirely, and the
      // only thing it gives up is the tail of the block the token ran out of.
      outer: while p &+ 64 <= to {
        let classes = stream_parsing_classify_structural_block(
          base.advanced(by: p).assumingMemoryBound(to: UInt8.self), 0, 0
        )
        // Anything unusual is the scalar loop's, from this block's first byte, so the byte an
        // error names is the byte the scalar loop names.
        if classes.needs_scalar != 0 { return p }
        // The gate, and the whole answer to "when does the classifier not pay". Two signals, one
        // strike each, counted per classified block; four strikes and the walk is done with this
        // parser. Both were chosen off a census of the classifier's own masks over every corpus
        // (blocks actually classified, per block):
        //
        //   corpus            raw delta   ws outside strings   in-string   starts
        //   CITM catalog        +37.9%           46.3             8.5        9.4
        //   GitHub events       +31.8%           17.0            39.7        7.9
        //   Twitter             +24.2%           21.9            32.2       10.5
        //   GSoC 2018           +15.2%           19.0            39.9        5.7
        //   LLM message          -0.1%            0.0            53.6       11.4
        //   Twitter escaped      -4.1%            0.0            49.5       15.3
        //   Canada               -5.7%            0.0             0.0       64.0
        //   Qwen workspace      (-25.8% typed)    0.0            56.9        8.1
        //   Qwen structured     (-11.5% typed)    0.0            54.6       10.0
        //   Mesh                -26.4%            6.7             0.0       57.3
        //
        // The split is total: every corpus the walk wins on has 17 or more whitespace bytes per
        // block *outside* its strings, and every corpus it loses on has none. That is the whole
        // mechanism -- the ladder's own whitespace scan is a SIMD loop entered once per token,
        // and replacing it with a `tzcnt` is what the classifier is actually buying. With no
        // whitespace to skip there is nothing left to buy: the walk re-reads the same byte the
        // ladder would have, through 139 more instructions per block. `starts` catches the one
        // shape that has whitespace but still nothing to skip -- `Mesh`, a run of numbers -- and
        // is kept as a second strike for it.
        //
        // Not one block of `CITM`, `Twitter`, `GitHub` or `GSoC` is whitespace-free, so four
        // strikes never fire on them; `Canada`, `Mesh`, both Qwen payloads and `Twitter escaped`
        // strike on essentially every block and are out of the walk within four of them.
        if classes.no_outer_whitespace != 0 || classes.starts.nonzeroBitCount >= 48 {
          self.blockWalkStrikes &+= 1
          if self.blockWalkStrikes >= 4 {
            self.blockWalkGivenUp = true
            return ~p
          }
        } else if self.blockWalkStrikes != 0 {
          // Consecutive, not cumulative. `GSoC 2018` averages 19 whitespace bytes per block and
          // wins 18%, but it does hold the odd whitespace-free one, and counting those up over
          // 13343 blocks reached four and threw the win away (+18.1% -> -0.8%, measured).
          self.blockWalkStrikes = 0
        }
        let containsNonASCII = classes.non_ascii != 0
        var mask = classes.starts

        while mask != 0 {
          let bit = mask.trailingZeroBitCount
          let at = p &+ bit
          let byte = base.load(fromByteOffset: at, as: UInt8.self)
          let raw = state.rawValue

          // The quote arm, ahead of the ladder exactly as it is in `consumeStructural`: a key or
          // a string value, in a state that admits one.
          if byte == .asciiQuote, raw <= State.firstKey.rawValue,
            raw != State.afterValue.rawValue
          {
            // Bits 0...bit. `1 << bit` is in range for every bit of a 64-bit mask, and the
            // wrapping `&<< 1` folds bit 63 to zero, whose `&- 1` is all ones -- which is the
            // right answer there (nothing lies above byte 63).
            let consumed = ((UInt64(1) &<< UInt64(bit)) &<< 1) &- 1
            let closers = classes.quote & ~consumed
            // No closing quote in this block: the extent is not a pair of bits, so this is the
            // scalar arm's own scan, restated. Handing the token back to the scalar loop instead
            // was measured, and it is what the long-string corpora lost to (`Qwen 3 workspace
            // edit` -26%, `LLM message` -3%): the block that found the opening quote was
            // classified and thrown away once per string, and the walk was re-entered per token.
            guard closers != 0 else {
              let run = streamStringRun(base: base, from: at &+ 1, to: to)
              let closed =
                run.end < to && base.load(fromByteOffset: run.end, as: UInt8.self) == .asciiQuote
              if raw <= State.firstValue.rawValue {
                self.isKeyToken = false
                guard closed else {
                  if run.end < to {
                    let next = try self.consumeEscapedStringInRun(
                      base: base, quoteAt: at, from: at &+ 1, to: to, run: run, into: &sink
                    )
                    state = self.state
                    if !state.isStructural { return next }
                    if next &- p >= 64 {
                      p = next
                      continue outer
                    }
                    mask &= UInt64.max &<< UInt64(next &- p)
                    continue
                  }
                  // Cut by the chunk end: `consumeStringRun` takes the token from the opening
                  // quote, exactly as it does when the scalar arm hands it over.
                  self.stringBeginPending = true
                  state = .inString
                  return at &+ 1
                }
                do throws(JSONParsingError) {
                  try self.validateUTF8IfNeeded(
                    base: base, from: at &+ 1, to: run.end,
                    containsNonASCII: run.containsNonASCII, reportAt: nil
                  )
                } catch {
                  try self.record(
                    .stringBegin, start: at, length: 1, end: at &+ 1, base: base, into: &sink
                  )
                  try Self.fail(error)
                }
                try self.record(
                  .string, start: at &+ 1, length: run.end &- at &- 1, end: run.end &+ 1,
                  base: base, into: &sink
                )
                state = .afterValue
              } else {
                guard closed else {
                  self.isKeyToken = true
                  self.bufferCount = 0
                  self.keyContainsNonASCII = false
                  state = .inKey
                  return at &+ 1
                }
                try self.emitKeyInPlace(
                  base: base, from: at &+ 1, to: run.end, containsNonASCII: run.containsNonASCII,
                  into: &sink
                )
                state = .afterKey
              }
              if run.end &+ 1 &- p >= 64 {
                p = run.end &+ 1
                continue outer
              }
              mask &= UInt64.max &<< UInt64(run.end &+ 1 &- p)
              continue
            }
            let closeBit = closers.trailingZeroBitCount
            let closeAt = p &+ closeBit
            let escapes =
              classes.backslash & ~consumed & ((UInt64(1) &<< UInt64(closeBit)) &- 1)

            if escapes != 0 {
              // A key with an escape in it is rare enough not to be worth a second decoder here;
              // the scalar loop buffers it through `consumeKeyRun` as it does today.
              guard raw <= State.firstValue.rawValue else { return at }
              // A string value with an escape: the existing decoder, entered exactly as the
              // scalar run enters it -- the scan from the byte after the opening quote (which
              // stops at that first backslash), then `consumeEscapedStringInRun`, which owns the
              // `stringBegin`, the chunks, the `stringEnd` and the comma fusion.
              self.isKeyToken = false
              let run = streamStringRun(base: base, from: at &+ 1, to: to)
              let next = try self.consumeEscapedStringInRun(
                base: base, quoteAt: at, from: at &+ 1, to: to, run: run, into: &sink
              )
              state = self.state
              // `fuseAfterValue` may have left a per-byte state behind (or the token may have
              // been cut); either way the run's own `isStructural` check is what decides, and the
              // caller's copy of `state` has just been told.
              if !state.isStructural { return next }
              if next &- p >= 64 {
                p = next
                continue outer
              }
              mask &= UInt64.max &<< UInt64(next &- p)
              continue
            }

            if raw <= State.firstValue.rawValue {
              self.isKeyToken = false
              do throws(JSONParsingError) {
                try self.validateUTF8IfNeeded(
                  base: base, from: at &+ 1, to: closeAt, containsNonASCII: containsNonASCII,
                  reportAt: nil
                )
              } catch {
                // `stringBegin` precedes the error on the call-per-event path; keep that order.
                try self.record(
                  .stringBegin, start: at, length: 1, end: at &+ 1, base: base, into: &sink
                )
                try Self.fail(error)
              }
              try self.record(
                .string, start: at &+ 1, length: closeAt &- at &- 1, end: closeAt &+ 1,
                base: base, into: &sink
              )
              state = .afterValue
            } else {
              try self.emitKeyInPlace(
                base: base, from: at &+ 1, to: closeAt, containsNonASCII: containsNonASCII,
                into: &sink
              )
              state = .afterKey
            }
            if closeBit == 63 {
              p = closeAt &+ 1
              continue outer
            }
            mask &= UInt64.max &<< UInt64(closeBit &+ 1)
            continue
          }

          if raw <= State.firstValue.rawValue {
            switch byte {
            case .asciiObjectStart:
              let disposition = try self.recordContainerOpen(
                object: true, end: at &+ 1, into: &sink
              )
              guard depth < Self.maximumDepth else {
                try Self.fail(.depthExceeded, byteOffset: self.consumedByteCount &+ at)
              }
              containers |= 1 &<< Self.shiftAmount(depth)
              depth &+= 1
              // The skip scanner owns the subtree from here; the dispatcher re-enters it.
              //
              // Skipping it *in place* instead -- walking the rest of the block's `starts` bits,
              // pairing strings off with the quote mask, matching brackets, delivering the close
              // when it lands in the same block -- was built, tested against the scalar ladder at
              // every alignment, and measured. It is a real win where the subtrees are small
              // (`Twitter - bulk discarding` +3.5% against +2.6%, `GitHub events` +3.1%), and a
              // loss where they are not: `CITM catalog - bulk discarding` -3.7% against -1.8% and
              // `LLM message - bulk` -1.4% against +1.5%, because a subtree that outlives its
              // block leaves the walk to re-read bytes the skip scanner's own kernel would have
              // taken 64 at a time. Sweep mean +4.07% against +5.24%, so it is not here.
              if disposition != .stream {
                self.skipEndDepth = UInt8(truncatingIfNeeded: depth &- 1)
                state = .skipping
                return at &+ 1
              }
              state = .firstKey
            case .asciiArrayStart:
              let disposition = try self.recordContainerOpen(
                object: false, end: at &+ 1, into: &sink
              )
              guard depth < Self.maximumDepth else {
                try Self.fail(.depthExceeded, byteOffset: self.consumedByteCount &+ at)
              }
              containers &= ~(1 &<< Self.shiftAmount(depth))
              depth &+= 1
              if disposition != .stream {
                self.skipEndDepth = UInt8(truncatingIfNeeded: depth &- 1)
                state = .skipping
                return at &+ 1
              }
              state = .firstValue
            case .asciiArrayEnd:
              guard state == .firstValue, !Self.topIsObject(depth: depth, containers: containers)
              else {
                try Self.fail(.unexpectedToken, byteOffset: self.consumedByteCount &+ at)
              }
              try self.record(
                .endArray, start: at, length: 1, end: at &+ 1, base: base, into: &sink
              )
              depth &-= 1
              if depth == 0 {
                state = .done
                return at &+ 1
              }
              state = .afterValue
            // `"` was taken ahead of the ladder.
            case .asciiLowerT:
              guard to &- at >= 4,
                UInt32(littleEndian: base.loadUnaligned(fromByteOffset: at, as: UInt32.self))
                  == 0x6575_7274
              else { return at }
              try self.record(
                .boolean, start: at, length: 4, end: at &+ 4, extra: 1, base: base, into: &sink
              )
              state = .afterValue
              if bit &+ 4 >= 64 {
                p = at &+ 4
                continue outer
              }
              mask &= UInt64.max &<< UInt64(bit &+ 4)
              continue
            case .asciiLowerF:
              guard to &- at >= 5,
                UInt32(littleEndian: base.loadUnaligned(fromByteOffset: at &+ 1, as: UInt32.self))
                  == 0x6573_6c61
              else { return at }
              try self.record(
                .boolean, start: at, length: 5, end: at &+ 5, base: base, into: &sink
              )
              state = .afterValue
              if bit &+ 5 >= 64 {
                p = at &+ 5
                continue outer
              }
              mask &= UInt64.max &<< UInt64(bit &+ 5)
              continue
            case .asciiLowerN:
              guard to &- at >= 4,
                UInt32(littleEndian: base.loadUnaligned(fromByteOffset: at, as: UInt32.self))
                  == 0x6c6c_756e
              else { return at }
              try self.record(.null, start: at, length: 4, end: at &+ 4, base: base, into: &sink)
              state = .afterValue
              if bit &+ 4 >= 64 {
                p = at &+ 4
                continue outer
              }
              mask &= UInt64.max &<< UInt64(bit &+ 4)
              continue
            case .asciiDash, .asciiZero ... .asciiNine:
              // The extent is deliberately *not* taken from the masks: `12abc` has to report
              // `unexpectedToken` at the `a`, which is what the grammar walk behind
              // `streamNumberRunEnd` does and what a mask over the number's byte class would not.
              let end = streamNumberRunEnd(base: base, from: at, to: to)
              guard end < to else {
                // The token may continue in the next chunk, so it goes to the per-byte path
                // whole, exactly as the scalar arm hands it over.
                self.resetNumber()
                state = .number
                return at
              }
              try self.emitNumber(base: base, from: at, to: end, into: &sink, reportAt: end)
              state = .afterValue
              if end &- p >= 64 {
                p = end
                continue outer
              }
              mask &= UInt64.max &<< UInt64(end &- p)
              continue
            default:
              try Self.fail(.unexpectedToken, byteOffset: self.consumedByteCount &+ at)
            }

          } else if raw == State.afterValue.rawValue {
            switch byte {
            case .asciiComma:
              guard depth > 0 else {
                try Self.fail(.unexpectedToken, byteOffset: self.consumedByteCount &+ at)
              }
              state = Self.topIsObject(depth: depth, containers: containers) ? .key : .value
            case .asciiArrayEnd:
              guard depth > 0, !Self.topIsObject(depth: depth, containers: containers) else {
                try Self.fail(.unexpectedToken, byteOffset: self.consumedByteCount &+ at)
              }
              try self.record(
                .endArray, start: at, length: 1, end: at &+ 1, base: base, into: &sink
              )
              depth &-= 1
              if depth == 0 {
                state = .done
                return at &+ 1
              }
              state = .afterValue
            case .asciiObjectEnd:
              guard Self.topIsObject(depth: depth, containers: containers) else {
                try Self.fail(.unexpectedToken, byteOffset: self.consumedByteCount &+ at)
              }
              try self.record(
                .endObject, start: at, length: 1, end: at &+ 1, base: base, into: &sink
              )
              depth &-= 1
              if depth == 0 {
                state = .done
                return at &+ 1
              }
              state = .afterValue
            default:
              try Self.fail(.unexpectedToken, byteOffset: self.consumedByteCount &+ at)
            }

          } else if raw <= State.firstKey.rawValue {
            switch byte {
            // `"` was taken ahead of the ladder.
            case .asciiObjectEnd:
              guard state == .firstKey, Self.topIsObject(depth: depth, containers: containers)
              else {
                try Self.fail(.unexpectedToken, byteOffset: self.consumedByteCount &+ at)
              }
              try self.record(
                .endObject, start: at, length: 1, end: at &+ 1, base: base, into: &sink
              )
              depth &-= 1
              if depth == 0 {
                state = .done
                return at &+ 1
              }
              state = .afterValue
            default:
              try Self.fail(.unexpectedToken, byteOffset: self.consumedByteCount &+ at)
            }

          } else if raw == State.afterKey.rawValue {
            guard byte == .asciiColon else {
              try Self.fail(.unexpectedToken, byteOffset: self.consumedByteCount &+ at)
            }
            state = .value
          } else if raw == State.done.rawValue {
            try Self.fail(.trailingContent, byteOffset: self.consumedByteCount &+ at)
          } else {
            try Self.fail(.unexpectedToken, byteOffset: self.consumedByteCount &+ at)
          }
          // Every arm that falls through here consumed exactly its one byte.
          mask &= mask &- 1
        }

        // The mask is exhausted, so everything left in the block is whitespace: every string it
        // held was finished (in place, or by the scan above), so nothing is open at the edge and
        // the next block is classifiable with nothing carried in.
        p &+= 64
      }
      return p
    }
  }
#endif
