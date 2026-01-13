// MARK: - Macros

@attached(extension, conformances: StreamParseable, names: named(Partial))
@attached(member, names: named(streamPartialValue))
public macro StreamParseable(partialMembers: PartialMembersMode = .optional) =
  #externalMacro(module: "StreamParsingMacros", type: "StreamParseableMacro")

@attached(peer)
public macro StreamParseableMember(key: String) =
  #externalMacro(module: "StreamParsingMacros", type: "StreamParseableMemberMacro")

@attached(peer)
public macro StreamParseableMember(keyNames: [String]) =
  #externalMacro(module: "StreamParsingMacros", type: "StreamParseableMemberMacro")

@attached(peer)
public macro StreamParseableIgnored() =
  #externalMacro(module: "StreamParsingMacros", type: "StreamParseableIgnoredMacro")

// MARK: - Helpers

public struct PartialMembersMode: Sendable {
  public static let optional = Self()
  public static let initialParseableValue = Self()
}
