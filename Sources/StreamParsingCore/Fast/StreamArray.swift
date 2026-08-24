// Array storage the parser can hold a pointer into, and that a snapshot can copy without copying
// the elements.
//
// Everything left of the parse cursor is immutable: once an element is closed it never changes.
// `Array` cannot express that, because any divergence from a shared buffer copies all of it, so
// keeping a value while parsing continues costs a full rebuild per snapshot.
//
// Two pieces make that cheap here:
//
// - **The open element lives outside the storage.** `pending` is held inline, so the parser's
//   frame points at a slot no other value can see, and its address survives every append. A write
//   through it is an ordinary mutation that respects the slot contents' own copy on write, rather
//   than the raw pointer bypass into a shared buffer that made kept values change after the fact.
// - **Sealed elements live in uniform power-of-two blocks.** Committing an element touches only
//   the filling block, so the first commit after a snapshot copies at most one block instead of all
//   the elements. Copying the value itself retains one buffer object per field, not one per block.
//
// A plain value copy is therefore already a correct snapshot, which is why nothing here has a
// `streamSnapshot()`.
//
// Blocks are `ContiguousArray` rather than a class wrapping one: a `ContiguousArray` is already a
// single refcounted pointer, so the spine copies for the same cost, copy on write for the filling
// block comes for free instead of being written by hand, and every stored property stays a value
// type, which is what lets `Sendable` be checked rather than asserted.
public struct StreamArray<Element> {
  // Sealed and never written again except through the checked subscript. Every block in an
  // instance holds its chosen capacity, which keeps indexing a shift and a mask rather than a
  // search over prefix sums.
  @usableFromInline var blocks: [ContiguousArray<Element>]

  // The filling block. Its first allocation is deliberately smaller than the chosen block
  // capacity; it promotes once if needed, while every tail after the first sealed block starts at
  // full size. This is what a commit copies when a snapshot shares it.
  @usableFromInline var tail: ContiguousArray<Element>

  // The element being parsed, or nil when none is open. Reads see it as the last element, which is
  // what keeps an incomplete element visible while it streams.
  @usableFromInline var pending: Element?

  // Capacity hints choose this while the array is empty. Keeping it as a shift makes the count and
  // index arithmetic independent of division, while the default path remains the same immediate
  // shift and mask used before adaptive blocks were introduced.
  @usableFromInline var blockShiftBits: UInt8

  // Cached separately because `commit` needs the capacity for every element, whereas the shift is
  // only needed when a block seals or an element is indexed. This avoids reconstructing the value
  // with a variable shift in the append hot path. The maximum adaptive capacity fits in UInt16.
  @usableFromInline var blockCapacityBits: UInt16

  // A power of two, so the sealed count is `blocks.count << blockShift` and needs no stored field.
  @usableFromInline static var initialTailCapacity: Int { 8 }
  @usableFromInline static var blockShift: Int { 5 }
  @usableFromInline static var blockCapacity: Int { 1 &<< Self.blockShift }
  @usableFromInline static var blockMask: Int { Self.blockCapacity &- 1 }

  public init() {
    self.blocks = []
    self.tail = ContiguousArray<Element>()
    self.pending = nil
    self.blockShiftBits = UInt8(Self.blockShift)
    self.blockCapacityBits = UInt16(Self.blockCapacity)
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
    for element in elements { self.appendSealed(element) }
  }

  @usableFromInline var currentBlockCapacity: Int { Int(self.blockCapacityBits) }

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
    guard desired > Self.blockCapacity else { return UInt8(Self.blockShift) }
    let roundedShift = Int.bitWidth &- (desired &- 1).leadingZeroBitCount
    return UInt8(Swift.min(9, roundedShift))
  }

  // Appends past the pending slot, which is what every path other than the parser wants: a user
  // appending to a parsed array adds after the open element rather than replacing it.
  @inlinable
  mutating func appendSealed(_ element: Element) {
    self.drainPending()
    self.commit(element)
  }

  @inlinable
  mutating func drainPending() {
    // Swapped out rather than read out. Reading leaves the original to be destroyed by the
    // reassignment, which is two element sized copies where this is one, and measured 30% worse on
    // the append loop. `consume self.pending` is not an option: consuming storage of a copyable
    // type is rejected.
    var taken = Element?.none
    swap(&taken, &self.pending)
    guard taken != nil else { return }
    self.commit(taken.unsafelyUnwrapped)
  }

  @inlinable
  mutating func commit(_ element: Element) {
    let blockCapacity = Int(self.blockCapacityBits)
    let neededCapacity = self.tail.count &+ 1
    if self.tail.capacity < neededCapacity {
      let reservation = self.blocks.isEmpty && self.tail.isEmpty
        ? Self.initialTailCapacity
        : blockCapacity
      self.tail.reserveCapacity(reservation)
    }
    self.tail.append(element)
    guard self.tail.count == blockCapacity else { return }
    self.blocks.append(self.tail)
    self.tail = ContiguousArray<Element>()
  }
}

// MARK: - Collection

extension StreamArray: RandomAccessCollection, MutableCollection {
  public typealias Index = Int

  public var startIndex: Int { 0 }

  public var endIndex: Int {
    self.sealedCount &+ self.tail.count &+ (self.pending == nil ? 0 : 1)
  }

  public subscript(position: Int) -> Element {
    get {
      let sealed = self.sealedCount
      if position < sealed {
        if _fastPath(self.blockShiftBits == UInt8(Self.blockShift)) {
          return self.blocks[position &>> Self.blockShift][position & Self.blockMask]
        }
        let shift = Int(self.blockShiftBits)
        return self.blocks[position &>> shift][position & ((1 &<< shift) &- 1)]
      }
      let offset = position &- sealed
      if offset < self.tail.count { return self.tail[offset] }
      precondition(
        offset == self.tail.count && self.pending != nil, "StreamArray index out of range"
      )
      return self.pending.unsafelyUnwrapped
    }
    set {
      let sealed = self.sealedCount
      if position < sealed {
        // Writes through the block, which copies that one block when a snapshot shares it and
        // leaves every other block alone. This is the only door into sealed storage.
        if _fastPath(self.blockShiftBits == UInt8(Self.blockShift)) {
          self.blocks[position &>> Self.blockShift][position & Self.blockMask] = newValue
        } else {
          let shift = Int(self.blockShiftBits)
          self.blocks[position &>> shift][position & ((1 &<< shift) &- 1)] = newValue
        }
        return
      }
      let offset = position &- sealed
      if offset < self.tail.count {
        self.tail[offset] = newValue
        return
      }
      precondition(
        offset == self.tail.count && self.pending != nil, "StreamArray index out of range"
      )
      self.pending = newValue
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
    self.tail = ContiguousArray<Element>()
    self.pending = nil
    let blockCapacity = self.currentBlockCapacity
    var start = 0
    while start &+ blockCapacity <= flat.count {
      self.blocks.append(ContiguousArray(flat[start..<(start &+ blockCapacity)]))
      start &+= blockCapacity
    }
    if start < flat.count {
      self.tail.reserveCapacity(blockCapacity)
      self.tail.append(contentsOf: flat[start...])
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
    if self.blocks.isEmpty && self.tail.isEmpty && minimumCapacity > 0 {
      self.tail.reserveCapacity(Swift.min(minimumCapacity, blockCapacity))
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
// pending and tail split falls, and they are the same array.
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

// Checked rather than `@unchecked`: every stored property is a value type, so the compiler can see
// that sharing a copy shares nothing mutable.
extension StreamArray: Sendable where Element: Sendable {}

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
        self.appendSealed(try container.decode(Element.self))
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

  /// A borrowed window onto the array, for reading elements or spans of sealed elements without
  /// copying the whole array or any element in it.
  ///
  /// Only the parser's own open ``StreamArray/pending`` element needs the same raw-pointer
  /// lifetime bridging every macro-generated field accessor needs (see `_streamMemberView`) —
  /// everything to its left is committed and immutable, so `sealedBlock(_:)`/`tail` read it
  /// through a `Span` built the same way `Array.span` builds its own.
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
    /// zero-copy access. Costs what reading a ``StreamPointerView`` would have: the block spine
    /// is a retain, so this only truly copies the open element (if there is one).
    @inlinable
    public var value: StreamArray<Element> { self.storage.pointee }

    /// The number of full, sealed blocks. Blocks within one array have a uniform size — see
    /// ``sealedBlock(_:)``.
    @inlinable
    public var sealedBlockCount: Int { self.storage.pointee.blocks.count }

    /// A zero-copy window onto one full, sealed block of elements.
    @_lifetime(borrow self)
    public func sealedBlock(_ blockIndex: Int) -> Span<Element> {
      let buffer = self.storage.pointee.blocks[blockIndex].withUnsafeBufferPointer { $0 }
      return _overrideLifetime(Span(_unsafeElements: buffer), borrowing: self)
    }

    /// A zero-copy window onto the committed elements past the last sealed block, not including
    /// the open element, if there is one.
    public var tail: Span<Element> {
      @_lifetime(borrow self)
      get {
        let buffer = self.storage.pointee.tail.withUnsafeBufferPointer { $0 }
        return _overrideLifetime(Span(_unsafeElements: buffer), borrowing: self)
      }
    }

    /// A view onto the element at `index`, or `nil` when `index` is out of bounds.
    ///
    /// Dispatches into a sealed block, the tail, or the open element — whichever holds `index` —
    /// without copying it, the same way a macro-generated field accessor does.
    public subscript(index: Int) -> Element.View? {
      @_lifetime(borrow self)
      get {
        guard index >= 0, index < self.count else { return nil }
        let sealed = self.storage.pointee.sealedCount
        if index < sealed {
          let shift = Int(self.storage.pointee.blockShiftBits)
          let blockIndex = index &>> shift
          let offset = index & ((1 &<< shift) &- 1)
          let base = self.storage.pointee.blocks[blockIndex]
            .withUnsafeBufferPointer { $0.baseAddress! }
          let view = Element.streamView(UnsafeMutableRawPointer(mutating: base + offset))
          return _overrideLifetime(view, borrowing: self)
        }
        let offset = index &- sealed
        if offset < self.storage.pointee.tail.count {
          let base = self.storage.pointee.tail.withUnsafeBufferPointer { $0.baseAddress! }
          let view = Element.streamView(UnsafeMutableRawPointer(mutating: base + offset))
          return _overrideLifetime(view, borrowing: self)
        }
        let view = _streamMemberView(&self.storage.pointee.pending)
        return _overrideLifetime(view, borrowing: self)
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
  /// Commits the open element and opens a new one, returning the address of its slot.
  ///
  /// Underscored because only the frame entry helpers have a reason to call it. The returned
  /// pointer stays valid until the next call, which is what the sink guarantees by resolving an
  /// element's destination once per element rather than once per token.
  @inlinable
  // swiftlint:disable:next identifier_name
  public mutating func _openElement(_ initial: Element) -> UnsafeMutableRawPointer {
    self.drainPending()
    self.pending = initial
    return withUnsafeMutablePointer(to: &self.pending) { UnsafeMutableRawPointer($0) }
  }
}
