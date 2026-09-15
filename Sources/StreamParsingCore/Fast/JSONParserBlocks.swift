#if arch(arm64) || arch(x86_64)
  import StreamParsingShims

  // The structural run's 64-byte block path: `consumeStructural`'s walk driven by the three masks
  // of `stream_parsing_classify_structural_block` (NEON inlined; the AVX2 twin is a call per
  // block). Every arm restates its `consumeStructural` arm -- same events, spans, failure offsets
  // and error reasons; anything the masks cannot settle goes back to the scalar loop at the byte it
  // starts on. See NEW_ARCHITECTURE.md, "The structural block walk".
  extension JSONParser {
    // Entered with a structural state, no token in flight and a whole block ahead. Returns where
    // the scalar loop resumes (`~p` once the gate gives up), `state`/`depth`/`containers` written
    // back. Out of line like `consumeSkipBlocks`: the classifier's hoisted constants would put a d8
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
        // The gate: a block strikes with no whitespace outside strings (nothing for the `tzcnt` to
        // buy over the ladder's scan) or dense `starts` (Mesh); four in a row and the walk is done
        // with this parser. Census in NEW_ARCHITECTURE.md. x86 gets the verdict whole from the
        // kernel: baseline x86-64 has no `popcnt` (`nonzeroBitCount` was 17 instructions a block).
        #if arch(x86_64)
          let strike = classes.strike != 0
        #else
          let strike =
            classes.no_outer_whitespace != 0
            || classes.starts.nonzeroBitCount >= Int(STREAM_PARSING_BLOCK_WALK_DENSE_STARTS)
        #endif
        if strike {
          self.blockWalkStrikes &+= 1
          if self.blockWalkStrikes >= 4 {
            self.blockWalkGivenUp = true
            return ~p
          }
        } else if self.blockWalkStrikes != 0 {
          // Consecutive, not cumulative. Measured: counting GSoC's odd whitespace-free blocks up
          // reached four and threw its win away (+18.1% -> -0.8%).
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

        // Mask exhausted: the rest of the block is whitespace and every string in it was finished,
        // so the next block is classifiable with nothing carried in.
        p &+= 64
      }
      return p
    }
  }
#endif
