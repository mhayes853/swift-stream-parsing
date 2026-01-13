public protocol StreamParseable {
  associatedtype Partial: StreamParseableValue

  var streamPartialValue: Partial { get }
}

extension StreamParseable where Partial == Self {
  public var streamPartialValue: Partial {
    self
  }
}
