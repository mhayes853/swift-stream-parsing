// SCRATCH: differential fuzzer used for a bug hunt. Not for commit.
import Foundation
import StreamParsingCore
import Testing

private struct LogSink: StreamParseSink {
  var log: [String] = []
  var str: [UInt8] = []
  var inString = false
  var depth = 0
  var skipAtDepth = Int.max
  var streamFailure: StreamSinkFailure?

  mutating func beginObject() -> StreamContainerDisposition {
    depth += 1
    log.append("{")
    return depth >= skipAtDepth ? .skip : .stream
  }
  mutating func endObject() { depth -= 1; log.append("}") }
  mutating func beginArray() -> StreamContainerDisposition {
    depth += 1
    log.append("[")
    return depth >= skipAtDepth ? .skip : .stream
  }
  mutating func endArray() { depth -= 1; log.append("]") }
  mutating func key(_ bytes: Span<UInt8>) {
    let b = bytes.withUnsafeBufferPointer { Array($0) }
    log.append("K" + b.map { String(format: "%02x", $0) }.joined())
  }
  mutating func stringBegin() {
    if inString { log.append("!nested-begin") }
    inString = true
    str.removeAll()
  }
  mutating func stringChunk(_ bytes: Span<UInt8>) {
    if !inString { log.append("!chunk-outside") }
    bytes.withUnsafeBufferPointer { str.append(contentsOf: $0) }
  }
  mutating func stringEnd() {
    if !inString { log.append("!end-outside") }
    inString = false
    log.append("S" + str.map { String(format: "%02x", $0) }.joined())
  }
  mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) {
    let b = bytes.withUnsafeBufferPointer { Array($0) }
    log.append(
      "N" + String(decoding: b, as: UTF8.self)
        + "|\(info.flags.contains(.overflowed) ? 0 : info.magnitude),\(info.exponent),\(info.digitCount),\(info.flags.rawValue)"
    )
  }
  mutating func boolean(_ value: Bool) { log.append(value ? "T" : "F") }
  mutating func null() { log.append("Z") }
}

private enum Outcome: Equatable, CustomStringConvertible {
  case ok([String])
  case fail(JSONParsingError, [String])
  var description: String {
    switch self {
    case .ok(let l): return "ok(\(l.suffix(6)))"
    case .fail(let e, let l): return "fail(\(e.reason)@\(e.byteOffset), \(l.count) events, tail \(l.suffix(4)))"
    }
  }
  var accepted: Bool { if case .ok = self { return true }; return false }
}

private func run(_ bytes: [UInt8], ranges: [Range<Int>]?, skipAt: Int = .max, cap: Int = 4096) -> Outcome {
  var parser = JSONParser(bufferCapacity: cap)
  var sink = LogSink()
  sink.skipAtDepth = skipAt
  do {
    if let ranges {
      try bytes.withUnsafeBufferPointer { buf in
        for r in ranges {
          try parser.parse(UnsafeBufferPointer(rebasing: buf[r]), into: &sink)
        }
      }
    } else {
      for b in bytes { try parser.parse(byte: b, into: &sink) }
    }
    try parser.finish(into: &sink)
    return .ok(sink.log)
  } catch let e as JSONParsingError {
    return .fail(e, sink.log)
  } catch {
    fatalError()
  }
}

private struct RNG: RandomNumberGenerator {
  var s: UInt64
  mutating func next() -> UInt64 {
    s &+= 0x9E37_79B9_7F4A_7C15
    var z = s
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

private struct Gen {
  var r: RNG
  mutating func int(_ n: Int) -> Int { Int.random(in: 0..<n, using: &r) }
  mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &r) < p }

  mutating func ws(_ out: inout [UInt8]) {
    if chance(0.6) { return }
    let n = chance(0.1) ? int(80) : int(4)
    for _ in 0..<n { out.append([0x20, 0x0A, 0x09, 0x0D, 0x20, 0x20][int(6)]) }
  }

  mutating func string(_ out: inout [UInt8], long: Bool = false) {
    out.append(0x22)
    let n = chance(0.15) ? int(300) : int(12)
    for _ in 0..<n {
      switch int(20) {
      case 0: out += Array("\\n".utf8)
      case 1: out += Array("\\\"".utf8)
      case 2: out += Array("\\\\".utf8)
      case 3: out += Array("\\/".utf8)
      case 4: out += Array(String(format: "\\u%04x", int(0xD800)).utf8)
      case 5: out += Array("\\ud83d\\ude00".utf8)
      case 6: out += Array("é".utf8)
      case 7: out += Array("€".utf8)
      case 8: out += Array("😀".utf8)
      case 9: out += Array("\\b\\f\\r\\t".utf8)
      case 10: out += Array("\\u00e9".utf8)
      default: out.append(UInt8(0x61 + int(26)))
      }
    }
    out.append(0x22)
  }

  mutating func number(_ out: inout [UInt8]) {
    if chance(0.3) { out.append(0x2D) }
    if chance(0.2) { out.append(0x30) } else {
      out.append(UInt8(0x31 + int(9)))
      let n = chance(0.1) ? int(25) : int(6)
      for _ in 0..<n { out.append(UInt8(0x30 + int(10))) }
    }
    if chance(0.3) {
      out.append(0x2E)
      let n = 1 + (chance(0.1) ? int(25) : int(5))
      for _ in 0..<n { out.append(UInt8(0x30 + int(10))) }
    }
    if chance(0.2) {
      out.append(chance(0.5) ? 0x65 : 0x45)
      if chance(0.5) { out.append(chance(0.5) ? 0x2B : 0x2D) }
      let n = 1 + int(2)
      for _ in 0..<n { out.append(UInt8(0x30 + int(10))) }
    }
  }

  mutating func value(_ out: inout [UInt8], depth: Int) {
    let k = depth > 6 ? 4 + int(4) : int(10)
    switch k {
    case 0, 1:
      out.append(0x5B); ws(&out)
      let n = chance(0.2) ? 0 : (chance(0.15) ? int(40) : int(5))
      for i in 0..<n {
        if i > 0 { ws(&out); out.append(0x2C); ws(&out) }
        value(&out, depth: depth + 1)
      }
      ws(&out); out.append(0x5D)
    case 2, 3:
      out.append(0x7B); ws(&out)
      let n = chance(0.2) ? 0 : int(6)
      for i in 0..<n {
        if i > 0 { ws(&out); out.append(0x2C); ws(&out) }
        string(&out); ws(&out); out.append(0x3A); ws(&out)
        value(&out, depth: depth + 1)
      }
      ws(&out); out.append(0x7D)
    case 4, 5: string(&out)
    case 6, 7: number(&out)
    case 8: out += Array(["true", "false", "null"][int(3)].utf8)
    default:
      // number arrays, the fused path
      out.append(0x5B)
      let n = int(30)
      let indent = chance(0.5)
      for i in 0..<n {
        if i > 0 { out.append(0x2C) }
        if indent { out += Array("\n      ".utf8) } else if chance(0.3) { out.append(0x20) }
        number(&out)
      }
      if indent { out += Array("\n    ".utf8) }
      out.append(0x5D)
    }
  }

  static let interesting: [UInt8] = Array("{}[]\",:\\ 0123456789eE.-+tfnulr/".utf8) + [
    0x00, 0x01, 0x1F, 0x7F, 0x80, 0xBF, 0xC0, 0xC2, 0xE0, 0xED, 0xA0, 0xF0, 0xF4, 0x90, 0xF5, 0xFF,
  ]

  mutating func mutate(_ doc: inout [UInt8]) {
    let ops = 1 + int(3)
    for _ in 0..<ops {
      guard !doc.isEmpty else { doc.append(Gen.interesting[int(Gen.interesting.count)]); continue }
      let p = int(doc.count)
      switch int(5) {
      case 0: doc.remove(at: p)
      case 1: doc.insert(Gen.interesting[int(Gen.interesting.count)], at: p)
      case 2: doc[p] = Gen.interesting[int(Gen.interesting.count)]
      case 3: doc.removeSubrange(p...)
      default:
        let q = min(doc.count, p + int(10))
        doc.insert(contentsOf: Array(doc[p..<q]), at: int(doc.count))
      }
    }
  }
}

private func randomRanges(_ count: Int, _ g: inout Gen) -> [Range<Int>] {
  var out: [Range<Int>] = []
  var s = 0
  let mode = g.int(3)
  let fixed = 1 + g.int(70)
  while s < count {
    let len: Int
    switch mode {
    case 0: len = fixed
    case 1: len = 1 + g.int(g.chance(0.5) ? 8 : 130)
    default: len = g.chance(0.5) ? 1 : 1 + g.int(200)
    }
    out.append(s..<min(count, s + len))
    s += len
  }
  return out
}

// Canonical tree text from our log, for oracle comparison.
private func oracleAccepts(_ bytes: [UInt8]) -> Bool {
  (try? JSONSerialization.jsonObject(with: Data(bytes), options: [.fragmentsAllowed])) != nil
}

@Suite
struct ZZScratchFuzz {
  @Test func fuzz() {
    let iterations = Int(ProcessInfo.processInfo.environment["FUZZ_N"] ?? "3000")!
    let seed = UInt64(ProcessInfo.processInfo.environment["FUZZ_SEED"] ?? "1")!
    var g = Gen(r: RNG(s: seed))
    var invariance = 0, oracle = 0, skipIssues = 0
    var seen = Set<String>()
    for it in 0..<iterations {
      var doc: [UInt8] = []
      g.ws(&doc)
      if g.chance(0.15) {
        // deep nest around the 64 cap
        let d = 58 + g.int(10)
        var closes: [UInt8] = []
        for _ in 0..<d {
          if g.chance(0.5) { doc.append(0x5B); closes.append(0x5D) } else { doc += Array("{\"k\":".utf8); closes.append(0x7D) }
          g.ws(&doc)
        }
        g.value(&doc, depth: 7)
        for c in closes.reversed() { g.ws(&doc); doc.append(c) }
      } else {
        g.value(&doc, depth: 0)
      }
      if g.chance(0.05) { g.ws(&doc); g.value(&doc, depth: 3) }
      g.ws(&doc)
      if g.chance(0.5) { g.mutate(&doc) }
      let whole = run(doc, ranges: [0..<doc.count])
      var variants: [(String, Outcome)] = [("bytewise", run(doc, ranges: nil))]
      for _ in 0..<3 {
        let rs = randomRanges(doc.count, &g)
        variants.append(("chunks\(rs.prefix(4).map { $0.count })", run(doc, ranges: rs)))
      }
      for (name, o) in variants where o != whole {
        invariance += 1
        let key = "inv:\(whole.accepted):\(o.accepted)"
        if seen.insert(key + "\(it % 1)").inserted || invariance < 15 {
          print("INVARIANCE it=\(it) \(name)\n  doc=\(String(decoding: doc, as: UTF8.self).debugDescription)\n  bytes=\(doc.count)\n  whole=\(whole)\n  other=\(o)")
        }
      }
      let oa = oracleAccepts(doc)
      if oa != whole.accepted {
        oracle += 1
        if oracle < 25 {
          print("ORACLE it=\(it) foundation=\(oa) ours=\(whole)\n  doc=\(String(decoding: doc, as: UTF8.self).debugDescription)")
        }
      }
      // Skip at a random depth: chunking invariance of the skip path, valid or not.
      do {
        let sd = 1 + g.int(4)
        let a = run(doc, ranges: [0..<doc.count], skipAt: sd)
        let b = run(doc, ranges: nil, skipAt: sd)
        let c = run(doc, ranges: randomRanges(doc.count, &g), skipAt: sd)
        if a != b || a != c {
          skipIssues += 1
          if skipIssues < 15 {
            print("SKIPINV it=\(it) sd=\(sd)\n  doc=\(String(decoding: doc, as: UTF8.self).debugDescription)\n  whole=\(a)\n  bytewise=\(b)\n  chunks=\(c)")
          }
        }
        if whole.accepted && !a.accepted {
          skipIssues += 1
          if skipIssues < 15 { print("SKIPREJ it=\(it) sd=\(sd)\n  doc=\(String(decoding: doc, as: UTF8.self).debugDescription)\n  whole=\(a)") }
        }
      }
      // Small buffer: when neither run exhausts, results must match.
      do {
        let a = run(doc, ranges: [0..<doc.count], cap: 64)
        let rs = randomRanges(doc.count, &g)
        let b = run(doc, ranges: rs, cap: 64)
        func exhausted(_ o: Outcome) -> Bool { if case .fail(let e, _) = o, e.reason == .bufferExhausted { return true }; return false }
        if !exhausted(a) && !exhausted(b) && (a != b || a != whole) {
          invariance += 1
          if invariance < 15 { print("CAP64 it=\(it)\n  doc=\(String(decoding: doc, as: UTF8.self).debugDescription)\n  whole=\(a)\n  chunks=\(b)\n  default=\(whole)") }
        }
      }
      // reset(): a parser used on a prefix, reset, must behave as fresh.
      do {
        var parser = JSONParser()
        var sink = LogSink()
        let cut = g.int(doc.count + 1)
        try? doc.withUnsafeBufferPointer { buf in try parser.parse(UnsafeBufferPointer(rebasing: buf[0..<cut]), into: &sink) }
        parser.reset()
        var sink2 = LogSink()
        var out: Outcome
        do {
          try doc.withUnsafeBufferPointer { buf in try parser.parse(buf, into: &sink2) }
          try parser.finish(into: &sink2)
          out = .ok(sink2.log)
        } catch let e as JSONParsingError { out = .fail(e, sink2.log) } catch { fatalError() }
        if out != whole {
          invariance += 1
          if invariance < 15 { print("RESET it=\(it) cut=\(cut)\n  doc=\(String(decoding: doc, as: UTF8.self).debugDescription)\n  fresh=\(whole)\n  reset=\(out)") }
        }
      }
      // Skip path: a sink skipping at depth 2 must agree on accept/reject for valid docs.
      if whole.accepted {
        let sk = run(doc, ranges: [0..<doc.count], skipAt: 2)
        let skb = run(doc, ranges: nil, skipAt: 2)
        if !sk.accepted || sk != skb {
          skipIssues += 1
          if skipIssues < 15 {
            print("SKIP it=\(it)\n  doc=\(String(decoding: doc, as: UTF8.self).debugDescription)\n  whole=\(sk)\n  bytewise=\(skb)")
          }
        }
      }
    }
    print("DONE invariance=\(invariance) oracle=\(oracle) skip=\(skipIssues)")
  }
}
