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
}

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
@inlinable
public func _streamInlineArraySchema<let count: Int, Element: StreamParseableRoot>(
  _ type: InlineArray<count, Element>.Type,
  element: StreamSchema
) -> StreamSchema {
  precondition(count <= Int(Int32.max), "InlineArray count exceeds the stream frame cursor")
  return StreamSchema(
    shape: .array,
    appendElement: { storage, index in
      // PartialSink owns this cursor and checks it against fixedElementCount before invoking the
      // witness. Keep the witness branch-free so a specialized closure becomes one scaled address
      // calculation rather than repeating that bounds check for every element.
      return _streamOpenInlineElement(
        in: &storage.assumingMemoryBound(to: InlineArray<count, Element>.self).pointee,
        at: Int(index),
        schema: element
      )
    },
    leafRoute: .inlineArray,
    fixedElementCount: Int32(count)
  )
}
