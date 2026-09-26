import CustomDump
import Testing

import StreamParsing
import StreamParsingCore

@StreamParseable
struct ViewAddress: Equatable {
  var city: String = ""
  var postalCode: String = ""
}

@StreamParseable
struct ViewProfile: Equatable {
  var id: Int = 0
  var name: String = ""
  var active: Bool = false
  var scores: [Int] = []
  var address: ViewAddress = ViewAddress()
  var counts: [String: Int] = [:]
}

// A view reads part of the value in place. It exists because `current` copies the containers in a
// whole value, which is the right default for keeping a state and the wrong one for rendering a
// field as it arrives.
@Suite
struct `Stream view tests` {
  private func stream(_ json: String) throws -> PartialsStream<ViewProfile.Partial> {
    var stream = PartialsStream(initialValue: ViewProfile.Partial(), from: .json())
    try stream.next(Array(json.utf8))
    return stream
  }

  // MARK: - Reading through a view

  @Test
  func `A view reads scalar members`() throws {
    let stream = try self.stream(#"{"id":42,"name":"Blob","active":true}"#)
    stream.withView { profile in
      expectNoDifference(profile.id?.value, 42)
      expectNoDifference(profile.name?.value, "Blob")
      expectNoDifference(profile.active?.value, true)
    }
  }

  @Test
  func `A member that has not arrived reads as nil`() throws {
    let stream = try self.stream(#"{"id":42}"#)
    stream.withView { profile in
      expectNoDifference(profile.id?.value, 42)
      expectNoDifference(profile.name?.value, nil)
      expectNoDifference(profile.scores?.value, nil)
    }
  }

  @Test
  func `A view reads container members`() throws {
    let stream = try self.stream(#"{"scores":[1,2,3],"counts":{"a":1}}"#)
    stream.withView { profile in
      expectNoDifference(profile.scores?.value, [1, 2, 3])
      expectNoDifference(profile.counts?.value["a"], 1)
    }
  }

  // A nested object yields another view rather than a copy of the subtree, so reading one leaf
  // deep in a value never materializes the levels above it.
  @Test
  func `A nested object yields another view`() throws {
    let stream = try self.stream(#"{"address":{"city":"Brooklyn","postalCode":"11215"}}"#)
    stream.withView { profile in
      switch profile.address {
      case .some(let address):
        expectNoDifference(address.city?.value, "Brooklyn")
        expectNoDifference(address.postalCode?.value, "11215")
      case .none:
        Issue.record("Expected an address view.")
      }
    }
  }

  @Test
  func `An absent nested object yields no view`() throws {
    let stream = try self.stream(#"{"id":1}"#)
    stream.withView { profile in
      switch profile.address {
      case .some: Issue.record("Expected no address view.")
      case .none: break
      }
    }
  }

  // MARK: - Views track the parse

  // The view holds the parser's storage rather than a copy of it, so it reports the value as it
  // stands each time it is taken. This is the difference from `current`, and the reason it cannot
  // be allowed to outlive the call.
  @Test
  func `A view taken later sees later bytes`() throws {
    var stream = PartialsStream(initialValue: ViewProfile.Partial(), from: .json())
    try stream.next(Array(#"{"name":"Bl"#.utf8))
    stream.withView { expectNoDifference($0.name?.value, "Bl") }
    try stream.next(Array(#"ob","id":7}"#.utf8))
    stream.withView {
      expectNoDifference($0.name?.value, "Blob")
      expectNoDifference($0.id?.value, 7)
    }
  }

  // MARK: - What a view hands back is safe to keep

  // Reading a container off a view snapshots that container, so what comes out does not change
  // afterwards even though the view itself is a window onto live storage.
  @Test
  func `A container read from a view does not change afterwards`() throws {
    var stream = PartialsStream(initialValue: ViewProfile.Partial(), from: .json())
    try stream.next(Array(#"{"scores":[1,2"#.utf8))
    // The trailing 2 is an open token — the next chunk continues it into 23 — so the state
    // read here holds only the committed element.
    let scores = stream.withView { $0.scores?.value }
    expectNoDifference(scores, [1])
    try stream.next(Array("3,4]}".utf8))
    expectNoDifference(scores, [1], "the value read out should not have followed the parse")
    expectNoDifference(stream.current.scores, [1, 23, 4])
  }

  @Test
  func `A string read from a view does not change afterwards`() throws {
    var stream = PartialsStream(initialValue: ViewProfile.Partial(), from: .json())
    try stream.next(Array(#"{"name":"Bl"#.utf8))
    let name = stream.withView { $0.name?.value }
    expectNoDifference(name, "Bl")
    try stream.next(Array(#"ob"}"#.utf8))
    expectNoDifference(name, "Bl", "the value read out should not have followed the parse")
  }

  // MARK: - Zero-copy container access

  // 259 elements crosses one full sealed block into the tail. `scores` is `[Int]`, whose
  // default block holds 256 (a trivial eight-byte element is blocked by bytes, not by the
  // 32-element count a non-trivial one keeps).
  //
  // All 259 are visible here. A homogeneous number array appends through `_appendClosed`: a
  // number token is delivered whole and exactly once, so there is no half-written element for
  // `pending` to hold and nothing is left outside the blocks. An array whose elements *are*
  // built incrementally (an array of objects) still keeps its last element in `pending`, which
  // these spans deliberately do not expose (see the comment on `StreamDictionary.View`).
  @Test
  func `A view exposes sealed elements as spans`() throws {
    let elements = (0..<259).map(String.init).joined(separator: ",")
    let stream = try self.stream(#"{"scores":["# + elements + "]}")
    stream.withView { profile in
      expectNoDifference(scoresSealedBlockCount(profile), 1)
      for index in 0..<256 {
        expectNoDifference(scoresBlockElement(profile, at: index), index, "block index \(index)")
      }
      expectNoDifference(scoresTailCount(profile), 3)
      for index in 0..<3 {
        expectNoDifference(
          scoresTailElement(profile, at: index), 256 + index, "tail index \(index)"
        )
      }
    }
  }

  @Test
  func `A view reports a dictionary's entry count`() throws {
    let stream = try self.stream(#"{"counts":{"a":1,"b":2}}"#)
    stream.withView { profile in
      expectNoDifference(countsCount(profile), 2)
    }
  }

  // The container subscripts are read through a `borrowing` view parameter (the helpers below).
  // On Swift 6.4 (swiftlang-6.4.0.25.4) two shapes still fail the lifetime checker ("lifetime-
  // dependent value escapes its scope"): subscripting a view bound by `case .some(let v)` off a
  // parent view, and `?.` chained through a subscript into a member view.
  @Test
  func `An array view subscript reads sealed, tail and out of range elements`() throws {
    let elements = (0..<259).map(String.init).joined(separator: ",")
    let stream = try self.stream(#"{"scores":["# + elements + "]}")
    let cases: [(Int, Int?)] = [(0, 0), (255, 255), (256, 256), (258, 258), (259, nil), (-1, nil)]
    stream.withView { profile in
      for (index, expected) in cases {
        expectNoDifference(scoresElement(profile, at: index), expected, "index \(index)")
      }
    }
  }

  // The open element lives in `pending`, outside the blocks; the subscript reaches it as the last.
  @Test
  func `An array view subscript reaches the open element`() throws {
    var stream = PartialsStream(initialValue: StreamArray<ViewAddress.Partial>(), from: .json())
    try stream.next(Array(#"[{"city":"A"},{"city":"Br"#.utf8))
    let cases: [(Int, String?)] = [(0, "A"), (1, "Br"), (2, nil)]
    stream.withView { view in
      for (index, expected) in cases {
        expectNoDifference(addressCity(view, at: index), expected, "index \(index)")
      }
    }
  }

  @Test
  func `A dictionary view subscript reads present and absent keys`() throws {
    let stream = try self.stream(#"{"counts":{"a":1,"b":2}}"#)
    let cases: [(String, Int?)] = [("a", 1), ("b", 2), ("c", nil)]
    stream.withView { profile in
      for (key, expected) in cases {
        expectNoDifference(countsValue(profile, key), expected, "key \(key)")
      }
    }
  }

  // A repeated key resumes in `pendingValue` while its stored slot still holds the old value;
  // the subscript must read the live one.
  @Test
  func `A dictionary view subscript reads a resumed key's live value`() throws {
    var stream = PartialsStream(
      initialValue: StreamDictionary<ViewAddress.Partial>(), from: .json()
    )
    try stream.next(Array(#"{"x":{"city":"A"},"y":{"city":"B"},"x":{"postalCode":"1"#.utf8))
    let cases: [(String, [String?])] = [("x", ["A", "1"]), ("y", ["B", nil]), ("z", [nil, nil])]
    stream.withView { view in
      for (key, expected) in cases {
        expectNoDifference(keyedAddress(view, key), expected, "key \(key)")
      }
    }
  }

  // MARK: - Equivalence with a snapshot

  @Test(arguments: [Int.max, 7, 1])
  func `A view agrees with a snapshot`(chunk: Int) throws {
    let json = #"{"id":4,"name":"Blob","active":true,"scores":[5,6],"address":{"city":"NY"}}"#
    var stream = PartialsStream(initialValue: ViewProfile.Partial(), from: .json())
    for bytes in Array(json.utf8).chunked(into: chunk) {
      try stream.next(bytes)
    }
    let snapshot = stream.current
    stream.withView { profile in
      expectNoDifference(profile.id?.value, snapshot.id)
      expectNoDifference(profile.name?.value, snapshot.name)
      expectNoDifference(profile.active?.value, snapshot.active)
      expectNoDifference(profile.scores?.value, snapshot.scores)
      switch profile.address {
      case .some(let address): expectNoDifference(address.city?.value, snapshot.address?.city)
      case .none: expectNoDifference(snapshot.address == nil, true)
      }
    }
  }
}

extension Array {
  fileprivate func chunked(into size: Int) -> [[Element]] {
    guard size < self.count else { return [Array(self)] }
    return stride(from: 0, to: self.count, by: size).map {
      Array(self[$0..<Swift.min($0 + size, self.count)])
    }
  }
}

// File scope rather than nested in a test: each switches on the view exactly once and returns a
// plain, Escapable value, which is the one shape that reliably compiled while writing the
// zero-copy container view tests above — see the comment on `A view exposes sealed elements as
// spans`.
private func scoresSealedBlockCount(_ profile: borrowing ViewProfile.Partial.View) -> Int? {
  switch profile.scores {
  case .some(let scores): return scores.sealedBlockCount
  case .none: return nil
  }
}

private func scoresBlockElement(
  _ profile: borrowing ViewProfile.Partial.View, at index: Int
) -> Int? {
  switch profile.scores {
  case .some(let scores): return scores.sealedBlock(0)[index]
  case .none: return nil
  }
}

private func scoresTailCount(_ profile: borrowing ViewProfile.Partial.View) -> Int? {
  switch profile.scores {
  case .some(let scores): return scores.tail.count
  case .none: return nil
  }
}

private func scoresTailElement(
  _ profile: borrowing ViewProfile.Partial.View, at index: Int
) -> Int? {
  switch profile.scores {
  case .some(let scores): return scores.tail[index]
  case .none: return nil
  }
}

private func countsCount(_ profile: borrowing ViewProfile.Partial.View) -> Int? {
  switch profile.counts {
  case .some(let counts): return counts.count
  case .none: return nil
  }
}

// The container subscripts, each on a `borrowing` parameter; see `An array view subscript reads
// sealed, tail and out of range elements` for the shapes that do not compile.
private func arrayElement(_ view: borrowing StreamArray<Int>.View, at index: Int) -> Int? {
  view[index]?.value
}

private func dictionaryValue(_ view: borrowing StreamDictionary<Int>.View, _ key: String) -> Int? {
  view[key]?.value
}

private func scoresElement(_ profile: borrowing ViewProfile.Partial.View, at index: Int) -> Int? {
  switch profile.scores {
  case .some(let scores): return arrayElement(scores, at: index)
  case .none: return nil
  }
}

private func countsValue(_ profile: borrowing ViewProfile.Partial.View, _ key: String) -> Int? {
  switch profile.counts {
  case .some(let counts): return dictionaryValue(counts, key)
  case .none: return nil
  }
}

private func addressFields(_ address: borrowing ViewAddress.Partial.View) -> [String?] {
  [(address.city?.value).map(String.init), (address.postalCode?.value).map(String.init)]
}

private func addressCity(
  _ view: borrowing StreamArray<ViewAddress.Partial>.View, at index: Int
) -> String? {
  switch view[index] {
  case .some(let element): return addressFields(element)[0]
  case .none: return nil
  }
}

private func keyedAddress(
  _ view: borrowing StreamDictionary<ViewAddress.Partial>.View, _ key: String
) -> [String?] {
  switch view[key] {
  case .some(let value): return addressFields(value)
  case .none: return [nil, nil]
  }
}
