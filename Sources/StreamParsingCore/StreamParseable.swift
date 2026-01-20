/// A value that can expose the partial parsing state consumed from a stream.
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
