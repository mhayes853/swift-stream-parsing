import Benchmark
import StreamParsingCore

// What a schema call costs, by representation.
//
// `StreamSchema` is a class holding escaping closures, so a token's route to its destination is:
// load the closure out of the class, retain its context, call through the function pointer,
// release. The disassembly of `PartialSink.key` shows exactly that and nothing else — one retain
// and one release per schema call, around one indirect call — and `Layer Twitter bulk` counts
// 22,000 retains against 13,345 keys and ~9,700 scalar values, which is one per call.
//
// Every entry point carries a real context, verified rather than assumed: the macro's are static
// funcs and the scalar factories capture only a generic parameter, yet all eight probe non-nil,
// so the ARC lands on a live object rather than a null fast path.
//
// The three rows are the representations available, doing identical work on identical arguments:
//
//   thick closure   today: `@Sendable` closure property on a final class
//   thin pointer    `@convention(thin)` function pointer plus a raw context word, so a call is a
//                   load and a branch with no ARC, and the pair copies for free
//   direct          the same matcher called statically: the floor a fully specialized sink would
//                   reach, and what the indirect call itself costs against it
//
// Measured, p0, per call: direct 3.2 ns, thin 4.6 ns, thick 17.0 ns, bitcast pair 29 ns. The
// indirect call is nearly free — 1.4 ns over a static one — and the ARC around it is 12.4 ns, so a
// schema call is mostly its own refcounting.
//
// The thin row is `@convention(c)` rather than `@convention(thin)`. Thin is what a redesign would
// want, because it accepts any Swift type where `c` accepts only C representable ones, and it is
// unavailable: a thin function *reference* is "INTERNAL ERROR: feature not implemented: nontrivial
// thin function reference" under `-swift-version 6`, which this package uses, and compiles under
// `-swift-version 5`. Isolated to the language mode, not to the parameter types — it fails on all
// trivial ones too. So `c` is the representation available, and it costs the marshalling: spans
// become a base and a count and are rebuilt inside the callee, which is what these rows pass.
//
// The bitcast pair row is the way around that: take a thick closure apart into its two words, store
// them trivially, and rebuild the function value at the call site. It does not work. The optimizer
// retains what it rebuilt, twice per call, and the row is 70% slower than the closure it was meant
// to replace — so the pair is recorded here as measured and rejected rather than tried again.
//
// All four take `(UnsafeRawPointer, Int)`, which is the two registers a `Span<UInt8>` already is,
// so the only difference between the rows is the dispatch.
//
// Nothing here is the parse. It is the routing overhead per token, which is what a schema redesign
// would be buying, measured before committing to one.

// MARK: - The matcher

// The shape the macro emits: a switch over the key's padded leading word.
@inline(__always)
private func matchProbeField(_ base: UnsafeRawPointer, _ count: Int) -> Int32 {
  let key = Span(_unsafeElements: UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: count))
  switch key.paddedLeadingWord() {
  case 0x0000_0000_0064_69: return 0
  case 0x0000_0000_656D_616E: return 1
  case 0x0000_006C_6961_6D65: return 2
  case 0x0000_0000_6567_61: return 3
  default: return -1
  }
}

private func matchProbeFieldThick(_ base: UnsafeRawPointer, _ count: Int) -> Int32 {
  matchProbeField(base, count)
}

private func matchProbeFieldThin(
  _ context: UnsafeRawPointer?, _ base: UnsafeRawPointer, _ count: Int
) -> Int32 {
  matchProbeField(base, count)
}

// MARK: - The representations

private final class ThickSchema: @unchecked Sendable {
  let matchField: @Sendable (UnsafeRawPointer, Int) -> Int32

  init(matchField: @escaping @Sendable (UnsafeRawPointer, Int) -> Int32) {
    self.matchField = matchField
  }
}

private final class ThinSchema: @unchecked Sendable {
  let matchField: @convention(c) (UnsafeRawPointer?, UnsafeRawPointer, Int) -> Int32
  let context: UnsafeRawPointer?

  init(
    matchField: @convention(c) (UnsafeRawPointer?, UnsafeRawPointer, Int) -> Int32,
    context: UnsafeRawPointer?
  ) {
    self.matchField = matchField
    self.context = context
  }
}

// A thick closure taken apart into its two words and stored trivially, which is the representation
// available under Swift 6 mode: `@convention(thin)` crashes the compiler there and `@convention(c)`
// cannot carry a `Span`. Loading a pair of raw pointers is ARC free by construction, and the
// closure itself is kept alive in `retained` so the context word stays valid. Calling it means
// rebuilding the function value with `unsafeBitCast`, which is the part worth measuring: whether
// the optimizer still insists on retaining what it rebuilt.
private final class PairSchema: @unchecked Sendable {
  let pair: (UnsafeRawPointer, UnsafeRawPointer?)
  let retained: Any

  init(matchField: @escaping @Sendable (UnsafeRawPointer, Int) -> Int32) {
    self.retained = matchField
    self.pair = unsafeBitCast(matchField, to: (UnsafeRawPointer, UnsafeRawPointer?).self)
  }

  @inline(__always)
  func callMatchField(_ base: UnsafeRawPointer, _ count: Int) -> Int32 {
    unsafeBitCast(self.pair, to: (@Sendable (UnsafeRawPointer, Int) -> Int32).self)(base, count)
  }
}

// Opaque to the optimizer, so a call through one is a real indirect call rather than a
// devirtualized one: a global `var` cannot be folded the way a `let` holding a known closure can.
private nonisolated(unsafe) var thick = ThickSchema(matchField: matchProbeFieldThick)
private nonisolated(unsafe) var thin = ThinSchema(matchField: matchProbeFieldThin, context: nil)
private nonisolated(unsafe) var pair = PairSchema(matchField: matchProbeFieldThick)

// MARK: - Registration

func schemaDispatchBenchmarks() {
  // The key mix a document actually presents: some hit, some miss, all short.
  // 1,000 calls per iteration, because the wall clock quantizes to ~42 ns and six calls do not
  // clear one tick.
  let repeats = 167
  let keys = ["id", "name", "email", "age", "created_at", "screen_name"].map { Array($0.utf8) }
  let storage = keys.map { key -> (UnsafeMutableRawPointer, Int) in
    let buffer = UnsafeMutableRawPointer.allocate(
      byteCount: key.count + 16, alignment: 16
    )
    key.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress!, byteCount: key.count) }
    return (buffer, key.count)
  }

  Benchmark("Dispatch thick closure - 1002 calls") { benchmark in
    for _ in benchmark.scaledIterations {
      for _ in 0..<repeats {
        for (base, count) in storage {
          blackHole(thick.matchField(UnsafeRawPointer(base), count))
        }
      }
    }
  }

  Benchmark("Dispatch thin pointer - 1002 calls") { benchmark in
    for _ in benchmark.scaledIterations {
      for _ in 0..<repeats {
        for (base, count) in storage {
          blackHole(thin.matchField(thin.context, UnsafeRawPointer(base), count))
        }
      }
    }
  }

  Benchmark("Dispatch bitcast pair - 1002 calls") { benchmark in
    for _ in benchmark.scaledIterations {
      for _ in 0..<repeats {
        for (base, count) in storage {
          blackHole(pair.callMatchField(UnsafeRawPointer(base), count))
        }
      }
    }
  }

  Benchmark("Dispatch direct - 1002 calls") { benchmark in
    for _ in benchmark.scaledIterations {
      for _ in 0..<repeats {
        for (base, count) in storage {
          blackHole(matchProbeField(UnsafeRawPointer(base), count))
        }
      }
    }
  }
}
