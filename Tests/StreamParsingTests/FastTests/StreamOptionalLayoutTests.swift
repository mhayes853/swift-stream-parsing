import Testing

import StreamParsingCore

// The frame entry helpers reinterpret a pointer to an Optional as a pointer to its payload,
// which assumes single payload enums store the payload at offset zero and that writing a valid
// payload through it cannot flip the value back to nil. Both are implementation details, so
// they are checked here for the shapes the macro generates rather than assumed.
//
// If a future toolchain changes optional layout, these fail rather than the parser silently
// corrupting values.
@Suite
struct `Stream optional layout tests` {
  private static func expectPayloadAtOffsetZero<T: Equatable>(
    _ initial: T,
    mutate: (UnsafeMutablePointer<T>) -> Void,
    expected: T,
    _ label: String,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    var optional: T? = initial
    withUnsafeMutablePointer(to: &optional) { pointer in
      let payload = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: T.self)
      mutate(payload)
    }
    #expect(optional != nil, "\(label) became nil", sourceLocation: sourceLocation)
    #expect(optional == expected, "\(label) did not round trip", sourceLocation: sourceLocation)
  }

  // No spare bits, so the optional needs a separate tag byte.
  private struct Trivial: Equatable {
    var a: Int
    var b: Int
  }

  @Test
  func `A struct of integers keeps its payload at offset zero`() {
    Self.expectPayloadAtOffsetZero(
      Trivial(a: 1, b: 2),
      mutate: { $0.pointee.b = 99 },
      expected: Trivial(a: 1, b: 99),
      "Trivial"
    )
  }

  // Contains a reference, so the optional can use a spare bit representation instead of a tag.
  private struct WithReference: Equatable {
    var text: String
    var count: Int
  }

  @Test
  func `A struct containing a reference keeps its payload at offset zero`() {
    Self.expectPayloadAtOffsetZero(
      WithReference(text: "a", count: 1),
      mutate: { $0.pointee.text = "changed" },
      expected: WithReference(text: "changed", count: 1),
      "WithReference"
    )
  }

  // The shape the macro actually generates: every member optional.
  private struct AllOptional: Equatable {
    var id: Int?
    var name: String?
    var flag: Bool?
  }

  @Test
  func `A partial shaped struct keeps its payload at offset zero`() {
    Self.expectPayloadAtOffsetZero(
      AllOptional(),
      mutate: {
        $0.pointee.id = 42
        $0.pointee.name = "Blob"
      },
      expected: AllOptional(id: 42, name: "Blob", flag: nil),
      "AllOptional"
    )
  }

  private struct Nested: Equatable {
    var inner: AllOptional?
    var value: Int?
  }

  @Test
  func `A nested optional keeps its payload at offset zero`() {
    Self.expectPayloadAtOffsetZero(
      Nested(),
      mutate: { $0.pointee.value = 7 },
      expected: Nested(inner: nil, value: 7),
      "Nested"
    )
  }

  @Test
  func `An array keeps its payload at offset zero`() {
    Self.expectPayloadAtOffsetZero(
      [Int](),
      mutate: { $0.pointee.append(5) },
      expected: [5],
      "Array"
    )
  }

  // An empty struct has no bytes to spare, which is the case most likely to place a tag first.
  private struct Empty: Equatable {}

  @Test
  func `Optional payload offset is zero for every checked type`() {
    #expect(MemoryLayout<Trivial?>.size >= MemoryLayout<Trivial>.size)
    #expect(MemoryLayout<WithReference?>.size == MemoryLayout<WithReference>.size)
    #expect(MemoryLayout<[Int]?>.size == MemoryLayout<[Int]>.size)
  }
}
