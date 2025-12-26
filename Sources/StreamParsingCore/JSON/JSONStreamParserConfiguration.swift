public struct JSONStreamParserConfiguration: Sendable {
  public var completePartialValues = false
  public var allowComments = false
  public var allowTrailingCommas = false
  public var allowUnquotedKeys = false

  public init(
    completePartialValues: Bool = false,
    allowComments: Bool = false,
    allowTrailingCommas: Bool = false,
    allowUnquotedKeys: Bool = false
  ) {
    self.completePartialValues = completePartialValues
    self.allowComments = allowComments
    self.allowTrailingCommas = allowTrailingCommas
    self.allowUnquotedKeys = allowUnquotedKeys
  }
}
