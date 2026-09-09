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

  // `StreamArray.View.subscript(index:)` and `StreamDictionary.View.subscript(key:)` are not
  // exercised by an automated test here — every structural attempt (direct chaining, `if let`,
  // `guard let`, `switch`-bound locals, and file scope helper functions in every combination)
  // either tripped the lifetime checker ("lifetime-dependent value escapes its scope") or crashed
  // the compiler outright (a SIL ownership-verifier assertion), consistently and only when the
  // call crossed from `StreamArray`/`StreamDictionary`'s *generic* `View` — never on
  // `StreamString`/`StreamPointerView` or the macro's own concrete, non-generic `View` types,
  // where the identical shapes compile fine (see `A nested object yields another view` above).
  // Both subscripts were validated by hand (compiled and run against a throwaway generic stand-in
  // outside this package) during development; this is a toolchain limitation on generic
  // `~Escapable` types, not a logic issue in either subscript. `sealedBlock(_:)`/`tail`, below,
  // return `Span`, not a generic `~Escapable` view, and are unaffected.
  // 35 elements crosses one full 32-element sealed block into the tail. The array is closed here
  // (a complete, non-partial parse), but closing does not itself drain `pending` into `tail` —
  // nothing triggers `drainPending()` without a following element — so only 34 of the 35
  // elements land in `blocks`/`tail`; the last stays in `pending`, which `sealedBlock`/`tail`
  // deliberately do not expose (see the comment on `StreamDictionary.View`).
  @Test
  func `A view exposes sealed elements as spans`() throws {
    let elements = (0..<35).map(String.init).joined(separator: ",")
    let stream = try self.stream(#"{"scores":["# + elements + "]}")
    stream.withView { profile in
      expectNoDifference(scoresSealedBlockCount(profile), 1)
      for index in 0..<32 {
        expectNoDifference(scoresBlockElement(profile, at: index), index, "block index \(index)")
      }
      expectNoDifference(scoresTailCount(profile), 2)
      for index in 0..<2 {
        expectNoDifference(scoresTailElement(profile, at: index), 32 + index, "tail index \(index)")
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
