// The skip scanner: what runs between a container open whose sink answered `.skip` and its
// matching close. The interior is scanned *structurally* — brackets tracked in the same
// `depth`/`containers` registers the structural run uses (so a `[` closed by `}` is still
// rejected, and the depth cap still holds), strings skipped with control bytes still rejected
// and UTF-8 still validated — but token interiors are not re-checked: numbers are their byte
// class, escape selectors are consumed blind, literals are loose letters, and commas and
// colons are not positionally validated. That trade is the entire point: no key matching, no
// number parse, no escape decode, no sink call per token — and it is documented on
// `StreamContainerDisposition.skip`. simdjson's On Demand makes the same one for skipped
// values.
//
// The scanner delivers exactly one thing: the matching `endObject`/`endArray` call, at the
// close bracket, with the same failure-check offset the streaming path uses. That is the
// advisory contract's other half — a sink that answered `.skip` still sees its container
// close, so a `PartialSink` pops the ignored frame it pushed at the open.
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
    if state == .skippingEscape {
      guard i < to else { return i }
      // The escaped character, consumed blind — the selector is not validated in a skipped
      // interior. `\"` and `\\` are the two that matter structurally, and both are one byte.
      i &+= 1
      state = .skippingString
    }
    if state == .skippingString {
      guard let end = try self.skipStringBody(base: base, from: i, to: to, state: &state) else {
        return to
      }
      i = end
      state = .skipping
    }
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
          try self.record(.endObject, start: at, length: 1, end: i, into: &sink)
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
          try self.record(.endArray, start: at, length: 1, end: i, into: &sink)
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
        // Consumed blind, as above.
        i &+= 1
      } else {
        throw self.error(.unterminatedString, at: byteAt)
      }
    }
  }
}
