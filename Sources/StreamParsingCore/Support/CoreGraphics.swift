#if canImport(CoreGraphics)
  import CoreGraphics

  extension CGFloat: StreamActionReducer {
    public typealias StreamAction = DefaultStreamAction
  }

  extension CGFloat: StreamParseable {
    public typealias Partial = Self
  }

  extension CGFloat: ConvertibleFromStreamedValue {}
#endif
