// A block of elements a `StreamArray` fills and seals.
//
// A `ManagedBuffer` rather than a class holding a pointer, so a block is one allocation and not
// two; a reference type, so copying the array is one retain per block; and deliberately not
// generic over the element, because a generic header makes the element offset a metadata lookup
// wherever the block is reached unspecialized. See NEW_ARCHITECTURE.md, "The open element moves
// into the storage", for the measurements behind all three.
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
    // One slot is always allocated, so the header records the count that was allocated rather
    // than the one that was asked for: `slotCapacity` is the type's only statement about the room
    // it owns.
    let slots = Swift.max(capacity, 1)
    let buffer = Self.create(minimumCapacity: slots) { _ in
      StreamBlockHeader(count: 0, capacity: slots)
    }
    return unsafeDowncast(buffer, to: StreamBlock<Element>.self)
  }

  deinit {
    _ = self.withUnsafeMutablePointers { header, elements in
      Self.destroy(elements, count: header.pointee.count)
    }
  }

  // Destroys the elements where they live.
  //
  // `deinit` on a generic class is emitted ONCE, generically, so this body runs through
  // `Element`'s value witnesses however it is written -- the "specialised destroy" it used to
  // reach for never existed on the teardown path.
  // measured: a `(elements + index).move()` loop lowers unspecialised to an alloca +
  // `initializeWithTake` + destroy per element, 1.19 MB of memmove per Twitter full parse; keep
  // the counted form, which is one `swift_arrayDestroy` in place.
  @inlinable
  static func destroy(_ elements: UnsafeMutablePointer<Element>, count: Int) {
    // Nothing to do for a trivial element, and the call below is not free for 40,000 doubles:
    // destroying unconditionally cost the homogeneous double array 10%.
    guard !_isPOD(Element.self) else { return }
    elements.deinitialize(count: count)
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
