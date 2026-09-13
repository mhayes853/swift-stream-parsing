import CustomDump
import Testing

@testable import StreamParsingCore

@Suite
struct `Stream array tests` {
  @Test
  func `Initial Capacity Reserves The Spine And First Tail`() {
    let array = StreamArray<Int>(initialCapacity: 1_000)

    expectNoDifference(array.blocks.capacity >= 31, true)
    expectNoDifference((array.tail?.slotCapacity ?? 0) >= StreamArray<Int>.blockCapacity, true)
    expectNoDifference(array.isEmpty, true)
  }

  @Test
  func `Large Capacity Hints Adapt The Block Size`() {
    expectNoDifference(StreamArray<Int>().currentBlockCapacity, 32)
    expectNoDifference(StreamArray<Int>(initialCapacity: 2_048).currentBlockCapacity, 32)
    expectNoDifference(StreamArray<Int>(initialCapacity: 3_600).currentBlockCapacity, 64)
    expectNoDifference(StreamArray<Int>(initialCapacity: 7_200).currentBlockCapacity, 128)
    expectNoDifference(StreamArray<Int>(initialCapacity: 10_800).currentBlockCapacity, 256)
    expectNoDifference(StreamArray<Int>(initialCapacity: 33_408).currentBlockCapacity, 512)
    expectNoDifference(StreamArray<Int>.adaptiveBlockShift(for: .max), 9)
  }

  @Test
  func `Adaptive Blocks Preserve Collection And Snapshot Semantics`() {
    var array = StreamArray<Int>(initialCapacity: 10_800)
    for value in 0..<600 { array.append(value) }

    expectNoDifference(array.blocks.count, 2)
    expectNoDifference(array.tailCount, 88)
    expectNoDifference(Array(array), Array(0..<600))

    let snapshot = array
    array[300] = -1
    array.replaceSubrange(510..<520, with: [7, 8, 9])

    expectNoDifference(snapshot[300], 300)
    expectNoDifference(snapshot.count, 600)
    expectNoDifference(array[300], -1)
    expectNoDifference(array.count, 593)
    expectNoDifference(array.currentBlockCapacity, 256)
    expectNoDifference(Array(array[510..<513]), [7, 8, 9])
  }

  @Test
  func `Reserve Capacity Does Not Reblock Existing Elements`() {
    var array = StreamArray<Int>()
    array.append(1)
    array.reserveCapacity(33_408)

    expectNoDifference(array.currentBlockCapacity, 32)
    expectNoDifference(Array(array), [1])
  }

  @Test(arguments: [2_049, 4_097, 8_193, 32_769])
  func `Every Adaptive Block Size Survives Boundary Mutations`(hint: Int) {
    var array = StreamArray<Int>(initialCapacity: hint)
    var expected = Array(0..<(array.currentBlockCapacity * 2 + 17))
    for value in expected { array.append(value) }

    let boundary = array.currentBlockCapacity
    array[boundary - 1] = -1
    expected[boundary - 1] = -1
    array[boundary] = -2
    expected[boundary] = -2
    array.replaceSubrange((boundary - 2)..<(boundary + 3), with: [90, 91])
    expected.replaceSubrange((boundary - 2)..<(boundary + 3), with: [90, 91])

    expectNoDifference(Array(array), expected, "hint \(hint)")
  }

  @Test
  func `Reserved Array Grows Past An Underestimate`() {
    var array = StreamArray<Int>(initialCapacity: 3)
    for value in 0..<100 { array.append(value) }

    expectNoDifference(Array(array), Array(0..<100))
  }

  // The open element is not in a block: it sits in the array's inline slot until the next one
  // opens and moves it into place. So the first tail is allocated by the *second* open, holds
  // eight, is promoted to a full block when a ninth closes into it, and seals when a
  // thirty-third does.
  @Test
  func `Tail Grows From Eight To Block Capacity`() {
    var array = StreamArray<Int>()

    expectNoDifference(array.tail == nil, true)
    _ = array._openElement(0)
    expectNoDifference(array.tail == nil, true, "the first element is still in the inline slot")
    expectNoDifference(array.tailCount, 0)
    expectNoDifference(array.count, 1)

    for value in 1..<8 { _ = array._openElement(value) }
    expectNoDifference(array.tailCount, 7)
    expectNoDifference(array.tail?.slotCapacity, 8)

    _ = array._openElement(8)
    expectNoDifference(array.tailCount, 8)
    expectNoDifference(array.tail?.slotCapacity, 8)

    _ = array._openElement(9)
    expectNoDifference(array.tailCount, 9)
    expectNoDifference(array.tail?.slotCapacity, StreamArray<Int>.blockCapacity)

    for value in 10...32 { _ = array._openElement(value) }
    expectNoDifference(array.blocks.count, 0)
    expectNoDifference(array.tailCount, 32)

    _ = array._openElement(33)
    expectNoDifference(array.blocks.count, 1)
    expectNoDifference(array.tailCount, 1)
    expectNoDifference(array.tail?.slotCapacity, StreamArray<Int>.blockCapacity)
    expectNoDifference(Array(array), Array(0...33))
  }

  // The open element is the one piece of storage the parser writes that a copy taken mid-element
  // also reads, and it is held inline for exactly that reason: copying the array copies it, so
  // the two diverge with nothing asked of either side.
  @Test
  func `A Copy Taken While An Element Is Open Is Not Written Through`() {
    var array = StreamArray<Int>()
    let first = array._openElement(1)
    let snapshot = array
    first.assumingMemoryBound(to: Int.self).pointee = 2

    expectNoDifference(Array(snapshot), [1], "the copy took the open element with it")
    expectNoDifference(Array(array), [2])

    _ = array._openElement(4)
    expectNoDifference(Array(snapshot), [1])
    expectNoDifference(Array(array), [2, 4])

    let second = array
    array.append(5)
    expectNoDifference(Array(second), [2, 4])
    expectNoDifference(Array(array), [2, 4, 5])
  }

  // Closed elements are never written again, so the parser keeps committing into the very block
  // a copy holds: the slots it writes are above the count that copy captured, and so are not its
  // elements. This is what removes the copy-on-write check from the commit path.
  @Test
  func `Elements Committed After A Copy Are Not The Copy's`() {
    var array = StreamArray<Int>()
    for value in 0..<10 { _ = array._openElement(value) }
    let snapshot = array
    let sharedBlock = array.tail === snapshot.tail
    for value in 10..<40 { _ = array._openElement(value) }

    expectNoDifference(sharedBlock, true, "the copy shares the block the parser is filling")
    expectNoDifference(Array(snapshot), Array(0..<10))
    expectNoDifference(Array(array), Array(0..<40))
  }

  // A snapshot per element, every one kept.
  @Test
  func `Every Snapshot Kept While Parsing Stays Right`() {
    var array = StreamArray<Int>()
    var kept: [StreamArray<Int>] = []
    for value in 0..<200 {
      _ = array._openElement(value)
      kept.append(array)
    }
    expectNoDifference(Array(array), Array(0..<200))
    expectNoDifference(
      array.blocks.count * StreamArray<Int>.blockCapacity + array.tailCount + 1, 200
    )
    for (index, snapshot) in kept.enumerated() {
      expectNoDifference(Array(snapshot), Array(0...index), "snapshot \(index)")
    }
  }

  // Writing into an element the array already holds is the one case that copies, and it copies
  // the one block that element is in.
  @Test
  func `Writing Into A Shared Element Copies One Block`() {
    var array = StreamArray<Int>()
    for value in 0..<100 { _ = array._openElement(value) }
    let snapshot = array
    var mutated = array
    mutated[3] = 300
    mutated[98] = 980

    expectNoDifference(mutated[3], 300)
    expectNoDifference(mutated[98], 980)
    expectNoDifference(array[3], 3)
    expectNoDifference(array[98], 98)
    expectNoDifference(Array(snapshot), Array(0..<100))
  }

  // A repeated dictionary key resumes in the slot it already has, which may be the open one.
  @Test
  func `The Open Element Is Addressed As The Last`() {
    var array = StreamArray<Int>()
    _ = array._openElement(0)
    _ = array._openElement(1)
    array._uniqueSlotAddress(1).assumingMemoryBound(to: Int.self).pointee = 9

    expectNoDifference(Array(array), [0, 9])
    array._uniqueSlotAddress(0).assumingMemoryBound(to: Int.self).pointee = 8
    expectNoDifference(Array(array), [8, 9])
  }

  // `append` adds after the open element rather than replacing it, and closes it on the way.
  @Test
  func `Appending Adds After The Open Element`() {
    var array = StreamArray<Int>()
    _ = array._openElement(1)
    array.append(2)

    expectNoDifference(Array(array), [1, 2])
    expectNoDifference(array.pending == nil, true)
  }
}

// A class element, so that ownership transfers are observable. A `moveInitialize` out of a block
// someone else still holds leaves that holder's bits intact, so an `Int` array cannot tell a move
// from a copy by reading it -- only by watching what gets destroyed and when.
private final class TrackedElement {
  static nonisolated(unsafe) var deinitCount = 0
  let value: Int
  init(_ value: Int) { self.value = value }
  deinit { TrackedElement.deinitCount += 1 }
}

// The two mechanisms design B rests on, each written so that it fails when the mechanism is
// disabled -- checked by disabling it, not by assuming.
//
// They were both unguarded: making `View.tail` read the block's high-water mark, and making the
// promotion of the small first tail move even when the block is shared, each left the whole suite
// green. Ordinary parse-level tests cannot reach either, because both need a copy of an array to
// outlive a write into the block it shares, at a specific point in the block's growth.
@Suite
struct `Stream array sharing tests` {
  // `tailCount` is why the freeze chain could be deleted: the filling array appends into a block a
  // copy holds without any uniqueness check, because a copy captured its own count and every
  // slot written afterwards is above it. The block's own `count` is the filling array's
  // high-water mark and is *not* what a reader may use.
  @Test
  func `A copy reads its own count, not the block's high-water mark`() {
    var array = StreamArray<Int>()
    for value in 0..<5 { array.append(value) }
    array.drainPending()

    let snapshot = array
    for value in 5..<8 { array.append(value) }
    array.drainPending()

    // The premise: one block, shared, whose header has run ahead of the snapshot.
    expectNoDifference(snapshot.tail === array.tail, true, "the two must share one block")
    expectNoDifference(array.tail?.count, 8, "the filling array advanced the header")

    var kept = snapshot
    withUnsafeMutablePointer(to: &kept) { storage in
      let view = StreamArray<Int>.View(UnsafeMutableRawPointer(storage))
      expectNoDifference(view.tail.count, 5, "the span must stop at the snapshot's own count")
      var read = [Int]()
      for index in 0..<view.tail.count { read.append(view.tail[index]) }
      expectNoDifference(read, [0, 1, 2, 3, 4])
    }
    expectNoDifference(kept.count, 5)
  }

  // The small first tail is promoted to a full block the first time it fills. When something else
  // holds it that promotion has to copy: moving would hand the elements' ownership to the new
  // block while the holder still points at the old one, which reads as correct right up until the
  // filling array is released and takes the elements with it.
  @Test
  func `Promoting a shared first tail copies its elements rather than moving them`() {
    TrackedElement.deinitCount = 0
    do {
      var array = StreamArray<TrackedElement>()
      for value in 0..<8 { array.append(TrackedElement(value)) }
      array.drainPending()
      expectNoDifference(array.tail?.slotCapacity, 8, "still the small first tail")

      let snapshot = array
      // The ninth element fills the small tail, so the next slot promotes it.
      array.append(TrackedElement(8))
      array.drainPending()
      expectNoDifference(
        (array.tail?.slotCapacity ?? 0) > 8, true, "the tail was promoted to a full block"
      )
      expectNoDifference(snapshot.count, 8)
      expectNoDifference(TrackedElement.deinitCount, 0, "nothing should have been destroyed yet")

      // Releasing the filling array must not take the snapshot's elements with it: under a move
      // the promoted block owns all eight and destroys them here, leaving `snapshot` pointing at
      // objects that are gone.
      array = StreamArray<TrackedElement>()
      expectNoDifference(
        TrackedElement.deinitCount, 1,
        "only the ninth element, which the snapshot never held, should be gone"
      )
      var read = [Int]()
      for index in 0..<snapshot.count { read.append(snapshot[index].value) }
      expectNoDifference(read, [0, 1, 2, 3, 4, 5, 6, 7])
    }
    expectNoDifference(TrackedElement.deinitCount, 9, "everything goes when the snapshot does")
  }
}
