import Benchmark
import Foundation
import StreamParsing

// Where the allocations went.
//
// The snapshot benchmarks drop each state before the next byte arrives, so nothing is ever shared
// at the moment of a write and copy on write never fires. That is what takes the per byte malloc
// count from one per snapshot to zero, and it means the cost is now decided by how long the
// application holds a state rather than by how often it takes one.
//
// These hold states instead: a rolling window, and every state at once.

@inline(never)
private func streamSnapshottingRetained<Value: StreamParseableRoot>(
  _ bytes: [UInt8],
  window: Int,
  as type: Value.Type
) throws -> Value {
  var stream = PartialsStream(initialValue: Value.streamInitialValue(), from: .json())
  var kept = [Value?](repeating: nil, count: max(window, 1))
  var taken = 0
  for byte in bytes {
    try stream.next(byte)
    kept[taken % window] = stream.current
    taken += 1
  }
  blackHole(kept.count)
  return try stream.finish()
}

@inline(never)
private func streamSnapshottingAll<Value: StreamParseableRoot>(
  _ bytes: [UInt8],
  as type: Value.Type
) throws -> Value {
  var stream = PartialsStream(initialValue: Value.streamInitialValue(), from: .json())
  var kept = [Value]()
  kept.reserveCapacity(bytes.count)
  for byte in bytes {
    try stream.next(byte)
    kept.append(stream.current)
  }
  blackHole(kept.count)
  return try stream.finish()
}

func retentionBenchmarks() {
  // The capacity-hinted mesh uses larger adaptive blocks. These paired rows make the tradeoff
  // visible: fewer allocations while parsing versus more elements copied when the retained
  // window shares the active tail at a commit boundary.
  Benchmark("Retention Mesh - window 16") { benchmark in
    for _ in benchmark.scaledIterations {
      blackHole(
        try streamSnapshottingRetained(
          Payloads.mesh, window: 16, as: BenchmarkMesh.Partial.self
        )
      )
    }
  }

  Benchmark("Retention Mesh capacity hint - window 16") { benchmark in
    for _ in benchmark.scaledIterations {
      blackHole(
        try streamSnapshottingRetained(
          Payloads.mesh, window: 16, as: BenchmarkMeshCapacityHint.Partial.self
        )
      )
    }
  }

  for window in [4, 16, 64] {
    Benchmark("Retention 100 users - window \(window)") { benchmark in
      for _ in benchmark.scaledIterations {
        blackHole(
          try streamSnapshottingRetained(
            Payloads.userList, window: window, as: BenchmarkUserList.Partial.self
          )
        )
      }
    }
  }

  Benchmark("Retention 100 users - keep all") { benchmark in
    for _ in benchmark.scaledIterations {
      blackHole(try streamSnapshottingAll(Payloads.userList, as: BenchmarkUserList.Partial.self))
    }
  }

  // A long string in one field, to separate the container's copies from the open element's own.
  Benchmark("Retention 8KB document - keep all") { benchmark in
    for _ in benchmark.scaledIterations {
      blackHole(try streamSnapshottingAll(Payloads.document, as: BenchmarkDocument.Partial.self))
    }
  }

  // The dictionary swept by key count. `storedKeys`, `storedValues` and the index are all flat, so
  // the retained rows are where the copy and rehash per divergence point shows up, and the
  // discarding rows are where the scan and the key materialisation do.
  for count in Payloads.keyCounts {
    let payload = Payloads.countsByKeyCount[count]!

    Benchmark("Dictionary \(count) keys - discarding") { benchmark in
      for _ in benchmark.scaledIterations {
        blackHole(try streamDictionaryDiscarding(payload))
      }
    }

    Benchmark("Dictionary \(count) keys - snapshot per byte") { benchmark in
      for _ in benchmark.scaledIterations {
        blackHole(try streamSnapshottingAll(payload, as: BenchmarkCounts.Partial.self))
      }
    }

    Benchmark("Dictionary \(count) keys - window 16") { benchmark in
      for _ in benchmark.scaledIterations {
        blackHole(
          try streamSnapshottingRetained(payload, window: 16, as: BenchmarkCounts.Partial.self)
        )
      }
    }
  }

  Benchmark("Dictionary 128 long keys - discarding") { benchmark in
    for _ in benchmark.scaledIterations {
      blackHole(try streamDictionaryDiscarding(Payloads.countsLongKeys))
    }
  }
}

@inline(never)
private func streamDictionaryDiscarding(_ bytes: [UInt8]) throws -> BenchmarkCounts.Partial {
  var stream = PartialsStream(initialValue: BenchmarkCounts.Partial(), from: .json())
  for byte in bytes {
    try stream.next(byte)
  }
  return try stream.finish()
}
