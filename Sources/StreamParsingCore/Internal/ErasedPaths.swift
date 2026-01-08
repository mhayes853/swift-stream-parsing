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

extension Optional where Wrapped: StreamParseableValue {
  package var nullablePath: Void? {
    get { self != nil ? () : nil }
    set { self = nil }
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
