import Testing

@testable import StreamParsingCore

// `_streamCopyInitializeSome` writes `.some` over a `nil` slot by copying only the payload through
// its own witness and then the tag bytes behind it, so a payload with spare bits and one without
// both have to come out `.some`, equal to the template, and owning their own references. The field
// table holds each prepare closure in a box retained once; releasing the table must release it.
@Suite
struct `Stream Template Copy Tests` {
  final class Token: @unchecked Sendable {}

  // Small enough for the staged copy (48 bytes or fewer).
  struct Small: Equatable {
    var token: Token?
    var count = 0

    static func == (lhs: Small, rhs: Small) -> Bool {
      lhs.token === rhs.token && lhs.count == rhs.count
    }
  }

  // Past every threshold: takes the witness call.
  struct Large: Equatable {
    var token: Token?
    var name: String? = nil
    var values: [Int] = []
    var padding: (Int, Int, Int, Int, Int, Int, Int, Int, Int, Int, Int, Int, Int, Int, Int, Int) =
      (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    var trailing: Token?

    static func == (lhs: Large, rhs: Large) -> Bool {
      lhs.token === rhs.token && lhs.name == rhs.name && lhs.values == rhs.values
        && lhs.trailing === rhs.trailing
    }
  }

  // No spare bits anywhere, so `Optional` keeps its case in a tag byte past the payload.
  struct NoSpareBits: Equatable {
    var a = 0
    var b = 0
    var c = 0
    var d = 0
    var e = 0
    var f = 0
    var g = 0
  }

  private func copyRoundTrip<T: Equatable>(_ value: T) -> Bool {
    let template = UnsafeMutablePointer<T?>.allocate(capacity: 1)
    template.initialize(to: value)
    let slot = UnsafeMutablePointer<T?>.allocate(capacity: 1)
    slot.initialize(to: nil)
    _streamCopyInitializeSome(slot, from: template)
    let matches = slot.pointee == value
    slot.deinitialize(count: 1)
    slot.deallocate()
    template.deinitialize(count: 1)
    template.deallocate()
    return matches
  }

  @Test
  func `Copies A Payload With Spare Bits`() {
    #expect(MemoryLayout<Small?>.size == MemoryLayout<Small>.size)
    #expect(copyRoundTrip(Small(token: Token(), count: 7)))
    #expect(copyRoundTrip(Large(token: Token(), name: "n", values: [1, 2], trailing: Token())))
  }

  @Test
  func `Copies A Payload Without Spare Bits Along With Its Tag`() {
    #expect(MemoryLayout<NoSpareBits?>.size > MemoryLayout<NoSpareBits>.size)
    #expect(copyRoundTrip(NoSpareBits(a: 1, b: 2, c: 3, d: 4, e: 5, f: 6, g: 7)))
    // A nested optional whose payload is `.none` is still a present `.some(nil)`.
    #expect(copyRoundTrip(Int?.none))
    #expect(copyRoundTrip(Int?.some(3)))
  }

  @Test
  func `The Copy Owns Its References`() {
    var token = Token()
    let template = UnsafeMutablePointer<Large?>.allocate(capacity: 1)
    template.initialize(to: Large(token: token, values: [1], trailing: token))
    let slot = UnsafeMutablePointer<Large?>.allocate(capacity: 1)
    slot.initialize(to: nil)
    _streamCopyInitializeSome(slot, from: template)
    #expect(slot.pointee?.token === token)
    slot.deinitialize(count: 1)
    template.deinitialize(count: 1)
    slot.deallocate()
    template.deallocate()
    // Both copies released what they held; an unretained bitwise copy would have over-released.
    #expect(isKnownUniquelyReferenced(&token))
  }

  @Test
  func `Field Table Releases Its Prepare Boxes`() {
    weak var captured: Token?
    do {
      let token = Token()
      captured = token
      var field = StreamField(key: "a", index: 0, kind: .container, optional: true, offset: 0)
      field.prepare = { _, _ in _ = token }
      let table = StreamFieldTable([field])
      #expect(table.prepares[0] != nil)
    }
    #expect(captured == nil)
  }
}
