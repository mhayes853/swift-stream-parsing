#if canImport(CoreGraphics)
  import CoreGraphics

  extension CGFloat: StreamParseable {
    public typealias Partial = Self
  }

  extension CGFloat: StreamParseableReducer {}

  extension CGFloat: ConvertibleFromStreamedValue {}
#endif
