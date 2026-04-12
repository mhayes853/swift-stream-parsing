// MARK: - StreamParseableDictionaryObject

extension StreamParseableDictionaryObject {
  var erasedJSONPath: any StreamParseableDictionaryObject {
    get { self }
    set { self = newValue as! Self }
  }

  package var erasedPath: any StreamParseableDictionaryObject<Value> {
    get { self }
    set { self = newValue as! Self }
  }

  subscript(unwrapped key: String) -> Value {
    get { self[key] ?? Value.initialParseableValue() }
    set { self[key] = newValue }
  }
}

// MARK: - StreamParseableArrayObject

extension StreamParseableArrayObject {
  var erasedJSONPath: any StreamParseableArrayObject {
    get { self }
    set { self = newValue as! Self }
  }

  package var erasedPath: any StreamParseableArrayObject<Element> {
    get { self }
    set { self = newValue as! Self }
  }

  var currentElement: Element {
    get {
      let index = self.count - 1
      return self[index]
    }
    set {
      let index = self.count - 1
      self[index] = newValue
    }
  }

  mutating func appendNewElement() {
    self.append(contentsOf: CollectionOfOne(.initialParseableValue()))
  }
}

// MARK: - StreamParseableValue

extension StreamParseableValue {
  var erasedJSONPath: any StreamParseableValue {
    get { self }
    set { self = newValue as! Self }
  }

  mutating func reset() {
    self = .initialParseableValue()
  }
}

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
