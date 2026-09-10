// A block of elements a `StreamArray` fills and seals.
//
// `ContiguousArray` was the block type until the open element moved out of it. It could not
// stay: an array never exposes its spare capacity, so committing an element meant handing it to
// `append` and letting the array copy it in, and a shared array copies *all* of its elements
// before the first of those writes. This owns its capacity outright, so the parser writes the
// element into the slot it will live in, and a block a snapshot shares is written past rather
// than copied (see `StreamArray`).
//
// A `ManagedBuffer` rather than a class holding a pointer: the elements are tail-allocated with
// the object, so a block is one allocation, not two. That is not a nicety -- the two-allocation
// form doubled the malloc count of every number-heavy corpus (Canada 2,659 -> 5,109, a
// capacity-hinted Canada 58 K -> 116 K) and cost them 10-28%.
//
// A reference type so that a copy of the containing `StreamArray` is one retain per block and a
// snapshot shares the blocks instead of copying them.
//
// Not generic over the element: a generic header makes the header's size, and so the elements'
// offset, a question for the type's metadata wherever the block is reached unspecialized, which
// cost GitHub and GSoC 7-8%.
@usableFromInline
struct StreamBlockHeader {
  // The high-water mark of initialised slots, always a prefix of the capacity, and the count
  // `deinit` destroys. Written only by the array that fills the block, and read by nothing else
  // -- an array holding the block reads its *own* `tailCount`, which is a prefix of this one.
  // That is what lets the filling array keep appending into a block a snapshot shares: the
  // snapshot's count was captured when it was taken, so the slots past it are not its elements
  // and this field going up is not a change it can observe.
  @usableFromInline var count: Int
  // Stored rather than read back from `malloc_size` the way `ManagedBuffer.capacity` does.
  @usableFromInline let capacity: Int

  @usableFromInline
  init(count: Int, capacity: Int) {
    self.count = count
    self.capacity = capacity
  }
}

@usableFromInline
final class StreamBlock<Element>: ManagedBuffer<StreamBlockHeader, Element> {
  @inlinable
  static func make(capacity: Int) -> StreamBlock<Element> {
    let buffer = Self.create(minimumCapacity: Swift.max(capacity, 1)) { _ in
      StreamBlockHeader(count: 0, capacity: capacity)
    }
    return unsafeDowncast(buffer, to: StreamBlock<Element>.self)
  }

  deinit {
    _ = self.withUnsafeMutablePointers { header, elements in
      Self.destroy(elements, count: header.pointee.count)
    }
  }

  // Element by element rather than `deinitialize(count:)`: the counted form is
  // `swift_arrayDestroy`, a runtime call that consults the element's metadata first. Moving the
  // value out lets the specialised destroy run on it.
  @inlinable
  static func destroy(_ elements: UnsafeMutablePointer<Element>, count: Int) {
    // Nothing to do for a trivial element, and the loop below is not free for 40,000 doubles:
    // it cost the homogeneous double array 10% when it ran unconditionally.
    guard !_isPOD(Element.self) else { return }
    var index = 0
    while index < count {
      _ = (elements + index).move()
      index &+= 1
    }
  }

  // The element storage. `ManagedBuffer` hands it out through a closure; the address is a fixed
  // offset from the object and stays valid for the object's lifetime, which is the property the
  // parser's frames rely on.
  @inlinable
  var base: UnsafeMutablePointer<Element> {
    self.withUnsafeMutablePointerToElements { $0 }
  }

  // The header through its pointer rather than `ManagedBuffer.header`: that property is a
  // stored class property, and a stored class property read from outside its module is guarded
  // by a dynamic `swift_beginAccess` call even in release builds -- in the middle of what is
  // otherwise a load, a compare and a copy. The pointer is the same fixed offset from the object
  // as `base` is, and the closure folds to that arithmetic.
  @inlinable
  var headerPointer: UnsafeMutablePointer<StreamBlockHeader> {
    self.withUnsafeMutablePointerToHeader { $0 }
  }

  @inlinable
  var count: Int {
    get { self.headerPointer.pointee.count }
    set { self.headerPointer.pointee.count = newValue }
  }

  // Not `capacity`: `ManagedBuffer` owns that name for its `malloc_size` read.
  @inlinable
  var slotCapacity: Int { self.headerPointer.pointee.capacity }

  /// A block holding copies of this block's first `count` elements, with room for `capacity` of
  /// them: what a write into a block someone else can see goes through instead.
  ///
  /// The count is passed in rather than read from the header because the header's is the filling
  /// array's high-water mark, which can be ahead of the copying array's own.
  @inlinable
  func copy(count: Int, capacity: Int) -> StreamBlock<Element> {
    let copied = StreamBlock<Element>.make(capacity: capacity)
    copied.base.initialize(from: self.base, count: count)
    copied.count = count
    return copied
  }

  /// A block holding this block's first `count` elements, moved: this one is left empty. Only
  /// for a block nothing else references.
  @inlinable
  func moved(count: Int, capacity: Int) -> StreamBlock<Element> {
    let moved = StreamBlock<Element>.make(capacity: capacity)
    moved.base.moveInitialize(from: self.base, count: count)
    moved.count = count
    self.count = 0
    return moved
  }
}

// A block below the filling array's count is immutable, and the slots above it belong to that
// array alone; see the note on `count`. `StreamArray` asserts `Sendable` for the same reason and
// on the same condition.
extension StreamBlock: @unchecked Sendable where Element: Sendable {}
