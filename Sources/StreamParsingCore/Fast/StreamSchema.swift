public struct StreamFrame {
  public var storage: UnsafeMutableRawPointer
  public var schema: StreamSchema
  public var pendingField: Int32

  public init(storage: UnsafeMutableRawPointer, schema: StreamSchema, pendingField: Int32 = -1) {
    self.storage = storage
    self.schema = schema
    self.pendingField = pendingField
  }
}

// MARK: - Closed homogeneous leaf routes

// A closed byte naming the exact standard-library/storage pairings `PartialSink` can see through.
// Everything else stays `.generic` and goes through the schema closures, so a custom conformer is
// always correct and a fast route is always an explicit benchmarked choice. A scalar schema carries
// a `value...` case only so a container builder can map it; only container cases reach a frame.
@usableFromInline
enum _StreamLeafRoute: UInt8, Sendable {
  case generic
  case valueStreamString
  // Bounded inline storage of *any* capacity: the one route that is not tied to a single
  // destination type. The capacity travels in the schema's `fixedElementCount`, so one case
  // serves every `StreamInlineString<N>` and the sink never has to name one.
  case valueInlineString
  case valueBool
  case valueDouble
  case valueInt
  case valueOptionalStreamString
  case valueOptionalBool
  case valueOptionalDouble
  case valueOptionalInt
  case arrayStreamString
  case arrayOptionalStreamString
  case arrayBool
  case arrayOptionalBool
  case arrayDouble
  case arrayInt
  case arrayOptionalDouble
  case arrayOptionalInt
  case dictionaryStreamString
  case dictionaryOptionalStreamString
  case dictionaryBool
  case dictionaryOptionalBool
  // Kept contiguous and ordered by width. The sink uses the route both to distinguish a fixed
  // array from an ordinary one and to recover the exact arity without storing another field in
  // every schema. The generic cases still call `applyNumber`; the Double cases bypass it.
  case simd2Number
  case simd3Number
  case simd4Number
  case simd2Double
  case simd3Double
  case simd4Double
  case optionalSIMD2Double
  case optionalSIMD3Double
  case optionalSIMD4Double
  case arraySIMD2Double
  case arraySIMD3Double
  case arraySIMD4Double
  case arrayOptionalSIMD2Double
  case arrayOptionalSIMD3Double
  case arrayOptionalSIMD4Double
  case inlineArray

  @usableFromInline
  var fixedSIMDLaneCount: Int32 {
    switch self {
    case .simd2Number, .simd2Double, .optionalSIMD2Double: 2
    case .simd3Number, .simd3Double, .optionalSIMD3Double: 3
    case .simd4Number, .simd4Double, .optionalSIMD4Double: 4
    default: 0
    }
  }

  @usableFromInline
  var usesFrameElementIndex: Bool {
    self == .inlineArray || self.fixedSIMDLaneCount != 0
  }

  @usableFromInline
  static func optionalValue(_ base: Self) -> Self {
    switch base {
    case .valueStreamString: .valueOptionalStreamString
    case .valueBool: .valueOptionalBool
    case .valueDouble: .valueOptionalDouble
    case .valueInt: .valueOptionalInt
    case .simd2Double: .optionalSIMD2Double
    case .simd3Double: .optionalSIMD3Double
    case .simd4Double: .optionalSIMD4Double
    // No optional twin, but the lane route must survive: it is what makes the frame count lanes,
    // and without it every lane of an optional element found no slot and was dropped.
    case .simd2Number, .simd3Number, .simd4Number: base
    default: .generic
    }
  }

  @usableFromInline
  static func array(_ element: Self) -> Self {
    switch element {
    case .valueStreamString: .arrayStreamString
    case .valueOptionalStreamString: .arrayOptionalStreamString
    case .valueBool: .arrayBool
    case .valueOptionalBool: .arrayOptionalBool
    case .valueDouble: .arrayDouble
    case .valueInt: .arrayInt
    case .valueOptionalDouble: .arrayOptionalDouble
    case .valueOptionalInt: .arrayOptionalInt
    case .simd2Double: .arraySIMD2Double
    case .simd3Double: .arraySIMD3Double
    case .simd4Double: .arraySIMD4Double
    case .optionalSIMD2Double: .arrayOptionalSIMD2Double
    case .optionalSIMD3Double: .arrayOptionalSIMD3Double
    case .optionalSIMD4Double: .arrayOptionalSIMD4Double
    default: .generic
    }
  }

  @usableFromInline
  static func dictionary(_ value: Self) -> Self {
    switch value {
    case .valueStreamString: .dictionaryStreamString
    case .valueOptionalStreamString: .dictionaryOptionalStreamString
    case .valueBool: .dictionaryBool
    case .valueOptionalBool: .dictionaryOptionalBool
    default: .generic
    }
  }
}

// The packing of a frame's route word: the leaf route in the low byte, the element kind above
// it, the element's optionality above that. `elementKindMask` is non-zero exactly when a scalar
// arriving at the frame has a typed slot, which is the one test the scalar entry points make.
@usableFromInline
enum StreamRouteBits {
  @usableFromInline static var elementKindShift: UInt32 { 8 }
  @usableFromInline static var elementKindMask: UInt32 { 0xff << 8 }
  @usableFromInline static var elementOptionalBit: UInt32 { 1 << 16 }

  @inlinable
  static func pack(
    leafRoute: _StreamLeafRoute, elementKind: StreamFieldKind, elementOptional: Bool
  ) -> UInt32 {
    UInt32(leafRoute.rawValue)
      | (UInt32(elementKind.rawValue) << Self.elementKindShift)
      | (elementOptional ? Self.elementOptionalBit : 0)
  }

  // Bit casts, not `init(rawValue:)`: the word was packed from these enums, and the raw-value
  // initialiser is a range check and an unwrap on every read, which put a dozen instructions
  // back into each scalar entry point.
  @inlinable
  static func leafRoute(_ bits: UInt32) -> _StreamLeafRoute {
    unsafeBitCast(UInt8(truncatingIfNeeded: bits), to: _StreamLeafRoute.self)
  }

  @inlinable
  static func elementKind(_ bits: UInt32) -> StreamFieldKind {
    unsafeBitCast(UInt8(truncatingIfNeeded: bits >> Self.elementKindShift), to: StreamFieldKind.self)
  }

  @inlinable
  static func elementOptional(_ bits: UInt32) -> Bool { bits & Self.elementOptionalBit != 0 }
}

// `@unchecked` only for the three raw views of the field table below: immutable pointers into
// storage the schema itself owns for its whole lifetime, read and never written after `init`.
public final class StreamSchema: @unchecked Sendable {
  public enum Shape: UInt8, Sendable {
    case object
    case array
    case dictionary
    case scalar

    // Whether a container of `kind` can be written through a destination of this shape: a JSON object
    // reaches both an object and a dictionary, every other pairing is a type mismatch. Without it a
    // scalar destination absorbs any container that reaches it, because a scalar frame ignores keys
    // and applies every token to itself.
    public func canHold(container kind: Shape) -> Bool {
      switch (self, kind) {
      case (.object, .object), (.dictionary, .object), (.array, .array): true
      default: false
      }
    }
  }

  /// Which of a type's schemas is meant: the one for where the parser meets a value, relative to
  /// whatever holds it.
  ///
  /// Each usage has its own requirement, which defaults to ``root``'s, so the schemas differ only
  /// for a type that says otherwise -- `Optional`, whose element and value slots are opened already
  /// materialised. ``StreamSchemaCache`` keys each entry by type and usage.
  @nonexhaustive
  public enum Usage: Hashable, Sendable {
    /// The document's root: ``StreamParseableRoot/streamSchema``.
    case root
    /// An element of an array: ``StreamParseableRoot/streamArrayElementSchema``.
    case arrayElement
    /// A value in a dictionary: ``StreamParseableRoot/streamDictionaryValueSchema``.
    case dictionaryValue
    /// A declared member of an object, entered as its own frame:
    /// ``StreamContainerPartial/streamObjectMemberSchema``.
    case objectMember
  }

  public let shape: Shape

  /// Prepares root storage before a container frame begins writing through this schema.
  ///
  /// Most roots already hold their initialized value and need no work. Wrappers such as
  /// `Optional` use this hook to materialize storage even when an empty container produces no
  /// field or element events that would otherwise do so.
  public let prepareRoot: @Sendable (UnsafeMutableRawPointer) -> Void

  /// The field an apply closure receives when the destination *is* the value rather than a field
  /// of one -- an array element, a dictionary value, a bare scalar root.
  ///
  /// Must stay negative so it cannot collide with a declared field: at zero it collided with the
  /// first member a generated object schema declares, and an object schema's `default:
  /// .unsupported` is what turns those back into the mismatches they are.
  public static let wholeValueField = Int32(-1)

  // Where a key arriving at this schema has to go, precomputed into one byte so the common case --
  // a subtree the destination has no field for, 52% of `twitter.json`'s keys for a typical model --
  // never loads and calls a closure to reach `{ _ in -1 }`. Measured: 17 ns against 4.6 ns for a
  // bare function pointer; keep the byte, one load and one switch.
  @usableFromInline
  enum KeyRouting: UInt8, Sendable {
    case match
    case dictionary
    case ignore
    // Keys resolve against the field table; `pendingField` on such a frame is a table index.
    case table
  }

  @usableFromInline let keyRouting: KeyRouting
  // Only key recognition consults hooks; scalar/container routing retains its original flag.
  @usableFromInline let keyDispatch: _StreamKeyDispatch

  // The field table (StreamFieldTable.swift), or nil for a schema that routes keys through
  // `matchField`. Every macro-generated object schema carries one. The owner is `fields`; the
  // sink reads the three raw views, because loading a class reference off a frame's
  // `unowned(unsafe)` schema is a retain and a release, and the sink does it per key.
  @usableFromInline let fields: StreamFieldTable?
  @usableFromInline let fieldEntries: UnsafePointer<StreamFieldEntry>?
  @usableFromInline let fieldCount: Int
  @usableFromInline let fieldKeyBytes: UnsafePointer<UInt8>?
  @usableFromInline let fieldPrepares: UnsafePointer<StreamFieldPrepare?>?
  // The open-addressed index over `fields`, or nil below `StreamFieldTable.indexThreshold`.
  @usableFromInline let fieldIndex: UnsafePointer<Int32>?
  @usableFromInline let fieldIndexMask: Int

  /// The members the field table was built from, in declaration order; empty without a table.
  var declaredFields: [StreamField] { self.fields?.declared ?? [] }

  // The schema an array's elements or a dictionary's values are written through. Data on the
  // parent, not a value the closure returns: returning a `StreamFrame` meant a retain on the way
  // out and a release when the sink lowered it, per element. The bits are what the sink copies
  // into a frame (see `StreamFieldEntry.schemaBits`); the strong reference is the owner.
  public let elementSchema: StreamSchema?
  @usableFromInline let elementSchemaBits: UnsafeRawPointer?

  // For a fixed array whose elements sit at a stride from its storage -- an `InlineArray`, a SIMD
  // vector's lanes: the sink addresses element `i` at `storage + i * elementStride` and calls
  // nothing. Zero for every other schema.
  @usableFromInline let elementStride: Int32

  // The kind of value this schema writes when it stands over a scalar, in the same vocabulary the
  // field table uses for an object's members, so an array element, dictionary value or SIMD lane of
  // a known type is a typed store at the slot rather than a closure call. `custom` for anything
  // else; `scalarOptional` says the slot is an `Optional` opened `.some`, so a null writes `nil`.
  @usableFromInline let scalarKind: StreamFieldKind
  @usableFromInline let scalarOptional: Bool

  // The child's `scalarKind` and `scalarOptional`, cached on the container so the frame over it
  // can copy them at push time: a scalar arriving at an array, dictionary or fixed-array frame
  // reads a byte off the frame rather than chasing the element schema.
  @usableFromInline let elementKind: StreamFieldKind
  @usableFromInline let elementOptional: Bool

  // `leafRoute`, `elementKind` and `elementOptional` in one word, which is what a frame copies at
  // push and the sink caches as its active route: one load and one store, where three bytes
  // measured as a 1-3% drift on every corpus. Layout in `StreamRouteBits`.
  @usableFromInline let routeBits: UInt32

  // Whether this schema declares no matcher. Read when one schema is wrapped in another, so the
  // wrapper does not install a matcher over a destination that has none.
  @usableFromInline let ignoresKeys: Bool

  // Returns the field identifier for a key, or -1 when the destination has no such field.
  public let matchField: @Sendable (Span<UInt8>) -> Int32

  // Each reports what the destination did with the token: `.unsupported` for a matched field with no
  // destination for this token kind (how the sink tells a type mismatch from an absent key),
  // `.capacityExceeded` for full bounded storage. A result rather than a throw, because the check
  // after every call is on the hottest path. `field` is `wholeValueField` for a value destination.
  public let applyString: @Sendable (UnsafeMutableRawPointer, Int32, Span<UInt8>) -> StreamApplyResult
  public let applyNumber: @Sendable (
    UnsafeMutableRawPointer, Int32, Span<UInt8>, NumberInfo
  ) -> StreamApplyResult
  public let applyBoolean: @Sendable (UnsafeMutableRawPointer, Int32, Bool) -> StreamApplyResult
  public let applyNull: @Sendable (UnsafeMutableRawPointer, Int32) -> StreamApplyResult

  // Returns a frame for the container stored at `field`, materializing it when absent. It is not
  // reset when present, so a repeated key resumes the container the first occurrence built.
  // `ContainerReentryTests` pins that and the scalar cases, which do not agree with each other:
  // a repeated string concatenates and a repeated number replaces.
  public let enterField: @Sendable (UnsafeMutableRawPointer, Int32) -> StreamFrame?

  // Appends an element and returns its slot, which the sink writes through ``elementSchema``.
  // Arrays only. `index` is the element's position, which a dynamic array ignores.
  public let appendElement: @Sendable (UnsafeMutableRawPointer, Int32) -> UnsafeMutableRawPointer?

  // Returns the slot of the value stored under a dynamic key, written through
  // ``elementSchema``. Dictionaries only.
  public let enterKey: @Sendable (UnsafeMutableRawPointer, Span<UInt8>) -> UnsafeMutableRawPointer?

  // Appends a run of numbers to an array whose elements are numbers: `(storage, batch, from, to)`
  // appends the `number` records in `from..<to` and returns how many it took. Arrays of
  // number-convertible elements only; nil means the batch is unrolled through `appendElement` and
  // `applyNumber` one number at a time.
  public let appendNumbers: (
    @Sendable (UnsafeMutableRawPointer, borrowing StreamEventBatch, Int, Int) -> Int
  )?

  // Exact homogeneous operations the sink may perform without constructing a StreamFrame or
  // calling a stored closure. Hand-written schemas and unrecognized protocol conformers remain
  // `.generic`, preserving the public API's open-ended behavior.
  @usableFromInline let leafRoute: _StreamLeafRoute

  // The capacity of the bounded inline storage this schema writes into, or zero when the
  // destination is not bounded. Carried separately from `fixedElementCount` so that field keeps
  // meaning exactly one thing -- a fixed array's arity -- and a container schema can propagate its
  // element's capacity without the two colliding.
  @usableFromInline let inlineCapacity: Int32

  // Negative for a dynamic array. Kept off the frame: only an InlineArray's open and close need
  // it, while adding it to BorrowedFrame would grow every frame from 24 to 32 bytes.
  @usableFromInline let fixedElementCount: Int32

  // The box owning the element template a container schema's `appendElement`/`enterKey` copies
  // from, or nil for a schema with no template. Held only to bound the template's lifetime by the
  // schema's: the closures capture the raw pointer, never this. See `_StreamTemplateStorage`.
  @usableFromInline let templateOwner: _StreamTemplateStorage?

  /// Completes a string accepted by `applyString`. Nil for ordinary incremental string storage.
  /// The field identifier has the same meaning as in `applyString`.
  public let finishString: (@Sendable (UnsafeMutableRawPointer, Int32) -> StreamApplyResult)?

  // A converted container borrows its source's normal schema while the sink remembers where
  // to write its completed value. Ordinary schemas carry nil; ordinary frames stay 24 bytes.
  @usableFromInline let completedValue: _StreamCompletedValueHooks?

  /// Called once for each recognized object key, before its value is applied.
  /// Aliases share an identifier; unknown keys are not reported. Nil incurs no hook dispatch.
  public let onFieldRecognized: (@Sendable (UnsafeMutableRawPointer, StreamFieldID) -> Void)?



  // `matchField` is optional rather than defaulted so that "no matcher" is a fact the schema
  // carries rather than one indistinguishable from a matcher that happens to answer -1.
  public convenience init(
    shape: Shape,
    prepareRoot: @escaping @Sendable (UnsafeMutableRawPointer) -> Void = { _ in },
    matchField: (@Sendable (Span<UInt8>) -> Int32)? = nil,
    onFieldRecognized: (@Sendable (UnsafeMutableRawPointer, StreamFieldID) -> Void)? = nil,
    applyString: @escaping @Sendable (
      UnsafeMutableRawPointer, Int32, Span<UInt8>
    ) -> StreamApplyResult = { _, _, _ in .unsupported },
    applyNumber: @escaping @Sendable (
      UnsafeMutableRawPointer, Int32, Span<UInt8>, NumberInfo
    ) -> StreamApplyResult = { _, _, _, _ in .unsupported },
    applyBoolean: @escaping @Sendable (
      UnsafeMutableRawPointer, Int32, Bool
    ) -> StreamApplyResult = { _, _, _ in .unsupported },
    applyNull: @escaping @Sendable (UnsafeMutableRawPointer, Int32) -> StreamApplyResult = {
      _, _ in .unsupported
    },
    finishString: (@Sendable (UnsafeMutableRawPointer, Int32) -> StreamApplyResult)? = nil,
    enterField: @escaping @Sendable (UnsafeMutableRawPointer, Int32) -> StreamFrame? = { _, _ in nil },
    appendElement: @escaping @Sendable (UnsafeMutableRawPointer, Int32) -> UnsafeMutableRawPointer? = {
      _, _ in nil
    },
    enterKey: @escaping @Sendable (UnsafeMutableRawPointer, Span<UInt8>) -> UnsafeMutableRawPointer? = {
      _, _ in nil
    },
    appendNumbers: (@Sendable (UnsafeMutableRawPointer, borrowing StreamEventBatch, Int, Int) -> Int)? = nil,
    elementSchema: StreamSchema? = nil,
    fields: [StreamField] = []
  ) {
    self.init(
      shape: shape,
      prepareRoot: prepareRoot,
      matchField: matchField,
      onFieldRecognized: onFieldRecognized,
      applyString: applyString,
      applyNumber: applyNumber,
      applyBoolean: applyBoolean,
      applyNull: applyNull,
      finishString: finishString,
      enterField: enterField,
      appendElement: appendElement,
      enterKey: enterKey,
      appendNumbers: appendNumbers,
      elementSchema: elementSchema,
      leafRoute: .generic,
      fixedElementCount: -1,
      inlineCapacity: 0,
      fields: fields.isEmpty ? nil : StreamFieldTable(fields)
    )
  }

  @usableFromInline
  init(
    shape: Shape,
    prepareRoot: @escaping @Sendable (UnsafeMutableRawPointer) -> Void = { _ in },
    matchField: (@Sendable (Span<UInt8>) -> Int32)? = nil,
    onFieldRecognized: (@Sendable (UnsafeMutableRawPointer, StreamFieldID) -> Void)? = nil,
    applyString: @escaping @Sendable (
      UnsafeMutableRawPointer, Int32, Span<UInt8>
    ) -> StreamApplyResult = { _, _, _ in .unsupported },
    applyNumber: @escaping @Sendable (
      UnsafeMutableRawPointer, Int32, Span<UInt8>, NumberInfo
    ) -> StreamApplyResult = { _, _, _, _ in .unsupported },
    applyBoolean: @escaping @Sendable (
      UnsafeMutableRawPointer, Int32, Bool
    ) -> StreamApplyResult = { _, _, _ in .unsupported },
    applyNull: @escaping @Sendable (UnsafeMutableRawPointer, Int32) -> StreamApplyResult = {
      _, _ in .unsupported
    },
    finishString: (@Sendable (UnsafeMutableRawPointer, Int32) -> StreamApplyResult)? = nil,
    enterField: @escaping @Sendable (UnsafeMutableRawPointer, Int32) -> StreamFrame? = { _, _ in nil },
    appendElement: @escaping @Sendable (UnsafeMutableRawPointer, Int32) -> UnsafeMutableRawPointer? = {
      _, _ in nil
    },
    enterKey: @escaping @Sendable (UnsafeMutableRawPointer, Span<UInt8>) -> UnsafeMutableRawPointer? = {
      _, _ in nil
    },
    appendNumbers: (
      @Sendable (UnsafeMutableRawPointer, borrowing StreamEventBatch, Int, Int) -> Int
    )? = nil,
    elementSchema: StreamSchema? = nil,
    elementStride: Int32 = 0,
    scalarKind: StreamFieldKind = .custom,
    scalarOptional: Bool = false,
    elementKind: StreamFieldKind? = nil,
    elementOptional: Bool? = nil,
    leafRoute: _StreamLeafRoute = .generic,
    fixedElementCount: Int32 = -1,
    inlineCapacity: Int32 = 0,
    fields: StreamFieldTable? = nil,
    templateOwner: _StreamTemplateStorage? = nil,
    completedValue: _StreamCompletedValueHooks? = nil
  ) {
    self.finishString = finishString
    self.completedValue = completedValue
    self.templateOwner = templateOwner
    self.shape = shape
    self.prepareRoot = prepareRoot
    self.fields = fields
    self.fieldEntries = fields.map { UnsafePointer($0.entries) }
    self.fieldCount = fields?.count ?? 0
    self.fieldKeyBytes = fields.map { UnsafePointer($0.keyBytes) }
    self.fieldPrepares = fields.map { UnsafePointer($0.prepares) }
    self.fieldIndex = fields?.index.map { UnsafePointer($0) }
    self.fieldIndexMask = fields?.indexMask ?? 0
    self.elementSchema = elementSchema
    self.elementSchemaBits = elementSchema.map {
      UnsafeRawPointer(Unmanaged.passUnretained($0).toOpaque())
    }
    self.elementStride = elementStride
    self.scalarKind = scalarKind
    self.scalarOptional = scalarOptional
    // Defaulted from the element schema, so a container builder says nothing; a SIMD schema,
    // which has lanes rather than an element schema, names its lane kind directly.
    self.elementKind = elementKind ?? elementSchema?.scalarKind ?? .custom
    self.elementOptional = elementOptional ?? elementSchema?.scalarOptional ?? false
    self.routeBits = StreamRouteBits.pack(
      leafRoute: leafRoute, elementKind: self.elementKind, elementOptional: self.elementOptional
    )
    self.ignoresKeys = matchField == nil && fields == nil
    // A dictionary routes keys through `enterKey` whether or not it also carries a matcher, which
    // is the order the sink already applied. A table outranks a matcher: a schema built with both
    // matches through the table, and the matcher only serves a schema that wraps this one.
    self.keyRouting =
      shape == .dictionary
      ? .dictionary
      : (fields != nil ? .table : (matchField == nil ? .ignore : .match))
    self.keyDispatch = switch self.keyRouting {
    case .table: onFieldRecognized == nil ? .table : .observedTable
    case .match: onFieldRecognized == nil ? .match : .observedMatch
    case .dictionary: .dictionary
    case .ignore: .ignore
    }
    self.matchField = matchField ?? { _ in -1 }
    self.onFieldRecognized = onFieldRecognized
    self.applyString = applyString
    self.applyNumber = applyNumber
    self.applyBoolean = applyBoolean
    self.applyNull = applyNull
    self.enterField = enterField
    self.appendElement = appendElement
    self.appendNumbers = appendNumbers
    self.enterKey = enterKey
    self.leafRoute = leafRoute
    self.fixedElementCount = fixedElementCount
    self.inlineCapacity = inlineCapacity
  }
}

// Anything that can describe its own routing, whatever shape it is. A root schema has to be a
// protocol requirement rather than a macro overload, because a function generic over `Value` --
// `partials(of:from:)` -- cannot pick an overload on its behalf. Kept separate from
// `StreamParseableObject` so the constrained `_streamFieldRoute` cannot route a `String` field.
public protocol StreamParseableRoot: StreamInitializable {
  static var streamSchema: StreamSchema { get }

  #if !hasFeature(Embedded)
    /// Direct stored key paths used to validate field observation. Generated by `@StreamParseable`.
    ///
    /// Custom roots must list every stored member, including members ignored by their schema,
    /// so observation can reject ambiguous overlapping storage. Do not include computed or
    /// nested paths. The default empty list disables field observation.
    static var streamObservationFields: [PartialKeyPath<Self>] { get }
  #endif

  /// Appends a run of numbers to a `StreamArray<Self>` in one call, or `nil` when `Self` is not
  /// a number. Supplied for every ``StreamNumberConvertible`` type; the array schema carries it
  /// as ``StreamSchema/appendNumbers`` so `PartialSink` can take a batch without routing each
  /// number through a frame.
  static var _streamArrayNumberAppender:
    (@Sendable (UnsafeMutableRawPointer, borrowing StreamEventBatch, Int, Int) -> Int)? { get }

  /// The schema this type is written through as an array element, and the value the array opens
  /// the element's slot with. ``StreamSchema/Usage/arrayElement``.
  ///
  /// These differ from ``streamSchema`` and ``StreamInitializable/streamInitialValue()`` only for
  /// `Optional`: an array owns the slot it hands out and can open it already materialised, so an
  /// optional element never checks for `nil` before a write, where a bare optional *root* must.
  /// Worth 2.4x on `[Int?]` (NEW_ARCHITECTURE.md, "The optional seam"). The defaults are the root
  /// forms, so every type but `Optional` conforms without saying anything.
  static var streamArrayElementSchema: StreamSchema { get }

  /// - SeeAlso: ``streamArrayElementSchema``
  static func streamInitialArrayElement() -> Self

  /// The schema this type is written through as a dictionary value, and the value the dictionary
  /// opens the value's slot with. ``StreamSchema/Usage/dictionaryValue``.
  ///
  /// A dictionary owns the slot it opens under a key exactly as an array owns an element's, so
  /// the defaults are the array-element forms, which is what `Optional` relies on.
  static var streamDictionaryValueSchema: StreamSchema { get }

  /// - SeeAlso: ``streamDictionaryValueSchema``
  static func streamInitialDictionaryValue() -> Self

  /// What a whole-value `null` writes into a member of this type, or `nil` for a type that has
  /// no null of its own, whose optional member is cleared instead.
  ///
  /// The macro decides this from a member's declared type (`streamApplyNull`'s overloads) except
  /// where that type is a generic parameter's `Partial`, which the overloads cannot see through.
  /// Defaults to ``StreamNullable/streamNullValue()`` for a nullable type, so `Box<Int?>` takes a
  /// `null` as `.some(nil)` -- a present null, as `Codable` reads it -- where a concrete `Int?`
  /// member, whose optionality is written, has only the one `nil`.
  static var _streamNullValue: Self? { get }

  /// Whether a container opens a slot of this type by constructing ``streamInitialValue()``
  /// rather than copying the template its schema hoisted.
  ///
  /// True for the `Partial` the macro generates for a generic struct, and `false` for everything
  /// else. A bound generic struct's copy is not emitted field by field: it fetches the type's
  /// metadata and calls its value witness, which walks the fields through metadata too. Measured
  /// on the matched Twitter model, one generic level cost 1.5% per element opened that way, while
  /// constructing is the specialised `init`'s inline stores. A concrete `Partial` keeps the
  /// template: its copy is inline, and its `streamInitialValue()` is itself a copy of one.
  static var _streamOpensByConstruction: Bool { get }

  /// A borrowed window onto the value, for reading part of it without copying the whole.
  ///
  /// Defaults to ``StreamPointerView``, which is what a scalar wants. A type with members worth
  /// reading one at a time overrides it with a projection whose accessors copy only what they return.
  ///
  /// With the `LifetimeView` trait this is `~Escapable`, so "must outlive the view" on
  /// ``streamView(_:)`` is compiler-checked rather than merely documented. Without the trait,
  /// views are escapable unsafe pointer projections and callers must uphold that invariant.
  /// There is deliberately no `= Self` fallback because the macro generates member projections.
#if LifetimeView
  associatedtype View: ~Copyable, ~Escapable
#else
  associatedtype View: ~Copyable
#endif

  /// Builds a view over a value at `storage`.
  ///
  /// The lifetime dependency on `storage` ties the returned view's borrow-checked scope to the
  /// call site: the pointer itself carries no lifetime of its own, but the dependency still
  /// forces callers through an API shape (like a `withView`-style closure) that cannot let the
  /// view outlive the call that produced it.
#if LifetimeView
  @_lifetime(borrow storage)
#else
  @unsafe
#endif
  static func streamView(_ storage: UnsafeMutableRawPointer) -> View
}

extension StreamParseableRoot {
  @inlinable
  public static var streamArrayElementSchema: StreamSchema { Self.streamSchema }

  @inlinable
  public static func streamInitialArrayElement() -> Self { Self.streamInitialValue() }

  @inlinable
  public static var streamDictionaryValueSchema: StreamSchema { Self.streamArrayElementSchema }

  @inlinable
  public static func streamInitialDictionaryValue() -> Self { Self.streamInitialArrayElement() }

  @inlinable
  public static var _streamNullValue: Self? { nil }

  @inlinable
  public static var _streamOpensByConstruction: Bool { false }
}

extension StreamParseableRoot where Self: StreamNullable {
  @inlinable
  public static var _streamNullValue: Self? { Self.streamNullValue() }
}

extension StreamParseableRoot where View == StreamPointerView<Self> {
  // A correct snapshot without a recursive rebuild: every container the parser writes into holds
  // its open element in an inline slot, so a copy shares only storage that is sealed and never
  // written again, and the open element's own buffers copy on write at the next append.
#if LifetimeView
  @_lifetime(borrow storage)
#else
  @unsafe
#endif
  public static func streamView(_ storage: UnsafeMutableRawPointer) -> StreamPointerView<Self> {
    StreamPointerView(storage)
  }
}

/// A partial that can receive an incoming container when stored as a field.
///
/// The entry operation lives on the resolved partial type, so aliases and generic wrappers do not
/// need to expose their shape in source syntax. A partial whose storage is described directly by
/// its ``StreamParseableRoot/streamSchema`` can use the default implementation.
public protocol StreamContainerPartial: StreamParseableRoot {
  /// The schema a container entry installs on the frame it pushes when this type is a declared
  /// member of an object. ``StreamSchema/Usage/objectMember``.
  ///
  /// Separated from the frame so a caller can resolve it once and store it: `streamSchema` is a
  /// computed property on every generic partial, so reading it per entry allocates per container
  /// occurrence and leaves the entry's frame as the schema's only owner. The macro resolves it
  /// once per schema build, and the parent's field table owns the result.
  static var streamObjectMemberSchema: StreamSchema { get }

  /// Makes the storage of a member of this type ready for ``streamObjectMemberSchema`` to write
  /// through, before the sink pushes a frame over it; runs once per container occurrence. `nil`
  /// for a type whose storage is its own value, which is every type but `Optional`, which
  /// materialises its payload here. The table stores it as the member's `prepare`.
  static var _streamObjectMemberPrepare: StreamFieldPrepare? { get }
}

extension StreamContainerPartial {
  @inlinable
  public static var streamObjectMemberSchema: StreamSchema {
    Self.streamSchema
  }

  @inlinable
  public static var _streamObjectMemberPrepare: StreamFieldPrepare? { nil }
}

// Refines `StreamContainerPartial` so a nested object field's schema is hoisted by its parent
// exactly as a container field's is. Reading `T.streamSchema` per occurrence builds a fresh schema
// for any hand-written conformance, leaving the frame as its only owner — invisible while a frame
// retains its schema, fatal now that a frame borrows it.
public protocol StreamParseableObject: StreamContainerPartial {}

// MARK: - Scalar schemas

// Shared by the root conformances below and by the macro's `_streamSchema(for:)` overloads, so
// the two cannot describe the same type differently.

@inlinable
public func _streamStringSchema<T: StreamStringConvertible>(_ type: T.Type) -> StreamSchema {
  // Read once here, never per token, and a constant after specialization -- so every destination
  // that is not inline storage folds this away entirely.
  let inlineCapacity = T._streamInlineCapacity
  if inlineCapacity > 0 {
    // The layout the erased route is about to rely on, checked where a violation is a build-time
    // sized failure rather than a memory-safety one: header, then exactly `capacity` bytes.
    precondition(
      T._streamInlineByteOffset == _streamInlineStringByteOffset
        && MemoryLayout<T>.size == T._streamInlineByteOffset + inlineCapacity,
      "inline string storage does not match the layout the parser appends through"
    )
    precondition(
      inlineCapacity <= Int(Int32.max),
      "inline string capacity exceeds the stream schema's capacity field"
    )
    return StreamSchema(
      shape: .scalar,
      applyString: { storage, _, bytes in
        storage.assumingMemoryBound(to: T.self).pointee.streamAppend(utf8: bytes)
      },
      scalarKind: .inlineString,
      leafRoute: .valueInlineString,
      inlineCapacity: Int32(inlineCapacity)
    )
  }
  return StreamSchema(
    shape: .scalar,
    applyString: { storage, _, bytes in
      storage.assumingMemoryBound(to: T.self).pointee.streamAppend(utf8: bytes)
    },
    scalarKind: T.self == StreamString.self ? .streamString : .custom,
    leafRoute: T.self == StreamString.self ? .valueStreamString : .generic
  )
}

@inlinable
public func _streamNumberSchema<T: StreamNumberConvertible>(_ type: T.Type) -> StreamSchema {
  StreamSchema(
    shape: .scalar,
    applyNumber: { storage, _, bytes, info in
      // A token that does not fit the destination is a rejection, not a silent no-op, which is
      // what reports an overflow.
      guard let parsed = T(streamParsing: bytes, info: info) else { return .unsupported }
      storage.assumingMemoryBound(to: T.self).pointee = parsed
      return .applied
    },
    scalarKind: _streamNumberFieldKind(T.self),
    leafRoute: T.self == Double.self
      ? .valueDouble
      : (T.self == Int.self ? .valueInt : .generic)
  )
}

@inlinable
public func _streamBooleanSchema<T: StreamBooleanConvertible>(_ type: T.Type) -> StreamSchema {
  StreamSchema(
    shape: .scalar,
    applyBoolean: { storage, _, value in
      storage.assumingMemoryBound(to: T.self).pointee = T(streamParsingBoolean: value)
      return .applied
    },
    scalarKind: _streamBooleanFieldKind(T.self),
    leafRoute: T.self == Bool.self ? .valueBool : .generic
  )
}

// MARK: - Fixed-width SIMD schemas

// A SIMD value is a JSON array whose element count and storage are known before parsing begins, so
// there is no cursor, pending element or allocation in the value. `PartialSink` keeps the next lane
// in the frame's `pendingField` and, for a scalar the library knows (`elementKind`), writes lane `i`
// at `storage + i * stride` itself; only a custom scalar reaches `applyNumber` with the lane.
@inlinable
public func _streamSIMD2Schema<Scalar>(
  _ type: SIMD2<Scalar>.Type
) -> StreamSchema where Scalar: StreamNumberConvertible & StreamInitializable {
  if Scalar.self == Double.self { return _streamSIMD2DoubleSchema }
  return StreamSchema(
    shape: .array,
    applyNumber: { storage, field, bytes, info in
      guard field >= 0, field < 2, let value = Scalar(streamParsing: bytes, info: info) else {
        return .unsupported
      }
      storage.assumingMemoryBound(to: SIMD2<Scalar>.self).pointee[Int(field)] = value
      return .applied
    },
    elementStride: Int32(MemoryLayout<Scalar>.stride),
    elementKind: _streamNumberFieldKind(Scalar.self),
    elementOptional: false,
    leafRoute: .simd2Number,
    fixedElementCount: 2
  )
}

@inlinable
public func _streamSIMD3Schema<Scalar>(
  _ type: SIMD3<Scalar>.Type
) -> StreamSchema where Scalar: StreamNumberConvertible & StreamInitializable {
  if Scalar.self == Double.self { return _streamSIMD3DoubleSchema }
  return StreamSchema(
    shape: .array,
    applyNumber: { storage, field, bytes, info in
      guard field >= 0, field < 3, let value = Scalar(streamParsing: bytes, info: info) else {
        return .unsupported
      }
      storage.assumingMemoryBound(to: SIMD3<Scalar>.self).pointee[Int(field)] = value
      return .applied
    },
    elementStride: Int32(MemoryLayout<Scalar>.stride),
    elementKind: _streamNumberFieldKind(Scalar.self),
    elementOptional: false,
    leafRoute: .simd3Number,
    fixedElementCount: 3
  )
}

@inlinable
public func _streamSIMD4Schema<Scalar>(
  _ type: SIMD4<Scalar>.Type
) -> StreamSchema where Scalar: StreamNumberConvertible & StreamInitializable {
  if Scalar.self == Double.self { return _streamSIMD4DoubleSchema }
  return StreamSchema(
    shape: .array,
    applyNumber: { storage, field, bytes, info in
      guard field >= 0, field < 4, let value = Scalar(streamParsing: bytes, info: info) else {
        return .unsupported
      }
      storage.assumingMemoryBound(to: SIMD4<Scalar>.self).pointee[Int(field)] = value
      return .applied
    },
    elementStride: Int32(MemoryLayout<Scalar>.stride),
    elementKind: _streamNumberFieldKind(Scalar.self),
    elementOptional: false,
    leafRoute: .simd4Number,
    fixedElementCount: 4
  )
}

// Durable exact schemas let the sink open a SIMD element directly from a known parent array
// without constructing a frame whose schema is its only owner.
@usableFromInline
let _streamSIMD2DoubleSchema = StreamSchema(
  shape: .array,
  applyNumber: { storage, field, bytes, info in
    guard field >= 0, field < 2, let value = Double(streamParsing: bytes, info: info) else {
      return .unsupported
    }
    storage.assumingMemoryBound(to: SIMD2<Double>.self).pointee[Int(field)] = value
    return .applied
  },
  elementStride: Int32(MemoryLayout<Double>.stride),
  elementKind: .double,
  elementOptional: false,
  leafRoute: .simd2Double,
  fixedElementCount: 2
)

@usableFromInline
let _streamSIMD3DoubleSchema = StreamSchema(
  shape: .array,
  applyNumber: { storage, field, bytes, info in
    guard field >= 0, field < 3, let value = Double(streamParsing: bytes, info: info) else {
      return .unsupported
    }
    storage.assumingMemoryBound(to: SIMD3<Double>.self).pointee[Int(field)] = value
    return .applied
  },
  elementStride: Int32(MemoryLayout<Double>.stride),
  elementKind: .double,
  elementOptional: false,
  leafRoute: .simd3Double,
  fixedElementCount: 3
)

@usableFromInline
let _streamSIMD4DoubleSchema = StreamSchema(
  shape: .array,
  applyNumber: { storage, field, bytes, info in
    guard field >= 0, field < 4, let value = Double(streamParsing: bytes, info: info) else {
      return .unsupported
    }
    storage.assumingMemoryBound(to: SIMD4<Double>.self).pointee[Int(field)] = value
    return .applied
  },
  elementStride: Int32(MemoryLayout<Double>.stride),
  elementKind: .double,
  elementOptional: false,
  leafRoute: .simd4Double,
  fixedElementCount: 4
)

// MARK: - Container schemas

@inlinable
public func _streamArraySchema<Element: StreamParseableRoot>(
  _ type: Element.Type,
  element: StreamSchema
) -> StreamSchema {
  // One template per schema: the element is copy-initialised from this address straight into its slot
  // and the closure's only capture is the pointer. Building it inside the closure instead re-enters
  // the runtime's locking metadata cache per open and returns by value, a second whole-element copy.
  // The box is the schema's `templateOwner`, so it dies with the schema rather than per stream init.
  let owner = _streamOwnedTemplate(Element.streamInitialArrayElement())
  nonisolated(unsafe) let template = owner.address(as: Element.self)
  // Chosen here, once, so a concrete element's closure is the template copy and nothing else.
  let appendElement: @Sendable (UnsafeMutableRawPointer, Int32) -> UnsafeMutableRawPointer?
  if Element._streamOpensByConstruction {
    appendElement = { storage, _ in
      storage.assumingMemoryBound(to: StreamArray<Element>.self).pointee
        ._openElement(constructing: Element.streamInitialArrayElement())
    }
  } else {
    appendElement = { storage, _ in
      storage.assumingMemoryBound(to: StreamArray<Element>.self).pointee
        ._openElement(copying: template)
    }
  }
  return StreamSchema(
    shape: .array,
    appendElement: appendElement,
    appendNumbers: Element._streamArrayNumberAppender,
    elementSchema: element,
    // Deliberately *not* guarded on `element.shape == .scalar` the way the three sibling builders are:
    // a SIMD element's schema has shape `.array`, and that guard would demote `.arraySIMD2Double` and
    // its five siblings to `.generic`. `_StreamLeafRoute.array(_)` already maps every route it does
    // not recognise to `.generic`, so the guard buys nothing here.
    leafRoute: .array(element.leafRoute),
    inlineCapacity: element.inlineCapacity,
    templateOwner: owner
  )
}

/// A value copied from at a stable address for the rest of the process, leaked on purpose.
///
/// Superseded by `_streamOwnedTemplate`, which ties the same allocation to the schema that
/// captures it; kept because it is public API a client (or an older macro expansion) may call.
@inlinable
public func _streamLeakedTemplate<T>(_ value: T) -> UnsafePointer<T> {
  let template = UnsafeMutablePointer<T>.allocate(capacity: 1)
  template.initialize(to: value)
  return UnsafePointer(template)
}

extension StreamParseableRoot {
  @inlinable
  public static var _streamArrayNumberAppender:
    (@Sendable (UnsafeMutableRawPointer, borrowing StreamEventBatch, Int, Int) -> Int)?
  { nil }
}

// The bulk path for arrays of numbers: no frame per element, no schema borrow, no pending swap. The
// open element is drained first (`commit` appends past it) and the last number is left as the new
// open element, so a snapshot between a batch and the close sees what the one-at-a-time path leaves.
// Measured: unrolling 2/4/8 wide was monotonically worse (Mesh 323 -> 311 MB/s); keep the plain loop.
extension StreamParseableRoot where Self: StreamNumberConvertible {
  @inlinable
  public static var _streamArrayNumberAppender:
    (@Sendable (UnsafeMutableRawPointer, borrowing StreamEventBatch, Int, Int) -> Int)?
  {
    { storage, batch, from, to in
      let array = storage.assumingMemoryBound(to: StreamArray<Self>.self)
      guard to > from else { return 0 }
      array.pointee.drainPending()
      var index = from
      let last = to &- 1
      while index < last {
        guard let value = Self(streamParsing: batch.bytes(of: index), info: batch.info(of: index))
        else { return index &- from }
        array.pointee.commit(value)
        index &+= 1
      }
      guard let value = Self(streamParsing: batch.bytes(of: last), info: batch.info(of: last))
      else { return last &- from }
      array.pointee.pending = value
      return to &- from
    }
  }
}

// The schema an optional element or dictionary value is written through. Exactly two things differ
// from the wrapped type's own schema -- everything else is the *identical* closure value, so a token
// costs one schema call, not two. Nothing checks for `nil` first, because the container opened the
// slot materialised (73.5 ns/element against 32.9 here); and a null naming the value clears it.
@inlinable
public func _streamOptionalElementSchema<Wrapped: StreamInitializable>(
  _ type: Wrapped.Type,
  base: StreamSchema
) -> StreamSchema {
  StreamSchema(
    shape: base.shape,
    // Propagated rather than passed straight through, so a base that matches no keys stays one:
    // handing `base.matchField` over unconditionally would make `matchField != nil` true and route
    // every key through the closure that the `ignore` case exists to skip.
    matchField: base.ignoresKeys ? nil : base.matchField,
    onFieldRecognized: base.onFieldRecognized,
    applyString: base.applyString,
    applyNumber: base.applyNumber,
    applyBoolean: base.applyBoolean,
    applyNull: { storage, field in
      guard field == StreamSchema.wholeValueField else { return base.applyNull(storage, field) }
      storage.assumingMemoryBound(to: Wrapped?.self).pointee = nil
      return .applied
    },
    finishString: base.finishString,
    enterField: base.enterField,
    appendElement: base.appendElement,
    enterKey: base.enterKey,
    elementSchema: base.elementSchema,
    elementStride: base.elementStride,
    scalarKind: base.scalarKind,
    scalarOptional: true,
    elementKind: base.elementKind,
    elementOptional: base.elementOptional,
    leafRoute: base.leafRoute == .inlineArray
      ? .inlineArray
      : (base.shape == .scalar || base.leafRoute.fixedSIMDLaneCount != 0
        ? .optionalValue(base.leafRoute)
        : .generic),
    fixedElementCount: base.fixedElementCount,
    inlineCapacity: base.inlineCapacity,
    fields: base.fields,
    // `appendElement` and `enterKey` above dereference a raw template pointer the base's `templateOwner`
    // box owns, and the base can outlive this schema, so the box has to be carried. Not carried:
    // `prepareRoot`, since an element schema is never a root; and `appendNumbers`, whose closure binds
    // `storage` to the base's storage type, one `Optional` shallower than what it would be handed.
    templateOwner: base.templateOwner,
    completedValue: base.completedValue
  )
}

// An array whose elements are optional. The element is opened as `.some` rather than `nil`, which
// is the whole reason the element schema above can write straight through: `Optional`'s own
// `streamInitialValue()` is `nil`, and applying the wrapped type's schema to the `.none`
// representation is a write through a pointer to a value that is not there.
@inlinable
public func _streamOptionalArraySchema<Wrapped: StreamParseableRoot>(
  _ type: Wrapped.Type,
  element base: StreamSchema
) -> StreamSchema {
  let element = _streamOptionalElementSchema(Wrapped.self, base: base)
  let owner = _streamOwnedTemplate(Wrapped?.some(Wrapped.streamInitialValue()))
  nonisolated(unsafe) let template = owner.address(as: Wrapped?.self)
  // See `_streamArraySchema`.
  let appendElement: @Sendable (UnsafeMutableRawPointer, Int32) -> UnsafeMutableRawPointer?
  if Wrapped._streamOpensByConstruction {
    appendElement = { storage, _ in
      storage.assumingMemoryBound(to: StreamArray<Wrapped?>.self).pointee
        ._openElement(constructing: .some(Wrapped.streamInitialValue()))
    }
  } else {
    appendElement = { storage, _ in
      storage.assumingMemoryBound(to: StreamArray<Wrapped?>.self).pointee
        ._openElement(copying: template)
    }
  }
  return StreamSchema(
    shape: .array,
    appendElement: appendElement,
    elementSchema: element,
    // Unguarded for the reason `_streamArraySchema` gives: an optional SIMD element has shape
    // `.array`, and the guard demoted `.arrayOptionalSIMD2Double` and its siblings to `.generic`.
    leafRoute: .array(element.leafRoute),
    inlineCapacity: element.inlineCapacity,
    templateOwner: owner
  )
}

@inlinable
public func _streamOptionalDictionarySchema<Wrapped: StreamParseableRoot>(
  _ type: Wrapped.Type,
  value base: StreamSchema
) -> StreamSchema {
  let value = _streamOptionalElementSchema(Wrapped.self, base: base)
  // The template is the `.some` the dictionary's own `pendingValue` must end up holding, one
  // optional deeper than the element templates above: see `_openValue(forKey:copyingSome:)`.
  let owner = _streamOwnedTemplate(Wrapped??.some(.some(Wrapped.streamInitialValue())))
  nonisolated(unsafe) let template = owner.address(as: Wrapped??.self)
  // See `_streamArraySchema`.
  let enterKey: @Sendable (UnsafeMutableRawPointer, Span<UInt8>) -> UnsafeMutableRawPointer?
  if Wrapped._streamOpensByConstruction {
    enterKey = { storage, key in
      let initial: Wrapped?? = .some(.some(Wrapped.streamInitialValue()))
      return storage.assumingMemoryBound(to: StreamDictionary<Wrapped?>.self).pointee
        ._openValue(forKey: key, constructingSome: initial)
    }
  } else {
    enterKey = { storage, key in
      storage.assumingMemoryBound(to: StreamDictionary<Wrapped?>.self).pointee
        ._openValue(forKey: key, copyingSome: template)
    }
  }
  return StreamSchema(
    shape: .dictionary,
    enterKey: enterKey,
    elementSchema: value,
    leafRoute: value.shape == .scalar ? .dictionary(value.leafRoute) : .generic,
    inlineCapacity: value.inlineCapacity,
    templateOwner: owner
  )
}

@inlinable
public func _streamDictionarySchema<Value: StreamParseableRoot>(
  _ type: Value.Type,
  value valueSchema: StreamSchema
) -> StreamSchema {
  // See `_streamArraySchema` for the template. A repeated key resumes its stored value and reads
  // nothing from it.
  let owner = _streamOwnedTemplate(Value?.some(Value.streamInitialDictionaryValue()))
  nonisolated(unsafe) let template = owner.address(as: Value?.self)
  // See `_streamArraySchema`.
  let enterKey: @Sendable (UnsafeMutableRawPointer, Span<UInt8>) -> UnsafeMutableRawPointer?
  if Value._streamOpensByConstruction {
    enterKey = { storage, key in
      let initial: Value? = .some(Value.streamInitialDictionaryValue())
      return storage.assumingMemoryBound(to: StreamDictionary<Value>.self).pointee
        ._openValue(forKey: key, constructingSome: initial)
    }
  } else {
    enterKey = { storage, key in
      storage.assumingMemoryBound(to: StreamDictionary<Value>.self).pointee
        ._openValue(forKey: key, copyingSome: template)
    }
  }
  return StreamSchema(
    shape: .dictionary,
    enterKey: enterKey,
    elementSchema: valueSchema,
    leafRoute: valueSchema.shape == .scalar ? .dictionary(valueSchema.leafRoute) : .generic,
    inlineCapacity: valueSchema.inlineCapacity,
    templateOwner: owner
  )
}

// MARK: - Root conformances

extension StreamParseableRoot where Self: StreamStringConvertible {
  public static var streamSchema: StreamSchema { _streamStringSchema(Self.self) }
}

extension StreamParseableRoot where Self: StreamNumberConvertible {
  public static var streamSchema: StreamSchema { _streamNumberSchema(Self.self) }
}

extension StreamParseableRoot where Self: StreamBooleanConvertible {
  public static var streamSchema: StreamSchema { _streamBooleanSchema(Self.self) }
}

#if !hasFeature(Embedded)
  extension StreamParseableRoot {
    public static var streamObservationFields: [PartialKeyPath<Self>] { [] }
  }
#endif

// Kept separate from KeyRouting so instrumentation does not add cases to scalar hot paths.
@usableFromInline
enum _StreamKeyDispatch: UInt8, Sendable {
  case match
  case dictionary
  case ignore
  case table
  case observedTable
  case observedMatch
}
