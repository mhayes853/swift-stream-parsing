import Benchmark
import StreamParsingCore

// What the index costs, on the shipped type only.
//
// This file used to carry six prototype tables — a materialising scan, a span scan, a leading
// word scan, a hash scan, a `Dictionary` index and a chained bucket index — measured against each
// other to choose an implementation. That choice shipped as `StreamDictionary`'s open addressed
// table, so the losers are archaeology and the tables they produced live in NEW_ARCHITECTURE.md.
// What remains measures the real type through both of its entry points.
//
// The span route is what the parser takes: `_openValue(forKey:)` matches the span against the
// stored keys directly and materialises a `String` only for a key it has not seen. The `String`
// route is what a consumer takes through the public subscript. The prototype file only ever
// measured the second, which is not the one on the hot path.
//
// Two key sets, because the cost depends entirely on the keys. `prefixed` keys share their first
// eight bytes, which is the worst case for any leading-word prefilter and the shape a counts
// style payload produces; `diverse` keys differ from the first byte, which is what an object's
// field names look like. Absent keys are generated in the same shape and length as present ones,
// so a miss is not rejected for free by a length check.

// MARK: - Storage

// Allocated once at registration and never freed, so no sample pays for the setup. The process
// exits when the run does.
private func keyPointers(_ keys: [[UInt8]]) -> [UnsafeBufferPointer<UInt8>] {
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

// MARK: - Routes

private func buildBySpan(_ keys: [UnsafeBufferPointer<UInt8>]) -> StreamDictionary<Int> {
  var dictionary = StreamDictionary<Int>()
  for (value, key) in keys.enumerated() {
    withSpan(key) { span in
      dictionary._openValue(forKey: span, initial: value).assumingMemoryBound(to: Int.self)
        .pointee = value
    }
  }
  return dictionary
}

private func buildByString(_ keys: [UnsafeBufferPointer<UInt8>]) -> StreamDictionary<Int> {
  var dictionary = StreamDictionary<Int>()
  for (value, key) in keys.enumerated() {
    dictionary.updateValue(value, forKey: String(decoding: key, as: UTF8.self))
  }
  return dictionary
}

// MARK: - Benchmarks

private enum KeyShape: CaseIterable {
  case prefixed
  case diverse

  var label: String {
    switch self {
    case .prefixed: "prefixed"
    case .diverse: "diverse"
    }
  }

  func keys(_ count: Int) -> [[UInt8]] {
    switch self {
    case .prefixed: Payloads.countKeys(count, prefix: Payloads.shortKeyPrefix)
    case .diverse: Payloads.diverseKeys(count, from: 0)
    }
  }

  func absentKeys(_ count: Int) -> [[UInt8]] {
    switch self {
    case .prefixed: Payloads.countKeys(count, prefix: Payloads.shortKeyPrefix, from: count)
    case .diverse: Payloads.diverseKeys(count, from: count)
    }
  }
}

func keyLookupBenchmarks() {
  var configuration = Benchmark.defaultConfiguration
  configuration.maxDuration = .seconds(1)

  // The span route has no non-inserting probe: `_openValue` opens a slot for a key it has not
  // seen, so a "miss" on this route is an insert and `build` already measures it. The two rows
  // here are the two things it actually does — fill a table, and resume a key already in it.
  for shape in KeyShape.allCases {
    for count in Payloads.keyCounts {
      let present = keyPointers(shape.keys(count))
      var built = buildBySpan(present)

      Benchmark("Keys \(shape.label) span - build \(count)", configuration: configuration) { b in
        for _ in b.scaledIterations { blackHole(buildBySpan(present)) }
      }

      // A repeated key resumes the value already stored under it, which is the path a duplicate
      // key in a document takes and the one that must not materialise a `String`.
      Benchmark("Keys \(shape.label) span - hit \(count)", configuration: configuration) { b in
        for _ in b.scaledIterations {
          for key in present {
            withSpan(key) { blackHole(built._openValue(forKey: $0, initial: 0)) }
          }
        }
      }
    }
  }

  // The public subscript, which a consumer reads a parsed dictionary through. Swept on diverse
  // keys only: the span rows above already carry the prefix-collision axis, and this route pays
  // for a `String` on every lookup regardless of key shape.
  for count in Payloads.keyCounts {
    let present = keyPointers(KeyShape.diverse.keys(count))
    let absent = keyPointers(KeyShape.diverse.absentKeys(count))
    let built = buildByString(present)

    Benchmark("Keys diverse String - build \(count)", configuration: configuration) { b in
      for _ in b.scaledIterations { blackHole(buildByString(present)) }
    }

    Benchmark("Keys diverse String - hit \(count)", configuration: configuration) { b in
      for _ in b.scaledIterations {
        for key in present { blackHole(built[String(decoding: key, as: UTF8.self)]) }
      }
    }

    Benchmark("Keys diverse String - miss \(count)", configuration: configuration) { b in
      for _ in b.scaledIterations {
        for key in absent { blackHole(built[String(decoding: key, as: UTF8.self)]) }
      }
    }
  }

  // Past fifteen bytes a key is heap allocated, which the span route pays only on a new key and
  // the `String` route pays on every lookup.
  let longKeys = keyPointers(Payloads.countKeys(128, prefix: Payloads.longKeyPrefix))
  var longBuilt = buildBySpan(longKeys)

  Benchmark("Keys long span - build 128", configuration: configuration) { b in
    for _ in b.scaledIterations { blackHole(buildBySpan(longKeys)) }
  }

  Benchmark("Keys long span - hit 128", configuration: configuration) { b in
    for _ in b.scaledIterations {
      for key in longKeys {
        withSpan(key) { blackHole(longBuilt._openValue(forKey: $0, initial: 0)) }
      }
    }
  }

  let longStringBuilt = buildByString(longKeys)

  Benchmark("Keys long String - hit 128", configuration: configuration) { b in
    for _ in b.scaledIterations {
      for key in longKeys { blackHole(longStringBuilt[String(decoding: key, as: UTF8.self)]) }
    }
  }
}
