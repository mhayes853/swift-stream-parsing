import Benchmark
import StageOneLab

// Stage-1 extraction experiments: what does a simdjson-style classification pass cost on this
// corpus, and does interleaving it with a consuming pass per sub-chunk (so the second pass
// reads L1-resident bytes) beat one pass over the whole document? Three tiers:
//
//   String mask   backslash/quote/escape/in-string masks only (tier 1)
//   Full masks    + structural/whitespace classify + scalar starts, no extraction (tier 1.5)
//   Index         + bits-to-indices into a u32 position array (tier 2)
//   Index+Touch   tier 2 followed by a synthetic stage 2 that loads one byte per index,
//                 interleaved per window — the sub-chunk size sweep
//
// Rows report Payload MB/s next to the `Real <name> - bulk` rows, which is the parser these
// passes would be taxing. The kernel's index-entry definition is pinned by
// `verifyStageOneKernel()` against a scalar Swift reference at registration; a mismatch traps.

// MARK: - Drivers

// Every window except the last must be a multiple of 64: the C pass pads a short tail block
// with whitespace, which is only truthful at the end of the document.
@inline(__always)
private func checkedWindow(_ window: Int, count: Int) {
  precondition(window > 0 && (window % 64 == 0 || window >= count))
}

private func stage1StringMask(_ payload: [UInt8], window: Int) -> UInt64 {
  checkedWindow(window, count: payload.count)
  return payload.withUnsafeBufferPointer { buffer in
    guard let base = buffer.baseAddress else { return 0 }
    var carry = sp1_carry_t()
    var sum: UInt64 = 0
    var offset = 0
    while offset < buffer.count {
      let length = min(window, buffer.count - offset)
      sum ^= sp1_string_mask_pass(base + offset, length, &carry)
      offset += length
    }
    return sum
  }
}

private func stage1FullMasks(_ payload: [UInt8], window: Int) -> UInt64 {
  checkedWindow(window, count: payload.count)
  return payload.withUnsafeBufferPointer { buffer in
    guard let base = buffer.baseAddress else { return 0 }
    var carry = sp1_carry_t()
    var sum: UInt64 = 0
    var offset = 0
    while offset < buffer.count {
      let length = min(window, buffer.count - offset)
      sum ^= sp1_full_masks_pass(base + offset, length, &carry)
      offset += length
    }
    return sum
  }
}

private func stage1Index(
  _ payload: [UInt8], window: Int, into indices: UnsafeMutablePointer<UInt32>
) -> Int {
  checkedWindow(window, count: payload.count)
  return payload.withUnsafeBufferPointer { buffer in
    guard let base = buffer.baseAddress else { return 0 }
    var carry = sp1_carry_t()
    var total = 0
    var offset = 0
    while offset < buffer.count {
      let length = min(window, buffer.count - offset)
      total += sp1_index_pass(base + offset, length, UInt32(offset), &carry, indices)
      offset += length
    }
    return total
  }
}

private func stage1IndexTouch(
  _ payload: [UInt8], window: Int, into indices: UnsafeMutablePointer<UInt32>
) -> UInt64 {
  checkedWindow(window, count: payload.count)
  return payload.withUnsafeBufferPointer { buffer in
    guard let base = buffer.baseAddress else { return 0 }
    var carry = sp1_carry_t()
    var sum: UInt64 = 0
    var offset = 0
    while offset < buffer.count {
      let length = min(window, buffer.count - offset)
      let count = sp1_index_pass(base + offset, length, UInt32(offset), &carry, indices)
      sum &+= sp1_touch_pass(base, indices, count)
      offset += length
    }
    return sum
  }
}

// MARK: - Scratch

// One index buffer shared by every row, sized for the largest corpus plus the extraction
// groups' overshoot, allocated and touched once at registration so no row pays first-fault.
private final class IndexScratch: @unchecked Sendable {
  let pointer: UnsafeMutablePointer<UInt32>
  init(capacity: Int) {
    self.pointer = .allocate(capacity: capacity)
    self.pointer.initialize(repeating: 0, count: capacity)
  }
}

// MARK: - Registration

func stageOneBenchmarks() {
  let corpora: [(String, [UInt8])] = [
    ("Twitter", Payloads.twitter),
    ("Twitter escaped", Payloads.twitterEscaped),
    ("Canada", Payloads.canada),
    ("CITM catalog", Payloads.citmCatalog),
    ("GSoC 2018", Payloads.gsoc2018),
    ("GitHub events", Payloads.githubEvents),
    ("LLM message", Payloads.llmMessage),
    ("Mesh", Payloads.mesh),
  ]

  verifyStageOneKernel(corpora: corpora)

  let scratch = IndexScratch(capacity: corpora.map(\.1.count).max()! + 8)

  for (name, payload) in corpora {
    Benchmark("Stage1 String mask \(name)", configuration: payloadConfiguration) { benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(stage1StringMask(payload, window: payload.count))
      }
    }

    Benchmark("Stage1 Full masks \(name)", configuration: payloadConfiguration) { benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(stage1FullMasks(payload, window: payload.count))
      }
    }

    Benchmark("Stage1 Index \(name)", configuration: payloadConfiguration) { benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(stage1Index(payload, window: payload.count, into: scratch.pointer))
      }
    }
  }

  // The sub-chunk sweep: same total work at every size, different interleave. If the second
  // pass's residency matters, it shows up here as a knee; if the whole-document rows match
  // the small windows, the L1 hypothesis is dead for corpora this size.
  let sweepCorpora: [(String, [UInt8])] = [
    ("Canada", Payloads.canada),
    ("CITM catalog", Payloads.citmCatalog),
    ("GSoC 2018", Payloads.gsoc2018),
    ("Twitter", Payloads.twitter),
  ]
  let windows: [(String, Int)] = [
    ("512B", 512), ("4KB", 4096), ("32KB", 32_768), ("256KB", 262_144), ("whole", .max),
  ]

  for (name, payload) in sweepCorpora {
    for (label, window) in windows {
      let effective = min(window, payload.count)
      Benchmark(
        "Stage1 Index+Touch \(name) - \(label)", configuration: payloadConfiguration
      ) { benchmark in
        measurePayloadThroughput(benchmark, payload: payload) {
          blackHole(stage1IndexTouch(payload, window: effective, into: scratch.pointer))
        }
      }
    }
  }
}

// MARK: - Verification

// Scalar reference with the kernel's exact semantics (escape parity is positional and global,
// simdjson-style, not grammar-aware — identical on valid JSON, and defined the same way on
// byte soup so the random cases below can compare). One entry per: unescaped quote, structural
// char outside a string, first byte of a scalar run outside a string. 0x00 is whitespace here
// because the nibble tables classify it so; documented in StageOneLab.c.
private func referenceStage1Index(_ bytes: [UInt8]) -> [UInt32] {
  var out: [UInt32] = []
  var pendingEscape = false
  var inString = false
  var previousWasScalar = false
  for (i, byte) in bytes.enumerated() {
    let escaped = pendingEscape
    pendingEscape = byte == 0x5C && !escaped
    let isQuote = byte == 0x22 && !escaped
    if inString {
      previousWasScalar = false
      if isQuote {
        out.append(UInt32(i))
        inString = false
      }
    } else if isQuote {
      out.append(UInt32(i))
      inString = true
      previousWasScalar = false
    } else {
      switch byte {
      case 0x2C, 0x3A, 0x5B, 0x5D, 0x7B, 0x7D:
        out.append(UInt32(i))
        previousWasScalar = false
      case 0x20, 0x09, 0x0A, 0x0D, 0x00:
        previousWasScalar = false
      case 0x22:  // escaped quote outside a string: quote class, not scalar, no entry
        previousWasScalar = false
      default:
        if !previousWasScalar { out.append(UInt32(i)) }
        previousWasScalar = true
      }
    }
  }
  return out
}

private struct SplitMix64 {
  var state: UInt64
  mutating func next() -> UInt64 {
    self.state &+= 0x9E37_79B9_7F4A_7C15
    var z = self.state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

private func kernelIndex(_ bytes: [UInt8], window: Int) -> [UInt32] {
  guard !bytes.isEmpty else { return [] }
  let scratch = UnsafeMutablePointer<UInt32>.allocate(capacity: bytes.count + 8)
  defer { scratch.deallocate() }
  var out: [UInt32] = []
  out.reserveCapacity(bytes.count)
  bytes.withUnsafeBufferPointer { buffer in
    let base = buffer.baseAddress!
    var carry = sp1_carry_t()
    var offset = 0
    while offset < buffer.count {
      let length = min(window, buffer.count - offset)
      let count = sp1_index_pass(base + offset, length, UInt32(offset), &carry, scratch)
      out.append(contentsOf: UnsafeBufferPointer(start: scratch, count: count))
      offset += length
    }
  }
  return out
}

private func verifyStageOneKernel(corpora: [(String, [UInt8])]) {
  func check(_ name: String, _ bytes: [UInt8], windows: [Int]) {
    let expected = referenceStage1Index(bytes)
    for window in windows {
      let actual = kernelIndex(bytes, window: window)
      if actual != expected {
        let at = zip(actual, expected).enumerated().first { $1.0 != $1.1 }
        preconditionFailure(
          """
          Stage-1 kernel mismatch on \(name) (window \(window)): \
          \(actual.count) vs \(expected.count) entries, first divergence at \
          \(at.map { "entry \($0.offset): \($0.element.0) vs \($0.element.1)" } ?? "tail")
          """
        )
      }
    }
  }

  for (name, payload) in corpora {
    check(name, payload, windows: [payload.count, 4096])
  }

  // Backslash runs of every parity crossing the 64- and 128-byte boundaries.
  for runLength in 0..<130 {
    var bytes = Array("{\"k\":\"a".utf8)
    bytes.append(contentsOf: repeatElement(0x5C, count: runLength))
    bytes.append(contentsOf: Array("n b\"}".utf8))
    check("backslash run \(runLength)", bytes, windows: [bytes.count, 64, 128])
  }

  // Deterministic byte soup, weighted toward the characters the bit algebra can get wrong.
  var rng = SplitMix64(state: 0x5EED_5EED_5EED_5EED)
  let special = Array("\\\"{}[]:, \t\n\r0123456789.eEtrufalsn-".utf8)
  for _ in 0..<500 {
    let length = Int(rng.next() % 400)
    var bytes = [UInt8]()
    bytes.reserveCapacity(length)
    for _ in 0..<length {
      let roll = rng.next()
      if roll % 4 == 0 {
        bytes.append(UInt8(truncatingIfNeeded: roll >> 8))
      } else {
        bytes.append(special[Int(roll >> 8) % special.count])
      }
    }
    check("byte soup", bytes, windows: [max(bytes.count, 1), 64, 128])
  }
}
