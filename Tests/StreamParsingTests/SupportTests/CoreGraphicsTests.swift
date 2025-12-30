#if canImport(CoreGraphics)
  import CoreGraphics
  import StreamParsing
  import Testing

  @Suite
  struct `StreamActionReducer+CoreGraphics tests` {
    @Test
    func `Sets CGFloat From Double SetValue`() throws {
      try expectSetValue(initial: CGFloat(0), expected: CGFloat(12.5), streamedValue: .double(12.5))
    }

    @Test
    func `Sets CGFloat From Float SetValue`() throws {
      try expectSetValue(initial: CGFloat(0), expected: CGFloat(3.5), streamedValue: .float(3.5))
    }
  }
#endif
