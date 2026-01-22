/// A value that can expose the partial parsing state consumed from a stream.
///
/// You typically do not conform to ``StreamParseable`` directly; instead add the
/// `@StreamParseable` macro to your struct and let it synthesize the conformance.
public protocol StreamParseable {
  /// The partial representation exposed during parsing.
  associatedtype Partial: StreamParseableValue

  /// The partial state that corresponds to the type’s incremental parsing representation.
  var streamPartialValue: Partial { get }
}

extension StreamParseable where Partial == Self {
  public var streamPartialValue: Partial {
    self
  }
}
