import Benchmark
import Foundation
import StageOneLab

// Number kernel lab: the raw parser's number path costs ~24 cycles per 18-digit Canada number,
// and the question is whether that is latency (a chain explicit interleaving could overlap) or
// instructions (validation done per block and again in the grammar walk). Three kernels over
// the real number extents of four corpora, each extent parsed from a known end:
//
//   current port   the shipping algorithm's shape: short-integer fast path, then per-block
//                  validated SWAR accumulation with the grammar walk around it
//   single pass    one vector classification decides the shape, then unvalidated accumulation;
//                  anything but a simple decimal falls back to the port
//   paired         two extents classified before either is parsed
//
// Registration verifies the single-pass kernel against the port on every extent it accepts and
// prints how many it declines per corpus — the non-uniformity number.

private struct LabNumber: Equatable {
  var magnitude: UInt64
  var exponent: Int32
  var digitCount: UInt32
  var flags: UInt32
}

@inline(__always)
private func load64(_ p: UnsafePointer<UInt8>) -> UInt64 {
  UnsafeRawPointer(p).loadUnaligned(as: UInt64.self)
}

@inline(__always)
private func swar8(_ w: UInt64) -> UInt64 {
  var w = w &- 0x3030_3030_3030_3030
  w = (w &* 10) &+ (w >> 8)
  w = (((w & 0x0000_00FF_0000_00FF) &* (100 &+ (1_000_000 << 32)))
       &+ (((w >> 16) & 0x0000_00FF_0000_00FF) &* (1 &+ (10_000 << 32)))) >> 32
  return w
}

@inline(__always)
private func isEightDigits(_ w: UInt64) -> Bool {
  let x = w &- 0x3030_3030_3030_3030
  return (x & 0xF0F0_F0F0_F0F0_F0F0) == 0
    && ((x &+ 0x0606_0606_0606_0606) & 0xF0F0_F0F0_F0F0_F0F0) == 0
}

// The shipping number path, restated (JSONParser.emitNumber + streamAccumulateDigits +
// streamShortInteger's shape), returning nil where the parser would throw.
private func portCurrent(_ p: UnsafePointer<UInt8>, _ from: Int, _ to: Int) -> LabNumber? {
  // Short unsigned integer: one to eight digits, no leading zero (unless alone).
  if to &- from <= 8, to >= 8, p[from] != 0x30 || to &- from == 1 {
    // The token occupies the high `count` bytes of the window ending at `to`.
    let count = to &- from
    let w = load64(p + (to &- 8))
    let x = w &- 0x3030_3030_3030_3030
    let shifted = x >> UInt64((8 &- count) &* 8)
    if (shifted & 0xF0F0_F0F0_F0F0_F0F0) == 0
      && ((shifted &+ 0x0606_0606_0606_0606) & 0xF0F0_F0F0_F0F0_F0F0) == 0
    {
      let keep = UInt64.max << UInt64((8 &- count) &* 8)
      let padded = (w & keep) | (0x3030_3030_3030_3030 >> UInt64(count &* 8))
      return LabNumber(magnitude: swar8(padded), exponent: 0, digitCount: UInt32(count), flags: 0)
    }
  }
  var flags: UInt32 = 0
  var i = from
  if i < to, p[i] == 0x2D { flags |= 1; i &+= 1 }
  var magnitude: UInt64 = 0
  func accumulate(_ i: inout Int) {
    while i &+ 8 <= to {
      let w = load64(p + i)
      guard isEightDigits(w) else { break }
      magnitude = magnitude &* 100_000_000 &+ swar8(w)
      i &+= 8
    }
    while i < to {
      let d = p[i] &- 0x30
      guard d < 10 else { break }
      magnitude = magnitude &* 10 &+ UInt64(d)
      i &+= 1
    }
  }
  let intStart = i
  accumulate(&i)
  let intDigits = i &- intStart
  guard intDigits > 0 else { return nil }
  if intDigits > 1, p[intStart] == 0x30 { return nil }
  var fracDigits = 0
  if i < to, p[i] == 0x2E {
    flags |= 2
    i &+= 1
    let s = i
    accumulate(&i)
    fracDigits = i &- s
    if fracDigits == 0 { return nil }
  }
  var exp: Int32 = 0
  var expNeg = false
  if i < to, (p[i] | 0x20) == 0x65 {
    flags |= 4
    i &+= 1
    if i < to {
      if p[i] == 0x2D { expNeg = true; i &+= 1 } else if p[i] == 0x2B { i &+= 1 }
    }
    let s = i
    while i < to {
      let d = p[i] &- 0x30
      guard d < 10 else { break }
      if exp < 10_000 { exp = exp &* 10 &+ Int32(d) }
      i &+= 1
    }
    if i == s { return nil }
  }
  if i != to { return nil }
  let total = intDigits &+ fracDigits
  if total > 19 { flags |= 8 }
  return LabNumber(
    magnitude: magnitude, exponent: (expNeg ? -exp : exp) &- Int32(fracDigits),
    digitCount: UInt32(total), flags: flags
  )
}

// MARK: - Corpus extents

private final class NumberCorpus: @unchecked Sendable {
  let name: String
  let bytes: UnsafeMutablePointer<UInt8>   // padded copy: 64 readable bytes past the end
  let extents: [UInt32]                     // offset, length pairs
  let numberBytes: [UInt8]                  // a dummy payload of the summed extent length
  var declined = 0

  init(name: String, payload: [UInt8]) {
    self.name = name
    let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: payload.count + 64)
    bytes.initialize(repeating: 0x20, count: payload.count + 64)
    payload.withUnsafeBufferPointer { bytes.update(from: $0.baseAddress!, count: $0.count) }
    self.bytes = bytes
    var extents: [UInt32] = []
    var inString = false
    var escaped = false
    var i = 0
    var total = 0
    while i < payload.count {
      let b = payload[i]
      if inString {
        if escaped { escaped = false } else if b == 0x5C { escaped = true } else if b == 0x22 { inString = false }
        i += 1
      } else if b == 0x22 {
        inString = true
        i += 1
      } else if b == 0x2D || (b >= 0x30 && b <= 0x39) {
        var j = i
        while j < payload.count {
          let c = payload[j]
          let isNumber = (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x2B || c == 0x2E || c == 0x65 || c == 0x45
          if !isNumber { break }
          j += 1
        }
        extents.append(UInt32(i))
        extents.append(UInt32(j - i))
        total += j - i
        i = j
      } else {
        i += 1
      }
    }
    self.extents = extents
    self.numberBytes = [UInt8](repeating: 0, count: total)
  }

  var count: Int { self.extents.count / 2 }
}

// MARK: - Registration

func numberKernelBenchmarks() {
  let corpora = [
    NumberCorpus(name: "Canada", payload: Payloads.canada),
    NumberCorpus(name: "Mesh", payload: Payloads.mesh),
    NumberCorpus(name: "CITM catalog", payload: Payloads.citmCatalog),
    NumberCorpus(name: "Twitter", payload: Payloads.twitter),
  ]

  // Verification and the decline census, written to a file: the plugin swallows stdout.
  var report = ""
  for corpus in corpora {
    var declined = 0
    var mismatches = 0
    var lengths = [Int: Int]()
    for n in 0..<corpus.count {
      let offset = Int(corpus.extents[2 * n])
      let length = Int(corpus.extents[2 * n + 1])
      lengths[length, default: 0] += 1
      var lab = sp_lab_number()
      let handled = sp_lab_decimal(corpus.bytes + offset, length, &lab) != 0
      let expected = portCurrent(UnsafePointer(corpus.bytes), offset, offset + length)
      if handled {
        let got = LabNumber(
          magnitude: lab.magnitude, exponent: lab.exponent, digitCount: lab.digit_count,
          flags: lab.flags
        )
        if got != expected {
          mismatches += 1
          if mismatches <= 5 {
            let text = String(decoding: UnsafeBufferPointer(start: corpus.bytes + offset, count: length), as: UTF8.self)
            report += "  mismatch '\(text)': kernel \(got) port \(String(describing: expected))\n"
          }
        }
      } else {
        declined += 1
      }
    }
    corpus.declined = declined
    let p50 = lengths.sorted { $0.key < $1.key }.reduce(into: (0, 0)) { acc, kv in
      if acc.0 < corpus.count / 2 { acc.0 += kv.value; acc.1 = kv.key }
    }.1
    report += "\(corpus.name): \(corpus.count) numbers, length p50 \(p50), single pass declined \(declined) (\(declined * 100 / max(corpus.count, 1))%), mismatches \(mismatches)\n"
  }
  try? report.write(toFile: "/tmp/numkernel_report.txt", atomically: true, encoding: .utf8)

  for corpus in corpora {
    Benchmark("Number kernel \(corpus.name) - current port", configuration: payloadConfiguration) { benchmark in
      measurePayloadThroughput(benchmark, payload: corpus.numberBytes) {
        var sum: UInt64 = 0
        let p = UnsafePointer(corpus.bytes)
        var n = 0
        while n < corpus.extents.count {
          let offset = Int(corpus.extents[n]), length = Int(corpus.extents[n + 1])
          if let v = portCurrent(p, offset, offset + length) { sum &+= v.magnitude }
          n += 2
        }
        blackHole(sum)
      }
    }

    Benchmark("Number kernel \(corpus.name) - single pass", configuration: payloadConfiguration) { benchmark in
      measurePayloadThroughput(benchmark, payload: corpus.numberBytes) {
        var sum: UInt64 = 0
        let p = UnsafePointer(corpus.bytes)
        var n = 0
        var lab = sp_lab_number()
        while n < corpus.extents.count {
          let offset = Int(corpus.extents[n]), length = Int(corpus.extents[n + 1])
          if sp_lab_decimal(p + offset, length, &lab) != 0 {
            sum &+= lab.magnitude
          } else if let v = portCurrent(p, offset, offset + length) {
            sum &+= v.magnitude
          }
          n += 2
        }
        blackHole(sum)
      }
    }

    // Length-dispatched: the existing short-integer kernel for up to eight bytes, one-vector
    // classification for nine to sixteen, two-vector above. One compare on the known extent.
    Benchmark("Number kernel \(corpus.name) - hybrid", configuration: payloadConfiguration) { benchmark in
      measurePayloadThroughput(benchmark, payload: corpus.numberBytes) {
        var sum: UInt64 = 0
        let p = UnsafePointer(corpus.bytes)
        var n = 0
        var lab = sp_lab_number()
        while n < corpus.extents.count {
          let offset = Int(corpus.extents[n]), length = Int(corpus.extents[n + 1])
          if length <= 8 {
            if let v = portCurrent(p, offset, offset + length) { sum &+= v.magnitude }
          } else if length <= 16 {
            if sp_lab_decimal16(p + offset, length, &lab) != 0 {
              sum &+= lab.magnitude
            } else if let v = portCurrent(p, offset, offset + length) {
              sum &+= v.magnitude
            }
          } else if sp_lab_decimal(p + offset, length, &lab) != 0 {
            sum &+= lab.magnitude
          } else if let v = portCurrent(p, offset, offset + length) {
            sum &+= v.magnitude
          }
          n += 2
        }
        blackHole(sum)
      }
    }

    Benchmark("Number kernel \(corpus.name) - paired", configuration: payloadConfiguration) { benchmark in
      measurePayloadThroughput(benchmark, payload: corpus.numberBytes) {
        var sum: UInt64 = 0
        let p = UnsafePointer(corpus.bytes)
        var n = 0
        var a = sp_lab_number(), b = sp_lab_number()
        while n + 3 < corpus.extents.count {
          let o0 = Int(corpus.extents[n]), l0 = Int(corpus.extents[n + 1])
          let o1 = Int(corpus.extents[n + 2]), l1 = Int(corpus.extents[n + 3])
          if sp_lab_decimal_pair(p + o0, l0, p + o1, l1, &a, &b) != 0 {
            sum &+= a.magnitude &+ b.magnitude
          } else {
            if let v = portCurrent(p, o0, o0 + l0) { sum &+= v.magnitude }
            if let v = portCurrent(p, o1, o1 + l1) { sum &+= v.magnitude }
          }
          n += 4
        }
        blackHole(sum)
      }
    }
  }
}
