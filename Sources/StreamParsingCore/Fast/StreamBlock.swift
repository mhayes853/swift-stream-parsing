// A block of elements the parser writes into in place.
//
// `ContiguousArray` was the block type until the open element moved into the storage. It could
// not stay: an array never exposes its spare capacity, so the only way to add an element was to
// build it somewhere else and copy it in -- and for a partial of a few kilobytes that copy, and
// the moves that led up to it, were a third of a typed parse (NEW_ARCHITECTURE.md, "The open
// element moves into the storage"). This owns its capacity outright, so a new element is
// copy-initialised straight from its template into the slot it will live in and the parser is
// handed that slot's address.
//
// A `ManagedBuffer` rather than a class holding a pointer: the elements are tail-allocated with
// the object, so a block is one allocation, not two. That is not a nicety -- the two-allocation
// form doubled the malloc count of every number-heavy corpus (Canada 2,659 -> 5,109, a
// capacity-hinted Canada 58 K -> 116 K) and cost them 10-28%.
//
// A reference type so that a copy of the containing `StreamArray` is one retain per block and a
// snapshot shares the block instead of copying it. The sharing is what makes the uniqueness
// discipline in `StreamArray` load-bearing: a block reached through more than one array is never
// written, only replaced by a copy (`isKnownUniquelyReferenced` before a write into it). The
// parser settles that once per container it enters and once per parse call after a snapshot
// (`PartialSink.reseat()`), never per element; the public mutators settle it per mutation, the
// way `Array` does.
// Not generic over the element: a generic header makes the header's size, and so the elements'
// offset, a question for the type's metadata wherever the block is reached unspecialized. The
// links to other blocks are therefore raw bits of retained references, released by the block's
// deinit, rather than typed references. Not `AnyObject` either: an `AnyObject` reference is
// retained through `swift_unknownObjectRetain`, the Objective-C-aware slow path, and the links
// are touched once per snapshot cycle.
@usableFromInline
struct StreamBlockHeader {
  // Initialised elements, always a prefix of the capacity.
  @usableFromInline var count: Int
  // Stored rather than read back from `malloc_size` the way `ManagedBuffer.capacity` does.
  @usableFromInline let capacity: Int
  // A tail's frozen predecessors: blocks a snapshot shared that were left where they were
  // rather than copied (see `StreamArray.freezeTail`). Their elements precede this block's in
  // the array. Nil for a sealed block and for a tail no snapshot has interrupted.
  @usableFromInline var previous: UnsafeRawPointer?
  // The number of elements in the chain behind `previous`, all of them, which is also this
  // block's first element's offset within the array's tail region. A frozen block's own
  // logical count is its successor's `previousTotal` minus its own: the header's `count` may
  // be one higher, since a frozen tail keeps the stale copy of the element that was open when
  // the snapshot took it (the snapshot still reads it there).
  @usableFromInline var previousTotal: Int
  // The tail this one replaced when a snapshot interrupted an open element, kept so the next
  // interruption can reuse it once that snapshot has let go (see `StreamArray.freezeTail`).
  // With the latest state retained and the rest dropped -- the streaming shape -- the two
  // blocks alternate and no allocation happens per snapshot. Only ever a block that carries
  // none of the array's live elements.
  @usableFromInline var spare: UnsafeRawPointer?

  @usableFromInline
  init(count: Int, capacity: Int) {
    self.count = count
    self.capacity = capacity
    self.previous = nil
    self.previousTotal = 0
    self.spare = nil
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
      if let bits = header.pointee.previous { Unmanaged<StreamBlock<Element>>.fromOpaque(bits).release() }
      if let bits = header.pointee.spare { Unmanaged<StreamBlock<Element>>.fromOpaque(bits).release() }
    }
  }

  // Element by element rather than `deinitialize(count:)`: the counted form is
  // `swift_arrayDestroy`, a runtime call that consults the element's metadata first, and this
  // runs once per snapshot cycle on a block of one element. Moving the value out lets the
  // specialised destroy run on it.
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
  // by a dynamic `swift_beginAccess` call even in release builds -- two per element open, in the
  // middle of what is otherwise a load, a compare and a copy. The pointer is the same fixed
  // offset from the object as `base` is, and the closure folds to that arithmetic.
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

  @inlinable
  var isFull: Bool {
    let header = self.headerPointer
    return header.pointee.count == header.pointee.capacity
  }

  @inlinable
  var previous: StreamBlock<Element>? {
    get { Self.link(self.headerPointer.pointee.previous) }
    set { Self.setLink(&self.headerPointer.pointee.previous, newValue) }
  }

  @inlinable
  var spare: StreamBlock<Element>? {
    get { Self.link(self.headerPointer.pointee.spare) }
    set { Self.setLink(&self.headerPointer.pointee.spare, newValue) }
  }

  @inlinable
  static func link(_ bits: UnsafeRawPointer?) -> StreamBlock<Element>? {
    guard let bits else { return nil }
    return Unmanaged<StreamBlock<Element>>.fromOpaque(bits).takeUnretainedValue()
  }

  @inlinable
  static func setLink(_ bits: inout UnsafeRawPointer?, _ block: StreamBlock<Element>?) {
    let old = bits
    bits = block.map { UnsafeRawPointer(Unmanaged.passRetained($0).toOpaque()) }
    if let old { Unmanaged<StreamBlock<Element>>.fromOpaque(old).release() }
  }

  @inlinable
  var previousTotal: Int {
    get { self.headerPointer.pointee.previousTotal }
    set { self.headerPointer.pointee.previousTotal = newValue }
  }

  /// The spare block, if no snapshot still holds it, emptied and ready to be a tail again; nil
  /// otherwise, in which case the spare is let go.
  ///
  /// The header field is cleared on a block a snapshot may share. That write is benign: nothing
  /// reads `spare` but the one parser that owns the array's open element, a copy of the value
  /// only ever links a shared tail into its own chain, and the field is not part of the
  /// elements a snapshot exposes.
  @inlinable
  func takeSpare() -> StreamBlock<Element>? {
    guard let bits = self.headerPointer.pointee.spare else { return nil }
    self.headerPointer.pointee.spare = nil
    // The retained reference the header held, now owned by this local: the one reference left
    // if no snapshot still holds the block.
    var candidate: StreamBlock<Element>? = Unmanaged<StreamBlock<Element>>.fromOpaque(bits).takeRetainedValue()
    guard isKnownUniquelyReferenced(&candidate), let block = candidate else { return nil }
    Self.destroy(block.base, count: block.count)
    block.count = 0
    block.previous = nil
    block.previousTotal = 0
    block.spare = nil
    return block
  }

  /// A block holding copies of this block's elements, with room for `capacity` of them: what a
  /// write into a shared block goes through instead. The chain is not carried over.
  @inlinable
  func copy(capacity: Int) -> StreamBlock<Element> {
    let copied = StreamBlock<Element>.make(capacity: capacity)
    let count = self.count
    copied.base.initialize(from: self.base, count: count)
    copied.count = count
    return copied
  }

  /// A block holding this block's elements, moved: this one is left empty. Only for a block
  /// nothing else references. The chain moves with them.
  @inlinable
  func moved(capacity: Int) -> StreamBlock<Element> {
    let moved = StreamBlock<Element>.make(capacity: capacity)
    let count = self.count
    moved.base.moveInitialize(from: self.base, count: count)
    moved.count = count
    moved.previous = self.previous
    moved.previousTotal = self.previousTotal
    self.count = 0
    self.previous = nil
    self.previousTotal = 0
    return moved
  }
}

// The blocks are immutable once shared; see the note on the class. `StreamArray` asserts
// `Sendable` for the same reason and on the same condition.
extension StreamBlock: @unchecked Sendable where Element: Sendable {}
