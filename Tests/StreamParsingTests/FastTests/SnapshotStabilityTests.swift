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

  @Test
  func `Fixed SIMD array states stay stable while lanes are written`() throws {
    try self.expectStable(
      "[[1,2],[3,4]]", as: StreamArray<SIMD2<Double>>.self
    )
  }

  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  @Test
  func `InlineArray states stay stable while elements are written`() throws {
    try self.expectStable(
      #"["ab","cd"]"#, as: InlineArray<2, String>.self
    )
    try self.expectStable(
      "[[1,2],[3,4]]", as: InlineArray<2, InlineArray<2, Int>>.self
    )
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

  // MARK: - Copies taken through a view

  // A container read out of a view as a value shares the parser's blocks the way `current` does.
  // Every byte takes one such copy, so every byte is a chance for the next write to land in it.
  @Test
  func `Containers copied out of a view stay stable`() throws {
    let json = #"{"items":[{"id":1,"tags":["x"]},{"id":2,"tags":["yy","z"]}],"groups":{"a":[1,2],"b":[3]}}"#
    var stream = PartialsStream(initialValue: StabilityModel.Partial(), from: .json())
    var keptItems = [(rendering: String, value: StreamArray<StabilityItem.Partial>)]()
    var keptGroups = [(rendering: String, value: StreamDictionary<StreamArray<Int>>)]()
    for byte in Array(json.utf8) {
      try stream.next(byte)
      stream.withView { model in
        if let items = itemsValue(model) { keptItems.append((String(describing: items), items)) }
        if let groups = groupsValue(model) { keptGroups.append((String(describing: groups), groups)) }
      }
    }
    let final = try stream.finish()
    expectNoDifference(final.items?.count, 2)
    expectNoDifference(final.groups?.count, 2)

    for (offset, state) in keptItems.enumerated() {
      expectNoDifference(
        String(describing: state.value), state.rendering, "items copied at state \(offset) changed"
      )
    }
    for (offset, state) in keptGroups.enumerated() {
      expectNoDifference(
        String(describing: state.value), state.rendering, "groups copied at state \(offset) changed"
      )
    }
  }

  // The value a stream starts from may share its blocks with whoever supplied it. The parser
  // writes into those blocks in place, so it has to notice the share when it enters the
  // container, not merely when a snapshot is taken.
  @Test
  func `An initial value's storage is not written into`() throws {
    let supplied: StreamArray<Int> = [1, 2]
    var stream = PartialsStream(initialValue: supplied, from: .json())
    try stream.next(Array("[3,4]".utf8))
    let parsed = try stream.finishValue()

    expectNoDifference(Array(parsed), [1, 2, 3, 4])
    expectNoDifference(Array(supplied), [1, 2])

    var nested = StreamDictionary<StreamArray<Int>>()
    nested.updateValue([7], forKey: "a")
    let suppliedNested = nested
    var nestedStream = PartialsStream(initialValue: suppliedNested, from: .json())
    try nestedStream.next(Array(#"{"a":[8],"b":[9]}"#.utf8))
    let parsedNested = try nestedStream.finishValue()

    expectNoDifference(parsedNested, ["a": [7, 8], "b": [9]])
    expectNoDifference(suppliedNested, ["a": [7]])
  }

  // Driving `PartialSink` directly, a copy taken mid-parse needs nothing reported to the sink:
  // the open element of every container is inline, so the copy diverges on its own.
  @Test
  func `A sink driven directly keeps a copy taken mid-parse stable`() throws {
    let json = Array(#"[[1,2],[3,4]]"#.utf8)
    let storage = UnsafeMutablePointer<StreamArray<StreamArray<Int>>>.allocate(capacity: 1)
    storage.initialize(to: [])
    defer {
      storage.deinitialize(count: 1)
      storage.deallocate()
    }
    var sink = PartialSink(root: storage)
    var parser = JSONParser()
    try json[..<5].withUnsafeBufferPointer { try parser.parse($0, into: &sink) }
    let copy = storage.pointee
    let rendering = String(describing: copy)
    try json[5...].withUnsafeBufferPointer { try parser.parse($0, into: &sink) }
    try parser.finish(into: &sink)

    expectNoDifference(storage.pointee, [[1, 2], [3, 4]])
    expectNoDifference(String(describing: copy), rendering)
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

// File scope, one switch each, returning plain values: the shape that reliably compiles for
// generic `~Escapable` container views (see `StreamViewTests`).
private func itemsValue(
  _ model: borrowing StabilityModel.Partial.View
) -> StreamArray<StabilityItem.Partial>? {
  switch model.items {
  case .some(let items): return items.value
  case .none: return nil
  }
}

private func groupsValue(
  _ model: borrowing StabilityModel.Partial.View
) -> StreamDictionary<StreamArray<Int>>? {
  switch model.groups {
  case .some(let groups): return groups.value
  case .none: return nil
  }
}
