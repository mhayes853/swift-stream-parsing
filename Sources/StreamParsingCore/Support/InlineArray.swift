// InlineArray is fixed-size storage: every slot starts as a valid element and is visible at once,
// the sink frame carries how many the document supplied, and exact arity is checked at `]`. Gated
// to Apple OS 26, matching the standard library's own gate.

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
extension InlineArray: StreamInitializable where Element: StreamInitializable {
  public static func streamInitialValue() -> Self {
    // One initializer call per element: no shared CoW storage, and distinct identity for a
    // user-defined reference type.
    Self { _ in Element.streamInitialValue() }
  }
}

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
extension InlineArray: StreamParseableRoot, StreamContainerPartial
where Element: StreamParseableRoot {
  public static var streamSchema: StreamSchema {
    _streamInlineArraySchema(Self.self, element: Element.streamElementSchema)
  }
}

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
extension InlineArray: StreamParseable where Element: StreamParseable {
  public typealias Partial = InlineArray<count, Element.Partial>

  public var streamPartialValue: Partial {
    InlineArray<count, Element.Partial> { index in
      self[index].streamPartialValue
    }
  }

  // The element initializer cannot decline, so the strict conversion is checked first, then built:
  // two passes over a small arity, once per finished value.
  public init?(streamPartial: Partial) {
    for index in 0..<count where Element(streamPartial: streamPartial[index]) == nil {
      return nil
    }
    self.init { index in
      Element(streamPartial: streamPartial[index]).unsafelyUnwrapped
    }
  }

  public static func streamValueOrInitial(from partial: Partial) -> Self {
    Self { index in
      Element.streamValueOrInitial(from: partial[index])
    }
  }
}

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
@inlinable
public func _streamInlineArraySchema<let count: Int, Element: StreamParseableRoot>(
  _ type: InlineArray<count, Element>.Type,
  element: StreamSchema
) -> StreamSchema {
  precondition(count <= Int(Int32.max), "InlineArray count exceeds the stream frame cursor")
  precondition(
    MemoryLayout<Element>.stride <= Int(Int32.max)
      && MemoryLayout<InlineArray<count, Element>>.size == count * MemoryLayout<Element>.stride,
    "InlineArray storage does not match the stride the parser addresses elements through"
  )
  // No `appendElement`: the sink addresses element `i` as `storage + i * elementStride`, bounds
  // checked against `fixedElementCount`.
  return StreamSchema(
    shape: .array,
    elementSchema: element,
    elementStride: Int32(MemoryLayout<Element>.stride),
    leafRoute: .inlineArray,
    // The sink reads the *container* frame's `inlineCapacity` when it opens an inline-string
    // element (`openKnownStringSlot`) and writes an element's null tag (`applyKnownNull`), so it is
    // carried here as the array/dictionary builders carry it.
    fixedElementCount: Int32(count),
    inlineCapacity: element.inlineCapacity
  )
}
