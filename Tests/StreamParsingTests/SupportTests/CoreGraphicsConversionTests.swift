#if StreamParsingCoreGraphics && canImport(CoreGraphics)
  import CoreGraphics
  import Testing

  import StreamParsing
  import StreamParsingCore

  @StreamParseable
  struct CoreGraphicsValues: Equatable {
    var width: CGFloat = 0
    var height: CGFloat = 0
  }

  @Suite
  struct `CoreGraphics conversion tests` {
    @Test(arguments: [Int.max, 7, 1])
    func `CGFloat converts through Double`(chunk: Int) throws {
      var value = CoreGraphicsValues.Partial()
      try parsePartial(#"{"width":320.5,"height":-1.25e2}"#, into: &value, chunk: chunk)
      expectNoDifference(value.width, 320.5)
      expectNoDifference(value.height, -125)
    }

    @Test
    func `CGFloat takes whole numbers from the accumulated magnitude`() throws {
      var value = CoreGraphicsValues.Partial()
      try parsePartial(#"{"width":1024,"height":0}"#, into: &value)
      expectNoDifference(value.width, 1024)
      expectNoDifference(value.height, 0)
    }
  }
#endif
