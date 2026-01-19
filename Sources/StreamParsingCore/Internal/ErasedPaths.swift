// MARK: - StreamParseableDictionaryObject

extension StreamParseableDictionaryObject {
  package var erasedPath: any StreamParseableDictionaryObject<Value> {
    get { self }
    set { self = newValue as! Self }
  }
}

// MARK: - StreamParseableArrayObject

extension StreamParseableArrayObject {
  package var erasedPath: any StreamParseableArrayObject<Element> {
    get { self }
    set { self = newValue as! Self }
  }
}

// MARK: - StreamParseableValue

private protocol _StreamParsingNilLiteralConvertible {
  static func streamParsingNil() -> Self
}

extension Optional: _StreamParsingNilLiteralConvertible {
  fileprivate static func streamParsingNil() -> Self { nil }
}

extension Optional where Wrapped: StreamParseableValue {
  package var nullablePath: Void? {
    get { self != nil ? () : nil }
    set {
      if let nilConvertible = Wrapped.self as? _StreamParsingNilLiteralConvertible.Type,
        let nilValue = nilConvertible.streamParsingNil() as? Wrapped
      {
        self = .some(nilValue)
      } else {
        self = nil
      }
    }
  }
}

// MARK: - Int128

@available(StreamParsing128BitIntegers, *)
extension Int128 {
  package var erasedPath: any Sendable {
    get { self }
    set { self = newValue as! Int128 }
  }
}

// MARK: - UInt128

@available(StreamParsing128BitIntegers, *)
extension UInt128 {
  package var erasedPath: any Sendable {
    get { self }
    set { self = newValue as! UInt128 }
  }
}
