// Array storage the parser can hold a pointer into, and that a snapshot can copy without copying
// the elements.
//
// Everything left of the parse cursor is immutable: once an element is closed it never changes.
// `Array` cannot express that, because any divergence from a shared buffer copies all of it, so
// keeping a value while parsing continues costs a full rebuild per snapshot.
//
// Three pieces make that cheap here:
//
// - **The open element lives in the storage, in place.** The parser's frame points at the last
//   slot of the filling block, where the element was copy-initialised from its template and where
//   it stays for good: no separate pending slot, and so no move into the storage when the next
//   element opens. That move, and the swap and template copy around it, were six whole-element
//   copies per element -- a third of a typed parse on a document of large partials. The slot's
//   address is stable for the element's lifetime because an array only grows at the next open,
//   which the grammar puts after everything inside the current element has closed.
// - **Sealed elements live in uniform power-of-two blocks that are never written.** A block is a
//   `StreamBlock`, one refcounted object; copying the array retains the blocks and the filling
//   one, and copying is therefore a correct snapshot on its own. What keeps it correct afterwards
//   is that a shared block is never written: a write that finds its block shared copies that one
//   block first, which the parser settles once per container it enters and once per parse call
//   after a snapshot (`PartialSink.reseat()`), never per element.
// - **A shared tail is frozen, not copied.** The one block a snapshot shares that the parser
//   still has to write is the tail, and what the parser needs from it is only the open element.
//   So the tail is left where it is, chained behind a fresh tail that receives a copy of the open
//   element alone (`freezeTail`). The cost of a snapshot is one element, whatever the block size;
//   copying the block instead cost a retained snapshot per byte 90% of its throughput. The chain
//   hangs off the tail's header rather than entering the spine, because the spine is shared with
//   the snapshot too and appending to it copied the whole spine per snapshot -- quadratic on a
//   long array. Once the chain holds a block's worth it is compacted into full sealed blocks,
//   which keeps the spine uniform, indexing a shift and a mask, and the chain shorter than a
//   block.
//
// A plain value copy is therefore already a correct snapshot, which is why nothing here has a
// `streamSnapshot()`.
public struct StreamArray<Element> {
  // Sealed and never written again except through the checked subscript, which copies the block
  // it writes when a snapshot shares it. Every block in an instance holds its chosen capacity,
  // which keeps indexing a shift and a mask rather than a search over prefix sums.
  @usableFromInline var blocks: [StreamBlock<Element>]

  // The filling block, holding the open element (if any) in its last slot, and behind it (see
  // `StreamBlockHeader.previous`) any tails a snapshot froze. Nil until the first element, so an
  // empty array allocates nothing and copies nothing. Its first allocation is deliberately
  // smaller than the chosen block capacity; it grows once if needed, while every tail after the
  // first sealed block starts at full size. A full tail is sealed when the *next* element opens
  // rather than when it fills, so the open element is always in the tail.
  @usableFromInline var tail: StreamBlock<Element>?

  // Capacity hints choose this while the array is empty. Keeping it as a shift makes the count and
  // index arithmetic independent of division, while the default path remains the same immediate
  // shift and mask used before adaptive blocks were introduced.
  @usableFromInline var blockShiftBits: UInt8

  // Cached separately because the open path needs the capacity for every element, whereas the
  // shift is only needed when a block seals or an element is indexed. This avoids reconstructing
  // the value with a variable shift in the append hot path. The maximum adaptive capacity fits in
  // UInt16.
  @usableFromInline var blockCapacityBits: UInt16

  // A power of two, so the sealed count is `blocks.count << blockShift` and needs no stored field.
  @usableFromInline static var initialTailCapacity: Int { 8 }
  @usableFromInline static var blockShift: Int { 5 }
  @usableFromInline static var blockCapacity: Int { 1 &<< Self.blockShift }
  @usableFromInline static var blockMask: Int { Self.blockCapacity &- 1 }

  // A block is also what a write into a sealed block copies, so its size in bytes is bounded:
  // no cap while an element is at most 512 bytes, then a shift that keeps a block near 16 KB.
  // Blocks of two are the floor. Folds to a constant per element type.
  @usableFromInline static var strideBlockShiftCap: Int {
    let stride = MemoryLayout<Element>.stride
    guard stride > 512 else { return 9 }
    let strideShift = Int.bitWidth &- (stride &- 1).leadingZeroBitCount  // ceil(log2(stride))
    return Swift.max(14 &- strideShift, 1)
  }

  @usableFromInline static var defaultBlockShift: Int {
    Swift.min(Self.blockShift, Self.strideBlockShiftCap)
  }

  public init() {
    self.blocks = []
    self.tail = nil
    let shift = Self.defaultBlockShift
    self.blockShiftBits = UInt8(shift)
    self.blockCapacityBits = UInt16(1 &<< shift)
  }

  /// Creates an empty streaming array with storage reserved for at least the expected number of
  /// elements. The blocked representation remains an implementation detail: this is a hint that
  /// avoids growth of the block spine and lets large arrays use fewer internal allocations.
  public init(initialCapacity: Int) {
    self.init()
    self.reserveCapacity(initialCapacity)
  }

  public init(_ elements: some Sequence<Element>) {
    self.init()
    for element in elements { self.append(element) }
  }

  @usableFromInline var currentBlockCapacity: Int { Int(self.blockCapacityBits) }

  // Elements past the sealed blocks: the tail's own and every frozen block's behind it.
  @usableFromInline
  var tailCount: Int {
    guard let tail = self.tail else { return 0 }
    return tail.previousTotal &+ tail.count
  }

  @usableFromInline
  var sealedCount: Int {
    if _fastPath(self.blockShiftBits == UInt8(Self.blockShift)) {
      return self.blocks.count &<< Self.blockShift
    }
    return self.blocks.count &<< Int(self.blockShiftBits)
  }

  @usableFromInline
  static func adaptiveBlockShift(for minimumCapacity: Int) -> UInt8 {
    // Aim for roughly 64 sealed allocations. The clamps retain the established snapshot
    // granularity for ordinary arrays and bound the amount copied by the first write after a
    // retained snapshot. `minimumCapacity / 64` avoids overflowing for capacities near Int.max.
    let desired = minimumCapacity / 64 + (minimumCapacity % 64 == 0 ? 0 : 1)
    guard desired > Self.blockCapacity else { return UInt8(Self.defaultBlockShift) }
    let roundedShift = Int.bitWidth &- (desired &- 1).leadingZeroBitCount
    return UInt8(Swift.min(9, roundedShift, Self.strideBlockShiftCap))
  }

  // MARK: Locating

  // The address of element `offset` of the tail region: in the tail itself past the frozen
  // elements, otherwise in the frozen block whose range covers it. The chain is short -- fewer
  // links than a block holds elements, see `compactTail` -- and walked only for reads of
  // elements a snapshot froze.
  @inlinable
  func tailElementAddress(_ offset: Int) -> UnsafeMutablePointer<Element> {
    let tail = self.tail.unsafelyUnwrapped
    if _fastPath(offset >= tail.previousTotal) {
      return tail.base + (offset &- tail.previousTotal)
    }
    var block = tail.previous.unsafelyUnwrapped
    while offset < block.previousTotal { block = block.previous.unsafelyUnwrapped }
    return block.base + (offset &- block.previousTotal)
  }

  // MARK: Slots

  // The address the next element is initialised at, with the tail made ready for it: sealed if
  // full, grown if it is the small first tail, allocated if there is none. The common case -- a
  // tail with room -- is two loads and a compare; everything else is behind `prepareSlot`.
  //
  // The tail is assumed unique here. That is the contract every caller keeps: the parser makes
  // the tail unique once when it enters the array (`_prepareForWrites`) and again after any
  // parse call in which a snapshot may have been taken (`PartialSink.reseat()`), and never
  // between, because nothing but the parser touches the value while a parse call runs; the
  // public mutators call `ensureUniqueTail()` themselves. Checking here instead -- one runtime
  // call per element -- cost the homogeneous double array 29%.
  @inlinable
  @inline(__always)
  mutating func nextSlot() -> UnsafeMutablePointer<Element> {
    if let tail = self.tail, !tail.isFull {
      return tail.base + tail.count
    }
    return self.prepareSlot()
  }

  @inlinable
  @inline(never)
  mutating func prepareSlot() -> UnsafeMutablePointer<Element> {
    let blockCapacity = Int(self.blockCapacityBits)
    if let tail = self.tail {
      if tail.previous != nil {
        // Frozen blocks precede the tail's own elements, so the tail cannot seal as it is:
        // everything in the region is laid out again into full blocks and a fresh tail.
        self.compactTail(open: nil)
      } else if tail.count == blockCapacity {
        // Sealed at the next open rather than when it filled, so the open element was always
        // in the tail. The block object moves into the spine; the elements do not move.
        self.blocks.append(tail)
        self.tail = nil
      } else if tail.isFull {
        // The small first tail, promoted to a full block. Nothing points into the tail here:
        // the last element is closed and the next has not opened, and the tail is unique by
        // the contract above.
        self.tail = tail.moved(capacity: blockCapacity)
      }
    }
    if self.tail == nil {
      self.tail = StreamBlock.make(
        capacity: self.blocks.isEmpty ? Swift.min(Self.initialTailCapacity, blockCapacity) : blockCapacity
      )
    }
    let tail = self.tail.unsafelyUnwrapped
    return tail.base + tail.count
  }

  // Makes the tail safe to write, with the last element treated as open when `open` says so:
  // a tail a snapshot shares is frozen where it is and a fresh tail takes over, holding a copy
  // of the open element if there is one. Nothing else is copied. Asked before the block is
  // bound to a local: a bound reference is a second owner, and the check would answer "shared"
  // every time.
  //
  // The fresh tail links to the old one as its predecessor unless the old one contributed no
  // closed elements -- a snapshot taken inside the first element of a block, per byte, would
  // otherwise grow a chain of empty links -- and once the chain holds a block's worth of
  // elements it is compacted (`compactTail`), so a chain is always shorter than a block. That
  // bounds the reads that walk it and the recursion that releases it.
  //
  // Out of line: the unique case is settled by the callers with one runtime call, and this body
  // inlined into every container entry cost GitHub and GSoC 7-8% of their gain.
  @inlinable
  @inline(never)
  mutating func freezeTail(open: Bool) -> UnsafeMutablePointer<Element>? {
    guard let tail = self.tail else { return nil }
    let closed = open ? Swift.max(tail.count &- 1, 0) : tail.count
    if tail.previousTotal &+ closed >= Int(self.blockCapacityBits) {
      return self.compactTail(open: open && tail.count > 0 ? tail.base + closed : nil)
    }
    // A snapshot inside an open element, taken again and again -- a state kept per chunk as it
    // streams -- interrupts a tail that holds nothing but that element. Such a tail carries no
    // live elements once the open one is copied out, so it is kept as the fresh tail's spare and
    // becomes the fresh tail itself the next time round, once the snapshot that held it is gone.
    // Otherwise the tail joins the chain and a block is allocated.
    let fresh = tail.takeSpare() ?? StreamBlock<Element>.make(
      capacity: Swift.min(Self.initialTailCapacity, Int(self.blockCapacityBits))
    )
    if closed > 0 {
      fresh.previous = tail
      fresh.previousTotal = tail.previousTotal &+ closed
    } else {
      fresh.previous = tail.previous
      fresh.previousTotal = tail.previousTotal
      fresh.spare = tail
    }
    var slot: UnsafeMutablePointer<Element>? = nil
    if open, tail.count > 0 {
      _streamCopyInitialize(fresh.base, from: UnsafePointer(tail.base + closed))
      fresh.count = 1
      slot = fresh.base
    }
    self.tail = fresh
    return slot
  }

  // Lays the tail region out again: the frozen chain's elements and the tail's closed ones,
  // in order, copied into full blocks that seal and a fresh tail for the remainder -- then the
  // open element, if `open` names one, copied after them. Returns the open element's new address.
  // Copies, never moves, because the old blocks may be a snapshot's; and only the chain's
  // logical elements, never a frozen tail's stale open element.
  @inlinable
  @inline(never)
  mutating func compactTail(open: UnsafePointer<Element>?) -> UnsafeMutablePointer<Element>? {
    guard let tail = self.tail else { return nil }
    let blockCapacity = Int(self.blockCapacityBits)
    // The chain, oldest first, each with its logical count.
    var segments: [(base: UnsafePointer<Element>, count: Int)] = []
    var successorTotal = tail.previousTotal
    var link = tail.previous
    while let block = link {
      segments.append((UnsafePointer(block.base), successorTotal &- block.previousTotal))
      successorTotal = block.previousTotal
      link = block.previous
    }
    segments.reverse()
    let closedInTail = open == nil ? tail.count : tail.count &- 1
    if closedInTail > 0 { segments.append((UnsafePointer(tail.base), closedInTail)) }

    var fresh = StreamBlock<Element>.make(capacity: blockCapacity)
    for segment in segments {
      var taken = 0
      while taken < segment.count {
        let room = blockCapacity &- fresh.count
        let take = Swift.min(room, segment.count &- taken)
        (fresh.base + fresh.count).initialize(from: segment.base + taken, count: take)
        fresh.count &+= take
        taken &+= take
        if fresh.count == blockCapacity {
          self.blocks.append(fresh)
          fresh = StreamBlock<Element>.make(capacity: blockCapacity)
        }
      }
    }
    var slot: UnsafeMutablePointer<Element>? = nil
    if let open {
      slot = fresh.base + fresh.count
      _streamCopyInitialize(slot.unsafelyUnwrapped, from: open)
      fresh.count &+= 1
    }
    self.tail = fresh
    return slot
  }

  // The public mutators' door: a shared tail is frozen, nothing is copied.
  @inlinable
  mutating func ensureUniqueTail() {
    if !isKnownUniquelyReferenced(&self.tail), self.tail != nil {
      _ = self.freezeTail(open: false)
    }
  }

  // The tail region owned outright, chain and all, for a write to an element in it that is not
  // the open one: a dictionary's repeated key, the subscript setter. Rare, and at most a block
  // of copying.
  @inlinable
  mutating func makeTailRegionUnique() {
    guard let tail = self.tail else { return }
    if tail.previous != nil || !isKnownUniquelyReferenced(&self.tail) {
      _ = self.compactTail(open: nil)
    }
  }

  // Appends in place, tail assumed unique (see `nextSlot`). Forced inline: left to the optimizer
  // this inlines into the small bulk number appender but stays an outlined call inside larger
  // loops -- the fused slice measured that call hiding two-thirds of the double-array win (+6%
  // observed where +22% was real), and the per-element append route pays it once per number.
  @inlinable
  @inline(__always)
  mutating func commit(_ element: Element) {
    let slot = self.nextSlot()
    slot.initialize(to: element)
    self.tail.unsafelyUnwrapped.count &+= 1
  }

  // Writes to a sealed block go through here, copying that one block when a snapshot shares it
  // and leaving every other block alone. This is the only door into sealed storage.
  @inlinable
  mutating func uniqueBlock(_ index: Int) -> StreamBlock<Element> {
    if !isKnownUniquelyReferenced(&self.blocks[index]) {
      let block = self.blocks[index]
      self.blocks[index] = block.copy(capacity: block.slotCapacity)
    }
    return self.blocks[index]
  }

  // The address of element `position`, with the block holding it made unique first: where the
  // parser writes a value that already exists (a dictionary's repeated key).
  @inlinable
  mutating func uniqueSlotAddress(_ position: Int) -> UnsafeMutableRawPointer {
    let sealed = self.sealedCount
    if position < sealed {
      let shift = Int(self.blockShiftBits)
      let block = self.uniqueBlock(position &>> shift)
      return UnsafeMutableRawPointer(block.base + (position & ((1 &<< shift) &- 1)))
    }
    let offset = position &- sealed
    precondition(offset < self.tailCount, "StreamArray index out of range")
    self.makeTailRegionUnique()
    return UnsafeMutableRawPointer(self.tailElementAddress(offset))
  }

  // The address of element `position` for reading: no copy, whatever shares the block.
  @inlinable
  func elementAddress(_ position: Int) -> UnsafeMutableRawPointer {
    let sealed = self.sealedCount
    if position < sealed {
      let shift = Int(self.blockShiftBits)
      return UnsafeMutableRawPointer(
        self.blocks[position &>> shift].base + (position & ((1 &<< shift) &- 1))
      )
    }
    let offset = position &- sealed
    precondition(offset < self.tailCount, "StreamArray index out of range")
    return UnsafeMutableRawPointer(self.tailElementAddress(offset))
  }
}

// MARK: - Collection

extension StreamArray: RandomAccessCollection, MutableCollection {
  public typealias Index = Int

  public var startIndex: Int { 0 }

  public var endIndex: Int {
    self.sealedCount &+ self.tailCount
  }

  public subscript(position: Int) -> Element {
    get {
      self.elementAddress(position).assumingMemoryBound(to: Element.self).pointee
    }
    set {
      self.uniqueSlotAddress(position).assumingMemoryBound(to: Element.self).pointee = newValue
    }
  }
}

extension StreamArray: RangeReplaceableCollection {
  // Rebuilt from a flat buffer, because a general splice cannot preserve the fixed block length
  // the subscript relies on. Nothing calls this while parsing; `append` is the one that matters
  // and it stays O(1) amortised.
  public mutating func replaceSubrange(
    _ subrange: Range<Int>,
    with newElements: some Collection<Element>
  ) {
    var flat = ContiguousArray<Element>()
    flat.reserveCapacity(self.count &- subrange.count &+ newElements.count)
    for position in self.startIndex..<subrange.lowerBound { flat.append(self[position]) }
    flat.append(contentsOf: newElements)
    for position in subrange.upperBound..<self.endIndex { flat.append(self[position]) }

    self.blocks.removeAll()
    self.tail = nil
    let blockCapacity = self.currentBlockCapacity
    var start = 0
    while start &+ blockCapacity <= flat.count {
      let block = StreamBlock<Element>.make(capacity: blockCapacity)
      flat.withUnsafeBufferPointer { buffer in
        block.base.initialize(from: buffer.baseAddress! + start, count: blockCapacity)
      }
      block.count = blockCapacity
      self.blocks.append(block)
      start &+= blockCapacity
    }
    if start < flat.count {
      let block = StreamBlock<Element>.make(capacity: blockCapacity)
      flat.withUnsafeBufferPointer { buffer in
        block.base.initialize(from: buffer.baseAddress! + start, count: flat.count &- start)
      }
      block.count = flat.count &- start
      self.tail = block
    }
  }

  public mutating func append(_ newElement: Element) {
    self.ensureUniqueTail()
    self.commit(newElement)
  }

  public mutating func reserveCapacity(_ minimumCapacity: Int) {
    precondition(minimumCapacity >= 0, "StreamArray capacity must not be negative")
    if self.isEmpty {
      self.blockShiftBits = Self.adaptiveBlockShift(for: minimumCapacity)
      self.blockCapacityBits = UInt16(1 &<< Int(self.blockShiftBits))
    }
    let shift = Int(self.blockShiftBits)
    let blockCapacity = Int(self.blockCapacityBits)
    // Only complete blocks enter the spine; the remainder belongs to `tail`. Rounding up would
    // make a small exact hint allocate a spine buffer that can never be used.
    self.blocks.reserveCapacity(minimumCapacity &>> shift)
    if self.blocks.isEmpty && self.tail == nil && minimumCapacity > 0 {
      self.tail = StreamBlock.make(capacity: Swift.min(minimumCapacity, blockCapacity))
    }
  }
}

// MARK: - Conformances

extension StreamArray: ExpressibleByArrayLiteral {
  public init(arrayLiteral elements: Element...) {
    self.init(elements)
  }
}

// Element wise, not structural: two arrays holding the same elements can differ in where the
// block boundaries fall, and they are the same array.
extension StreamArray: Equatable where Element: Equatable {
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.count == rhs.count && lhs.elementsEqual(rhs)
  }
}

extension StreamArray: Hashable where Element: Hashable {
  public func hash(into hasher: inout Hasher) {
    hasher.combine(self.count)
    for element in self { hasher.combine(element) }
  }
}

// Asserted rather than checked, because the blocks are objects: what makes sharing one safe is
// the rule that a shared block is never written (see the note at the top), not the type system.
extension StreamArray: @unchecked Sendable where Element: Sendable {}

extension StreamArray: CustomStringConvertible {
  public var description: String {
    "[" + self.map { "\($0)" }.joined(separator: ", ") + "]"
  }
}

#if !hasFeature(Embedded)
  // Without this a reflecting printer walks the blocks and the tail, which puts the internals into
  // every custom dump and every recorded snapshot.
  extension StreamArray: CustomReflectable {
    public var customMirror: Mirror {
      Mirror(self, unlabeledChildren: Array(self), displayStyle: .collection)
    }
  }

  // As an unkeyed container, so a partial encodes the way the array it stands in for would. Both
  // sides are outside the embedded subset, which is why they are guarded rather than unconditional.
  extension StreamArray: Encodable where Element: Encodable {
    public func encode(to encoder: any Encoder) throws {
      var container = encoder.unkeyedContainer()
      for element in self { try container.encode(element) }
    }
  }

  extension StreamArray: Decodable where Element: Decodable {
    public init(from decoder: any Decoder) throws {
      self.init()
      var container = try decoder.unkeyedContainer()
      if let count = container.count { self.reserveCapacity(count) }
      while !container.isAtEnd {
        self.append(try container.decode(Element.self))
      }
    }
  }
#endif

// MARK: - Bridging

extension Array {
  public init(_ streamArray: StreamArray<Element>) {
    self.init()
    self.reserveCapacity(streamArray.count)
    for element in streamArray { self.append(element) }
  }
}

extension StreamArray: StreamInitializable {
  public static func streamInitialValue() -> Self { Self() }
}

extension StreamArray: StreamParseableRoot, StreamContainerPartial
where Element: StreamParseableRoot {
  public static var streamSchema: StreamSchema {
    _streamArraySchema(Element.self, element: Element.streamElementSchema)
  }

  // Generic types cannot hold a stored static, so `streamInitialValue()` above is a real `Self()`
  // every time rather than a load from a cached template the way a macro-generated partial's is,
  // and forming `Array<Element>` for the empty spine goes through the runtime's locking
  // generic-metadata cache. A container holding these as elements should hoist.
  @inlinable
  public static var _streamInitialValueIsExpensive: Bool { true }

  /// A borrowed window onto the array, for reading elements or spans of elements without
  /// copying the whole array or any element in it.
  ///
  /// Every element, the open one included, lives in a block, so `sealedBlock(_:)` and `tail`
  /// read them through a `Span` built the same way `Array.span` builds its own. The open element
  /// is the last element of `tail` while the parser is inside it.
  public struct View: ~Copyable, ~Escapable {
    @usableFromInline let storage: UnsafeMutablePointer<StreamArray<Element>>

    @_lifetime(borrow storage)
    @usableFromInline
    init(_ storage: UnsafeMutableRawPointer) {
      self.storage = storage.assumingMemoryBound(to: StreamArray<Element>.self)
    }

    /// The number of elements, including the open one if there is one.
    @inlinable
    public var count: Int { self.storage.pointee.count }

    /// A copy of the whole array, for callers that want an escaping snapshot rather than
    /// zero-copy access. The blocks are retained, not copied -- and the copy is recorded, so the
    /// parser knows to stop writing into blocks this copy now holds (see `_streamValueCopied`).
    @inlinable
    public var value: StreamArray<Element> {
      _streamValueCopied()
      return self.storage.pointee
    }

    /// The number of full, sealed blocks. Blocks within one array have a uniform size — see
    /// ``sealedBlock(_:)``.
    @inlinable
    public var sealedBlockCount: Int { self.storage.pointee.blocks.count }

    /// A zero-copy window onto one full, sealed block of elements.
    @_lifetime(borrow self)
    public func sealedBlock(_ blockIndex: Int) -> Span<Element> {
      let block = self.storage.pointee.blocks[blockIndex]
      let buffer = UnsafeBufferPointer(start: block.base, count: block.count)
      return _overrideLifetime(Span(_unsafeElements: buffer), borrowing: self)
    }

    /// A zero-copy window onto the elements in the filling block, the open element (if there is
    /// one) last. Elements a snapshot froze ahead of the filling block (see the note at the top
    /// of the file) are not in this span; the subscript reaches them.
    public var tail: Span<Element> {
      @_lifetime(borrow self)
      get {
        let buffer: UnsafeBufferPointer<Element>
        if let block = self.storage.pointee.tail {
          buffer = UnsafeBufferPointer(start: block.base, count: block.count)
        } else {
          buffer = UnsafeBufferPointer(start: nil, count: 0)
        }
        return _overrideLifetime(Span(_unsafeElements: buffer), borrowing: self)
      }
    }

    /// A view onto the element at `index`, or `nil` when `index` is out of bounds.
    ///
    /// Dispatches into a sealed block or the tail — whichever holds `index` — without copying
    /// it, the same way a macro-generated field accessor does.
    public subscript(index: Int) -> Element.View? {
      @_lifetime(borrow self)
      get {
        // Address first, view once. See the note on `StreamDictionary.View.subscript(_:)`:
        // forming an `Element.View` per dispatch branch crashes
        // PredictableDeadAllocationElimination on Swift 6.3 (fixed in 6.4), so every branch
        // yields a plain escapable address and the single exit turns it into a view.
        let address: UnsafeMutableRawPointer? =
          index < 0 || index >= self.count ? nil : self.storage.pointee.elementAddress(index)
        guard let address else { return nil }
        return _overrideLifetime(Element.streamView(address), borrowing: self)
      }
    }
  }

  @_lifetime(borrow storage)
  public static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
    View(storage)
  }
}

extension StreamArray: StreamParseable where Element: StreamParseableRoot {
  public typealias Partial = Self

  public var streamPartialValue: Self { self }
}

// MARK: - Parsing support

extension StreamArray {
  /// Opens a new element holding `initial`, returning the address of its slot.
  ///
  /// Underscored because only the frame entry helpers have a reason to call it. The returned
  /// pointer stays valid until the next call, which is what the sink guarantees by resolving an
  /// element's destination once per element rather than once per token. For the scalar kinds the
  /// sink opens directly; a partial of any size opens through ``_openElement(copying:)``. The
  /// tail must be unique: ``_prepareForWrites()`` once on entering the array settles that.
  @inlinable
  @inline(__always)
  @discardableResult
  public mutating func _openElement(_ initial: Element) -> UnsafeMutableRawPointer {
    let slot = self.nextSlot()
    slot.initialize(to: initial)
    self.tail.unsafelyUnwrapped.count &+= 1
    return UnsafeMutableRawPointer(slot)
  }

  /// Opens a new element copy-initialised from `template`, returning the address of its slot.
  ///
  /// One `initializeWithCopy` from the template's address into the slot and nothing else: the
  /// element is never materialised anywhere but where it will live. A template produced by a
  /// closure or an autoclosure would first be returned by value into a temporary, which for a
  /// partial of a few kilobytes is a second whole-element copy per element. The template must
  /// outlive every call; the schema builders allocate theirs once per schema and never free it.
  @inlinable
  @inline(__always)
  public mutating func _openElement(copying template: UnsafePointer<Element>) -> UnsafeMutableRawPointer {
    let slot = self.nextSlot()
    _streamCopyInitialize(slot, from: template)
    self.tail.unsafelyUnwrapped.count &+= 1
    return UnsafeMutableRawPointer(slot)
  }

  /// Makes the tail safe to write into: called by the sink when it enters the array, which is
  /// what lets every open after it skip the uniqueness check (see `nextSlot`). A tail a snapshot
  /// or a caller's copy shares is frozen in place; nothing is copied.
  @inlinable
  public mutating func _prepareForWrites() {
    self.ensureUniqueTail()
  }

  /// The address of the open element -- the last one -- safe to write into, or nil when there is
  /// none. For ``PartialSink/reseat()``: after a snapshot has shared the tail, the tail is frozen
  /// where it is and the open element alone is copied into a fresh one, so a snapshot costs one
  /// element, not one block.
  @inlinable
  public mutating func _reopenElement() -> UnsafeMutableRawPointer? {
    if isKnownUniquelyReferenced(&self.tail) {
      guard let tail = self.tail, tail.count > 0 else { return nil }
      return UnsafeMutableRawPointer(tail.base + (tail.count &- 1))
    }
    return self.freezeTail(open: true).map { UnsafeMutableRawPointer($0) }
  }

  /// The address of element `position`, with the block holding it made unique first. For a
  /// value that is written again where it already is: a dictionary's repeated key.
  @inlinable
  public mutating func _uniqueSlotAddress(_ position: Int) -> UnsafeMutableRawPointer {
    self.uniqueSlotAddress(position)
  }

  /// The address of element `position`, for reading through a view: no copy is made.
  @inlinable
  public func _elementAddress(_ position: Int) -> UnsafeMutableRawPointer {
    self.elementAddress(position)
  }
}
