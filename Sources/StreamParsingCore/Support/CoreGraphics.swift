#if CoreGraphics && canImport(CoreGraphics)
  import CoreGraphics

  // MARK: - Conversion protocols

  // `CGFloat` is not `LosslessStringConvertible`, so it converts through `Double`.
  extension CGFloat: StreamNumberConvertible, StreamInitializable, StreamPartial {
    public static func streamInitialValue() -> Self { 0 }

    public init?(streamParsing bytes: Span<UInt8>, info: NumberInfo) {
      guard let value = Double(streamParsing: bytes, info: info) else { return nil }
      self = CGFloat(value)
    }
  }

  // MARK: - StreamParseable

  extension CGFloat: StreamParseable {
    public typealias Partial = Self
  }
#endif
