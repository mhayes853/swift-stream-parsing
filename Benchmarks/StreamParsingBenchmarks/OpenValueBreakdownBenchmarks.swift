import Benchmark
@_spi(Benchmarking) import StreamParsingCore

// TEMPORARY: where `_openValue` spends its time.
//
// `Keys prefixed span - build 128` says an insert costs ~180 ns and a resume ~200 ns, while the
// public subscript — which hashes and probes the same key — costs ~55 ns including materializing a
// `String` to do it. That gap is the pending slot machinery, and these rows size it rather than
// arguing about it: the same 128 keys through each piece, so the residual is what is left when the
// hash and the probe are subtracted from the whole.

private func keyBuffers(_ keys: [[UInt8]]) -> [UnsafeBufferPointer<UInt8>] {
  keys.map { key in
    let copy = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: key.count)
    _ = copy.initialize(fromContentsOf: key)
    return UnsafeBufferPointer(copy)
  }
}

@inline(__always)
private func withSpan<R>(_ key: UnsafeBufferPointer<UInt8>, _ body: (Span<UInt8>) -> R) -> R {
  body(Span(_unsafeElements: key))
}

func openValueBreakdownBenchmarks() {
  var configuration = Benchmark.defaultConfiguration
  configuration.maxDuration = .seconds(1)

  let keys = keyBuffers(Payloads.countKeys(128, prefix: Payloads.shortKeyPrefix))

  // A dictionary already holding the keys, for the probe and resume rows.
  var built = StreamDictionary<Int>()
  for (value, key) in keys.enumerated() {
    withSpan(key) { built._openValue(forKey: $0, initial: value).assumingMemoryBound(to: Int.self).pointee = value }
  }
  built._benchmarkDrain()
  let hashes = keys.map { key in withSpan(key) { StreamDictionary<Int>._benchmarkHash($0) } }
  let probeTarget = built

  Benchmark("OpenValue hash only 128", configuration: configuration) { b in
    for _ in b.scaledIterations {
      for key in keys {
        withSpan(key) { blackHole(StreamDictionary<Int>._benchmarkHash($0)) }
      }
    }
  }

  Benchmark("OpenValue probe only 128", configuration: configuration) { b in
    for _ in b.scaledIterations {
      for (index, key) in keys.enumerated() {
        withSpan(key) { blackHole(probeTarget._benchmarkSlot($0, hash: hashes[index])) }
      }
    }
  }

  Benchmark("OpenValue hash and probe 128", configuration: configuration) { b in
    for _ in b.scaledIterations {
      for key in keys {
        withSpan(key) { span in
          blackHole(probeTarget._benchmarkSlot(span, hash: StreamDictionary<Int>._benchmarkHash(span)))
        }
      }
    }
  }

  // The whole thing, insert and resume, for the residual.
  Benchmark("OpenValue full insert 128", configuration: configuration) { b in
    for _ in b.scaledIterations {
      var dictionary = StreamDictionary<Int>()
      for (value, key) in keys.enumerated() {
        withSpan(key) {
          dictionary._openValue(forKey: $0, initial: value)
            .assumingMemoryBound(to: Int.self).pointee = value
        }
      }
      blackHole(dictionary.count)
    }
  }

  Benchmark("OpenValue full resume 128", configuration: configuration) { b in
    for _ in b.scaledIterations {
      var dictionary = probeTarget
      for key in keys {
        withSpan(key) { blackHole(dictionary._openValue(forKey: $0, initial: 0)) }
      }
    }
  }

  // Drain alone: a dictionary with one entry open, committed once per call.
  Benchmark("OpenValue drain only 128", configuration: configuration) { b in
    for _ in b.scaledIterations {
      var dictionary = probeTarget
      for key in keys {
        withSpan(key) { blackHole(dictionary._openValue(forKey: $0, initial: 0)) }
        dictionary._benchmarkDrain()
      }
    }
  }
}
