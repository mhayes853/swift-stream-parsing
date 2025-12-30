#if canImport(CoreGraphics)
  import CoreGraphics

  extension CGFloat: StreamActionReducer {
    public typealias StreamAction = DefaultStreamAction

    public mutating func reduce(action: DefaultStreamAction) throws {
      self = try action.standardLibraryValue(as: CGFloat.self)
    }
  }
#endif
