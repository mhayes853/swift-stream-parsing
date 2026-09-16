// A block of elements a `StreamArray` fills and seals. A `ManagedBuffer`, so one allocation, not
// two; a reference type, so copying the array is one retain per block; and a non-generic header,
// which would otherwise make the element offset a metadata lookup wherever the block is reached
// unspecialized. See NEW_ARCHITECTURE.md, "The open element moves into the storage".
@usableFromInline
struct StreamBlockHeader {
  // The high-water mark of initialised slots and the count `deinit` destroys. Written only by the
  // filling array and read by nothing else: a holder reads its own `tailCount`, a prefix of this,
  // so appending into a block a snapshot shares changes nothing the snapshot can observe.
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
    // At least one slot is allocated, so the header records what was allocated, not what was asked.
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

  // Destroys the elements in place. A generic class's `deinit` is emitted once, generically, so
  // this runs through value witnesses however it is written. Measured: a `move()` loop lowered to
  // an alloca + take + destroy per element, 1.19 MB of memmove per Twitter full parse; keep the
  // counted form (one `swift_arrayDestroy`). See NEW_ARCHITECTURE.md.
  @inlinable
  static func destroy(_ elements: UnsafeMutablePointer<Element>, count: Int) {
    // Measured: destroying unconditionally cost the homogeneous double array 10%.
    guard !_isPOD(Element.self) else { return }
    elements.deinitialize(count: count)
  }

  // The element storage: a fixed offset from the object for its lifetime, as the frames require.
  @inlinable
  var base: UnsafeMutablePointer<Element> {
    self.withUnsafeMutablePointerToElements { $0 }
  }

  // Through the pointer, not `ManagedBuffer.header`: a stored class property read from outside its
  // module pays a dynamic `swift_beginAccess` even in release. The closure folds to the same fixed
  // offset arithmetic as `base`.
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

  /// A block holding copies of this block's first `count` elements, with room for `capacity`: the
  /// path a write into a shared block takes. `count` is passed in because the header's is the
  /// filling array's high-water mark, which can be ahead of the copier's own.
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

// Below the filling array's count a block is immutable, and the slots above belong to that array
// alone (see `count`). `StreamArray` asserts `Sendable` on the same grounds.
extension StreamBlock: @unchecked Sendable where Element: Sendable {}
