#if canImport(CoreGraphics)
  import CoreGraphics

  extension CGFloat: StreamParseable {
    public typealias Partial = Self
  }

  extension CGFloat: StreamParseableReducer {
    public static func initialReduceableValue() -> Self {
      0
    }
  }

  extension CGFloat: ConvertibleFromStreamedValue {}
#endif
