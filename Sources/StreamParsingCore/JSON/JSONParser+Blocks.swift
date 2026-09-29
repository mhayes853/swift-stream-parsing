#if arch(arm64) || arch(x86_64)
  import StreamParsingShims

  // The structural run's 64-byte block path: `consumeStructural`'s walk driven by the three masks
  // of `stream_parsing_classify_structural_block` (NEON inlined; the AVX2 twin is a call per
  // block). Every arm restates its `consumeStructural` arm -- same events, spans, failure offsets
  // and error reasons; anything the masks cannot settle goes back to the scalar loop at the byte it
  // starts on. See NEW_ARCHITECTURE.md, "The structural block walk".
  extension JSONParser {
    // Entered with a structural state, no token in flight and a whole block ahead. Returns where
    // the scalar loop resumes, `state`/`depth`/`containers` written back. Out of line like `consumeSkipBlocks`: the classifier's hoisted constants would put a d8
    // save/restore in the prologue of `consumeStructuralRun`, which every byte-fed token pays.
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
      // The grid moves with the tokens, so carries are always zero: the walk only consumes tokens
      // that finish in the block, and re-anchors at the end of one that runs past it. Measured: a
      // fixed grid with real carries classifies every long string's interior, GSoC/LLM -9%/-20%.
      outer: while p &+ 64 <= to {
        let classes = stream_parsing_classify_structural_block(
          base.advanced(by: p).assumingMemoryBound(to: UInt8.self), 0, 0
        )
        // Anything unusual is the scalar loop's, from this block's first byte, so the byte an
        // error names is the byte the scalar loop names.
        if classes.needs_scalar != 0 { return p }
        // Nothing in the block for the walk to buy (the field's comment says what that means), so
        // it is the ladder's, which comes back at the next indentation or string it meets. A
        // function of this block alone -- no strikes, no verdict, no history.
        if classes.ladder_block != 0 { return p }
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
            // No closing quote in this block: the scalar arm's scan, restated. Measured: handing
            // the token back re-classified the block per string (Qwen workspace -26%, LLM -3%).
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
              // A string value with an escape, decoded as the scalar run decodes it. It does not
              // fuse the following comma (the fields do not hold this walk's container stack), so
              // a finished token comes back `.afterValue` and the walk takes the comma itself.
              self.isKeyToken = false
              let run = streamStringRun(base: base, from: at &+ 1, to: to)
              let next = try self.consumeEscapedStringInRun(
                base: base, quoteAt: at, from: at &+ 1, to: to, run: run, into: &sink
              )
              state = self.state
              // A token the chunk cut, or an escape left to the per-byte states, is non-structural.
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
              // The colon, taken with its key: it sits against the closing quote in every style
              // producers emit (`"k":`, `"k": `, indented), so this is not a spacing bet, and it
              // spares each member a whole trip round the mask loop for a byte that emits nothing.
              // `closeBit != 63` keeps the load inside the block (and so inside the chunk). Any
              // other byte -- `"k" :`, or an error -- goes round the loop as before, and the
              // `.afterKey` arm names it at the same offset.
              if closeBit != 63,
                base.load(fromByteOffset: closeAt &+ 1, as: UInt8.self) == .asciiColon
              {
                state = .value
                if closeBit == 62 {
                  p = closeAt &+ 2
                  continue outer
                }
                mask &= UInt64.max &<< UInt64(closeBit &+ 2)
                continue
              }
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
              Self.pushContainer(object: true, depth: &depth, containers: &containers)
              // The skip scanner owns the subtree from here; the dispatcher re-enters it. Measured:
              // skipping in place here lost where subtrees outlive the block (sweep mean +4.07% vs
              // +5.24%) -- see NEW_ARCHITECTURE.md, "Skipping a subtree inside the block walk".
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
              Self.pushContainer(object: false, depth: &depth, containers: &containers)
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
              // The extent is the first `scalar_end` bit above the token: one `tzcnt` in place of
              // `streamNumberRunEnd`'s dependent load/lookup/movemask chain per number. That bit
              // is where a *valid* number ends; a malformed one (`12abc`) runs on to it, fails
              // the whole-token parse before anything is emitted, and goes back to the scalar
              // loop at its first byte with the state untouched -- so `12abc` still reports
              // `unexpectedToken` at the `a`, from the code that has always reported it.
              let ends = classes.scalar_end & (UInt64.max &<< UInt64(bit))
              var end = p &+ ends.trailingZeroBitCount
              if ends == 0 {
                // The number runs out of the block (`end` is `p + 64` here, which the loop bound
                // keeps inside the chunk). Nothing up to there ends it, so the scalar scan picks
                // up at the edge rather than at the token's first byte.
                end = streamNumberRunEnd(base: base, from: end, to: to)
                guard end < to else {
                  // The token may continue in the next chunk, so it goes to the per-byte path
                  // whole, exactly as the scalar arm hands it over.
                  self.resetNumber()
                  state = .number
                  return at
                }
              }
              // One emit site: `emitNumber` is forced inline, and a second copy of it cost the
              // walk 118 instructions and 16 stack accesses.
              do throws(JSONParsingError) {
                try self.emitNumber(base: base, from: at, to: end, into: &sink, reportAt: end)
              } catch {
                guard case .invalidNumber = error.reason else { throw error }
                return at
              }
              state = .afterValue
              // An array's `,` after the number: the numbers behind it are `fuseNumberRun`'s, as
              // they are on the ladder. Measured: an indented numeric array cost the walk 274
              // instructions a number (the comma's trip round the mask loop, the number arm's
              // dispatch, a classify per three or four numbers) against the fused loop's ~200.
              // It returns past the block as often as not; the grid moves with it.
              if depth > 0, end &+ 1 < to,
                base.load(fromByteOffset: end, as: UInt8.self) == .asciiComma,
                !Self.topIsObject(depth: depth, containers: containers)
              {
                let resume = try self.fuseNumberRun(base: base, comma: end, to: to, into: &sink)
                guard resume >= 0 else {
                  // A number the chunk cut, from its first byte, reset for `.number`.
                  state = .number
                  return ~resume
                }
                if resume &- p >= 64 {
                  p = resume
                  continue outer
                }
                mask &= UInt64.max &<< UInt64(resume &- p)
                continue
              }
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
                try Self.failAfterValue(depth: depth, byteOffset: self.consumedByteCount &+ at)
              }
              state = Self.topIsObject(depth: depth, containers: containers) ? .key : .value
            case .asciiArrayEnd:
              guard depth > 0, !Self.topIsObject(depth: depth, containers: containers) else {
                try Self.failAfterValue(depth: depth, byteOffset: self.consumedByteCount &+ at)
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
                try Self.failAfterValue(depth: depth, byteOffset: self.consumedByteCount &+ at)
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
              try Self.failAfterValue(depth: depth, byteOffset: self.consumedByteCount &+ at)
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

        // Mask exhausted: the rest of the block is whitespace and every string in it was finished,
        // so the next block is classifiable with nothing carried in.
        p &+= 64
      }
      return p
    }
  }
#endif
