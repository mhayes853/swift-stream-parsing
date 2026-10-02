import Testing

@testable import StreamParsingCore

// `StreamEventBatch.inlineBytesOffset` reaches an inline record's bytes by arithmetic rather than
// through `MemoryLayout.offset(of:)`, because a key path does not compile under Embedded Swift.
// The arithmetic holds only while `extra` stays the record's last stored property, which is what
// this pins: reorder the record and the embedded build would keep compiling and read the wrong
// four bytes.
@Suite("StreamEventRecord layout tests")
struct StreamEventRecordLayoutTests {
  @Test("Inline Bytes Offset Is The Offset Of Extra")
  func inlineBytesOffsetIsOffsetOfExtra() {
    #expect(
      StreamEventBatch.inlineBytesOffset == MemoryLayout<StreamEventRecord>.offset(of: \.extra)
    )
  }
}
