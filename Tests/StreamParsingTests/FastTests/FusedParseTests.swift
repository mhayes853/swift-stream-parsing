import CustomDump
import Testing

import StreamParsing
@_spi(Benchmarks) import StreamParsingCore

// The fused slice (FusedParseExperiment.swift) against the recorded path, on the same documents:
// same values written, same failures, same offsets. The slice only exists to price the
// record/replay seam, but a priced loop that routes differently prices nothing, so these hold
// the two paths to each other on every route the slice touches -- the fused ones (table members,
// double runs) and the delegated ones (strings, literals, dictionaries, ignored subtrees).

@StreamParseable
private struct FusedRow: Equatable {
  var count: Int = 0
  var ratio: Double = 0
  var label: String = ""
  var live: Bool = false
  var maybe: Int? = nil
  var nested: FusedLeaf = FusedLeaf()
}

@StreamParseable
private struct FusedLeaf: Equatable {
  var n: Int = 0
}

@StreamParseable
private struct FusedRows: Equatable {
  var rows: [FusedRow] = []
}

@StreamParseable
private struct FusedDoubles: Equatable {
  var values: [Double] = []
}

@StreamParseable
private struct FusedCounts: Equatable {
  var counts: [String: Int] = [:]
}

@Suite
struct FusedParseTests {
  private func parseFused<Root: StreamParseableRoot>(
    _ json: String, into value: inout Root
  ) throws {
    try withUnsafeMutablePointer(to: &value) { pointer in
      var parser = JSONParser()
      var sink = makeFusedSliceSink(
        root: UnsafeMutableRawPointer(pointer), schema: Root.streamSchema
      )
      let bytes = Array(json.utf8)
      try bytes.withUnsafeBufferPointer { input in
        try parser.parseFusedDocument(input, into: &sink)
      }
    }
  }

  // The two paths on the same document, with any thrown error compared as part of the result.
  private func differential<Root: StreamParseableRoot>(
    _ json: String, as type: Root.Type, check: (Root, Root) -> Void
  ) throws {
    var recorded = Root.streamInitialValue()
    var recordedError: JSONParsingError?
    do {
      try parsePartial(json, into: &recorded)
    } catch let error as JSONParsingError {
      recordedError = error
    }
    var fused = Root.streamInitialValue()
    var fusedError: JSONParsingError?
    do {
      try self.parseFused(json, into: &fused)
    } catch let error as JSONParsingError {
      fusedError = error
    }
    expectNoDifference(fusedError, recordedError)
    check(fused, recorded)
  }

  @Test
  func `Table members and misses match the recorded path`() throws {
    let json = #"""
      {"rows":[
        {"count":42,"ratio":-0.5,"label":"a","live":true,"maybe":7,"nested":{"n":1}},
        {"count":9007199254740993,"ratio":1.5e3,"label":"","live":false,"maybe":null,
         "unknown":123,"skipped":{"deep":{"er":[1,2,3]}},"nested":{"n":2}}
      ]}
      """#
    try self.differential(json, as: FusedRows.Partial.self) { fused, recorded in
      expectNoDifference(fused.rows?.count, recorded.rows?.count)
      for index in 0..<(fused.rows?.count ?? 0) {
        expectNoDifference(fused.rows?[index].count, recorded.rows?[index].count)
        expectNoDifference(fused.rows?[index].ratio, recorded.rows?[index].ratio)
        expectNoDifference(fused.rows?[index].label, recorded.rows?[index].label)
        expectNoDifference(fused.rows?[index].live, recorded.rows?[index].live)
        expectNoDifference(fused.rows?[index].maybe, recorded.rows?[index].maybe)
        expectNoDifference(fused.rows?[index].nested?.n, recorded.rows?[index].nested?.n)
      }
    }
  }

  @Test
  func `A double run matches the recorded path value for value`() throws {
    let doubles = (0..<300).map { index -> String in
      let sign = index % 3 == 0 ? "-" : ""
      return "\(sign)\(40 + index % 60).\(1_000_000_000_000 + (index * 7_919) % 999_999_999_999)"
    }
    let json = #"{"values":[\#(doubles.joined(separator: ","))]}"#
    try self.differential(json, as: FusedDoubles.Partial.self) { fused, recorded in
      expectNoDifference(fused.values?.count, recorded.values?.count)
      expectNoDifference(fused.values.map(Array.init), recorded.values.map(Array.init))
    }
  }

  @Test
  func `Whitespace, exponents and single elements survive the run's comma fusion`() throws {
    let json = "{\"values\": [ 1.5 ,\n2e-3 ,-0.25, 1e10 ]}"
    try self.differential(json, as: FusedDoubles.Partial.self) { fused, recorded in
      expectNoDifference(fused.values.map(Array.init), recorded.values.map(Array.init))
    }
    try self.differential(#"{"values":[7.25]}"#, as: FusedDoubles.Partial.self) {
      fused, recorded in
      expectNoDifference(fused.values.map(Array.init), recorded.values.map(Array.init))
    }
    try self.differential(#"{"values":[]}"#, as: FusedDoubles.Partial.self) { fused, recorded in
      expectNoDifference(fused.values.map(Array.init), recorded.values.map(Array.init))
    }
  }

  @Test
  func `The delegated dictionary route matches the recorded path`() throws {
    let json = #"{"counts":{"a":1,"b":2,"c":3}}"#
    try self.differential(json, as: FusedCounts.Partial.self) { fused, recorded in
      expectNoDifference(fused.counts?["a"], recorded.counts?["a"])
      expectNoDifference(fused.counts?["b"], recorded.counts?["b"])
      expectNoDifference(fused.counts?["c"], recorded.counts?["c"])
      expectNoDifference(fused.counts?.count, recorded.counts?.count)
    }
  }

  @Test
  func `Failures surface as the recorded path's error, at its offset`() throws {
    // A string where a table member wants an int; a container where a scalar member is; a string
    // in a run of doubles; a number in place of the dictionary's container.
    for json in [
      #"{"rows":[{"count":"x"}]}"#,
      #"{"rows":[{"count":{"deep":1}}]}"#,
      #"{"values":[1.5,"x",2.5]}"#,
      #"{"counts":7}"#,
    ] {
      try self.differential(json, as: FusedRows.Partial.self) { _, _ in }
    }
    try self.differential(
      #"{"values":[1.5,"x",2.5]}"#, as: FusedDoubles.Partial.self
    ) { fused, recorded in
      expectNoDifference(fused.values.map(Array.init), recorded.values.map(Array.init))
    }
    try self.differential(#"{"counts":7}"#, as: FusedCounts.Partial.self) { _, _ in }
  }

  @Test
  func `Grammar errors match the recorded path`() throws {
    for json in [
      #"{"rows":[1,]}"#,
      #"{"rows" 1}"#,
      #"{"rows":truth}"#,
      #"{"rows":[01]}"#,
      #"{"rows":[1.]}"#,
      #"{"rows":[1e]}"#,
      #"{"rows":[]}extra"#,
      #"{"rows":[]"#,
      #"["#,
    ] {
      try self.differential(json, as: FusedRows.Partial.self) { _, _ in }
    }
  }

  @Test
  func `Non-ASCII keys and values validate and route`() throws {
    let json = #"{"rows":[{"label":"héllo ✓","cœur":1,"count":5}]}"#
    try self.differential(json, as: FusedRows.Partial.self) { fused, recorded in
      expectNoDifference(fused.rows?[0].label, recorded.rows?[0].label)
      expectNoDifference(fused.rows?[0].count, recorded.rows?[0].count)
    }
    // An invalid sequence inside a key is the same error either way.
    let bad = Array(#"{"rows":[{""#.utf8) + [0xC3, 0x28] + Array(#"":1}]}"#.utf8)
    var recorded = FusedRows.Partial.streamInitialValue()
    var recordedError: JSONParsingError?
    do {
      var parser = JSONParser()
      try withUnsafeMutablePointer(to: &recorded) { pointer in
        var sink = PartialSink(root: pointer)
        try bad.withUnsafeBufferPointer { try parser.parse($0, into: &sink) }
      }
    } catch let error as JSONParsingError {
      recordedError = error
    }
    var fused = FusedRows.Partial.streamInitialValue()
    var fusedError: JSONParsingError?
    do {
      var parser = JSONParser()
      try withUnsafeMutablePointer(to: &fused) { pointer in
        var sink = makeFusedSliceSink(
          root: UnsafeMutableRawPointer(pointer), schema: FusedRows.Partial.streamSchema
        )
        try bad.withUnsafeBufferPointer { try parser.parseFusedDocument($0, into: &sink) }
      }
    } catch let error as JSONParsingError {
      fusedError = error
    }
    expectNoDifference(fusedError?.reason, recordedError?.reason)
  }
}
