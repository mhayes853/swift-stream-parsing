#if canImport(CoreGraphics)
  import CoreGraphics

  extension CGFloat: StreamActionReducer {
    public typealias StreamAction = DefaultStreamAction
  }

  extension CGFloat: ConvertibleFromStreamedValue {}
#endif
