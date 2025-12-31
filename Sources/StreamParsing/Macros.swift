// MARK: - Macros

@attached(extension, conformances: StreamParseable, names: named(Partial))
public macro StreamParseable() =
  #externalMacro(module: "StreamParsingMacros", type: "StreamParseableMacro")

// MARK: - Helpers

public func _streamParsingPerformReduce<T: StreamParseableReducer>(
  _ value: inout T?,
  _ action: DefaultStreamAction
) throws where T.StreamAction == DefaultStreamAction {
  if value == nil {
    value = try T(action: action)
  }
  try value?.reduce(action: action)
}

public func _streamParsingPerformReduce<T: ConvertibleFromStreamedValue & StreamActionReducer>(
  _ value: inout T?,
  _ action: DefaultStreamAction
) throws where T.StreamAction == DefaultStreamAction {
  if value == nil {
    value = try action.extractedValue(expected: T.self) { T(streamedValue: $0) }
  }
  try value?.reduce(action: action)
}
