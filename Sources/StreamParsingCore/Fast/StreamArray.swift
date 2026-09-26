// Array storage the parser can hold a pointer into, and that a snapshot copies without copying
// the elements. The open element lives inline in `pending`, so a value copy diverges it for free;
// closed elements live in power-of-two blocks, shared until a mutation needs to copy a block.
// Appending into a shared tail copies that tail first, so both copies can continue independently.
// `pending`'s address never moves while blocks seal. See NEW_ARCHITECTURE.md, "The open element
// moves into the storage".
public struct StreamArray<Element> {
  // Sealed; written again only through the checked subscript, which copies a shared block first.
  // Every block holds the chosen capacity, so indexing is a shift and a mask.
  @usableFromInline var blocks: [StreamBlock<Element>]

  // The filling block, made unique before writing. The first allocation is smaller than the block
  // capacity and grows once; later tails start full size. A full tail seals when the *next* element
  // commits, not when it fills.
  @usableFromInline var tail: StreamBlock<Element>?

  // The open element, held outside the blocks so copying the array diverges it. Logically element
  // `sealedCount + tailCount` for every read; nil when nothing is parsing into this array.
  @usableFromInline var pending: Element?

  // The number of initialized elements in this array's tail, kept inline for indexing.
  @usableFromInline var tailCount: Int

  // Chosen by capacity hints while the array is empty; a shift, so indexing needs no division.
  @usableFromInline var blockShiftBits: UInt8

  // Cached apart from the shift: the open path needs the capacity per element.
  @usableFromInline var blockCapacityBits: UInt16

  // Block capacities are powers of two, so the sealed count is `blocks.count << blockShift`.
  @usableFromInline static var initialTailCapacity: Int { 8 }
  @usableFromInline static var blockShift: Int { 5 }

  // The ceiling every shift is clamped to: past 512 elements a block is a large allocation to copy.
  @usableFromInline static var maximumBlockShift: Int { 9 }

  // ceil(log2(stride)), so a byte budget divided by it is a bound. `stride == 1` is spelled out
  // rather than relying on `(0).leadingZeroBitCount` cancelling the subtraction.
  @usableFromInline static var strideShift: Int {
    let stride = MemoryLayout<Element>.stride
    return stride == 1 ? 0 : Int.bitWidth &- (stride &- 1).leadingZeroBitCount
  }

  // Bounds what a write into a shared block copies: uncapped up to 512-byte elements, then near
  // 16 KB per block, never below two elements.
  @usableFromInline static var strideBlockShiftCap: Int {
    guard MemoryLayout<Element>.stride > 512 else { return Self.maximumBlockShift }
    return Swift.max(14 &- Self.strideShift, 1)
  }

  // The byte target (2 KB) a small trivial element's block aims at instead of 32 elements: `Double`
  // gets 256-element blocks, `SIMD2<Double>` 128. Measured: at 32, `prepareSlot` was 4.0% of typed
  // Mesh; a 64-byte element ceiling instead of 16 cost CITM 1.2%. See NEW_ARCHITECTURE.md.
  @usableFromInline static var blockByteShift: Int { 11 }

  @usableFromInline static var defaultBlockCapacity: Int { 1 &<< Self.defaultBlockShift }

  @usableFromInline static var defaultBlockShift: Int {
    let base = Swift.min(Self.blockShift, Self.strideBlockShiftCap)
    let stride = MemoryLayout<Element>.stride
    // Non-trivial elements keep the default: their destroy loop dwarfs the malloc saved.
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

  /// Creates an empty streaming array with storage reserved for at least `initialCapacity`
  /// elements, so large arrays use fewer internal allocations.
  public init(initialCapacity: Int) {
    self.init()
    self.reserveCapacity(initialCapacity)
  }

  public init(_ elements: some Sequence<Element>) {
    self.init()
    for element in elements { self.append(element) }
  }

  @inlinable var currentBlockCapacity: Int { Int(self.blockCapacityBits) }

  // `@inlinable`, not `@usableFromInline`: `StreamDictionary.drainPending` specialises in the
  // client module, and otherwise called this generic getter once per key through runtime metadata.
  @inlinable
  var sealedCount: Int {
    // Against the *default* shift: a per-element-type constant, carried by every unhinted array.
    if _fastPath(self.blockShiftBits == UInt8(Self.defaultBlockShift)) {
      return self.blocks.count &<< Self.defaultBlockShift
    }
    return self.blocks.count &<< Int(self.blockShiftBits)
  }

  // The elements in blocks; the open one is not among them.
  @inlinable
  var closedCount: Int { self.sealedCount &+ self.tailCount }

  @usableFromInline
  static func adaptiveBlockShift(for minimumCapacity: Int) -> UInt8 {
    // Aims for roughly 64 sealed allocations, clamped to bound what a write into a shared block
    // copies. `minimumCapacity / 64` cannot overflow near `Int.max`.
    let desired = minimumCapacity / 64 + (minimumCapacity % 64 == 0 ? 0 : 1)
    // The floor below makes every `desired` up to the default capacity answer the default anyway.
    guard desired > Self.defaultBlockCapacity else { return UInt8(Self.defaultBlockShift) }
    let roundedShift = Int.bitWidth &- (desired &- 1).leadingZeroBitCount
    // Never below the default: a hint says the array will be large, and a small element's default
    // block is already chosen for that.
    return UInt8(
      Swift.max(
        Self.defaultBlockShift,
        Swift.min(Self.maximumBlockShift, roundedShift, Self.strideBlockShiftCap)
      )
    )
  }

  // MARK: Slots

  // The address the next closed element is initialised at, sealing, growing or allocating the tail
  // as needed. A copy can also append at `tailCount`, so even writes beyond the current count
  // need ordinary CoW. Check uniqueness before binding the tail to a local reference.
  @inlinable
  @inline(__always)
  mutating func nextSlot() -> UnsafeMutablePointer<Element> {
    if self.tail != nil, self.tailCount < self.tail.unsafelyUnwrapped.slotCapacity {
      self.ensureUniqueTail()
      return self.tail.unsafelyUnwrapped.base + self.tailCount
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
        // The small first tail, promoted to a full block: moved when unique, copied when shared.
        // Asked before binding the block to a local, which would be a second owner.
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

  // Counts a slot written by `nextSlot` as this array's, and as initialised in the block.
  @inlinable
  @inline(__always)
  mutating func advance() {
    self.tailCount &+= 1
    self.tail.unsafelyUnwrapped.count = self.tailCount
  }

  // Forced inline. Measured: otherwise it stays an outlined call inside larger loops, which hid
  // two-thirds of the double-array win. See NEW_ARCHITECTURE.md.
  @inlinable
  @inline(__always)
  mutating func commit(_ element: Element) {
    let slot = self.nextSlot()
    slot.initialize(to: element)
    self.advance()
  }

  // Moves the open element into its slot. The optional's tag is written once here, not per
  // element: `_openElement(copying:)` fuses this with the next open and leaves the tag alone.
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
      // Re-marks the box empty without destroying the moved-out payload again; a single-payload
      // enum keeps its payload at offset zero.
      box.initialize(to: nil)
    }
    self.advance()
  }

  // Appends past the open element, which every caller but the parser wants. Measured:
  // `@inline(__always)` for `_appendClosed` -- outlined, a `bl` and a frame per element cost more
  // than the `_openElement` round trip that route replaced.
  @inlinable
  @inline(__always)
  mutating func appendSealed(_ element: Element) {
    self.drainPending()
    self.commit(element)
  }

  // MARK: Uniqueness

  // Writes into existing elements copy the one block they land in when it is shared.
  @inlinable
  mutating func uniqueBlock(_ index: Int) -> StreamBlock<Element> {
    if !isKnownUniquelyReferenced(&self.blocks[index]) {
      let block = self.blocks[index]
      self.blocks[index] = block.copy(count: block.count, capacity: block.slotCapacity)
    }
    return self.blocks[index]
  }

  // The same for the filling block, for both element replacement and appending.
  @inlinable
  mutating func ensureUniqueTail() {
    guard self.tail != nil, !isKnownUniquelyReferenced(&self.tail) else { return }
    let old = self.tail.unsafelyUnwrapped
    self.tail = old.copy(count: self.tailCount, capacity: old.slotCapacity)
  }

  // MARK: Locating

  // The address of element `position`, its block made unique first: a dictionary's repeated key.
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

  // The address of element `position` for reading, with no copy; mutating only because the open
  // element's address is a projection of `pending`.
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

  // `@inlinable` so a client-module specialisation (a repeated dictionary key resuming its value)
  // reads the element directly instead of through the generic getter.
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
  // Rebuilt from a flat buffer: a splice cannot keep the fixed block length. Never parse-time.
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
    // Only ever raises: an empty array can still own a `tail` from a larger earlier hint, and
    // dropping the schedule under it lets `moved(count:capacity:)` receive a count larger than its
    // destination block -- a heap overflow.
    if self.isEmpty {
      let shift = Self.adaptiveBlockShift(for: minimumCapacity)
      if 1 &<< Int(shift) >= (self.tail?.slotCapacity ?? 0) {
        self.blockShiftBits = shift
        self.blockCapacityBits = UInt16(1 &<< Int(shift))
      }
    }
    let shift = Int(self.blockShiftBits)
    let blockCapacity = Int(self.blockCapacityBits)
    // Only complete blocks enter the spine; rounding up wastes a spine on a small hint.
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

// Element-wise: arrays with the same elements are equal wherever their block boundaries fall.
extension StreamArray: Equatable where Element: Equatable {
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.elementsEqual(rhs)
  }
}

extension StreamArray: Hashable where Element: Hashable {
  public func hash(into hasher: inout Hasher) {
    hasher.combine(self.count)
    for element in self { hasher.combine(element) }
  }
}

// Asserted, not checked: every write into a shared block first makes that block unique,
// including writes to its initialized count. Independent values can therefore mutate safely.
extension StreamArray: @unchecked Sendable where Element: Sendable {}

#if !hasFeature(Embedded)
  // Interpolating an unconstrained `Element` is reflection, outside the Embedded subset.
  extension StreamArray: CustomStringConvertible {
    public var description: String {
      "[" + self.map { "\($0)" }.joined(separator: ", ") + "]"
    }
  }

  // Otherwise a reflecting printer dumps the blocks, the tail and the pending slot.
  extension StreamArray: CustomReflectable {
    public var customMirror: Mirror {
      Mirror(self, unlabeledChildren: Array(self), displayStyle: .collection)
    }
  }

  // An unkeyed container, encoding as the array it stands in for. Outside the Embedded subset.
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
  // `@inlinable` so a client rooting a parse here builds the schema, and the `appendElement`
  // closure in it, where `Element` is concrete. Measured: generic, ~2.9% of the parse in
  // `swift_getGenericMetadata`. Cached because `PartialsStream.init` reads this computed property;
  // the closure still forms at the use site. See NEW_ARCHITECTURE.md.
  @inlinable
  public static var streamSchema: StreamSchema {
    StreamSchemaCache.shared.schema(for: Self.self) {
      _streamArraySchema(Element.self, element: Element.streamArrayElementSchema)
    }
  }

  /// A borrowed window onto the array, for reading elements or spans of elements without copying
  /// the array or any element in it.
  ///
  /// Closed elements are read through `sealedBlock(_:)` and `tail`; the open element is in neither,
  /// and the subscript reaches it as the last element.
#if LifetimeView
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

    /// A copy of the whole array, for an escaping snapshot. The blocks are retained, not copied;
    /// the open element is copied, so the copy stays stable while parsing continues.
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
        // Address first, view once: a view per branch crashes PredictableDeadAllocationElimination
        // on Swift 6.3 (fixed in 6.4). See `StreamDictionary.View.subscript(_:)`.
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
#else
  /// An unsafe zero-copy window onto the array.
  ///
  /// The view may escape, so every access requires the caller to ensure that its originating
  /// stream is still alive and that parsing has not invalidated the addressed storage.
  @unsafe
  public struct View: ~Copyable {
    @usableFromInline let storage: UnsafeMutablePointer<StreamArray<Element>>

    @usableFromInline
    init(_ storage: UnsafeMutableRawPointer) {
      self.storage = storage.assumingMemoryBound(to: StreamArray<Element>.self)
    }

    /// The number of elements, including the open one if there is one.
    @inlinable
    public var count: Int { self.storage.pointee.count }

    /// A copy of the whole array, for an escaping snapshot.
    @inlinable
    public var value: StreamArray<Element> { self.storage.pointee }

    /// The number of full, sealed blocks.
    @inlinable
    public var sealedBlockCount: Int { self.storage.pointee.blocks.count }

    /// A zero-copy window onto one full, sealed block of elements.
    @_lifetime(borrow self)
    public func sealedBlock(_ blockIndex: Int) -> Span<Element> {
      let block = self.storage.pointee.blocks[blockIndex]
      let buffer = UnsafeBufferPointer(start: block.base, count: block.count)
      return _overrideLifetime(Span(_unsafeElements: buffer), borrowing: self)
    }

    /// A zero-copy window onto the closed elements in the filling block.
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
    public subscript(index: Int) -> Element.View? {
      let address: UnsafeMutableRawPointer? =
        index < 0 || index >= self.count ? nil : self.storage.pointee.elementAddress(index)
      guard let address else { return nil }
      return Element.streamView(address)
    }
  }

  @unsafe
  public static func streamView(_ storage: UnsafeMutableRawPointer) -> View {
    View(storage)
  }
#endif
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
  /// For the frame entry helpers. The pointer stays valid until the next call; the sink resolves
  /// an element's destination once per element.
  @inlinable
  @inline(__always)
  @discardableResult
  public mutating func _openElement(_ initial: Element) -> UnsafeMutableRawPointer {
    self.drainPending()
    self.pending = initial
    return withUnsafeMutablePointer(to: &self.pending) { UnsafeMutableRawPointer($0) }
  }

  /// Moves the closed element into its slot and copy-initialises the template into the space it
  /// vacated: two whole-element copies (a by-value template would be a third). The optional's tag
  /// says `.some` throughout, and nothing between the two statements can observe or throw. The
  /// template must outlive every call; the schema builders allocate one per schema, never freed.
  @inlinable
  @inline(__always)
  public mutating func _openElement(
    copying template: UnsafePointer<Element>
  ) -> UnsafeMutableRawPointer {
    guard self.pending != nil else {
      // The first open, or the first after a public append: the tag must be written.
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

  /// The same open, initialising the vacated space with `initial` rather than a copy of a
  /// template: for an element whose copy costs more than its construction
  /// (`StreamParseableRoot._streamOpensByConstruction`). `initial` is only evaluated once the
  /// closed element has moved out.
  @inlinable
  @inline(__always)
  public mutating func _openElement(
    constructing initial: @autoclosure () -> Element
  ) -> UnsafeMutableRawPointer {
    guard self.pending != nil else {
      self.pending = initial()
      return withUnsafeMutablePointer(to: &self.pending) { UnsafeMutableRawPointer($0) }
    }
    let slot = self.nextSlot()
    let address = withUnsafeMutablePointer(to: &self.pending) {
      box -> UnsafeMutableRawPointer in
      let payload = UnsafeMutableRawPointer(box).assumingMemoryBound(to: Element.self)
      slot.moveInitialize(from: payload, count: 1)
      payload.initialize(to: initial())
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
  /// Appends a whole value, for the whole-value routes: a number is delivered once and entire
  /// (`emitBufferedNumber` holds one straddling a chunk), so no snapshot can see it half-written,
  /// which is all `pending` buys. The `drainPending` inside keeps order after a hand-made append.
  /// Measured: the `_openElement` round trip cost four stores and a load-compare where this is one.
  @inlinable
  @inline(__always)
  public mutating func _appendClosed(_ element: Element) {
    // `appendSealed` is `@inline(__always)` for this call site; see its note.
    self.appendSealed(element)
  }
}
