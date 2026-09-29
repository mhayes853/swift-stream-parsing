import StreamParsingCore

// Public only because macro expansions in client modules call these helpers. A converted member
// is routed and applied through `ConvertedPartial`'s own schema (`_streamDelegatedFieldRoute`).
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
