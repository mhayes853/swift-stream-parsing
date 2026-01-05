// MARK: - Macros

@attached(extension, conformances: StreamParseable, names: named(Partial))
public macro StreamParseable(partialMembers: PartialMembersMode = .optional) =
  #externalMacro(module: "StreamParsingMacros", type: "StreamParseableMacro")

// MARK: - Helpers

public struct PartialMembersMode: Sendable {
  public static let optional = Self()
  public static let initialParseableValue = Self()
}
