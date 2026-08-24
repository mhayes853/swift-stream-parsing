import CustomDump
import Testing

@testable import StreamParsingCore

@Suite
struct `Stream array tests` {
  @Test
  func `Initial Capacity Reserves The Spine And First Tail`() {
    let array = StreamArray<Int>(initialCapacity: 1_000)

    expectNoDifference(array.blocks.capacity >= 31, true)
    expectNoDifference(array.tail.capacity >= StreamArray<Int>.blockCapacity, true)
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
    expectNoDifference(array.tail.count, 88)
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

  @Test
  func `Reserved Array Grows Past An Underestimate`() {
    var array = StreamArray<Int>(initialCapacity: 3)
    for value in 0..<100 { array.append(value) }

    expectNoDifference(Array(array), Array(0..<100))
  }

  @Test
  func `Tail Grows From Eight To Block Capacity`() {
    var array = StreamArray<Int>()

    expectNoDifference(array.tail.capacity, 0)
    _ = array._openElement(0)
    expectNoDifference(array.tail.capacity, 0)

    for value in 1..<9 {
      _ = array._openElement(value)
    }
    expectNoDifference(array.tail.count, 8)
    expectNoDifference(array.tail.capacity, 8)

    _ = array._openElement(9)
    expectNoDifference(array.tail.count, 9)
    expectNoDifference(array.tail.capacity >= StreamArray<Int>.blockCapacity, true)

    for value in 10...32 {
      _ = array._openElement(value)
    }
    expectNoDifference(array.blocks.count, 1)
    expectNoDifference(array.tail.capacity, 0)

    _ = array._openElement(33)
    expectNoDifference(array.tail.count, 1)
    expectNoDifference(array.tail.capacity >= StreamArray<Int>.blockCapacity, true)
  }
}
