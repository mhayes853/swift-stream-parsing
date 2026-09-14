// Array storage the parser can hold a pointer into, and that a snapshot can copy without copying
// the elements.
//
// Everything left of the parse cursor is immutable: once an element is closed it never changes.
// `Array` cannot express that, because any divergence from a shared buffer copies all of it, so
// keeping a value while parsing continues costs a full rebuild per snapshot.
//
// Three pieces make that cheap here:
//
// - **The open element lives inline, in `pending`.** It is the one piece of storage the parser
//   writes that a snapshot taken mid-element also reads, so it is the one piece that has to
//   diverge -- and holding it inline makes a plain value copy diverge it, for free, with no
//   allocation and no bookkeeping. Holding it in the storage instead means buying that
//   divergence back with a heap block per retained snapshot, which is what the frozen-tail
//   chain that used to be here did. The inline slot costs one whole-element move per element
//   (the closed one, into its slot, when the next opens); the chain cost a malloc per snapshot
//   and could not be made to cost less.
// - **Closed elements live in uniform power-of-two blocks, and a shared block is written past,
//   not copied.** Each array holds its own `tailCount`, captured by value when the array is
//   copied, so a snapshot's elements are a prefix of the filling block's. The parser appends
//   above that prefix -- memory no snapshot reads -- so there is no copy-on-write check on the
//   commit path at all, at any block size. Only a write *into* the prefix (the checked
//   subscript, a repeated dictionary key in a sealed block) copies, and copies one block.
// - **The parser's write target never moves.** `pending` is at a fixed offset in the value, and
//   the value sits in storage the stream owns for its lifetime, so the address the sink is
//   handed when an element opens stays correct however the blocks behind it grow, seal or are
//   copied. That is what lets the sink resolve a destination once per element rather than
//   re-derive it per parse call.
//
// A plain value copy is therefore already a correct snapshot, which is why nothing here has a
// `streamSnapshot()`.
public struct StreamArray<Element> {
  // Sealed and never written again except through the checked subscript, which copies the block
  // it writes when anything else can see it. Every block in an instance holds its chosen
  // capacity, which keeps indexing a shift and a mask rather than a search over prefix sums.
  @usableFromInline var blocks: [StreamBlock<Element>]

  // The filling block. Nil until the first element, so an empty array allocates nothing and
  // copies nothing. Its first allocation is deliberately smaller than the chosen block capacity;
  // it grows once if needed, while every tail after the first sealed block starts at full size.
  // A full tail is sealed when the *next* element is committed rather than when it fills.
  @usableFromInline var tail: StreamBlock<Element>?

  // The open element: the one the parser is inside, held outside the blocks so that copying the
  // array diverges it. Logically the last element -- index `sealedCount + tailCount` -- for
  // every read, including a view's. Nil between parses and for an array nothing is parsing into.
  @usableFromInline var pending: Element?

  // This array's own elements in `tail`, as opposed to the block's high-water mark, which
  // belongs to whichever array is filling it and may be ahead of this one. Copied by value with
  // the array, which is what makes appending into a shared block safe: see `StreamBlockHeader`.
  @usableFromInline var tailCount: Int

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

  // The ceiling every shift below is clamped to: 512 elements, which is where a block stops
  // being a granularity choice and starts being a large allocation to copy.
  @usableFromInline static var maximumBlockShift: Int { 9 }

  // ceil(log2(stride)), so a byte budget divided by it is a bound rather than an average.
  // `stride == 1` is spelled out rather than left to `(0).leadingZeroBitCount == Int.bitWidth`
  // cancelling the subtraction to zero.
  @usableFromInline static var strideShift: Int {
    let stride = MemoryLayout<Element>.stride
    return stride == 1 ? 0 : Int.bitWidth &- (stride &- 1).leadingZeroBitCount
  }

  // A block is what a write into a shared block copies, so its size in bytes is bounded: no cap
  // while an element is at most 512 bytes, then a shift that keeps a block near 16 KB. Blocks of
  // two are the floor. Folds to a constant per element type.
  @usableFromInline static var strideBlockShiftCap: Int {
    guard MemoryLayout<Element>.stride > 512 else { return Self.maximumBlockShift }
    return Swift.max(14 &- Self.strideShift, 1)
  }

  // The block size an array with no capacity hint uses.
  //
  // 32 elements is the granularity the snapshot semantics were designed around, and it is what a
  // partial of a few hundred bytes wants: a block is what a write into a shared block copies and
  // what a half-filled tail wastes. It is the wrong size for a *small* element, though. A block
  // is one malloc, `prepareSlot` is one out-of-line call, and a block of 32 doubles is 256 bytes
  // -- so a flat array of ten thousand numbers pays a malloc every 256 bytes of payload. That
  // showed up directly: `prepareSlot` was 4.0% of typed Mesh and 3.0% of typed Canada, all of it
  // under the number-array and SIMD-pair element opens.
  //
  // So: for a trivial element of at most sixteen bytes, aim the block at `blockByteShift` bytes'
  // worth of elements instead of at 32 elements. Doubles and `Int`s get 256-element (2 KB)
  // blocks, `SIMD2<Double>` 128-element ones, and everything else keeps exactly the size it had.
  //
  // The sixteen-byte ceiling is not arithmetic, it is measured. Raising it to 64 covered small
  // POD *partials* too -- a dictionary's value blocks, for instance -- and cost CITM 1.2% for no
  // gain anywhere: those containers hold tens of elements, not thousands, so the larger block is
  // a 2 KB allocation they never fill instead of a malloc they never repeat. Sixteen bytes is
  // exactly the width of the elements that come in their thousands (a number, a coordinate
  // pair), which is where the malloc traffic actually was.
  //
  // Folds to a constant per element type: every term is a compile-time property of `Element`.
  //
  // Spelled as a shift, which is the only form the byte target was ever used in: 2 KB.
  @usableFromInline static var blockByteShift: Int { 11 }

  @usableFromInline static var defaultBlockCapacity: Int { 1 &<< Self.defaultBlockShift }

  @usableFromInline static var defaultBlockShift: Int {
    let base = Swift.min(Self.blockShift, Self.strideBlockShiftCap)
    let stride = MemoryLayout<Element>.stride
    // Non-trivial elements are left alone: their blocks carry a destroy loop, and the reason to
    // grow a block is malloc traffic the destroy loop dwarfs anyway.
    guard _isPOD(Element.self), stride > 0, stride <= 16 else { return base }
    return Swift.max(
      base,
      Swift.min(
        Self.maximumBlockShift, Self.strideBlockShiftCap, Self.blockByteShift &- Self.strideShift
      )
    )
  }

  public init() {
    self.blocks = []
    self.tail = nil
    self.pending = nil
    self.tailCount = 0
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

  @inlinable var currentBlockCapacity: Int { Int(self.blockCapacityBits) }

  // `@inlinable`, not merely `@usableFromInline`: `StreamDictionary.drainPending` is inlinable and
  // specialises in the *client* module, and a `@usableFromInline` body does not travel with it.
  // At b01cfd6 the specialised `drainPending` called the unspecialised, generic
  // `StreamArray.sealedCount.getter` once per dictionary key -- a runtime-metadata call to read
  // `blocks.count`, and a barrier the surrounding loads could not be folded across.
  @inlinable
  var sealedCount: Int {
    // Against the *default* shift, not the fixed 32: the default is still a per-element-type
    // constant, and it is the shift every array that was never given a capacity hint carries.
    if _fastPath(self.blockShiftBits == UInt8(Self.defaultBlockShift)) {
      return self.blocks.count &<< Self.defaultBlockShift
    }
    return self.blocks.count &<< Int(self.blockShiftBits)
  }

  // The elements that are in blocks. The open one is not among them.
  @inlinable
  var closedCount: Int { self.sealedCount &+ self.tailCount }

  @usableFromInline
  static func adaptiveBlockShift(for minimumCapacity: Int) -> UInt8 {
    // Aim for roughly 64 sealed allocations. The clamps retain the established snapshot
    // granularity for ordinary arrays and bound the amount copied by a write into a shared
    // block. `minimumCapacity / 64` avoids overflowing for capacities near Int.max.
    let desired = minimumCapacity / 64 + (minimumCapacity % 64 == 0 ? 0 : 1)
    // Against the default capacity rather than the fixed 32: the `max(defaultBlockShift, ...)`
    // below floors the result at the default anyway, so every `desired` between the two
    // thresholds already answered `defaultBlockShift` -- this just stops computing it.
    guard desired > Self.defaultBlockCapacity else { return UInt8(Self.defaultBlockShift) }
    let roundedShift = Int.bitWidth &- (desired &- 1).leadingZeroBitCount
    // Never below the default: a hint is a statement that the array will be *large*, and a small
    // element's default block is already chosen for a large array. Without the floor a hint of a
    // few thousand doubles would ask for smaller blocks than the same array gets with no hint
    // at all.
    return UInt8(
      Swift.max(
        Self.defaultBlockShift,
        Swift.min(Self.maximumBlockShift, roundedShift, Self.strideBlockShiftCap)
      )
    )
  }

  // MARK: Slots

  // The address the next closed element is initialised at, with the tail made ready for it:
  // sealed if full, grown if it is the small first tail, allocated if there is none. The common
  // case -- a tail with room -- is two loads and a compare.
  //
  // No uniqueness check: the slot is above this array's own count, so no copy of this array can
  // reach it. See the note on `StreamBlockHeader.count`.
  @inlinable
  @inline(__always)
  mutating func nextSlot() -> UnsafeMutablePointer<Element> {
    if let tail = self.tail, self.tailCount < tail.slotCapacity {
      return tail.base + self.tailCount
    }
    return self.prepareSlot()
  }

  @inlinable
  @inline(never)
  mutating func prepareSlot() -> UnsafeMutablePointer<Element> {
    let blockCapacity = Int(self.blockCapacityBits)
    if self.tail != nil {
      if self.tailCount == blockCapacity {
        // The block object moves into the spine; the elements do not move.
        self.blocks.append(self.tail.unsafelyUnwrapped)
        self.tail = nil
        self.tailCount = 0
      } else {
        // The small first tail, promoted to a full block. Moved when nothing else holds it,
        // copied when something does -- asked before the block is bound to a local, since a
        // bound reference is a second owner and the check would answer "shared" every time.
        let unique = isKnownUniquelyReferenced(&self.tail)
        let old = self.tail.unsafelyUnwrapped
        let count = self.tailCount
        self.tail =
          unique
          ? old.moved(count: count, capacity: blockCapacity)
          : old.copy(count: count, capacity: blockCapacity)
      }
    }
    if self.tail == nil {
      self.tail = StreamBlock.make(
        capacity: self.blocks.isEmpty
          ? Swift.min(Self.initialTailCapacity, blockCapacity) : blockCapacity
      )
    }
    return self.tail.unsafelyUnwrapped.base + self.tailCount
  }

  // Records a slot written by `nextSlot` as this array's, and as initialised in the block.
  @inlinable
  @inline(__always)
  mutating func advance() {
    self.tailCount &+= 1
    self.tail.unsafelyUnwrapped.count = self.tailCount
  }

  // Appends in place. Forced inline: left to the optimizer this inlines into the small bulk
  // number appender but stays an outlined call inside larger loops -- the fused slice measured
  // that call hiding two-thirds of the double-array win (+6% observed where +22% was real).
  @inlinable
  @inline(__always)
  mutating func commit(_ element: Element) {
    let slot = self.nextSlot()
    slot.initialize(to: element)
    self.advance()
  }

  // Moves the open element into its slot, leaving no open element. One whole-element move, and
  // the optional's tag is written once here rather than per element -- `_openElement` fuses this
  // with the next open and leaves the tag alone.
  @inlinable
  @inline(__always)
  mutating func drainPending() {
    guard self.pending != nil else { return }
    let slot = self.nextSlot()
    withUnsafeMutablePointer(to: &self.pending) { box in
      slot.moveInitialize(
        from: UnsafeMutableRawPointer(box).assumingMemoryBound(to: Element.self),
        count: 1
      )
      // The payload has been moved out; this re-marks the slot empty without destroying it a
      // second time. A single-payload enum keeps its payload at offset zero, so `.some`'s bits
      // are the element's bits.
      box.initialize(to: nil)
    }
    self.advance()
  }

  // Appends past the open element, which is what every path other than the parser wants: a user
  // appending to a parsed array adds after it rather than replacing it.
  //
  // `@inline(__always)`: at this size the optimizer left it outlined, and `_appendClosed` -- which
  // is this function, per element of a homogeneous number array -- measured worse with a `bl` and
  // a frame per element than the `_openElement` round trip it replaced. Both halves are
  // `@inline(__always)` too, so every caller gets straight-line code.
  @inlinable
  @inline(__always)
  mutating func appendSealed(_ element: Element) {
    self.drainPending()
    self.commit(element)
  }

  // MARK: Uniqueness

  // Writes into elements this array already has go through here, copying the one block they
  // land in when anything else can see it and leaving every other block alone.
  @inlinable
  mutating func uniqueBlock(_ index: Int) -> StreamBlock<Element> {
    if !isKnownUniquelyReferenced(&self.blocks[index]) {
      let block = self.blocks[index]
      self.blocks[index] = block.copy(count: block.count, capacity: block.slotCapacity)
    }
    return self.blocks[index]
  }

  // The same for the filling block. Only a write into an element this array already holds needs
  // it; appending never does.
  @inlinable
  mutating func ensureUniqueTail() {
    guard self.tail != nil, !isKnownUniquelyReferenced(&self.tail) else { return }
    let old = self.tail.unsafelyUnwrapped
    self.tail = old.copy(count: self.tailCount, capacity: old.slotCapacity)
  }

  // MARK: Locating

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
    if offset == self.tailCount {
      precondition(self.pending != nil, "StreamArray index out of range")
      return withUnsafeMutablePointer(to: &self.pending) { UnsafeMutableRawPointer($0) }
    }
    precondition(offset < self.tailCount, "StreamArray index out of range")
    self.ensureUniqueTail()
    return UnsafeMutableRawPointer(self.tail.unsafelyUnwrapped.base + offset)
  }

  // The address of element `position` for reading: no copy, whatever shares the block. Mutating
  // only because the open element's address is a projection of `pending`.
  @inlinable
  mutating func elementAddress(_ position: Int) -> UnsafeMutableRawPointer {
    let sealed = self.sealedCount
    if position < sealed {
      let shift = Int(self.blockShiftBits)
      return UnsafeMutableRawPointer(
        self.blocks[position &>> shift].base + (position & ((1 &<< shift) &- 1))
      )
    }
    let offset = position &- sealed
    if offset < self.tailCount {
      return UnsafeMutableRawPointer(self.tail.unsafelyUnwrapped.base + offset)
    }
    precondition(offset == self.tailCount && self.pending != nil, "StreamArray index out of range")
    return withUnsafeMutablePointer(to: &self.pending) { UnsafeMutableRawPointer($0) }
  }
}

// MARK: - Collection

extension StreamArray: RandomAccessCollection, MutableCollection {
  public typealias Index = Int

  public var startIndex: Int { 0 }

  public var endIndex: Int {
    self.closedCount &+ (self.pending == nil ? 0 : 1)
  }

  // `@inlinable` so a client-module specialisation (a repeated dictionary key resuming its stored
  // value) reads the element directly instead of calling the unspecialised generic getter through
  // instantiated metadata.
  @inlinable
  public subscript(position: Int) -> Element {
    get {
      let sealed = self.sealedCount
      if position < sealed {
        let shift = Int(self.blockShiftBits)
        return (self.blocks[position &>> shift].base + (position & ((1 &<< shift) &- 1))).pointee
      }
      let offset = position &- sealed
      if offset < self.tailCount { return (self.tail.unsafelyUnwrapped.base + offset).pointee }
      precondition(
        offset == self.tailCount && self.pending != nil, "StreamArray index out of range"
      )
      return self.pending.unsafelyUnwrapped
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
    self.tailCount = 0
    self.pending = nil
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
      self.tailCount = flat.count &- start
    }
  }

  public mutating func append(_ newElement: Element) {
    self.appendSealed(newElement)
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
// the rule that a block is only ever written above the count every sharer captured (see the note
// at the top), not the type system.
extension StreamArray: @unchecked Sendable where Element: Sendable {}

extension StreamArray: CustomStringConvertible {
  public var description: String {
    "[" + self.map { "\($0)" }.joined(separator: ", ") + "]"
  }
}

#if !hasFeature(Embedded)
  // Without this a reflecting printer walks the blocks, the tail and the pending slot, which puts
  // the internals into every custom dump and every recorded snapshot.
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
  // `@inlinable` so a client that roots a parse at `StreamArray<Element>` builds the schema --
  // and therefore the `appendElement` closure inside it -- in its own module, where `Element` is
  // concrete and the closure body specialises. Without it the whole body is emitted once here,
  // generically: every `_openElement` in the closure goes through `Element`'s value witnesses and
  // `Optional<Element>`'s runtime-instantiated metadata. Measured on a root `StreamDictionary`
  // (the same shape, below): ~2.9% of the parse in `swift_getGenericMetadata`/`getCache` alone,
  // plus a generic single-payload-enum `assignWithTake` per key. A macro-generated partial never
  // hit this because its container schemas are built at the use site already.
  //
  // Cached per element type (`_streamCachedSchema`), because this is a *computed* property and
  // `PartialsStream.init` reads it: every stream rooted at an array rebuilt the whole schema,
  // template allocation included. The `@inlinable` stays -- the closure handed to the cache is
  // formed here, at the use site, so it still specialises; only the probe is out of line.
  @inlinable
  public static var streamSchema: StreamSchema {
    _streamCachedSchema(for: Self.self) {
      _streamArraySchema(Element.self, element: Element.streamElementSchema)
    }
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
  /// The closed elements live in blocks, so `sealedBlock(_:)` and `tail` read them through a
  /// `Span` built the same way `Array.span` builds its own. The open element is not in either;
  /// the subscript reaches it as the last element.
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
    /// zero-copy access. The blocks are retained, not copied; the open element is copied, which
    /// is what makes the copy stable while parsing continues.
    @inlinable
    public var value: StreamArray<Element> { self.storage.pointee }

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

    /// A zero-copy window onto the closed elements in the filling block. The open element is not
    /// among them — it is held outside the blocks — and the subscript reaches it.
    public var tail: Span<Element> {
      @_lifetime(borrow self)
      get {
        let buffer: UnsafeBufferPointer<Element>
        if let block = self.storage.pointee.tail {
          buffer = UnsafeBufferPointer(start: block.base, count: self.storage.pointee.tailCount)
        } else {
          buffer = UnsafeBufferPointer(start: nil, count: 0)
        }
        return _overrideLifetime(Span(_unsafeElements: buffer), borrowing: self)
      }
    }

    /// A view onto the element at `index`, or `nil` when `index` is out of bounds.
    ///
    /// Dispatches into a sealed block, the filling block or the open element — whichever holds
    /// `index` — without copying it, the same way a macro-generated field accessor does.
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
  /// Commits the open element and opens a new one holding `initial`, returning the address of
  /// its slot.
  ///
  /// Underscored because only the frame entry helpers have a reason to call it. The returned
  /// pointer stays valid until the next call, which is what the sink guarantees by resolving an
  /// element's destination once per element rather than once per token.
  @inlinable
  @inline(__always)
  @discardableResult
  public mutating func _openElement(_ initial: Element) -> UnsafeMutableRawPointer {
    self.drainPending()
    self.pending = initial
    return withUnsafeMutablePointer(to: &self.pending) { UnsafeMutableRawPointer($0) }
  }

  /// The same, copy-initialising the new element from `template`.
  ///
  /// Two whole-element copies and nothing else: the closed element moves into its slot, and the
  /// new one is copy-initialised into the space it vacated. Neither is materialised anywhere
  /// else -- a template passed or returned by value would be a third copy per element, and for a
  /// partial of a few kilobytes that is worth measuring. The optional's tag is not touched: it
  /// says `.some` on the way in and on the way out, so there is no enum injection on this path
  /// and the payload is uninitialised only between the two statements below, which nothing can
  /// observe and nothing between them can throw. The template must outlive every call; the
  /// schema builders allocate theirs once per schema and never free it.
  @inlinable
  @inline(__always)
  public mutating func _openElement(
    copying template: UnsafePointer<Element>
  ) -> UnsafeMutableRawPointer {
    guard self.pending != nil else {
      // First element of this array, or the first after a public append: the tag has to be
      // written, so this is the one open that goes through the optional.
      self.pending = template.pointee
      return withUnsafeMutablePointer(to: &self.pending) { UnsafeMutableRawPointer($0) }
    }
    let slot = self.nextSlot()
    let address = withUnsafeMutablePointer(to: &self.pending) {
      box -> UnsafeMutableRawPointer in
      let payload = UnsafeMutableRawPointer(box).assumingMemoryBound(to: Element.self)
      slot.moveInitialize(from: payload, count: 1)
      _streamCopyInitialize(payload, from: template)
      return UnsafeMutableRawPointer(box)
    }
    self.advance()
    return address
  }

  /// The address the next appended element is initialised at, without counting it yet: for a
  /// caller that moves a value in rather than handing one over. ``_commitAppend()`` follows.
  @inlinable
  public mutating func _slotForAppend() -> UnsafeMutableRawPointer {
    UnsafeMutableRawPointer(self.nextSlot())
  }

  /// Counts the element written at ``_slotForAppend()``.
  @inlinable
  public mutating func _commitAppend() {
    self.advance()
  }

  /// The address of the open element, or nil when there is none.
  ///
  /// It never moves, so this is a projection of `pending` and nothing more.
  @inlinable
  public mutating func _openElementAddress() -> UnsafeMutableRawPointer? {
    guard self.pending != nil else { return nil }
    return withUnsafeMutablePointer(to: &self.pending) { UnsafeMutableRawPointer($0) }
  }

  /// The address of element `position`, with the block holding it made unique first. For a
  /// value that is written again where it already is: a dictionary's repeated key.
  @inlinable
  public mutating func _uniqueSlotAddress(_ position: Int) -> UnsafeMutableRawPointer {
    self.uniqueSlotAddress(position)
  }

  /// The address of element `position`, for reading through a view: no copy is made.
  @inlinable
  public mutating func _elementAddress(_ position: Int) -> UnsafeMutableRawPointer {
    self.elementAddress(position)
  }
}

// MARK: - Closed appends

extension StreamArray {
  /// Appends `element` as an already-closed element: it goes straight into its block slot and no
  /// open element is left behind.
  ///
  /// The whole-value routes use this. A number token is delivered to the sink exactly once and
  /// whole -- the parser buffers a number that straddles a chunk boundary and emits it at the
  /// closing byte (`emitBufferedNumber`) -- so there is no window in which a snapshot could
  /// observe a half-written element, which is the only thing `pending` buys. Going through
  /// `_openElement` instead cost, per element, a whole-element move out of `pending` into the
  /// slot, the `nil` tag written over the vacated payload, and the new value plus its `.some`
  /// tag written back into `pending`: four stores and a load-compare where this is one store.
  ///
  /// The `drainPending` ahead of the commit is a load, a compare and a never-taken branch on
  /// this route (nothing else opens an element in a homogeneous number array), and it is what
  /// keeps the element order right for an array a caller had already appended to by hand.
  @inlinable
  @inline(__always)
  public mutating func _appendClosed(_ element: Element) {
    // `appendSealed` is `@inline(__always)` for this call site's sake: left outlined it costs a
    // `bl` and a frame per element, which measured worse than the `_openElement` round trip this
    // route replaced.
    self.appendSealed(element)
  }
}
