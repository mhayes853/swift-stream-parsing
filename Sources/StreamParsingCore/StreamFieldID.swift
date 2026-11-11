/// The identity of a declared field within one stream schema.
///
/// All aliases for a field have the same identity. Obtain identifiers from generated
/// references or recognition callbacks. They are not array positions, table indices,
/// or persistent identifiers, and must only be compared within the same schema.
public struct StreamFieldID: Hashable, Sendable {
  fileprivate let value: Int32
}

/// Bridges generated schema references to field identities.
///
/// This is generator/runtime support. Consumers should use the identifier expressions
/// provided by `StreamParsingMacroSupport` instead of constructing numeric identities.
public func _streamFieldID(_ schemaLocalIndex: Int32) -> StreamFieldID {
  precondition(schemaLocalIndex >= 0)
  return StreamFieldID(value: schemaLocalIndex)
}
