import CustomDump
import Testing

@testable import StreamParsingCore

@Suite
struct `Stream array tests` {
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
