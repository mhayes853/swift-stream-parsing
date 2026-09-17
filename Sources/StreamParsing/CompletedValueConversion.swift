import StreamParsingCore

#if !hasFeature(Embedded)
  // Public only because macro expansions in client modules call these helpers.
  public func _streamWithConverted<C: StreamCompletedValueConversion>(
    _ value: inout ConvertedPartial<C>,
    _ body: (UnsafeMutableRawPointer) -> StreamApplyResult
  ) -> StreamApplyResult {
    withUnsafeMutablePointer(to: &value) { body(UnsafeMutableRawPointer($0)) }
  }

  public func _streamWithConverted<C: StreamCompletedValueConversion>(
    _ value: inout ConvertedPartial<C>?,
    _ body: (UnsafeMutableRawPointer) -> StreamApplyResult
  ) -> StreamApplyResult {
    if value == nil { value = ConvertedPartial() }
    return withUnsafeMutablePointer(to: &value!) { body(UnsafeMutableRawPointer($0)) }
  }

  public func _streamFieldRoute<C: StreamCompletedValueConversion>(
    _ value: inout ConvertedPartial<C>,
    schema: StreamSchema?
  ) -> StreamFieldRoute {
    StreamFieldRoute(
      schema!.shape == .scalar ? .custom : .container,
      optional: false,
      schema: schema
    )
  }

  public func _streamFieldRoute<C: StreamCompletedValueConversion>(
    _ value: inout ConvertedPartial<C>?,
    schema: StreamSchema?
  ) -> StreamFieldRoute {
    StreamFieldRoute(
      schema!.shape == .scalar ? .custom : .container,
      optional: true,
      schema: schema,
      prepare: _streamOptionalContainerPrepare(ConvertedPartial<C>.self)
    )
  }

  public func _streamConvertedValue<C: StreamCompletedValueConversion>(
    _ partial: ConvertedPartial<C>?
  ) -> C.Value? { partial?.value }

  public func _streamOptionalConvertedValue<C: StreamCompletedValueConversion>(
    _ partial: ConvertedPartial<C>?
  ) -> C.Value?? {
    guard let partial else { return .some(nil) }
    guard let value = partial.value else { return nil }
    return .some(.some(value))
  }
#endif
