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

// The public conversion protocols remain open-ended. This byte is deliberately not: it names the
// few exact standard-library/storage pairings whose implementation PartialSink can see through
// completely. Everything else stays `.generic` and uses the schema closures, so adding a custom
// conformer never changes correctness and adding a fast route is an explicit benchmarked choice.
//
// A scalar schema carries a `value...` case only so an array/dictionary builder can map it to the
// exact container operation. Only container cases are ever cached on an active frame.
@usableFromInline
enum _StreamLeafRoute: UInt8, Sendable {
  case generic
  case valueStreamString
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

public final class StreamSchema: Sendable {
  public enum Shape: UInt8, Sendable {
    case object
    case array
    case dictionary
    case scalar

    // Whether a container of `kind` can be written through a destination of this shape. A JSON
    // object reaches both an object and a dictionary; every other pairing is a type mismatch.
    //
    // Without this a scalar destination accepts the contents of any container that reaches it,
    // because a scalar frame ignores keys and applies every token to itself: `[2,3]` arriving at
    // a `StreamDictionary<Int>` value wrote 2 and then 3 into it.
    public func canHold(container kind: Shape) -> Bool {
      switch (self, kind) {
      case (.object, .object), (.dictionary, .object), (.array, .array): true
      default: false
      }
    }
  }

  public let shape: Shape

  /// Prepares root storage before a container frame begins writing through this schema.
  ///
  /// Most roots already hold their initialized value and need no work. Wrappers such as
  /// `Optional` use this hook to materialize storage even when an empty container produces no
  /// field or element events that would otherwise do so.
  public let prepareRoot: @Sendable (UnsafeMutableRawPointer) -> Void

  /// The field an apply closure receives when the destination *is* the value rather than a field
  /// of one — an array element, a dictionary value, a bare scalar root.
  ///
  /// Zero cannot say that, because zero is also the first field a generated object schema
  /// declares, and the two reached the same `applyString(storage, 0, bytes)`. An object arriving
  /// as an array element therefore absorbed a scalar into whichever member happened to be
  /// declared first: `["abc"]` into a `StreamArray<Person.Partial>` set `name` to "abc", and `[5]`
  /// was a type mismatch only because `name` could not hold a number.
  ///
  /// A negative field cannot collide with a declared one, so an object schema's
  /// `default: return false` turns those back into the mismatches they are. A scalar schema
  /// ignores the field either way and is unaffected.
  public static let wholeValueField = Int32(-1)

  // Where a key arriving at this schema has to go, precomputed into one byte.
  //
  // A schema call costs a closure load, a retain, an indirect call and a release — 17 ns against
  // 4.6 ns for a bare function pointer, measured in `SchemaDispatchBenchmarks` — and a schema with
  // no matcher spends all of it to reach `{ _ in -1 }`. That is not a rare case: the schema stood
  // up for a subtree the destination has no field for is this one, and 52% of `twitter.json`'s
  // 13,345 keys are inside such a subtree when parsed into a model that declares part of it, which
  // is what a model normally does.
  //
  // One byte rather than a `shape == .dictionary` test followed by a matcher test, because the
  // dictionary test was already on this path: routing the two questions through a single load and
  // a single switch is what keeps the schemas that *do* match from paying for the ones that do not.
  @usableFromInline
  enum KeyRouting: UInt8, Sendable {
    case match
    case dictionary
    case ignore
  }

  @usableFromInline let keyRouting: KeyRouting

  // Whether this schema declares no matcher. Read when one schema is wrapped in another, so the
  // wrapper does not install a matcher over a destination that has none.
  @usableFromInline let ignoresKeys: Bool

  // Returns the field identifier for a key, or -1 when the destination has no such field.
  public let matchField: @Sendable (Span<UInt8>) -> Int32

  // Each returns whether the token was actually applied. A field that matched a key but has no
  // destination for this kind of token returns false, which is what lets the sink tell a type
  // mismatch from a key the destination simply does not have. A bool return rather than a throw,
  // for the same reason the sink methods do not throw: a check after every call sits on the
  // hottest path.
  //
  // The field is a declared field's identifier when the schema stands over an object, and
  // ``wholeValueField`` when the destination *is* the value.
  public let applyString: @Sendable (UnsafeMutableRawPointer, Int32, Span<UInt8>) -> Bool
  public let applyNumber: @Sendable (UnsafeMutableRawPointer, Int32, Span<UInt8>, NumberInfo) -> Bool
  public let applyBoolean: @Sendable (UnsafeMutableRawPointer, Int32, Bool) -> Bool
  public let applyNull: @Sendable (UnsafeMutableRawPointer, Int32) -> Bool

  // Returns a frame for the container stored at `field`, materializing it when absent. It is not
  // reset when present, so a key that repeats resumes the container the first occurrence built
  // rather than replacing it. `ContainerReentryTests` pins that, along with the scalar cases,
  // which do not agree with each other: a repeated string concatenates and a repeated number
  // replaces.
  public let enterField: @Sendable (UnsafeMutableRawPointer, Int32) -> StreamFrame?

  // Appends an element and returns a frame for it. Arrays only.
  //
  // Dynamic arrays ignore `index`; fixed arrays use it to address their inline storage. Carrying
  // the cursor through the existing operation avoids adding a second element-opening witness to
  // every schema merely for the fixed case.
  public let appendElement: @Sendable (UnsafeMutableRawPointer, Int32) -> StreamFrame?

  // Returns a frame for the value stored under a dynamic key. Dictionaries only.
  public let enterKey: @Sendable (UnsafeMutableRawPointer, Span<UInt8>) -> StreamFrame?

  // Exact homogeneous operations the sink may perform without constructing a StreamFrame or
  // calling a stored closure. Hand-written schemas and unrecognized protocol conformers remain
  // `.generic`, preserving the public API's open-ended behavior.
  @usableFromInline let leafRoute: _StreamLeafRoute

  // Negative for a dynamic array. Kept off the frame: only an InlineArray's open and close need
  // it, while adding it to BorrowedFrame would grow every frame from 24 to 32 bytes.
  @usableFromInline let fixedElementCount: Int32

  // `matchField` is optional rather than defaulted so that "no matcher" is a fact the schema
  // carries rather than one indistinguishable from a matcher that happens to answer -1.
  public convenience init(
    shape: Shape,
    prepareRoot: @escaping @Sendable (UnsafeMutableRawPointer) -> Void = { _ in },
    matchField: (@Sendable (Span<UInt8>) -> Int32)? = nil,
    applyString: @escaping @Sendable (UnsafeMutableRawPointer, Int32, Span<UInt8>) -> Bool = {
      _, _, _ in false
    },
    applyNumber: @escaping @Sendable (
      UnsafeMutableRawPointer, Int32, Span<UInt8>, NumberInfo
    ) -> Bool = { _, _, _, _ in false },
    applyBoolean: @escaping @Sendable (UnsafeMutableRawPointer, Int32, Bool) -> Bool = {
      _, _, _ in false
    },
    applyNull: @escaping @Sendable (UnsafeMutableRawPointer, Int32) -> Bool = { _, _ in false },
    enterField: @escaping @Sendable (UnsafeMutableRawPointer, Int32) -> StreamFrame? = { _, _ in nil },
    appendElement: @escaping @Sendable (UnsafeMutableRawPointer, Int32) -> StreamFrame? = {
      _, _ in nil
    },
    enterKey: @escaping @Sendable (UnsafeMutableRawPointer, Span<UInt8>) -> StreamFrame? = {
      _, _ in nil
    }
  ) {
    self.init(
      shape: shape,
      prepareRoot: prepareRoot,
      matchField: matchField,
      applyString: applyString,
      applyNumber: applyNumber,
      applyBoolean: applyBoolean,
      applyNull: applyNull,
      enterField: enterField,
      appendElement: appendElement,
      enterKey: enterKey,
      leafRoute: .generic,
      fixedElementCount: -1
    )
  }

  @usableFromInline
  init(
    shape: Shape,
    prepareRoot: @escaping @Sendable (UnsafeMutableRawPointer) -> Void = { _ in },
    matchField: (@Sendable (Span<UInt8>) -> Int32)? = nil,
    applyString: @escaping @Sendable (UnsafeMutableRawPointer, Int32, Span<UInt8>) -> Bool = {
      _, _, _ in false
    },
    applyNumber: @escaping @Sendable (
      UnsafeMutableRawPointer, Int32, Span<UInt8>, NumberInfo
    ) -> Bool = { _, _, _, _ in false },
    applyBoolean: @escaping @Sendable (UnsafeMutableRawPointer, Int32, Bool) -> Bool = {
      _, _, _ in false
    },
    applyNull: @escaping @Sendable (UnsafeMutableRawPointer, Int32) -> Bool = { _, _ in false },
    enterField: @escaping @Sendable (UnsafeMutableRawPointer, Int32) -> StreamFrame? = { _, _ in nil },
    appendElement: @escaping @Sendable (UnsafeMutableRawPointer, Int32) -> StreamFrame? = {
      _, _ in nil
    },
    enterKey: @escaping @Sendable (UnsafeMutableRawPointer, Span<UInt8>) -> StreamFrame? = {
      _, _ in nil
    },
    leafRoute: _StreamLeafRoute = .generic,
    fixedElementCount: Int32 = -1
  ) {
    self.shape = shape
    self.prepareRoot = prepareRoot
    self.ignoresKeys = matchField == nil
    // A dictionary routes keys through `enterKey` whether or not it also carries a matcher, which
    // is the order the sink already applied.
    self.keyRouting = shape == .dictionary ? .dictionary : (matchField == nil ? .ignore : .match)
    self.matchField = matchField ?? { _ in -1 }
    self.applyString = applyString
    self.applyNumber = applyNumber
    self.applyBoolean = applyBoolean
    self.applyNull = applyNull
    self.enterField = enterField
    self.appendElement = appendElement
    self.enterKey = enterKey
    self.leafRoute = leafRoute
    self.fixedElementCount = fixedElementCount
  }
}

// Anything that can describe its own routing, whatever shape it is.
//
// The macro resolves a field's shape through overloads, because it sees only syntax. That works
// where a concrete type is written and nowhere else: a function generic over `Value` cannot pick
// an overload on its behalf. `partials(of:from:)` is exactly such a function, so a root schema
// has to come from a protocol requirement rather than an overload.
//
// Kept separate from `StreamParseableObject` because the constrained `_streamEnterField` keys off
// that one, and it must not match a `String` field and hand it a frame instead of a scalar write.
public protocol StreamParseableRoot: StreamInitializable {
  static var streamSchema: StreamSchema { get }

  /// The schema this type is written through when a container holds it, and the value that
  /// container opens its slot with.
  ///
  /// These differ from ``streamSchema`` and ``StreamInitializable/streamInitialValue()`` only
  /// where the two positions differ, which today means only for `Optional`. A container owns the
  /// slot it hands out and can therefore open it already materialised, so an optional element does
  /// not have to check for `nil` before every write — where a bare optional *root* has no such
  /// owner and must. That is worth two requirements because the difference is 2.4x: measured on a
  /// 20,000 element array, `[Int?]` costs 73.5 ns/element written through ``streamSchema`` and
  /// 32.9 through these, against 32.1 for the non-optional path.
  ///
  /// The defaults are the root forms, so a type for which the two positions are the same — every
  /// type but `Optional` — conforms without saying anything.
  ///
  /// "Element" covers a dictionary's values too, matching `_streamOptionalElementSchema`, which
  /// both container builders call.
  static var streamElementSchema: StreamSchema { get }

  /// - SeeAlso: ``streamElementSchema``
  static func streamElementInitialValue() -> Self

  /// A borrowed window onto the value, for reading part of it without copying the whole.
  ///
  /// Defaults to ``StreamPointerView``, which is what a scalar wants: there is nothing to defer,
  /// so the view is just a dereference away from the whole value. A type with members worth
  /// reading one at a time overrides it with a projection whose accessors copy only what they
  /// return.
  ///
  /// `~Escapable`, so "must outlive the view" on ``streamView(_:)`` is checked rather than merely
  /// documented — every conformer's `View`, defaulted or overridden, ties the view's borrow-
  /// checked scope to the call that produced it, and a caller cannot move one out to somewhere
  /// longer-lived. There is deliberately no `= Self` fallback: letting some conformers' `View` be
  /// plain `Self` (Escapable) and others be a genuine projection (`~Escapable`) is exactly what
  /// makes per-field code generation ambiguous — see the macro's `partialStructView`.
  associatedtype View: ~Copyable, ~Escapable

  /// Builds a view over a value at `storage`.
  ///
  /// The lifetime dependency on `storage` ties the returned view's borrow-checked scope to the
  /// call site: the pointer itself carries no lifetime of its own, but the dependency still
  /// forces callers through an API shape (like a `withView`-style closure) that cannot let the
  /// view outlive the call that produced it.
  @_lifetime(borrow storage)
  static func streamView(_ storage: UnsafeMutableRawPointer) -> View
}

extension StreamParseableRoot {
  @inlinable
  public static var streamElementSchema: StreamSchema { Self.streamSchema }

  @inlinable
  public static func streamElementInitialValue() -> Self { Self.streamInitialValue() }
}

extension StreamParseableRoot where View == StreamPointerView<Self> {
  // A view of a value with nothing to project defers its one dereference to the read, rather
  // than copying immediately the way the old `View == Self` default did. Either way, this is a
  // correct snapshot: every container the parser writes into holds its open element in an inline
  // slot, so a copy shares only storage that is sealed and never written again, and the open
  // element's own buffers copy on write at the parser's next append. This is what replaced a
  // recursive `streamSnapshot()` rebuild.
  @_lifetime(borrow storage)
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
  /// The schema ``streamContainerFrame(at:schema:)`` installs.
  ///
  /// Separated from the frame so a caller can resolve it once and store it: `streamSchema` is a
  /// computed property on every generic partial, so reading it per entry allocates per container
  /// occurrence, and the schema built for one entry died with that entry's frame — the only
  /// schema in the system without a durable owner. The macro hoists this value into a
  /// `private static let` on the generated `Partial` and passes it back per entry.
  static var streamContainerSchema: StreamSchema { get }

  /// Returns the frame that writes a container into `storage`, carrying a resolved
  /// ``streamContainerSchema``.
  static func streamContainerFrame(
    at storage: UnsafeMutableRawPointer,
    schema: StreamSchema
  ) -> StreamFrame
}

extension StreamContainerPartial {
  @inlinable
  public static var streamContainerSchema: StreamSchema {
    Self.streamSchema
  }

  @inlinable
  public static func streamContainerFrame(
    at storage: UnsafeMutableRawPointer,
    schema: StreamSchema
  ) -> StreamFrame {
    StreamFrame(storage: storage, schema: schema)
  }
}

// Refines `StreamContainerPartial` so that a nested object field's schema is hoisted by its
// parent exactly as a container field's is. Without that the entry read `T.streamSchema` per
// occurrence, which is a stored static for a generated `Partial` and a freshly built schema for
// any hand-written conformance — `PersonNameComponents` is one — leaving the frame as its only
// owner. That is invisible while a frame retains its schema and fatal once a frame borrows it.
public protocol StreamParseableObject: StreamContainerPartial {}

// MARK: - Scalar schemas

// Shared by the root conformances below and by the macro's `_streamSchema(for:)` overloads, so
// the two cannot describe the same type differently.

@inlinable
public func _streamStringSchema<T: StreamStringConvertible>(_ type: T.Type) -> StreamSchema {
  return StreamSchema(
    shape: .scalar,
    applyString: { storage, _, bytes in
      storage.assumingMemoryBound(to: T.self).pointee.streamAppend(utf8: bytes)
      return true
    },
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
      guard let parsed = T(streamParsing: bytes, info: info) else { return false }
      storage.assumingMemoryBound(to: T.self).pointee = parsed
      return true
    },
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
      return true
    },
    leafRoute: T.self == Bool.self ? .valueBool : .generic
  )
}

// MARK: - Fixed-width SIMD schemas

// A SIMD value is a JSON array, but unlike `StreamArray` its element count and storage are known
// before parsing begins. `PartialSink` keeps the next lane in the frame's existing `pendingField`
// and passes it here as `field` for scalar types without a closed direct route. There is therefore
// no cursor, optional pending element or allocation in the value itself.
@inlinable
public func _streamSIMD2Schema<Scalar>(
  _ type: SIMD2<Scalar>.Type
) -> StreamSchema where Scalar: StreamNumberConvertible & StreamInitializable {
  if Scalar.self == Double.self { return _streamSIMD2DoubleSchema }
  return StreamSchema(
    shape: .array,
    applyNumber: { storage, field, bytes, info in
      guard field >= 0, field < 2, let value = Scalar(streamParsing: bytes, info: info) else {
        return false
      }
      storage.assumingMemoryBound(to: SIMD2<Scalar>.self).pointee[Int(field)] = value
      return true
    },
    leafRoute: .simd2Number
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
        return false
      }
      storage.assumingMemoryBound(to: SIMD3<Scalar>.self).pointee[Int(field)] = value
      return true
    },
    leafRoute: .simd3Number
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
        return false
      }
      storage.assumingMemoryBound(to: SIMD4<Scalar>.self).pointee[Int(field)] = value
      return true
    },
    leafRoute: .simd4Number
  )
}

// Durable exact schemas let the sink open a SIMD element directly from a known parent array
// without constructing a frame whose schema is its only owner.
@usableFromInline
let _streamSIMD2DoubleSchema = StreamSchema(
  shape: .array,
  applyNumber: { storage, field, bytes, info in
    guard field >= 0, field < 2, let value = Double(streamParsing: bytes, info: info) else {
      return false
    }
    storage.assumingMemoryBound(to: SIMD2<Double>.self).pointee[Int(field)] = value
    return true
  },
  leafRoute: .simd2Double
)

@usableFromInline
let _streamSIMD3DoubleSchema = StreamSchema(
  shape: .array,
  applyNumber: { storage, field, bytes, info in
    guard field >= 0, field < 3, let value = Double(streamParsing: bytes, info: info) else {
      return false
    }
    storage.assumingMemoryBound(to: SIMD3<Double>.self).pointee[Int(field)] = value
    return true
  },
  leafRoute: .simd3Double
)

@usableFromInline
let _streamSIMD4DoubleSchema = StreamSchema(
  shape: .array,
  applyNumber: { storage, field, bytes, info in
    guard field >= 0, field < 4, let value = Double(streamParsing: bytes, info: info) else {
      return false
    }
    storage.assumingMemoryBound(to: SIMD4<Double>.self).pointee[Int(field)] = value
    return true
  },
  leafRoute: .simd4Double
)

// MARK: - Container schemas

@inlinable
public func _streamArraySchema<Element: StreamParseableRoot>(
  _ type: Element.Type,
  element: StreamSchema
) -> StreamSchema {
  StreamSchema(
    shape: .array,
    appendElement: { storage, _ in
      _streamOpenElement(
        in: &storage.assumingMemoryBound(to: StreamArray<Element>.self).pointee,
        initial: Element.streamElementInitialValue(),
        schema: element
      )
    },
    leafRoute: .array(element.leafRoute)
  )
}

// The schema an optional element or dictionary value is written through.
//
// Exactly two things differ from the wrapped type's own schema, and the point is that everything
// else is not merely equivalent but *identical*: `applyString`, `applyNumber`, `applyBoolean`,
// `enterField`, `appendElement` and `enterKey` are the same closure values the non-optional path
// stores, so a token routed through an optional element costs one schema call, not two.
//
// The first difference is that nothing here checks for `nil` before it writes, because the
// container that produced this opened the slot already materialised. That is what the wrapper
// below could not do: `Optional.streamSchema` has to materialise per token, and to materialise it
// must load and call another schema's closure afterwards. Measured on a 20,000 element array, the
// wrapper costs 73.5 ns/element against 32.1 for the non-optional path; this costs 32.9.
//
// The second is that a null naming the value itself clears the optional, where the wrapped type
// only knows how to null one of its fields. `StreamSchema.wholeValueField` is what makes that
// expressible at all — before it, a null arriving at an element and a null arriving at the
// element's first field were the same call with the same arguments.
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
    applyString: base.applyString,
    applyNumber: base.applyNumber,
    applyBoolean: base.applyBoolean,
    applyNull: { storage, field in
      guard field == StreamSchema.wholeValueField else { return base.applyNull(storage, field) }
      storage.assumingMemoryBound(to: Wrapped?.self).pointee = nil
      return true
    },
    enterField: base.enterField,
    appendElement: base.appendElement,
    enterKey: base.enterKey,
    leafRoute: base.leafRoute == .inlineArray
      ? .inlineArray
      : (base.shape == .scalar || base.leafRoute.fixedSIMDLaneCount != 0
        ? .optionalValue(base.leafRoute)
        : .generic),
    fixedElementCount: base.fixedElementCount
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
  return StreamSchema(
    shape: .array,
    appendElement: { storage, _ in
      _streamOpenElement(
        in: &storage.assumingMemoryBound(to: StreamArray<Wrapped?>.self).pointee,
        initial: Wrapped?.some(Wrapped.streamInitialValue()),
        schema: element
      )
    },
    leafRoute: element.shape == .scalar ? .array(element.leafRoute) : .generic
  )
}

@inlinable
public func _streamOptionalDictionarySchema<Wrapped: StreamParseableRoot>(
  _ type: Wrapped.Type,
  value base: StreamSchema
) -> StreamSchema {
  let value = _streamOptionalElementSchema(Wrapped.self, base: base)
  return StreamSchema(
    shape: .dictionary,
    enterKey: { storage, key in
      _streamEnterDictionaryValue(
        &storage.assumingMemoryBound(to: StreamDictionary<Wrapped?>.self).pointee,
        key: key,
        initial: Wrapped?.some(Wrapped.streamInitialValue()),
        schema: value
      )
    },
    leafRoute: value.shape == .scalar ? .dictionary(value.leafRoute) : .generic
  )
}

@inlinable
public func _streamDictionarySchema<Value: StreamParseableRoot>(
  _ type: Value.Type,
  value valueSchema: StreamSchema
) -> StreamSchema {
  StreamSchema(
    shape: .dictionary,
    enterKey: { storage, key in
      _streamEnterDictionaryValue(
        &storage.assumingMemoryBound(to: StreamDictionary<Value>.self).pointee,
        key: key,
        initial: Value.streamElementInitialValue(),
        schema: valueSchema
      )
    },
    leafRoute: valueSchema.shape == .scalar ? .dictionary(valueSchema.leafRoute) : .generic
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
