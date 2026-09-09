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

  // Every element opens in place: the first tail holds eight, is promoted to a full block on the
  // ninth, and a full tail seals when the element after it opens, so the open element is always
  // in the tail.
  @Test
  func `Tail Grows From Eight To Block Capacity`() {
    var array = StreamArray<Int>()

    expectNoDifference(array.tail == nil, true)
    _ = array._openElement(0)
    expectNoDifference(array.tailCount, 1)
    expectNoDifference(array.tail?.slotCapacity, 8)

    for value in 1..<8 {
      _ = array._openElement(value)
    }
    expectNoDifference(array.tailCount, 8)
    expectNoDifference(array.tail?.slotCapacity, 8)

    _ = array._openElement(8)
    expectNoDifference(array.tailCount, 9)
    expectNoDifference(array.tail?.slotCapacity, StreamArray<Int>.blockCapacity)

    for value in 9..<32 {
      _ = array._openElement(value)
    }
    expectNoDifference(array.blocks.count, 0)
    expectNoDifference(array.tailCount, 32)

    _ = array._openElement(32)
    expectNoDifference(array.blocks.count, 1)
    expectNoDifference(array.tailCount, 1)
    expectNoDifference(array.tail?.slotCapacity, StreamArray<Int>.blockCapacity)
    expectNoDifference(Array(array), Array(0...32))
  }

  // The open element is written through a pointer into the tail's block. A copy taken while it
  // is open shares that block; the parser's contract is to make the tail unique again before it
  // opens anything else (`_reopenElement`), and the public `append` does so itself.
  @Test
  func `A Copy Taken While An Element Is Open Is Not Written Through`() {
    var array = StreamArray<Int>()
    let first = array._openElement(1)
    let snapshot = array
    first.assumingMemoryBound(to: Int.self).pointee = 2

    expectNoDifference(Array(snapshot), [2], "a write into the open element before any open is visible")
    let reopened = array._reopenElement()
    reopened?.assumingMemoryBound(to: Int.self).pointee = 3
    _ = array._openElement(4)

    expectNoDifference(Array(snapshot), [2])
    expectNoDifference(Array(array), [3, 4])

    let second = array
    array.append(5)
    expectNoDifference(Array(second), [3, 4])
    expectNoDifference(Array(array), [3, 4, 5])
  }

  @Test
  func `Reopening The Element Copies A Shared Block`() {
    var array = StreamArray<Int>()
    let first = array._openElement(1)
    let snapshot = array
    let reopened = array._reopenElement()

    expectNoDifference(reopened != first, true)
    reopened?.assumingMemoryBound(to: Int.self).pointee = 9
    expectNoDifference(Array(snapshot), [1])
    expectNoDifference(Array(array), [9])
  }

  // A shared tail is frozen where it is: the open element alone is copied into a fresh tail, the
  // frozen block is chained behind it, and indexing across the chain stays right.
  @Test
  func `Reopening Freezes The Shared Tail And Copies Only The Open Element`() {
    var array = StreamArray<Int>()
    for value in 0..<40 { _ = array._openElement(value) }
    let snapshot = array
    let reopened = array._reopenElement()
    reopened?.assumingMemoryBound(to: Int.self).pointee = -39

    expectNoDifference(array.blocks.count, 1, "the full block; the frozen seven hang off the tail")
    expectNoDifference(array.tail?.previousTotal, 7)
    expectNoDifference(array.tail?.count, 1)
    expectNoDifference(array.tailCount, 8)
    expectNoDifference(Array(snapshot), Array(0..<40))
    expectNoDifference(Array(array), Array(0..<39) + [-39])
    for position in 0..<40 {
      expectNoDifference(array[position], position == 39 ? -39 : position, "position \(position)")
    }

    for value in 40..<100 { _ = array._openElement(value) }
    expectNoDifference(array.blocks.count, 3, "the chain compacted into full blocks as the tail filled")
    expectNoDifference(array.tail?.previous == nil, true)
    expectNoDifference(Array(array), Array(0..<39) + [-39] + Array(40..<100))
    expectNoDifference(Array(snapshot), Array(0..<40))

    var mutated = array
    mutated[3] = 300
    mutated[98] = 980
    expectNoDifference(mutated[3], 300)
    expectNoDifference(mutated[98], 980)
    expectNoDifference(array[3], 3)
    expectNoDifference(array[98], 98)
  }

  // A snapshot per element, every one kept: the chain must stay bounded and the spine uniform.
  @Test
  func `Snapshots Kept Per Element Compact The Chain`() {
    var array = StreamArray<Int>()
    var kept: [StreamArray<Int>] = []
    for value in 0..<200 {
      _ = array._reopenElement()
      _ = array._openElement(value)
      kept.append(array)
    }
    expectNoDifference(Array(array), Array(0..<200))
    expectNoDifference(array.blocks.count, 200 / 32)
    var links = 0
    var link = array.tail?.previous
    while let block = link {
      links += 1
      link = block.previous
    }
    expectNoDifference(links < 32, true)
    for (index, snapshot) in kept.enumerated() {
      expectNoDifference(Array(snapshot), Array(0...index), "snapshot \(index)")
    }
  }

  // A snapshot inside the first element of a tail, taken per byte, must not chain empty links.
  @Test
  func `Snapshots Inside The Open Element Do Not Grow The Chain`() {
    var array = StreamArray<Int>()
    var kept: [StreamArray<Int>] = []
    _ = array._openElement(0)
    for step in 1...100 {
      kept.append(array)
      let slot = array._reopenElement()
      slot?.assumingMemoryBound(to: Int.self).pointee = step
    }
    expectNoDifference(array.tail?.previous == nil, true)
    expectNoDifference(Array(array), [100])
    for (index, snapshot) in kept.enumerated() {
      expectNoDifference(Array(snapshot), [index], "snapshot \(index)")
    }
  }

  @Test
  func `Preparing For Writes Freezes A Shared Tail Without Copying`() {
    var array = StreamArray<Int>()
    for value in 0..<5 { _ = array._openElement(value) }
    let snapshot = array
    array._prepareForWrites()
    _ = array._openElement(5)

    expectNoDifference(array.blocks.count, 0)
    expectNoDifference(array.tail?.previousTotal, 5)
    expectNoDifference(Array(array), Array(0..<6))
    expectNoDifference(Array(snapshot), Array(0..<5))
  }
}
