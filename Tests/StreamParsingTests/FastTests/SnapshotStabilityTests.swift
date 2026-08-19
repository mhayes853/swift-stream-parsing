import CustomDump
import Testing

import StreamParsing
import StreamParsingCore

@StreamParseable
struct StabilityItem: Equatable {
  var id: Int = 0
  var tags: [String] = []
}

@StreamParseable
struct StabilityModel: Equatable {
  var items: [StabilityItem] = []
  var counts: [String: Int] = [:]
  var groups: [String: [Int]] = [:]
}

// A state handed out while parsing continues must not change afterwards.
//
// This is the bug `partials()` had: the sink wrote container elements through a raw pointer, which
// never triggers copy on write, so every state emitted shared the buffer being written into and a
// captured `[String]` read `[""]` and then `["a"]` two bytes later. The differential that was meant
// to catch it compared final values rather than sequences, which is exactly what it cannot catch.
//
// So these compare each state against a rendering of itself taken at the moment it was handed out.
// A state that follows the parse fails on the byte after the one that produced it, whatever the
// shape of the value.
@Suite
struct `Snapshot stability tests` {
  // Feeds one byte at a time, keeping every state along with what it looked like when taken.
  private func expectStable<Value: StreamParseableRoot>(
    _ json: String,
    as type: Value.Type
  ) throws {
    var stream = PartialsStream(initialValue: Value.streamInitialValue(), from: .json())
    var kept = [(rendering: String, value: Value)]()
    for byte in Array(json.utf8) {
      try stream.next(byte)
      let snapshot = stream.current
      kept.append((String(describing: snapshot), snapshot))
    }
    try stream.finish()

    for (offset, state) in kept.enumerated() {
      expectNoDifference(String(describing: state.value), state.rendering,
        """
        the state taken after byte \(offset) changed after the fact
        was:   \(state.rendering)
        is now: \(String(describing: state.value))
        """)
    }
  }

  // MARK: - Arrays

  @Test
  func `Array states stay stable`() throws {
    try self.expectStable("[1,2,3]", as: StreamArray<Int>.self)
    try self.expectStable(#"["ab","cd"]"#, as: StreamArray<String>.self)
  }

  // A one level copy fixes `[String]` and `[[Int]]` but not `[[String]]`, whose inner element used
  // to be written through a raw pointer too. That is why this one is here by name.
  @Test
  func `Nested array states stay stable`() throws {
    try self.expectStable("[[1,2],[3]]", as: StreamArray<StreamArray<Int>>.self)
    try self.expectStable(#"[["ab"],["cd","ef"]]"#, as: StreamArray<StreamArray<String>>.self)
  }

  // Enough elements to cross a block boundary, so the states span a seal.
  @Test
  func `Array states stay stable across a block boundary`() throws {
    let json = "[" + (0..<40).map(String.init).joined(separator: ",") + "]"
    try self.expectStable(json, as: StreamArray<Int>.self)
  }

  // MARK: - Dictionaries

  @Test
  func `Dictionary states stay stable`() throws {
    try self.expectStable(#"{"a":1,"b":2}"#, as: StreamDictionary<Int>.self)
    try self.expectStable(#"{"a":"xy","b":"z"}"#, as: StreamDictionary<String>.self)
  }

  // The shape the dictionary rework is aimed at: an inline pending slot inside an inline pending
  // slot, one per level.
  @Test
  func `Dictionary of arrays states stay stable`() throws {
    try self.expectStable(#"{"a":[1,2],"b":[3]}"#, as: StreamDictionary<StreamArray<Int>>.self)
  }

  @Test
  func `Dictionary of dictionaries states stay stable`() throws {
    try self.expectStable(
      #"{"a":{"x":1},"b":{"y":2}}"#, as: StreamDictionary<StreamDictionary<Int>>.self
    )
  }

  @Test
  func `Array of dictionaries states stay stable`() throws {
    try self.expectStable(
      #"[{"a":1},{"b":2}]"#, as: StreamArray<StreamDictionary<Int>>.self
    )
  }

  // Three deep, which is where a rebuild based snapshot stopped being correct.
  @Test
  func `Dictionary of arrays of arrays states stay stable`() throws {
    try self.expectStable(
      #"{"a":[[1],[2,3]]}"#, as: StreamDictionary<StreamArray<StreamArray<Int>>>.self
    )
  }

  // A repeated key writes into a slot that earlier states can be holding, so this is the case that
  // has to keep working when the storage is blocked.
  @Test
  func `States taken before a repeated key are unaffected by it`() throws {
    try self.expectStable(#"{"a":1,"b":2,"a":3}"#, as: StreamDictionary<Int>.self)
    try self.expectStable(
      #"{"a":[1],"b":[9],"a":[2]}"#, as: StreamDictionary<StreamArray<Int>>.self
    )
  }

  // MARK: - Macro generated partials

  @Test
  func `Object states stay stable`() throws {
    try self.expectStable(
      #"{"items":[{"id":1,"tags":["x"]},{"id":2,"tags":["y","z"]}]}"#,
      as: StabilityModel.Partial.self
    )
  }

  @Test
  func `Object states with dictionary members stay stable`() throws {
    try self.expectStable(#"{"counts":{"a":1,"b":2}}"#, as: StabilityModel.Partial.self)
    try self.expectStable(#"{"groups":{"a":[1,2],"b":[3]}}"#, as: StabilityModel.Partial.self)
  }

  // MARK: - The value actually parsed

  // Stability is worthless if the states are all wrong in the same way, so the shapes above are
  // also checked to arrive at the right final value.
  @Test
  func `The stable shapes parse correctly`() throws {
    var groups = StreamDictionary<StreamArray<Int>>()
    try parsePartial(#"{"a":[1,2],"b":[3]}"#, into: &groups)
    expectNoDifference(groups, ["a": [1, 2], "b": [3]])

    var deep = StreamDictionary<StreamArray<StreamArray<Int>>>()
    try parsePartial(#"{"a":[[1],[2,3]]}"#, into: &deep)
    expectNoDifference(deep, ["a": [[1], [2, 3]]])

    var model = StabilityModel.Partial()
    try parsePartial(#"{"groups":{"a":[1,2],"b":[3]}}"#, into: &model)
    expectNoDifference(model.groups, ["a": [1, 2], "b": [3]])
  }
}
