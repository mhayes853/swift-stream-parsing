// InlineArray is fixed-size storage, not a collection with an incremental logical count. Every
// slot therefore starts as a valid element and is immediately visible; the sink frame carries how
// many slots the document has actually supplied and exact arity is checked when `]` arrives.
//
// The standard library currently gates InlineArray to Apple OS 26. Keep the conformances gated so
// this package's older deployment targets continue to build and run without exposing unavailable
// API.

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
extension InlineArray: StreamInitializable where Element: StreamInitializable {
  public static func streamInitialValue() -> Self {
    // Invoke the initializer once per element rather than repeating one value. Besides avoiding
    // unnecessary shared COW storage, this preserves distinct identity for a user-defined
    // reference type that chooses to participate in streaming.
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

  // The element initializer cannot decline, so the strict conversion is checked first and built
  // second. Two passes over a fixed, usually small arity, on a path that runs once per finished
  // value rather than per byte.
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
  // No `appendElement`: the storage is `count` elements at a stride, and the sink addresses
  // element `i` from the frame's cursor as `storage + i * elementStride`, bounds checked against
  // `fixedElementCount` before it does.
  return StreamSchema(
    shape: .array,
    elementSchema: element,
    elementStride: Int32(MemoryLayout<Element>.stride),
    leafRoute: .inlineArray,
    fixedElementCount: Int32(count)
  )
}
