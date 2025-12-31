// MARK: - Macros

@attached(extension, conformances: StreamParseable, names: named(Partial))
public macro StreamParseable() =
  #externalMacro(module: "StreamParsingMacros", type: "StreamParseableMacro")

// MARK: - Helpers

public func _streamParsingPerformReduce<T: StreamParseableReducer>(
  _ value: inout T?,
  _ action: StreamAction
) throws {
  if value == nil {
    value = T.initialValue()
  }
  try value?.reduce(action: action)
}
