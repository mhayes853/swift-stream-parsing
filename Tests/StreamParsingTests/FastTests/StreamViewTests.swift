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
      expectNoDifference(profile.id, 42)
      expectNoDifference(profile.name, "Blob")
      expectNoDifference(profile.active, true)
    }
  }

  @Test
  func `A member that has not arrived reads as nil`() throws {
    let stream = try self.stream(#"{"id":42}"#)
    stream.withView { profile in
      expectNoDifference(profile.id, 42)
      #expect(profile.name == nil)
      #expect(profile.scores == nil)
    }
  }

  @Test
  func `A view reads container members`() throws {
    let stream = try self.stream(#"{"scores":[1,2,3],"counts":{"a":1}}"#)
    stream.withView { profile in
      expectNoDifference(profile.scores, [1, 2, 3])
      expectNoDifference(profile.counts?["a"], 1)
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
        expectNoDifference(address.city, "Brooklyn")
        expectNoDifference(address.postalCode, "11215")
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
    stream.withView { expectNoDifference($0.name, "Bl") }
    try stream.next(Array(#"ob","id":7}"#.utf8))
    stream.withView {
      expectNoDifference($0.name, "Blob")
      expectNoDifference($0.id, 7)
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
    let scores = stream.withView { $0.scores }
    expectNoDifference(scores, [1])
    try stream.next(Array("3,4]}".utf8))
    #expect(scores == [1], "the value read out should not have followed the parse")
    expectNoDifference(stream.current.scores, [1, 23, 4])
  }

  @Test
  func `A string read from a view does not change afterwards`() throws {
    var stream = PartialsStream(initialValue: ViewProfile.Partial(), from: .json())
    try stream.next(Array(#"{"name":"Bl"#.utf8))
    let name = stream.withView { $0.name }
    expectNoDifference(name, "Bl")
    try stream.next(Array(#"ob"}"#.utf8))
    #expect(name == "Bl", "the value read out should not have followed the parse")
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
      expectNoDifference(profile.id, snapshot.id)
      expectNoDifference(profile.name, snapshot.name)
      expectNoDifference(profile.active, snapshot.active)
      expectNoDifference(profile.scores, snapshot.scores)
      switch profile.address {
      case .some(let address): expectNoDifference(address.city, snapshot.address?.city)
      case .none: #expect(snapshot.address == nil)
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
