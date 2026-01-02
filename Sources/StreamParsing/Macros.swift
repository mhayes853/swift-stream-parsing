// MARK: - Macros

@attached(extension, conformances: StreamParseable, names: named(Partial))
public macro StreamParseable(partialMembers: _PartialMembersMode = .optional) =
  #externalMacro(module: "StreamParsingMacros", type: "StreamParseableMacro")

// MARK: - Helpers

public struct _PartialMembersMode: Sendable {
  public static let optional = Self()
  public static let initialReduceableValue = Self()
}

public func _streamParsingPerformReduce<T: StreamParseableReducer>(
  _ value: inout T?,
  _ action: StreamAction
) throws {
  var next: T? = value ?? .initialReduceableValue()
  try next?.reduce(action: action)
  value = next
}
