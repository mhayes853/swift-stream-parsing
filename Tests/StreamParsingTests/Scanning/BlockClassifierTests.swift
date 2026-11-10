#if arch(arm64)
  import CustomDump
  import StreamParsingShims
  import Testing

  // The two 64-byte block classifiers, held field by field to a byte-at-a-time restatement of what
  // their comments in `StreamParsingShims.h` promise. The walks' agreement tests reach the
  // classifiers only through documents; these put every byte value at every position of a block,
  // under every pair of carries, which is where a lane or bit-order mistake in the movemask shows
  // (the NEON kernels load the block deinterleaved and put the bits back in order).
  @Suite
  struct `Block classifier tests` {
    // Bytes the scalar ladder and the skip switch accept outside a string: whitespace, the quote,
    // number characters, the colon and comma, the brackets, and the lower-case letters (literals).
    // A backslash outside a string is never accepted either -- it rides on the quote's row of the
    // tables but is tested separately below.
    private static func isAccepted(_ byte: UInt8) -> Bool {
      switch byte {
      case 0x09, 0x0A, 0x0D, 0x20, 0x22, 0x2B, 0x2C, 0x2D, 0x2E, 0x30...0x3A, 0x45, 0x5B, 0x5D,
        0x61...0x7A, 0x7B, 0x7D:
        return true
      default:
        return false
      }
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
      byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func isBracket(_ byte: UInt8) -> Bool {
      byte == 0x5B || byte == 0x5D || byte == 0x7B || byte == 0x7D
    }

    private struct Reference: Equatable {
      var starts: UInt64 = 0
      var quote: UInt64 = 0
      var backslash: UInt64 = 0
      var scalarEnd: UInt64 = 0
      var brackets: UInt64 = 0
      var inString: UInt64 = 0
      var endsOdd: UInt64 = 0
      var needsScalar = false
      var nonASCII = false
      var ladderBlock = false
    }

    private static func reference(_ block: [UInt8], inStringCarry: Bool, endsOddCarry: Bool)
      -> Reference
    {
      var result = Reference()
      var escapePending = endsOddCarry
      var inside = inStringCarry
      var insideBits: UInt64 = 0
      var whitespace: UInt64 = 0
      var separator: UInt64 = 0
      for (index, byte) in block.enumerated() {
        let bit = UInt64(1) << UInt64(index)
        let escaped = escapePending
        escapePending = byte == 0x5C && !escaped
        if byte == 0x5C { result.backslash |= bit }
        if byte == 0x22 && !escaped {
          result.quote |= bit
          inside.toggle()
        }
        // After the toggle: the opening quote is inside its string, the closing one is not.
        let isInside = inside
        if isInside { insideBits |= bit }
        if isWhitespace(byte) { whitespace |= bit }
        if byte == 0x2C || isBracket(byte) { separator |= bit }
        if isBracket(byte) && !isInside { result.brackets |= bit }
        if byte >= 0x80 { result.nonASCII = true }
        if isInside ? byte < 0x20 : !isAccepted(byte) { result.needsScalar = true }
      }
      result.endsOdd = escapePending ? 1 : 0
      result.inString = insideBits >> 63 != 0 ? .max : 0
      if result.quote == 0 && insideBits == .max {
        result.ladderBlock = true
        return result
      }
      let outerWhitespace = whitespace & ~insideBits
      result.ladderBlock =
        outerWhitespace == 0
        || (result.quote == 0 && outerWhitespace & (outerWhitespace << 1) == 0)
      result.starts = ~(insideBits | whitespace | result.quote) | (result.quote & insideBits)
      result.scalarEnd = whitespace | separator
      return result
    }

    private static func expectClassifiers(
      _ block: [UInt8], inStringCarry: Bool, endsOddCarry: Bool, _ label: @autoclosure () -> String
    ) {
      let expected = reference(block, inStringCarry: inStringCarry, endsOddCarry: endsOddCarry)
      let (structural, skip) = block.withUnsafeBufferPointer { buffer in
        let p = buffer.baseAddress!
        let inCarry: UInt64 = inStringCarry ? .max : 0
        let oddCarry: UInt64 = endsOddCarry ? 1 : 0
        return (
          stream_parsing_classify_structural_block(p, inCarry, oddCarry),
          stream_parsing_classify_skip_block(p, inCarry, oddCarry)
        )
      }
      var actual = Reference()
      actual.starts = structural.starts
      actual.quote = structural.quote
      actual.backslash = structural.backslash
      actual.scalarEnd = structural.scalar_end
      actual.brackets = expected.brackets
      actual.inString = structural.in_string
      actual.endsOdd = structural.ends_odd
      actual.needsScalar = structural.needs_scalar != 0
      actual.nonASCII = structural.non_ascii != 0
      actual.ladderBlock = structural.ladder_block != 0
      // `starts` and `scalar_end` are documented as read only when `needs_scalar` is zero, but the
      // kernel is deterministic in them, so they are held to the reference everywhere.
      expectNoDifference(actual, expected, "structural, \(label())")

      var skipActual = expected
      skipActual.brackets = skip.brackets
      skipActual.inString = skip.in_string
      skipActual.endsOdd = skip.ends_odd
      skipActual.needsScalar = skip.needs_scalar != 0
      skipActual.nonASCII = skip.non_ascii != 0
      expectNoDifference(skipActual, expected, "skip, \(label())")
    }

    // Backgrounds chosen so the probed byte lands outside a string, inside one, next to a
    // backslash run, and in a block that lies edge to edge inside a string.
    private static let backgrounds: [[UInt8]] = [
      Array(#"{"key": [1, 2.5e3], "s": "a b\"c", "t": true}  ,  [null]  , {"x":0} "#.utf8),
      Array(#"  "inside a long string with spaces and \\ \" escapes, and more"  "#.utf8),
      Array(#"\\\\\"\\""\\\\\"\\""\\\\\"\\""\\\\\"\\""\\\\\"\\""\\\\\"\\""\\\\\"\\"#.utf8),
      Array(repeating: UInt8(ascii: "q"), count: 64),
    ].map { Array(($0 + Array(repeating: UInt8(ascii: " "), count: 64)).prefix(64)) }

    @Test
    func `Every byte value at every position classifies as documented`() {
      for (backgroundIndex, background) in Self.backgrounds.enumerated() {
        for byte in UInt8.min...UInt8.max {
          for position in 0..<64 {
            var block = background
            block[position] = byte
            for carries in 0..<4 {
              Self.expectClassifiers(
                block, inStringCarry: carries & 1 != 0, endsOddCarry: carries & 2 != 0,
                "background \(backgroundIndex), byte 0x\(String(byte, radix: 16)) at \(position), carries \(carries)"
              )
            }
          }
        }
      }
    }

    @Test
    func `Random blocks over the JSON alphabet classify as documented`() {
      var state: UInt64 = 0x2026_1109_B10C_0001
      let alphabet: [UInt8] =
        [0x22, 0x22, 0x5C, 0x5C] + Array("{}[],: tn0123456789-+.eEaluxyz".utf8)
        + [0x09, 0x0A, 0x0D, 0x01, 0x7F, 0x80, 0xC3, 0xA9]
      for round in 0..<20_000 {
        var block = [UInt8](repeating: 0, count: 64)
        for index in 0..<64 {
          state ^= state << 13
          state ^= state >> 7
          state ^= state << 17
          block[index] = alphabet[Int(state >> 40) % alphabet.count]
        }
        Self.expectClassifiers(
          block, inStringCarry: round & 1 != 0, endsOddCarry: round & 2 != 0, "random block \(round)"
        )
      }
    }
  }
#endif
