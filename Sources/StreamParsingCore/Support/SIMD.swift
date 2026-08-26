// Native SIMD values are fixed-width JSON arrays. Their parsing cursor belongs to the sink frame,
// not the value, so a partially parsed vector remains an ordinary inline value whose completed
// lanes are immediately observable and whose remaining lanes retain their initial value.

extension SIMD2: StreamInitializable where Scalar: StreamInitializable {
  public static func streamInitialValue() -> Self {
    Self(repeating: Scalar.streamInitialValue())
  }
}

extension SIMD3: StreamInitializable where Scalar: StreamInitializable {
  public static func streamInitialValue() -> Self {
    Self(repeating: Scalar.streamInitialValue())
  }
}

extension SIMD4: StreamInitializable where Scalar: StreamInitializable {
  public static func streamInitialValue() -> Self {
    Self(repeating: Scalar.streamInitialValue())
  }
}

extension SIMD2: StreamParseableRoot
where Scalar: StreamNumberConvertible & StreamInitializable {
  public static var streamSchema: StreamSchema { _streamSIMD2Schema(Self.self) }
}

extension SIMD3: StreamParseableRoot
where Scalar: StreamNumberConvertible & StreamInitializable {
  public static var streamSchema: StreamSchema { _streamSIMD3Schema(Self.self) }
}

extension SIMD4: StreamParseableRoot
where Scalar: StreamNumberConvertible & StreamInitializable {
  public static var streamSchema: StreamSchema { _streamSIMD4Schema(Self.self) }
}

extension SIMD2: StreamContainerPartial
where Scalar: StreamNumberConvertible & StreamInitializable {}

extension SIMD3: StreamContainerPartial
where Scalar: StreamNumberConvertible & StreamInitializable {}

extension SIMD4: StreamContainerPartial
where Scalar: StreamNumberConvertible & StreamInitializable {}

extension SIMD2: StreamParseable
where Scalar: StreamNumberConvertible & StreamInitializable {
  public typealias Partial = Self
}

extension SIMD3: StreamParseable
where Scalar: StreamNumberConvertible & StreamInitializable {
  public typealias Partial = Self
}

extension SIMD4: StreamParseable
where Scalar: StreamNumberConvertible & StreamInitializable {
  public typealias Partial = Self
}
