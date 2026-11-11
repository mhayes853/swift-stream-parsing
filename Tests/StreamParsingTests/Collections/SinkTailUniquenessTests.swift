import CustomDump
import Testing

import StreamParsing
import StreamParsingCore

@StreamParseable
struct TailUniquenessPoint: Equatable {
  var xs: [Double] = []
  var ids: [Int] = []
  var n: Int = 0
}

// The sink remembers, for the length of one parse call, a tail block it has already proven unique,
// and appends into it without asking the runtime again (`PartialSink.knownUniqueTail`). These hold
// that to what ordinary copy-on-write promises: whatever a caller copies between parse calls --
// a snapshot, a seed, a state it later resets the stream to -- is never written into.
@Suite
struct `Sink tail uniqueness tests` {
  // Cuts `json` at every offset, snapshots between the halves, finishes, then appends to the
  // snapshot. The snapshot must read as it did when taken, the parse must produce what an uncut
  // parse produces, and the snapshot's append must not reach the parsed value.
  private func expectSnapshotsIsolated<Value: StreamParseable>(
    _ json: String,
    as type: Value.Type,
    mutate: (inout Value.Partial) -> Void
  ) throws {
    let bytes = Array(json.utf8)
    var whole = PartialsStream<Value>(from: .json())
    try whole.next(bytes)
    let expected = String(describing: try whole.finishPartial())

    for cut in 1..<bytes.count {
      var stream = PartialsStream<Value>(from: .json())
      try stream.next(bytes[..<cut])
      var snapshot = stream.current
      let taken = String(describing: snapshot)
      try stream.next(bytes[cut...])
      let parsed = try stream.finishPartial()
      expectNoDifference(String(describing: snapshot), taken, "cut at \(cut): snapshot changed")
      expectNoDifference(String(describing: parsed), expected, "cut at \(cut): parse changed")
      mutate(&snapshot)
      expectNoDifference(
        String(describing: parsed), expected, "cut at \(cut): snapshot append reached the parse"
      )
    }
  }

  // Feeds `json` in `chunk`-byte pieces, keeping a snapshot after every piece, so every parse call
  // after the first starts on tails the previous snapshot shares.
  private func expectEveryChunkSnapshotStable<Value: StreamParseable>(
    _ json: String, as type: Value.Type, chunk: Int
  ) throws {
    let bytes = Array(json.utf8)
    var stream = PartialsStream<Value>(from: .json())
    var kept = [(rendering: String, value: Value.Partial)]()
    var start = 0
    while start < bytes.count {
      let end = min(start + chunk, bytes.count)
      try stream.next(bytes[start..<end])
      let snapshot = stream.current
      kept.append((String(describing: snapshot), snapshot))
      start = end
    }
    _ = try stream.finishPartial()
    for (index, state) in kept.enumerated() {
      expectNoDifference(String(describing: state.value), state.rendering, "chunk \(index)")
    }
  }

  @Test
  func `Snapshots of number arrays stay isolated at every cut`() throws {
    try self.expectSnapshotsIsolated("[1.5,2.5,3.5,4.5,5.5]", as: StreamArray<Double>.self) {
      $0.append(-1)
    }
    try self.expectSnapshotsIsolated("[1,2,3,4,5]", as: StreamArray<Int>.self) { $0.append(-1) }
  }

  @Test
  func `Snapshots of SIMD arrays stay isolated at every cut`() throws {
    try self.expectSnapshotsIsolated(
      "[[1,2],[3,4],[5,6]]", as: StreamArray<SIMD2<Double>>.self
    ) { $0.append(SIMD2(-1, -1)) }
  }

  @Test
  func `Snapshots of nested arrays stay isolated at every cut`() throws {
    try self.expectSnapshotsIsolated(
      "[[1.5,2.5,3.5],[4.5,5.5],[6.5]]", as: StreamArray<StreamArray<Double>>.self
    ) { snapshot in
      // Into the inner array the parse was filling, and into the outer one.
      if !snapshot.isEmpty { snapshot[snapshot.count - 1].append(-1) }
      snapshot.append([-2])
    }
  }

  @Test
  func `Snapshots of arrays of structs stay isolated at every cut`() throws {
    try self.expectSnapshotsIsolated(
      #"[{"xs":[1.5,2.5],"ids":[1,2],"n":1},{"xs":[3.5],"ids":[3,4,5],"n":2}]"#,
      as: [TailUniquenessPoint].self
    ) { snapshot in
      if !snapshot.isEmpty {
        snapshot[snapshot.count - 1].xs?.append(-1)
        snapshot[snapshot.count - 1].ids?.append(-1)
      }
    }
  }

  // Long enough to seal blocks (256 doubles to a block), in chunks that land inside and across
  // them.
  @Test(arguments: [1, 7, 64, 1000])
  func `A snapshot after every chunk stays stable`(chunk: Int) throws {
    let doubles = "[" + (0..<700).map { "\(Double($0) + 0.5)" }.joined(separator: ",") + "]"
    try self.expectEveryChunkSnapshotStable(doubles, as: StreamArray<Double>.self, chunk: chunk)
    let pairs = "[" + (0..<300).map { "[\($0),\($0 + 1)]" }.joined(separator: ",") + "]"
    try self.expectEveryChunkSnapshotStable(
      pairs, as: StreamArray<SIMD2<Double>>.self, chunk: chunk
    )
  }

  // The case a remembered tail could get wrong: the stream is reset to an *earlier* state, so the
  // live array is back on a shared tail with a smaller count than a later state still holding it.
  // Appending without the check would write over the later state's elements.
  @Test
  func `Resetting to an earlier state never writes into a later one`() throws {
    var stream = PartialsStream<StreamArray<Double>>(from: .json())
    try stream.next("[1.5,2.5,".utf8)
    let early = stream.current
    try stream.next("3.5,4.5,".utf8)
    let late = stream.current
    stream.reset(to: early)
    try stream.next("[9.5,8.5,7.5]".utf8)
    let parsed = try stream.finishPartial()
    expectNoDifference(Array(parsed), [1.5, 2.5, 9.5, 8.5, 7.5])
    expectNoDifference(Array(early), [1.5, 2.5])
    expectNoDifference(Array(late), [1.5, 2.5, 3.5, 4.5])

    var pairs = PartialsStream<StreamArray<SIMD2<Double>>>(from: .json())
    try pairs.next("[[1,2],".utf8)
    let earlyPairs = pairs.current
    try pairs.next("[3,4],".utf8)
    let latePairs = pairs.current
    pairs.reset(to: earlyPairs)
    try pairs.next("[[9,9]]".utf8)
    let parsedPairs = try pairs.finishPartial()
    expectNoDifference(Array(parsedPairs), [SIMD2(1, 2), SIMD2(9, 9)])
    expectNoDifference(Array(latePairs), [SIMD2(1, 2), SIMD2(3, 4)])
  }

  // A seed the caller still holds, with room left in its tail, is copied rather than appended into.
  @Test
  func `A seed with room in its tail is never written into`() throws {
    var seed = StreamArray<Int>(initialCapacity: 64)
    seed.append(contentsOf: [1, 2, 3])
    var stream = PartialsStream<StreamArray<Int>>(initialValue: seed, from: .json())
    try stream.next("[4,5]".utf8)
    let parsed = try stream.finishPartial()
    seed.append(7)
    expectNoDifference(Array(parsed), [1, 2, 3, 4, 5])
    expectNoDifference(Array(seed), [1, 2, 3, 7])
  }

  // `finishAndReset` reuses the sink: the next document must not inherit the last one's tail.
  @Test
  func `A reused stream does not append into the previous document`() throws {
    var stream = PartialsStream<StreamArray<Double>>(from: .json())
    try stream.next("[1.5,2.5]".utf8)
    let first = try stream.finishAndReset(to: stream.current)
    try stream.next("[3.5]".utf8)
    let second = try stream.finishPartial()
    expectNoDifference(Array(first), [1.5, 2.5])
    expectNoDifference(Array(second), [1.5, 2.5, 3.5])
  }

  // Driving the sink by hand, a copy taken between parse calls is all a caller can do; the parser
  // commits at the end of each call, which is where the remembered tail is forgotten.
  @Test
  func `A sink driven directly forgets its tail between parse calls`() throws {
    let json = Array("[1.5,2.5,3.5,4.5]".utf8)
    let storage = UnsafeMutablePointer<StreamArray<Double>>.allocate(capacity: 1)
    storage.initialize(to: [])
    defer {
      storage.deinitialize(count: 1)
      storage.deallocate()
    }
    var sink = PartialSink(root: storage)
    var parser = JSONParser()
    try json[..<9].withUnsafeBufferPointer { try parser.parse($0, into: &sink) }
    var copy = storage.pointee
    try json[9...].withUnsafeBufferPointer { try parser.parse($0, into: &sink) }
    try parser.finish(into: &sink)
    copy.append(-1)
    expectNoDifference(Array(storage.pointee), [1.5, 2.5, 3.5, 4.5])
    expectNoDifference(Array(copy), [1.5, 2.5, -1])
  }
}
