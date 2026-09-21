// A `StreamFrame` whose schema is borrowed: the sink lowers every frame to this and never stores a
// `StreamFrame`, so nothing it holds retains and push/pop is a store and a decrement. Sound only
// while every schema a frame carries outlives the parse (a parent's hoisted `private static let`,
// a container schema's captured child, `rootSchema`, `ignoredStreamSchema`), which
// `StreamSchemaBorrowAudit` checks in debug builds. NEW_ARCHITECTURE.md, "Routing: frames borrow
// their schema".
@usableFromInline
struct BorrowedFrame {
  @usableFromInline var storage: UnsafeMutableRawPointer
  @usableFromInline unowned(unsafe) var schema: StreamSchema
  @usableFromInline var pendingField: Int32
  // In the 24-byte frame's padding: the schema's `routeBits` (leaf route, element kind and
  // optionality), copied when a container opens so a scalar tests a word on the frame rather than
  // chasing cold leaf metadata.
  @usableFromInline var routeBits: UInt32

  @usableFromInline var leafRoute: _StreamLeafRoute { StreamRouteBits.leafRoute(self.routeBits) }
  @usableFromInline var elementKind: StreamFieldKind { StreamRouteBits.elementKind(self.routeBits) }
  @usableFromInline var elementOptional: Bool { StreamRouteBits.elementOptional(self.routeBits) }

  @usableFromInline
  init(storage: UnsafeMutableRawPointer, schema: StreamSchema) {
    self.storage = storage
    self.schema = schema
    self.pendingField = -1
    self.routeBits = 0
  }

  @usableFromInline
  init(borrowing frame: StreamFrame) {
    self.storage = frame.storage
    self.schema = frame.schema
    self.pendingField = frame.pendingField
    self.routeBits = 0
  }

  // From a schema's object address, as the field table and a container schema hold it. The bits
  // become the unowned field directly; no reference is formed, so nothing is retained.
  @usableFromInline
  @inline(__always)
  init(storage: UnsafeMutableRawPointer, schemaBits: UnsafeRawPointer) {
    self.storage = storage
    self.schema = unsafeBitCast(schemaBits, to: StreamSchema.self)
    self.pendingField = -1
    self.routeBits = 0
  }

  // The unowned field back out as bits, for a `ScalarTarget` built from a frame: a bitcast is
  // a plain load, where `Unmanaged.passUnretained` of the field would first form a guaranteed
  // reference — which is the retain this type exists to avoid.
  @usableFromInline
  @inline(__always)
  var schemaBits: UnsafeRawPointer { unsafeBitCast(self.schema, to: UnsafeRawPointer.self) }

  // The zero-ARC closure call, same idiom as `ScalarTarget.withSchema`: a stored closure called
  // off the unowned field directly is copied first — a retain and a release of its context box
  // per call. Inside the guaranteed-ref scope the property call borrows.
  @usableFromInline
  @inline(__always)
  func withSchema<R>(_ body: (StreamSchema) -> R) -> R {
    Unmanaged<StreamSchema>.fromOpaque(self.schemaBits)._withUnsafeGuaranteedRef(body)
  }
}

// Embedded Swift has no `weak`, so the audit compiles out there along with the calls to it. That
// is not a gap worth closing: a schema without a durable owner is a mistake a conformance makes,
// and it is caught by any non-Embedded debug build of the same conformance.
#if DEBUG && !hasFeature(Embedded)
  // Whether the schemas the sink borrowed outlived their frames: one owned only by its frame (a
  // hand-written `enterField` building it on the spot) is a use-after-free with nothing pointing at
  // the cause. Weak, not `isKnownUniquelyReferenced` (which differs between -Onone and -O); per
  // sink, so nothing shared races. NEW_ARCHITECTURE.md, "The tripwire".
  @usableFromInline
  struct StreamSchemaBorrowAudit {
    @usableFromInline
    struct Borrow {
      @usableFromInline weak var schema: StreamSchema?
      @usableFromInline let identity: ObjectIdentifier

      @usableFromInline
      init(_ schema: StreamSchema) {
        self.schema = schema
        self.identity = ObjectIdentifier(schema)
      }
    }

    @usableFromInline var borrows: [Borrow] = []

    @usableFromInline
    init() {}

    // One entry per distinct schema, not per frame: a document enters the same schema once per
    // occurrence and there are only ever a handful of them.
    @usableFromInline
    mutating func record(_ schema: StreamSchema) {
      let identity = ObjectIdentifier(schema)
      guard !self.borrows.contains(where: { $0.identity == identity }) else { return }
      self.borrows.append(Borrow(schema))
    }

    @usableFromInline
    func verify() {
      for borrow in self.borrows where borrow.schema == nil {
        preconditionFailure(
          """
          A StreamFrame's schema was deallocated while the sink still borrowed it, which means the \
          frame was its only owner. Schema \(borrow.identity) has to be stored somewhere that \
          outlives the parse — the `private static let` the macro hoists onto the enclosing \
          Partial, or a stored `let` next to the conformance that builds it.
          """
        )
      }
    }
  }
#endif

// At file scope on purpose: nested in a generic `PartialSink`, its metadata depended on `Root` and
// `scalarTarget = nil` lowered to a value-witness destroy (20-30% on every string element). Kept
// here so re-introducing a type parameter cannot re-create the trap.
@usableFromInline
struct ScalarTarget {
  var storage: UnsafeMutableRawPointer
  // Raw bits, not a reference of any strength. Measured: a strong field made `scalarTarget = nil`
  // a value-witness destroy (4% of a small typed parse); `unowned(unsafe)` moved the retain/release
  // to every scalar use (4-5% byte-fed). Bits read through `Unmanaged` are +0; the root schema the
  // sink holds strong owns the graph.
  var schemaBits: UnsafeRawPointer
  var field: Int32

  // The only zero-ARC read: a computed strong `schema` costs a retain/release per scalar token;
  // the guaranteed-ref scope hands the reference over borrowed.
  @inline(__always)
  func withSchema<R>(_ body: (StreamSchema) -> R) -> R {
    Unmanaged<StreamSchema>.fromOpaque(self.schemaBits)._withUnsafeGuaranteedRef(body)
  }
  // The table entry the target came from, or nil for a target the closures apply: an array
  // element, a dictionary value, a scalar root, or a `custom`/`container` field. For a table
  // target `storage` is already the member's address.
  var entry: UnsafePointer<StreamFieldEntry>?
}

// Routes parse events into a value described by a `StreamSchema`. Frames point into the value:
// only the innermost open container is mutated, and each holds its open element inline at a fixed
// offset, so neither an outer append nor a copy between parse calls invalidates a frame. Not
// generic over the root: a phantom parameter cost ~30% in metadata accessors on the table route.
public struct PartialSink: ~Copyable, StreamParseSink {
  // Strings accumulate into `StreamString`, paying per chunk call rather than per byte copied --
  // the sink escaped-value coalescing (`JSONParser.coalescedEscapedStringTail`) was built for.
  public private(set) var streamFailure: StreamSinkFailure?

  @usableFromInline var root: UnsafeMutableRawPointer
  @usableFromInline var rootSchema: StreamSchema
  @usableFromInline var started = false
  // The top frame's `routeBits`, cached next to `started`, so the common scalar route tests a
  // fixed word rather than calling out to rediscover the top frame and its schema.
  @usableFromInline var activeRouteBits: UInt32 = 0
  @usableFromInline var activeLeafRoute: _StreamLeafRoute {
    StreamRouteBits.leafRoute(self.activeRouteBits)
  }
  // Non-zero when a scalar arriving at the top frame has a typed slot: an element, value or
  // lane of a kind the table writes.
  @usableFromInline var activeElementKindBits: UInt32 {
    self.activeRouteBits & StreamRouteBits.elementKindMask
  }
  // The slot `enterKey` opened for the value after the last dictionary key, written through the
  // dictionary schema's `elementSchema`. Consumed by the value that follows.
  @usableFromInline var pendingDictionaryStorage: UnsafeMutableRawPointer?

  // The frame stack: one fixed allocation (the parser caps depth), sparing `key(_:)` the uniqueness
  // and bounds checks an `Array` charged per key. Capacity is the cap plus one: the cap is checked
  // *after* the sink is told a container opened, so the rejected depth's frame arrives first.
  @usableFromInline let frames: UnsafeMutablePointer<BorrowedFrame>
  @usableFromInline var frameCount = 0

  // Frames there was no room for, kept balanced for a caller that catches the depth error and keeps
  // feeding. Only containers past the *first* overflow count: that one is pushed as `ignoredFrame`
  // into the reserved slot, because `key(_:)` and the scalar entries have no depth test and would
  // otherwise write an over-deep key into the parent.
  @usableFromInline var droppedFrameCount = 0

  #if DEBUG && !hasFeature(Embedded)
    @usableFromInline var audit = StreamSchemaBorrowAudit()
  #endif

  // Lowers a frame the schema handed back, recording the borrow so a debug build can tell whether
  // the schema outlives it.
  @usableFromInline
  mutating func borrow(_ frame: StreamFrame) -> BorrowedFrame {
    #if DEBUG && !hasFeature(Embedded)
      self.audit.record(frame.schema)
    #endif
    return BorrowedFrame(borrowing: frame)
  }

  @usableFromInline
  static var frameCapacity: Int { JSONParser.maximumDepth + 1 }

  // One slot past every frame a legal document can produce, reserved for the ignored frame that
  // absorbs an over-deep subtree. Nothing the parser feeds ever reaches it -- the parser rejects
  // the depth first -- so it costs one 24-byte frame in an allocation that already exists.
  @usableFromInline
  static var overflowCapacity: Int { Self.frameCapacity + 1 }

  // A document whose root is an array, a dictionary or a bare scalar is as valid as one rooted
  // in an object, so the root's shape comes from its schema rather than from a constraint.
  public init(root: UnsafeMutableRawPointer, schema: StreamSchema) {
    self.root = root
    self.rootSchema = schema
    self.frames = .allocate(capacity: Self.overflowCapacity)
  }

  public init<Root>(root: UnsafeMutablePointer<Root>, schema: StreamSchema) {
    self.init(root: UnsafeMutableRawPointer(root), schema: schema)
  }

  deinit {
    self.frames.deinitialize(count: self.frameCount)
    self.frames.deallocate()
  }

  /// Rewinds the sink to its freshly initialized state while keeping the frame allocation.
  ///
  /// The root pointer and schema stay: a reused sink writes the next document into the same
  /// slot the stream re-initializes. Legal in any state, including mid-document and after a
  /// recorded failure.
  public mutating func reset() {
    self.streamFailure = nil
    self.started = false
    self.activeRouteBits = 0
    self.pendingDictionaryStorage = nil
    // Frames are trivially destroyable, so this is bookkeeping rather than work — kept in the
    // same shape as `deinit` so a frame that ever grows a non-trivial field is still correct.
    self.frames.deinitialize(count: self.frameCount)
    self.frameCount = 0
    self.droppedFrameCount = 0
    self.completedValues.removeAll(keepingCapacity: true)
    self.scalarTarget = nil
    self.homogeneousStringStorage = nil
    self.inlineStringStorage = nil
    self.inlineStringCapacity = 0
    self.stringResultRaw = 0
    #if DEBUG && !hasFeature(Embedded)
      // The borrows recorded for the previous document are over with its last frame. Keeping
      // them would fail the tripwire during the *next* document for a schema the previous one
      // borrowed and legitimately released after this reset.
      self.audit = StreamSchemaBorrowAudit()
    #endif
  }

  // MARK: Frame stack

  @usableFromInline
  var topFrame: UnsafeMutablePointer<BorrowedFrame>? {
    self.frameCount > 0 ? self.frames + (self.frameCount &- 1) : nil
  }

  @usableFromInline
  mutating func pushFrame(_ initialFrame: BorrowedFrame) {
    #if DEBUG && !hasFeature(Embedded)
      self.audit.verify()
    #endif
    guard self.frameCount < Self.frameCapacity else {
      self.pushOverflowFrame()
      return
    }
    var frame = initialFrame
    if frame.withSchema({ $0.completedValue != nil }) {
      frame = self.openCompletedValue(frame)
    }
    frame.routeBits = frame.schema.routeBits
    if frame.leafRoute.usesFrameElementIndex {
      // Objects use this field for a matched member. A fixed-width array has no keys, so the same
      // four bytes are its element cursor without increasing the 24-byte frame.
      frame.pendingField = 0
    }
    (self.frames + self.frameCount).initialize(to: frame)
    self.frameCount &+= 1
    self.activeRouteBits = frame.routeBits
  }

  // The cold half of `pushFrame`, outlined so the depth check stays a predicted-not-taken branch
  // over a call rather than inlining the overflow bookkeeping into every container open.
  @usableFromInline
  @inline(never)
  mutating func pushOverflowFrame() {
    self.recordFailure(.depthExceeded)
    guard self.frameCount < Self.overflowCapacity else {
      // Already inside an ignored subtree: the top frame discards, so deeper containers only have
      // to stay balanced against `popFrame`.
      self.droppedFrameCount &+= 1
      return
    }
    var frame = self.ignoredFrame
    frame.routeBits = frame.schema.routeBits
    (self.frames + self.frameCount).initialize(to: frame)
    self.frameCount &+= 1
    self.activeRouteBits = frame.routeBits
  }

  @usableFromInline
  mutating func popFrame() {
    guard self.droppedFrameCount == 0 else {
      self.droppedFrameCount &-= 1
      return
    }
    guard self.frameCount > 0 else { return }
    if !self.completedValues.isEmpty { self.finishCompletedValues() }
    self.frameCount &-= 1
    (self.frames + self.frameCount).deinitialize(count: 1)
    self.activeRouteBits = self.frameCount == 0
      ? 0
      : (self.frames + (self.frameCount &- 1)).pointee.routeBits
  }

  // Outlined so ordinary push/pop do not carry conversion ownership and stack bookkeeping.
  @inline(never)
  private mutating func openCompletedValue(_ initialFrame: BorrowedFrame) -> BorrowedFrame {
    var frame = initialFrame
    while let hooks = frame.schema.completedValue {
      self.completedValues.append(
        _StreamPendingCompletedValue(depth: self.frameCount + 1, storage: frame.storage, hooks: hooks)
      )
      frame = BorrowedFrame(storage: hooks.begin(frame.storage), schema: hooks.source)
      #if DEBUG && !hasFeature(Embedded)
        self.audit.record(hooks.source)
      #endif
    }
    return frame
  }

  @inline(never)
  private mutating func finishCompletedValues() {
    while self.completedValues.last?.depth == self.frameCount {
      let completed = self.completedValues.removeLast()
      if self.streamFailure == nil {
        let result = completed.hooks.finish(completed.storage)
        if result != .applied { self.recordFailure(Self.failureReason(for: result)) }
      }
    }
  }

  // MARK: Containers

  public mutating func beginObject() -> StreamContainerDisposition {
    self.enterContainer(shape: .object)
  }

  public mutating func beginArray() -> StreamContainerDisposition {
    switch self.activeLeafRoute {
    case .arraySIMD2Double, .arraySIMD3Double, .arraySIMD4Double,
      .arrayOptionalSIMD2Double, .arrayOptionalSIMD3Double, .arrayOptionalSIMD4Double:
      self.openKnownSIMDDoubleElement(self.activeLeafRoute)
      return .stream
    default:
      break
    }
    return self.enterContainer(shape: .array)
  }

  public mutating func endObject() {
    self.popFrame()
  }

  public mutating func endArray() {
    if self.droppedFrameCount == 0, self.activeLeafRoute.usesFrameElementIndex,
      let top = self.topFrame, top.pointee.pendingField != top.pointee.schema.fixedElementCount
    {
      // A fixed array -- an `InlineArray`, a SIMD vector -- that closes short of its arity.
      self.recordFailure(.typeMismatch)
    }
    self.popFrame()
  }

  private mutating func enterContainer(shape: StreamSchema.Shape) -> StreamContainerDisposition {
    guard self.started else {
      self.started = true
      let canHoldContainer = self.rootSchema.shape.canHold(container: shape)
      if !canHoldContainer { self.recordFailure(.typeMismatch) }
      if canHoldContainer { self.rootSchema.prepareRoot(self.root) }
      self.pushFrame(
        canHoldContainer
          ? BorrowedFrame(storage: self.root, schema: self.rootSchema)
          : self.ignoredFrame
      )
      return .stream
    }

    let hasKnownDestination = self.hasKnownValueDestination
    guard let target = self.valueTarget() else {
      // A container under an unknown object key is ignored. Every other missing target describes
      // a known destination whose schema cannot accept a container — that stays `.stream` so the
      // failure just recorded surfaces at the opening bracket, exactly as before.
      if hasKnownDestination {
        self.recordFailure(.typeMismatch)
        self.pushFrame(self.ignoredFrame)
        return .stream
      }
      // The ignored frame is pushed even though the answer is `.skip`: the disposition is
      // advisory, so the interior may still arrive (the batching adapter's replay), and the
      // matching end call always does. Either way the frame is popped exactly once.
      self.pushFrame(self.ignoredFrame)
      return .skip
    }
    guard target.schema.shape.canHold(container: shape) else {
      self.recordFailure(.typeMismatch)
      self.pushFrame(self.ignoredFrame)
      return .stream
    }
    self.pushFrame(target)
    return .stream
  }

  private var hasKnownValueDestination: Bool {
    guard let top = self.topFrame else { return false }
    switch top.pointee.schema.shape {
    case .array: return true
    case .object: return top.pointee.pendingField >= 0
    case .dictionary:
      return self.pendingDictionaryStorage != nil
    case .scalar: return true
    }
  }

  // The slot for the next element of the array frame at `top`: addressed from the cursor when
  // the schema declares a stride, opened by the schema's `appendElement` otherwise.
  @inline(__always)
  private static func openElement(
    _ top: UnsafeMutablePointer<BorrowedFrame>, _ index: Int32
  ) -> UnsafeMutableRawPointer? {
    let stride = top.pointee.schema.elementStride
    if stride != 0 {
      return top.pointee.storage + Int(index) &* Int(stride)
    }
    // In a guaranteed-ref scope, as in `ScalarTarget.withSchema`: loading `appendElement` off the
    // unowned schema copied the closure, a retain/release per element.
    return Unmanaged<StreamSchema>.fromOpaque(top.pointee.schemaBits)._withUnsafeGuaranteedRef {
      $0.appendElement(top.pointee.storage, index)
    }
  }

  // The array and dictionary arms `valueTarget` and `resolveScalarTarget` share: open the next
  // element slot and pair it with the element schema. `dictionary` is a literal at all four call
  // sites, so each copy folds to the arm it asked for.
  @inline(__always)
  private mutating func openElementSlot(
    _ top: UnsafeMutablePointer<BorrowedFrame>, dictionary: Bool
  ) -> (UnsafeMutableRawPointer, UnsafeRawPointer)? {
    let slot: UnsafeMutableRawPointer
    if dictionary {
      guard let pending = self.pendingDictionaryStorage else { return nil }
      self.pendingDictionaryStorage = nil
      slot = pending
    } else {
      let indexed = top.pointee.leafRoute == .inlineArray
      let index = indexed ? top.pointee.pendingField : -1
      if indexed, index >= top.pointee.schema.fixedElementCount {
        // More elements than the fixed array declares: bounded storage overflowing, the same
        // failure an inline string reports when a value outruns its capacity. An array that
        // closes *short* of its arity is still a mismatch, checked in `endArray`.
        self.recordFailure(.capacityExceeded)
        return nil
      }
      guard let opened = Self.openElement(top, index) else {
        if indexed { self.recordFailure(.capacityExceeded) }
        return nil
      }
      if indexed { top.pointee.pendingField = index &+ 1 }
      slot = opened
    }
    // A slot with nothing to describe it -- a hand-written schema that declared no element
    // schema -- is a destination the sink cannot write, and is ignored.
    guard let bits = top.pointee.schema.elementSchemaBits else { return nil }
    return (slot, bits)
  }

  // The frame a value is written through, appending an array element first. Whether that frame
  // can hold the arriving value is the caller's question.
  private mutating func valueTarget() -> BorrowedFrame? {
    guard let top = self.topFrame else { return nil }
    switch top.pointee.schema.shape {
    case .array:
      guard let (slot, bits) = self.openElementSlot(top, dictionary: false) else { return nil }
      return BorrowedFrame(storage: slot, schemaBits: bits)
    case .object:
      guard top.pointee.pendingField >= 0 else { return nil }
      var field = top.pointee.pendingField
      if top.pointee.schema.keyRouting == .table {
        let entry = top.pointee.schema.fieldEntries.unsafelyUnwrapped + Int(field)
        // A scalar member cannot hold a container; the caller reads nil against a known
        // destination as the mismatch it is.
        guard entry.pointee.kind == .container else { return nil }
        // The entry names the child's schema: the frame is the member's address and that schema,
        // once the member is prepared -- an optional materialised, a capacity reserved. No
        // closure for a member that needs neither, and never a `StreamFrame` to lower.
        if let bits = entry.pointee.schemaBits {
          let member = top.pointee.storage + Int(entry.pointee.offset)
          if entry.pointee.hasPrepare {
            let prepare = top.pointee.schema.fieldPrepares.unsafelyUnwrapped + Int(field)
            prepare.pointee.unsafelyUnwrapped(member, entry.pointee.capacity)
          }
          return BorrowedFrame(storage: member, schemaBits: bits)
        }
        field = entry.pointee.index
      }
      let entered = top.pointee.withSchema { $0.enterField(top.pointee.storage, field) }
      guard let frame = entered else { return nil }
      return self.borrow(frame)
    case .dictionary:
      guard let (slot, bits) = self.openElementSlot(top, dictionary: true) else { return nil }
      return BorrowedFrame(storage: slot, schemaBits: bits)
    case .scalar:
      return nil
    }
  }

  // MARK: Keys

  // One load and one switch over the schema's precomputed routing. `ignore` spares the closure call
  // (load, retain, indirect call, release) on frames over undeclared subtrees, which see most keys
  // of a partly modelled document -- 52% of `twitter.json`'s.
  public mutating func key(_ bytes: Span<UInt8>) {
    guard let top = self.topFrame else { return }
    // Read through the frame each time, not bound to a local: a local passed to `enterKey` kept the
    // schema alive across the call, a retain per dictionary entry. In place it is a borrow.
    switch top.pointee.schema.keyDispatch {
    case .table:
      top.pointee.pendingField = Self.matchTable(top, bytes)
    case .match:
      top.pointee.pendingField = top.pointee.withSchema { $0.matchField(bytes) }
    case .observedTable:
      let entry = Self.matchTable(top, bytes)
      top.pointee.pendingField = entry
      if entry >= 0 {
        let field = top.pointee.schema.fieldEntries.unsafelyUnwrapped[Int(entry)].index
        top.pointee.withSchema {
          $0.onFieldRecognized!(top.pointee.storage, _streamFieldID(field))
        }
      }
    case .observedMatch:
      let field = top.pointee.withSchema { $0.matchField(bytes) }
      top.pointee.pendingField = field
      if field >= 0 {
        top.pointee.withSchema {
          $0.onFieldRecognized!(top.pointee.storage, _streamFieldID(field))
        }
      }
    case .dictionary:
      switch self.activeLeafRoute {
      case .dictionaryStreamString, .dictionaryOptionalStreamString,
        .dictionaryBool, .dictionaryOptionalBool:
        self.pendingDictionaryStorage = self.openKnownDictionaryValue(
          top.pointee.storage, route: self.activeLeafRoute, forKey: bytes
        )
        return
      default:
        break
      }
      // The key span does not outlive this call, so the value's slot is opened now rather than
      // remembered and opened when the value arrives.
      self.pendingDictionaryStorage = top.pointee.withSchema { $0.enterKey(top.pointee.storage, bytes) }
    case .ignore:
      top.pointee.pendingField = -1
    }
  }

  // MARK: Scalars

  public mutating func stringBegin() {
    switch self.activeLeafRoute {
    case .arrayStreamString, .arrayOptionalStreamString,
      .dictionaryStreamString, .dictionaryOptionalStreamString:
      self.homogeneousStringStorage = self.openKnownStreamStringTarget(self.activeLeafRoute)
      self.scalarTarget = nil
      return
    case .simd2Number, .simd3Number, .simd4Number,
      .simd2Double, .simd3Double, .simd4Double,
      .optionalSIMD2Double, .optionalSIMD3Double, .optionalSIMD4Double:
      self.scalarTarget = nil
      self.recordFailure(.typeMismatch)
      return
    default:
      break
    }
    if self.activeElementKindBits != 0 {
      self.openKnownStringSlot()
      return
    }
    let target = self.resolveScalarTarget()
    self.scalarTarget = target
    guard let target else { return }
    if let entry = target.entry {
      // A table member: materialised and reserved here, appended to in place by the chunks.
      let result = self.openTableString(entry, target.storage)
      if result != .applied {
        self.scalarTarget = nil
        self.recordFailure(Self.failureReason(for: result))
      }
      return
    }
    // The empty span both materializes the destination and settles whether it accepts strings at
    // all, so a mismatch is reported at the opening quote rather than at the first chunk.
    let result = target.withSchema { $0.applyString(target.storage, target.field, Span()) }
    if result != .applied {
      self.scalarTarget = nil
      self.recordFailure(Self.failureReason(for: result))
      return
    }
    // Bounded inline storage is recognized here, not through a container route: the resolved target
    // has one shape for a field, an element and a dictionary value.
    let (leafRoute, inlineCapacity) = target.withSchema { ($0.leafRoute, $0.inlineCapacity) }
    if leafRoute == .valueInlineString {
      self.inlineStringCapacity = inlineCapacity
      self.inlineStringStorage = target.storage
      self.scalarTarget = nil
    }
  }

  // An element, value or lane of a kind the table knows: a string slot is opened in place and
  // the chunks append to it; any other kind cannot hold a string. Outlined so `stringBegin`'s
  // object path keeps its instruction stream; inlined, it doubled the function.
  @inline(never)
  private mutating func openKnownStringSlot() {
    self.scalarTarget = nil
    guard let (slot, kind) = self.knownScalarSlot() else { return }
    switch kind {
    case .streamString:
      self.homogeneousStringStorage = slot
    case .inlineString:
      self.inlineStringCapacity = self.topFrame.unsafelyUnwrapped.pointee.schema.inlineCapacity
      self.inlineStringStorage = slot
    default:
      self.recordFailure(.typeMismatch)
    }
  }

  public mutating func stringChunk(_ bytes: Span<UInt8>) {
    if let storage = self.homogeneousStringStorage {
      storage.assumingMemoryBound(to: StreamString.self).pointee.streamAppend(utf8: bytes)
      return
    }
    // Bounded inline storage has its own slot, tested *after* the `StreamString` path: a byte
    // test ahead of that append cost `LLM message` and `GSoC` 2-3%, documents made of long
    // strings fed as many chunks.
    if let storage = self.inlineStringStorage {
      let result = _streamInlineStringAppend(storage, capacity: self.inlineStringCapacity, bytes)
      self.stringResultRaw = max(self.stringResultRaw, result.rawValue)
      return
    }
    guard let target = self.scalarTarget else { return }
    // Deliberately not a branch. Measured: checking the result here cost Twitter discarding 8.7%
    // (the compare kept the schema live and broke the tail call); the `max` fold is at parity, and
    // sticky since `applied` is zero. The failure surfaces at the closing quote, same token.
    // NEW_ARCHITECTURE.md, "The chunk check that cost 8.7%".
    let result = target.withSchema { $0.applyString(target.storage, target.field, bytes) }
    self.stringResultRaw = max(self.stringResultRaw, result.rawValue)
  }

  public mutating func stringEnd() {
    if self.stringResultRaw == 0, let target = self.scalarTarget {
      let result = target.withSchema {
        $0.finishString?(target.storage, target.field) ?? .applied
      }
      self.stringResultRaw = result.rawValue
    }
    self.homogeneousStringStorage = nil
    self.inlineStringStorage = nil
    self.scalarTarget = nil
    self.inlineStringCapacity = 0
    // Once per string value rather than per chunk, which is what makes the fold above worth it.
    if self.stringResultRaw != 0 {
      self.recordFailure(
        Self.failureReason(for: StreamApplyResult(rawValue: self.stringResultRaw)!)
      )
      self.stringResultRaw = 0
    }
  }

  // The whole-string form: a table entry writes the member in place, a matched field goes through
  // the closure with the empty span settling acceptance first (a mismatch reports at the opening
  // quote). Elements, dictionary values and roots unroll into the chunked triple.
  public mutating func string(_ bytes: Span<UInt8>) {
    if self.activeElementKindBits == 0, let top = self.topFrame,
      top.pointee.schema.shape == .object
    {
      let field = top.pointee.pendingField
      switch top.pointee.schema.keyRouting {
      case .table:
        if field >= 0 {
          let entry = top.pointee.schema.fieldEntries.unsafelyUnwrapped + Int(field)
          let result = self.writeTableString(entry, frame: top, bytes)
          if result != .applied { self.recordFailure(Self.failureReason(for: result)) }
        }
        return
      case .match:
        if field >= 0 {
          let opened = top.pointee.schema.applyString(top.pointee.storage, field, Span())
          if opened != .applied {
            self.recordFailure(Self.failureReason(for: opened))
            return
          }
          if bytes.count > 0 {
            let result = top.pointee.schema.applyString(top.pointee.storage, field, bytes)
            if result != .applied { self.recordFailure(Self.failureReason(for: result)) }
          }
          if self.streamFailure == nil {
            let result = top.pointee.schema.finishString?(top.pointee.storage, field) ?? .applied
            if result != .applied { self.recordFailure(Self.failureReason(for: result)) }
          }
        }
        return
      default:
        break
      }
    }
    self.stringBegin()
    if self.streamFailure != nil {
      // Clear what `stringBegin` set, as `stringEnd` would minus the report: left live, a driver
      // that keeps feeding after a recorded failure routes the next string to this destination.
      self.homogeneousStringStorage = nil
      self.inlineStringStorage = nil
      self.scalarTarget = nil
      self.inlineStringCapacity = 0
      self.stringResultRaw = 0
      return
    }
    if bytes.count > 0 { self.stringChunk(bytes) }
    self.stringEnd()
  }

  public mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) {
    switch self.activeLeafRoute {
    case .arrayDouble:
      self.appendHomogeneousDouble(bytes, info: info)
      return
    case .arrayInt:
      self.appendHomogeneousInt(bytes, info: info)
      return
    case .simd2Double, .simd3Double, .simd4Double:
      self.storeSIMDDoubleLane(bytes, info: info)
      return
    default:
      // SIMD lanes included: the frame carries the lane kind and the schema the lane stride.
      if self.activeElementKindBits != 0 {
        self.applyKnownNumber(bytes, info: info)
        return
      }
      // A scalar under an object frame always directly follows its key, so the matched field is
      // fresh and the value is a typed store at the member's offset: no frame resolution, no
      // `ScalarTarget`.
      if let top = self.topFrame, top.pointee.schema.shape == .object {
        let field = top.pointee.pendingField
        switch top.pointee.schema.keyRouting {
        case .table:
          if field >= 0 {
            let entry = top.pointee.schema.fieldEntries.unsafelyUnwrapped + Int(field)
            let result =
              entry.pointee.kind == .custom
              ? top.pointee.schema.applyNumber(top.pointee.storage, entry.pointee.index, bytes, info)
              : Self.writeTableNumber(
                entry, member: top.pointee.storage + Int(entry.pointee.offset), bytes, info
              )
            if result != .applied { self.recordFailure(Self.failureReason(for: result)) }
          }
          return
        case .match:
          if field >= 0 {
            let result = top.pointee.schema.applyNumber(top.pointee.storage, field, bytes, info)
            if result != .applied { self.recordFailure(Self.failureReason(for: result)) }
          }
          return
        default:
          break
        }
      }
      self.applyNumberNormally(bytes, info: info)
      return
    }
  }

  public mutating func boolean(_ value: Bool) {
    switch self.activeLeafRoute {
    case .arrayBool, .arrayOptionalBool, .dictionaryBool, .dictionaryOptionalBool:
      self.applyKnownBoolean(value, route: self.activeLeafRoute)
      return
    case .simd2Number, .simd3Number, .simd4Number,
      .simd2Double, .simd3Double, .simd4Double,
      .optionalSIMD2Double, .optionalSIMD3Double, .optionalSIMD4Double:
      self.recordFailure(.typeMismatch)
      return
    default:
      if self.activeElementKindBits != 0 {
        self.applyKnownBoolean(value)
        return
      }
      // The pairing, as in `number` above.
      if let top = self.topFrame, top.pointee.schema.shape == .object {
        let field = top.pointee.pendingField
        switch top.pointee.schema.keyRouting {
        case .table:
          if field >= 0 {
            let entry = top.pointee.schema.fieldEntries.unsafelyUnwrapped + Int(field)
            let result =
              entry.pointee.kind == .custom
              ? top.pointee.schema.applyBoolean(top.pointee.storage, entry.pointee.index, value)
              : Self.writeTableBoolean(
                entry, member: top.pointee.storage + Int(entry.pointee.offset), value
              )
            if result != .applied { self.recordFailure(Self.failureReason(for: result)) }
          }
          return
        case .match:
          if field >= 0 {
            let result = top.pointee.schema.applyBoolean(top.pointee.storage, field, value)
            if result != .applied { self.recordFailure(Self.failureReason(for: result)) }
          }
          return
        default:
          break
        }
      }
      self.applyBooleanNormally(value)
      return
    }
  }

  public mutating func null() {
    if self.topFrame == nil, !self.started {
      let result = self.rootSchema.applyNull(self.root, StreamSchema.wholeValueField)
      if result != .applied {
        self.recordFailure(Self.failureReason(for: result))
      }
      return
    }
    switch self.activeLeafRoute {
    case .arrayOptionalStreamString, .arrayOptionalBool,
      .arrayOptionalDouble, .arrayOptionalInt,
      .dictionaryOptionalStreamString, .dictionaryOptionalBool:
      self.applyKnownNull(self.activeLeafRoute)
      return
    case .simd2Number, .simd3Number, .simd4Number,
      .simd2Double, .simd3Double, .simd4Double,
      .optionalSIMD2Double, .optionalSIMD3Double, .optionalSIMD4Double:
      self.recordFailure(.typeMismatch)
      return
    default:
      if self.activeElementKindBits != 0 {
        self.applyKnownNull()
        return
      }
      // The pairing, as in `number` above. `container` joins `custom` on the closure route: a
      // null for a container member nils the optional through the schema.
      if let top = self.topFrame, top.pointee.schema.shape == .object {
        let field = top.pointee.pendingField
        switch top.pointee.schema.keyRouting {
        case .table:
          if field >= 0 {
            let entry = top.pointee.schema.fieldEntries.unsafelyUnwrapped + Int(field)
            let kind = entry.pointee.kind
            let result =
              kind == .custom || kind == .container
              ? top.pointee.schema.applyNull(top.pointee.storage, entry.pointee.index)
              : Self.writeTableNull(entry, member: top.pointee.storage + Int(entry.pointee.offset))
            if result != .applied { self.recordFailure(Self.failureReason(for: result)) }
          }
          return
        case .match:
          if field >= 0 {
            let result = top.pointee.schema.applyNull(top.pointee.storage, field)
            if result != .applied { self.recordFailure(Self.failureReason(for: result)) }
          }
          return
        default:
          break
        }
      }
      self.applyNullNormally()
      return
    }
  }

  // MARK: Scalar routing

  @usableFromInline var scalarTarget: ScalarTarget?

  @usableFromInline var homogeneousStringStorage: UnsafeMutableRawPointer?

  // The open string value's bounded inline slot -- a table member, an element, a value -- with
  // `inlineStringCapacity` its capacity. Kept apart from `homogeneousStringStorage` so the
  // `StreamString` chunk path tests one pointer and nothing else.
  @usableFromInline var inlineStringStorage: UnsafeMutableRawPointer?

  // Non-zero while the open string value writes into bounded inline storage, in which case it is
  // that storage's capacity. One store per string value at `stringBegin`, which is what buys the
  // chunk path a capacity in a register instead of a load off the schema.
  @usableFromInline var inlineStringCapacity: Int32 = 0

  // The open string value's worst result so far, as a raw value so chunks can fold into it
  // without branching. Read and reset once per value in `stringEnd`.
  @usableFromInline var stringResultRaw: UInt8 = 0

  // Kept after the existing hot fields. Ordinary parsing never allocates this stack.
  @usableFromInline var completedValues: [_StreamPendingCompletedValue] = []

  @inline(never)
  private mutating func openKnownStreamStringTarget(
    _ route: _StreamLeafRoute
  ) -> UnsafeMutableRawPointer? {
    guard let top = self.topFrame else { return nil }
    switch route {
    case .arrayStreamString:
      return top.pointee.storage.assumingMemoryBound(to: StreamArray<StreamString>.self)
        .pointee._openElement(StreamString())
    case .arrayOptionalStreamString:
      return top.pointee.storage.assumingMemoryBound(to: StreamArray<StreamString?>.self)
        .pointee._openElement(.some(StreamString()))
    case .dictionaryStreamString:
      guard let pending = self.pendingDictionaryStorage else { return nil }
      self.pendingDictionaryStorage = nil
      return pending
    case .dictionaryOptionalStreamString:
      guard let pending = self.pendingDictionaryStorage else { return nil }
      self.pendingDictionaryStorage = nil
      _streamMaterializeOptional(pending, as: StreamString.self)
      return pending
    default:
      return nil
    }
  }

  @inline(never)
  private mutating func applyKnownBoolean(_ value: Bool, route: _StreamLeafRoute) {
    switch route {
    case .arrayBool:
      guard let top = self.topFrame else { return }
      _ = top.pointee.storage.assumingMemoryBound(to: StreamArray<Bool>.self).pointee
        ._openElement(value)
    case .arrayOptionalBool:
      guard let top = self.topFrame else { return }
      _ = top.pointee.storage.assumingMemoryBound(to: StreamArray<Bool?>.self).pointee
        ._openElement(.some(value))
    case .dictionaryBool:
      guard let storage = self.pendingDictionaryStorage else { return }
      self.pendingDictionaryStorage = nil
      storage.assumingMemoryBound(to: Bool.self).pointee = value
    case .dictionaryOptionalBool:
      guard let storage = self.pendingDictionaryStorage else { return }
      self.pendingDictionaryStorage = nil
      storage.assumingMemoryBound(to: Bool?.self).pointee = .some(value)
    default:
      return
    }
  }

  @inline(never)
  private mutating func applyKnownNull(_ route: _StreamLeafRoute) {
    switch route {
    case .arrayOptionalStreamString:
      guard let top = self.topFrame else { return }
      _ = top.pointee.storage.assumingMemoryBound(to: StreamArray<StreamString?>.self)
        .pointee._openElement(nil)
    case .arrayOptionalBool:
      guard let top = self.topFrame else { return }
      _ = top.pointee.storage.assumingMemoryBound(to: StreamArray<Bool?>.self)
        .pointee._openElement(nil)
    case .arrayOptionalDouble:
      guard let top = self.topFrame else { return }
      _ = top.pointee.storage.assumingMemoryBound(to: StreamArray<Double?>.self)
        .pointee._openElement(nil)
    case .arrayOptionalInt:
      guard let top = self.topFrame else { return }
      _ = top.pointee.storage.assumingMemoryBound(to: StreamArray<Int?>.self)
        .pointee._openElement(nil)
    case .dictionaryOptionalStreamString:
      guard let storage = self.pendingDictionaryStorage else { return }
      self.pendingDictionaryStorage = nil
      storage.assumingMemoryBound(to: StreamString?.self).pointee = nil
    case .dictionaryOptionalBool:
      guard let storage = self.pendingDictionaryStorage else { return }
      self.pendingDictionaryStorage = nil
      storage.assumingMemoryBound(to: Bool?.self).pointee = nil
    default:
      return
    }
  }

  @inline(never)
  private mutating func openKnownDictionaryValue(
    _ storage: UnsafeMutableRawPointer,
    route: _StreamLeafRoute,
    forKey key: Span<UInt8>
  ) -> UnsafeMutableRawPointer {
    switch route {
    case .dictionaryStreamString:
      return storage.assumingMemoryBound(to: StreamDictionary<StreamString>.self).pointee
        ._openValue(forKey: key, initial: StreamString())
    case .dictionaryOptionalStreamString:
      return storage.assumingMemoryBound(to: StreamDictionary<StreamString?>.self).pointee
        ._openValue(forKey: key, initial: .some(StreamString()))
    case .dictionaryBool:
      return storage.assumingMemoryBound(to: StreamDictionary<Bool>.self).pointee
        ._openValue(forKey: key, initial: false)
    case .dictionaryOptionalBool:
      return storage.assumingMemoryBound(to: StreamDictionary<Bool?>.self).pointee
        ._openValue(forKey: key, initial: .some(false))
    default:
      preconditionFailure("A generic dictionary route reached the closed leaf opener")
    }
  }

  @inline(never)
  private mutating func openKnownSIMDDoubleElement(_ route: _StreamLeafRoute) {
    // `activeRouteBits` is zero with an empty stack, so the top frame is this array. Asserted, not
    // tolerated: returning without pushing would let the matching `endArray` pop the parent.
    guard let top = self.topFrame else {
      preconditionFailure("A SIMD array element opened with no frame for the array itself")
    }
    switch route {
    case .arraySIMD2Double:
      let storage = top.pointee.storage.assumingMemoryBound(
        to: StreamArray<SIMD2<Double>>.self
      ).pointee._openElement(.zero)
      self.pushFrame(BorrowedFrame(storage: storage, schema: _streamSIMD2DoubleSchema))
    case .arraySIMD3Double:
      let storage = top.pointee.storage.assumingMemoryBound(
        to: StreamArray<SIMD3<Double>>.self
      ).pointee._openElement(.zero)
      self.pushFrame(BorrowedFrame(storage: storage, schema: _streamSIMD3DoubleSchema))
    case .arraySIMD4Double:
      let storage = top.pointee.storage.assumingMemoryBound(
        to: StreamArray<SIMD4<Double>>.self
      ).pointee._openElement(.zero)
      self.pushFrame(BorrowedFrame(storage: storage, schema: _streamSIMD4DoubleSchema))
    case .arrayOptionalSIMD2Double:
      let storage = top.pointee.storage.assumingMemoryBound(
        to: StreamArray<SIMD2<Double>?>.self
      ).pointee._openElement(.some(.zero))
      self.pushFrame(BorrowedFrame(storage: storage, schema: _streamSIMD2DoubleSchema))
    case .arrayOptionalSIMD3Double:
      let storage = top.pointee.storage.assumingMemoryBound(
        to: StreamArray<SIMD3<Double>?>.self
      ).pointee._openElement(.some(.zero))
      self.pushFrame(BorrowedFrame(storage: storage, schema: _streamSIMD3DoubleSchema))
    case .arrayOptionalSIMD4Double:
      let storage = top.pointee.storage.assumingMemoryBound(
        to: StreamArray<SIMD4<Double>?>.self
      ).pointee._openElement(.some(.zero))
      self.pushFrame(BorrowedFrame(storage: storage, schema: _streamSIMD4DoubleSchema))
    default:
      preconditionFailure("A non-SIMD-array route reached the closed SIMD element opener")
    }
  }

  // Forced inline: `number`'s hottest arm on number-dense corpora, and `number` is itself out of
  // line, so an outlined call per element was most of this route's gap.
  @inline(__always)
  private mutating func appendHomogeneousDouble(_ bytes: Span<UInt8>, info: NumberInfo) {
    guard let value = Double(streamParsing: bytes, info: info) else {
      self.recordFailure(.typeMismatch)
      return
    }
    guard let top = self.topFrame else { return }
    top.pointee.storage.assumingMemoryBound(to: StreamArray<Double>.self).pointee
      ._appendClosed(value)
  }

  @inline(__always)
  private mutating func appendHomogeneousInt(_ bytes: Span<UInt8>, info: NumberInfo) {
    guard let value = Int(streamParsing: bytes, info: info) else {
      self.recordFailure(.typeMismatch)
      return
    }
    guard let top = self.topFrame else { return }
    top.pointee.storage.assumingMemoryBound(to: StreamArray<Int>.self).pointee
      ._appendClosed(value)
  }

  // The lane store for a `SIMD2/3/4<Double>` frame (Canada's coordinates). These routes exist only
  // for non-optional `.double` elements, so `knownScalarSlot` and `storeNumber`'s twelve-way switch
  // collapse to a bounds check and a scaled store. The cursor is bumped before the conversion so a
  // refused token leaves the frame where `knownScalarSlot` would.
  @inline(__always)
  private mutating func storeSIMDDoubleLane(_ bytes: Span<UInt8>, info: NumberInfo) {
    guard let top = self.topFrame else { return }
    let index = top.pointee.pendingField
    guard index < top.pointee.schema.fixedElementCount else {
      // Past the vector's arity: the same mismatch the lane path has always reported.
      self.recordFailure(.typeMismatch)
      return
    }
    top.pointee.pendingField = index &+ 1
    guard let value = Double(streamParsing: bytes, info: info) else {
      self.recordFailure(.typeMismatch)
      return
    }
    (top.pointee.storage + Int(index) &* MemoryLayout<Double>.stride)
      .assumingMemoryBound(to: Double.self).pointee = value
  }

  // The typed slot paths and the closure routes below, each outlined behind one word test in its
  // entry point, so the entry tail-calls a route without saving the closure branch's registers.
  @inline(never)
  private mutating func applyKnownNumber(_ bytes: Span<UInt8>, info: NumberInfo) {
    guard let (slot, kind) = self.knownScalarSlot() else { return }
    let result = Self.storeNumber(
      kind, optional: StreamRouteBits.elementOptional(self.activeRouteBits), at: slot, bytes, info
    )
    if result != .applied { self.recordFailure(Self.failureReason(for: result)) }
  }

  @inline(never)
  private mutating func applyKnownBoolean(_ value: Bool) {
    guard let (slot, kind) = self.knownScalarSlot() else { return }
    let result = Self.storeBoolean(
      kind, optional: StreamRouteBits.elementOptional(self.activeRouteBits), at: slot, value
    )
    if result != .applied { self.recordFailure(Self.failureReason(for: result)) }
  }

  @inline(never)
  private mutating func applyKnownNull() {
    guard let (slot, kind) = self.knownScalarSlot() else { return }
    let result = Self.storeNull(
      kind, optional: StreamRouteBits.elementOptional(self.activeRouteBits), at: slot,
      capacity: self.topFrame.unsafelyUnwrapped.pointee.schema.inlineCapacity
    )
    if result != .applied { self.recordFailure(Self.failureReason(for: result)) }
  }

  @inline(never)
  private mutating func applyNumberNormally(_ bytes: Span<UInt8>, info: NumberInfo) {
    self.withScalarTarget(
      table: { entry, storage, schema in
        entry.pointee.kind == .custom
          ? schema.applyNumber(storage, entry.pointee.index, bytes, info)
          : Self.writeTableNumber(entry, member: storage, bytes, info)
      }
    ) { storage, field, schema in
      schema.applyNumber(storage, field, bytes, info)
    }
  }

  @inline(never)
  private mutating func applyBooleanNormally(_ value: Bool) {
    self.withScalarTarget(
      table: { entry, storage, schema in
        entry.pointee.kind == .custom
          ? schema.applyBoolean(storage, entry.pointee.index, value)
          : Self.writeTableBoolean(entry, member: storage, value)
      }
    ) { storage, field, schema in
      schema.applyBoolean(storage, field, value)
    }
  }

  @inline(never)
  private mutating func applyNullNormally() {
    self.withScalarTarget(
      table: { entry, storage, schema in
        entry.pointee.kind == .custom || entry.pointee.kind == .container
          ? schema.applyNull(storage, entry.pointee.index)
          : Self.writeTableNull(entry, member: storage)
      }
    ) { storage, field, schema in
      schema.applyNull(storage, field)
    }
  }

  // MARK: Known scalar slots

  // The slot and kind for a scalar at the top frame when its child kind is one the table writes:
  // an array element (opened here), a dictionary value (opened by the key), a SIMD lane or
  // `InlineArray` slot (from the cursor). Nil sends it down the closure path.
  @inline(__always)
  private mutating func knownScalarSlot() -> (UnsafeMutableRawPointer, StreamFieldKind)? {
    guard let top = self.topFrame else { return nil }
    let kind = top.pointee.elementKind
    guard kind != .custom else { return nil }
    switch top.pointee.schema.shape {
    case .array:
      if top.pointee.leafRoute.usesFrameElementIndex {
        let index = top.pointee.pendingField
        guard index < top.pointee.schema.fixedElementCount else {
          // Past the arity: bounded storage overflowing for an `InlineArray`, a mismatch for a
          // vector, which is what each reported before the lanes were typed.
          self.recordFailure(
            top.pointee.leafRoute == .inlineArray ? .capacityExceeded : .typeMismatch
          )
          return nil
        }
        top.pointee.pendingField = index &+ 1
        return (
          top.pointee.storage + Int(index) &* Int(top.pointee.schema.elementStride), kind
        )
      }
      guard let slot = top.pointee.schema.appendElement(top.pointee.storage, -1) else {
        return nil
      }
      return (slot, kind)
    case .dictionary:
      guard let slot = self.pendingDictionaryStorage else { return nil }
      self.pendingDictionaryStorage = nil
      return (slot, kind)
    case .object, .scalar:
      return nil
    }
  }

  // MARK: Table writes

  // The key match against the top frame's table, through the schema's raw views: nothing here
  // loads a reference, so nothing is retained per key.
  @inline(__always)
  private static func matchTable(
    _ frame: UnsafeMutablePointer<BorrowedFrame>, _ key: Span<UInt8>
  ) -> Int32 {
    if let index = frame.pointee.schema.fieldIndex {
      return streamMatchFieldIndexed(
        frame.pointee.schema.fieldEntries.unsafelyUnwrapped,
        index: index,
        mask: frame.pointee.schema.fieldIndexMask,
        keyBytes: frame.pointee.schema.fieldKeyBytes.unsafelyUnwrapped,
        key
      )
    }
    return streamMatchField(
      frame.pointee.schema.fieldEntries.unsafelyUnwrapped,
      count: frame.pointee.schema.fieldCount,
      keyBytes: frame.pointee.schema.fieldKeyBytes.unsafelyUnwrapped,
      key
    )
  }

  // A table entry's target. For a kind the table writes, `storage` is the member's own address;
  // a `custom` or `container` entry keeps the object's storage, which is what its closures take.
  @inline(__always)
  private static func tableTarget(
    _ entry: UnsafePointer<StreamFieldEntry>,
    _ storage: UnsafeMutableRawPointer,
    _ schemaBits: UnsafeRawPointer
  ) -> ScalarTarget {
    let kind = entry.pointee.kind
    let direct = kind != .custom && kind != .container
    return ScalarTarget(
      storage: direct ? storage + Int(entry.pointee.offset) : storage,
      schemaBits: schemaBits,
      field: entry.pointee.index,
      entry: entry
    )
  }

  // The typed store behind every number kind: convert, then write the value or its `.some`. The
  // optional store is a typed assignment rather than a raw write because `Optional`'s tag is
  // laid out per payload type, and the compiler knows where.
  @inline(__always)
  private static func storeNumber<T: StreamNumberConvertible>(
    _ type: T.Type,
    at storage: UnsafeMutableRawPointer,
    optional: Bool,
    _ bytes: Span<UInt8>,
    _ info: NumberInfo
  ) -> StreamApplyResult {
    guard let value = T(streamParsing: bytes, info: info) else { return .unsupported }
    if optional {
      storage.assumingMemoryBound(to: T?.self).pointee = value
    } else {
      storage.assumingMemoryBound(to: T.self).pointee = value
    }
    return .applied
  }

  @inline(__always)
  private static func storeNil<T>(
    _ type: T.Type, at storage: UnsafeMutableRawPointer
  ) -> StreamApplyResult {
    storage.assumingMemoryBound(to: T?.self).pointee = nil
    return .applied
  }

  // The kinds the table writes, at the member's own address. `custom` is the caller's to route to
  // the closure, so the schema never comes through here.
  @inline(never)
  private static func writeTableNumber(
    _ entry: UnsafePointer<StreamFieldEntry>,
    member: UnsafeMutableRawPointer,
    _ bytes: Span<UInt8>,
    _ info: NumberInfo
  ) -> StreamApplyResult {
    Self.storeNumber(entry.pointee.kind, optional: entry.pointee.isOptional, at: member, bytes, info)
  }

  // A number of `kind` at `member`, or `.unsupported` for a kind that is not a number. One switch
  // shared by the table, the element, the value and the lane paths. Inlined: as an outlined call
  // it cost the SIMD lane path 3% against the direct Double store it replaced.
  @inline(__always)
  private static func storeNumber(
    _ kind: StreamFieldKind,
    optional: Bool,
    at member: UnsafeMutableRawPointer,
    _ bytes: Span<UInt8>,
    _ info: NumberInfo
  ) -> StreamApplyResult {
    switch kind {
    case .int: return Self.storeNumber(Int.self, at: member, optional: optional, bytes, info)
    case .double: return Self.storeNumber(Double.self, at: member, optional: optional, bytes, info)
    case .int64: return Self.storeNumber(Int64.self, at: member, optional: optional, bytes, info)
    case .uint64: return Self.storeNumber(UInt64.self, at: member, optional: optional, bytes, info)
    case .uint: return Self.storeNumber(UInt.self, at: member, optional: optional, bytes, info)
    case .int32: return Self.storeNumber(Int32.self, at: member, optional: optional, bytes, info)
    case .uint32: return Self.storeNumber(UInt32.self, at: member, optional: optional, bytes, info)
    case .int16: return Self.storeNumber(Int16.self, at: member, optional: optional, bytes, info)
    case .uint16: return Self.storeNumber(UInt16.self, at: member, optional: optional, bytes, info)
    case .int8: return Self.storeNumber(Int8.self, at: member, optional: optional, bytes, info)
    case .uint8: return Self.storeNumber(UInt8.self, at: member, optional: optional, bytes, info)
    case .float: return Self.storeNumber(Float.self, at: member, optional: optional, bytes, info)
    case .custom, .bool, .streamString, .inlineString, .container:
      return .unsupported
    }
  }

  @inline(never)
  private static func writeTableBoolean(
    _ entry: UnsafePointer<StreamFieldEntry>,
    member: UnsafeMutableRawPointer,
    _ value: Bool
  ) -> StreamApplyResult {
    Self.storeBoolean(entry.pointee.kind, optional: entry.pointee.isOptional, at: member, value)
  }

  @inline(__always)
  private static func storeBoolean(
    _ kind: StreamFieldKind, optional: Bool, at member: UnsafeMutableRawPointer, _ value: Bool
  ) -> StreamApplyResult {
    guard kind == .bool else { return .unsupported }
    if optional {
      member.assumingMemoryBound(to: Bool?.self).pointee = value
    } else {
      member.assumingMemoryBound(to: Bool.self).pointee = value
    }
    return .applied
  }

  // A null clears an optional member of any kind the table writes. A container member is nulled
  // through the closure, which knows the container's type; a non-optional member is a mismatch,
  // as `streamApplyNull`'s disfavoured overload always reported it.
  @inline(never)
  private static func writeTableNull(
    _ entry: UnsafePointer<StreamFieldEntry>,
    member: UnsafeMutableRawPointer
  ) -> StreamApplyResult {
    Self.storeNull(
      entry.pointee.kind, optional: entry.pointee.isOptional, at: member,
      capacity: entry.pointee.capacity
    )
  }

  @inline(never)
  private static func storeNull(
    _ kind: StreamFieldKind, optional: Bool, at member: UnsafeMutableRawPointer, capacity: Int32
  ) -> StreamApplyResult {
    guard optional else { return .unsupported }
    switch kind {
    case .int: return Self.storeNil(Int.self, at: member)
    case .double: return Self.storeNil(Double.self, at: member)
    case .int64: return Self.storeNil(Int64.self, at: member)
    case .uint64: return Self.storeNil(UInt64.self, at: member)
    case .uint: return Self.storeNil(UInt.self, at: member)
    case .int32: return Self.storeNil(Int32.self, at: member)
    case .uint32: return Self.storeNil(UInt32.self, at: member)
    case .int16: return Self.storeNil(Int16.self, at: member)
    case .uint16: return Self.storeNil(UInt16.self, at: member)
    case .int8: return Self.storeNil(Int8.self, at: member)
    case .uint8: return Self.storeNil(UInt8.self, at: member)
    case .float: return Self.storeNil(Float.self, at: member)
    case .bool: return Self.storeNil(Bool.self, at: member)
    case .streamString: return Self.storeNil(StreamString.self, at: member)
    case .inlineString:
      // `StreamInlineString<N>?`: the payload has no spare bits (an `Int32` count and raw bytes),
      // so the optional's tag is the byte after the payload, and nil is a one there.
      member.storeBytes(
        of: 1, toByteOffset: _streamInlineStringByteOffset + Int(capacity), as: UInt8.self
      )
      return .applied
    case .custom, .container:
      return .unsupported
    }
  }

  // Materialises an optional inline string by hand: a zero count and a zero tag after the payload.
  @inline(__always)
  private static func materializeInlineString(
    _ member: UnsafeMutableRawPointer, capacity: Int32
  ) {
    let tagOffset = _streamInlineStringByteOffset + Int(capacity)
    if member.load(fromByteOffset: tagOffset, as: UInt8.self) != 0 {
      member.storeBytes(of: 0, as: Int32.self)
      member.storeBytes(of: 0, toByteOffset: tagOffset, as: UInt8.self)
    }
  }

  // Opens a string member for in-place appends: materialises an optional, reserves the hinted
  // capacity, and points the chunk path at the storage. `storage` is the member's own address
  // for a kind the table writes and the object's for `custom`.
  @inline(never)
  private mutating func openTableString(
    _ entry: UnsafePointer<StreamFieldEntry>,
    _ storage: UnsafeMutableRawPointer
  ) -> StreamApplyResult {
    switch entry.pointee.kind {
    case .streamString:
      if entry.pointee.isOptional {
        _streamMaterializeOptional(storage, as: StreamString.self)
      }
      if entry.pointee.capacity > 0 {
        storage.assumingMemoryBound(to: StreamString.self).pointee
          .streamReserve(utf8ByteCount: Int(entry.pointee.capacity))
      }
      self.homogeneousStringStorage = storage
      self.scalarTarget = nil
      return .applied
    case .inlineString:
      if entry.pointee.isOptional {
        Self.materializeInlineString(storage, capacity: entry.pointee.capacity)
      }
      self.inlineStringCapacity = entry.pointee.capacity
      self.inlineStringStorage = storage
      // The chunks write through the slot; nothing needs the target, and holding it is a retain.
      self.scalarTarget = nil
      return .applied
    case .custom:
      // The closure route, exactly as before the table: the empty span materialises and settles.
      let target = self.scalarTarget.unsafelyUnwrapped
      let field = entry.pointee.index
      return target.withSchema { $0.applyString(storage, field, Span()) }
    default:
      return .unsupported
    }
  }

  // The whole-string form of `openTableString`, written from the frame.
  @inline(never)
  private mutating func writeTableString(
    _ entry: UnsafePointer<StreamFieldEntry>,
    frame: UnsafeMutablePointer<BorrowedFrame>,
    _ bytes: Span<UInt8>
  ) -> StreamApplyResult {
    let storage = frame.pointee.storage
    let member = storage + Int(entry.pointee.offset)
    switch entry.pointee.kind {
    case .streamString:
      if entry.pointee.isOptional {
        _streamMaterializeOptional(member, as: StreamString.self)
      }
      let string = member.assumingMemoryBound(to: StreamString.self)
      if entry.pointee.capacity > 0 {
        string.pointee.streamReserve(utf8ByteCount: Int(entry.pointee.capacity))
      }
      if bytes.count > 0 { string.pointee.streamAppend(utf8: bytes) }
      return .applied
    case .inlineString:
      if entry.pointee.isOptional {
        Self.materializeInlineString(member, capacity: entry.pointee.capacity)
      }
      return _streamInlineStringAppend(member, capacity: entry.pointee.capacity, bytes)
    case .custom:
      let opened = frame.pointee.schema.applyString(storage, entry.pointee.index, Span())
      if opened != .applied { return opened }
      if bytes.count > 0 {
        let result = frame.pointee.schema.applyString(storage, entry.pointee.index, bytes)
        if result != .applied { return result }
      }
      return frame.pointee.schema.finishString?(storage, entry.pointee.index) ?? .applied
    default:
      return .unsupported
    }
  }


  private mutating func resolveScalarTarget() -> ScalarTarget? {
    #if DEBUG && !hasFeature(Embedded)
      self.audit.verify()
    #endif
    guard let top = self.topFrame else {
      // A bare scalar document never opens a container, so no frame was ever pushed and the
      // root is the destination.
      guard !self.started else { return nil }
      guard self.rootSchema.shape == .scalar else {
        self.recordFailure(.typeMismatch)
        return nil
      }
      return ScalarTarget(
        storage: self.root,
        schemaBits: Unmanaged.passUnretained(self.rootSchema).toOpaque(),
        field: StreamSchema.wholeValueField,
        entry: nil
      )
    }
    switch top.pointee.schema.shape {
    case .array:
      guard let (slot, bits) = self.openElementSlot(top, dictionary: false) else { return nil }
      return ScalarTarget(
        storage: slot, schemaBits: bits, field: StreamSchema.wholeValueField, entry: nil
      )
    case .object:
      guard top.pointee.pendingField >= 0 else { return nil }
      if top.pointee.schema.keyRouting == .table {
        let entry = top.pointee.schema.fieldEntries.unsafelyUnwrapped + Int(top.pointee.pendingField)
        return Self.tableTarget(entry, top.pointee.storage, top.pointee.schemaBits)
      }
      return ScalarTarget(
        storage: top.pointee.storage, schemaBits: top.pointee.schemaBits,
        field: top.pointee.pendingField, entry: nil
      )
    case .dictionary:
      guard let (slot, bits) = self.openElementSlot(top, dictionary: true) else { return nil }
      return ScalarTarget(
        storage: slot, schemaBits: bits, field: StreamSchema.wholeValueField, entry: nil
      )
    case .scalar:
      return ScalarTarget(
        storage: top.pointee.storage, schemaBits: top.pointee.schemaBits,
        field: StreamSchema.wholeValueField, entry: nil
      )
    }
  }

  // A nil target means the destination has no such field, which is not an error: unknown keys
  // have always been ignored. A target that refuses the token is a type mismatch, because the
  // key matched something that cannot hold this kind of value. `table` writes a target that is a
  // field entry; `body` is the closure route for everything else.
  private mutating func withScalarTarget(
    table: (UnsafePointer<StreamFieldEntry>, UnsafeMutableRawPointer, StreamSchema) -> StreamApplyResult,
    _ body: (UnsafeMutableRawPointer, Int32, StreamSchema) -> StreamApplyResult
  ) {
    guard let target = self.resolveScalarTarget() else { return }
    let result =
      if let entry = target.entry {
        target.withSchema { table(entry, target.storage, $0) }
      } else {
        target.withSchema { body(target.storage, target.field, $0) }
      }
    if result != .applied {
      self.recordFailure(Self.failureReason(for: result))
    }
  }

  // The sink reports one reason per failed apply. `unsupported` and anything a later version of
  // the enum adds read as a mismatch, which is what this sink could always say about a token a
  // destination refused; only capacity has a distinct answer.
  @usableFromInline
  static func failureReason(for result: StreamApplyResult) -> StreamSinkFailure.Reason {
    switch result {
    case .capacityExceeded: .capacityExceeded
    case .conversionFailed: .conversionFailed
    default: .typeMismatch
    }
  }

  @usableFromInline
  mutating func recordFailure(_ reason: StreamSinkFailure.Reason) {
    guard self.streamFailure == nil else { return }
    self.streamFailure = StreamSinkFailure(reason: reason)
  }

  // A frame over a subtree the destination has no field for, whose schema discards everything;
  // without it an unknown key's nested object routes to the parent. Built from bits: storing the
  // global as a reference was a retain/release per ignored container.
  @usableFromInline
  var ignoredFrame: BorrowedFrame {
    BorrowedFrame(storage: self.root, schemaBits: ignoredStreamSchemaBits)
  }
}

@usableFromInline let ignoredStreamSchema = StreamSchema(shape: .object)
@usableFromInline nonisolated(unsafe) let ignoredStreamSchemaBits = UnsafeRawPointer(
  Unmanaged.passUnretained(ignoredStreamSchema).toOpaque()
)

extension PartialSink {
  public init<Root: StreamParseableRoot>(root: UnsafeMutablePointer<Root>) {
    self.init(root: UnsafeMutableRawPointer(root), schema: Root.streamSchema)
  }
}
