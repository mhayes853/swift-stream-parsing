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
// - **Sealed elements live in fixed size blocks.** Committing an element touches only the filling
//   block, so the first commit after a snapshot copies at most `blockCapacity` elements instead of
//   all of them. Copying the value itself retains one buffer object per field, not one per block.
//
// A plain value copy is therefore already a correct snapshot, which is why nothing here has a
// `streamSnapshot()`.
//
// Blocks are `ContiguousArray` rather than a class wrapping one: a `ContiguousArray` is already a
// single refcounted pointer, so the spine copies for the same cost, copy on write for the filling
// block comes for free instead of being written by hand, and every stored property stays a value
// type, which is what lets `Sendable` be checked rather than asserted.
public struct StreamArray<Element> {
  // Sealed and never written again except through the checked subscript. Every block here holds
  // exactly `blockCapacity` elements, which keeps indexing a shift and a mask rather than a search
  // over prefix sums.
  @usableFromInline var blocks: [ContiguousArray<Element>]

  // The filling block. The only place `blockCapacity` shows up as a cost, since this is what a
  // commit copies when a snapshot shares it.
  @usableFromInline var tail: ContiguousArray<Element>

  // The element being parsed, or nil when none is open. Reads see it as the last element, which is
  // what keeps an incomplete element visible while it streams.
  @usableFromInline var pending: Element?

  // A power of two, so the sealed count is `blocks.count << blockShift` and needs no stored field.
  @usableFromInline static var blockShift: Int { 5 }
  @usableFromInline static var blockCapacity: Int { 1 &<< Self.blockShift }
  @usableFromInline static var blockMask: Int { Self.blockCapacity &- 1 }

  public init() {
    self.blocks = []
    self.tail = ContiguousArray<Element>()
    self.pending = nil
  }

  public init(_ elements: some Sequence<Element>) {
    self.init()
    for element in elements { self.appendSealed(element) }
  }

  @usableFromInline var sealedCount: Int { self.blocks.count &<< Self.blockShift }

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
    if self.tail.capacity < Self.blockCapacity {
      self.tail.reserveCapacity(Self.blockCapacity)
    }
    self.tail.append(element)
    guard self.tail.count == Self.blockCapacity else { return }
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
        return self.blocks[position &>> Self.blockShift][position & Self.blockMask]
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
        self.blocks[position &>> Self.blockShift][position & Self.blockMask] = newValue
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
    var start = 0
    while start &+ Self.blockCapacity <= flat.count {
      self.blocks.append(ContiguousArray(flat[start..<(start &+ Self.blockCapacity)]))
      start &+= Self.blockCapacity
    }
    if start < flat.count {
      self.tail.reserveCapacity(Self.blockCapacity)
      self.tail.append(contentsOf: flat[start...])
    }
  }

  public mutating func append(_ newElement: Element) {
    self.appendSealed(newElement)
  }

  public mutating func reserveCapacity(_ minimumCapacity: Int) {
    self.blocks.reserveCapacity((minimumCapacity &+ Self.blockMask) &>> Self.blockShift)
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
    _streamArraySchema(Element.self, element: Element.streamSchema)
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
