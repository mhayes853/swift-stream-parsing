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
