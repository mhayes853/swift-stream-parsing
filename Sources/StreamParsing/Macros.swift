// MARK: - Macros

@attached(extension, conformances: StreamParseable, names: named(Partial))
public macro StreamParseable(partialMembers: _PartialMembersMode = .optional) =
  #externalMacro(module: "StreamParsingMacros", type: "StreamParseableMacro")

// MARK: - Helpers

public struct _PartialMembersMode: Sendable {
  public static let optional = Self()
  public static let initialReduceableValue = Self()
}
