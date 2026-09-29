import CustomDump
import Testing

import StreamParsing
import StreamParsingCore

// Optionals whose slot a container opens rather than the document root: an `InlineArray` element,
// which starts `nil`, and the inner optional of a `T??` element. The wrapped type's fast writes (a
// struct's field table, a vector's lanes) go straight into the payload, so the slot has to be
// materialised all the way down before its first byte arrives.

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
@StreamParseable
struct NestedOptionalChild: Equatable {
  var id: Int = 0
  var name: String = ""
}

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
@StreamParseable
private struct NestedOptionalBox<Value: StreamParseable & Equatable> {
  var v: Value
}

@available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
@StreamParseable
private struct OptionalInlineChildren {
  var children: InlineArray<2, NestedOptionalChild?> = InlineArray(repeating: nil)
}

@Suite
struct `Nested optional tests` {
  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  private func box<Value: StreamParseable & Equatable>(
    _ json: String, as type: Value.Type, chunk: Int = .max
  ) throws -> Value? {
    var partial = NestedOptionalBox<Value>.Partial()
    try parsePartial(json, into: &partial, chunk: chunk)
    return NestedOptionalBox<Value>(streamPartial: partial)?.v
  }

  // MARK: - Double optional elements

  @Test(arguments: [1, 3, Int.max])
  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  func `Double optional vector elements keep their lanes`(chunk: Int) throws {
    var vectors = StreamArray<SIMD2<Double>??>.streamInitialValue()
    try parsePartial("[[1,2],null]", into: &vectors, chunk: chunk)
    expectNoDifference(Array(vectors), [.some(.some(SIMD2(1, 2))), nil])
  }

  @Test(arguments: [1, 3, Int.max])
  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  func `Double optional struct elements are materialised before their fields`(chunk: Int) throws {
    let json = #"{"v":[{"id":3,"name":"x"},null]}"#
    let children = try self.box(json, as: [NestedOptionalChild??].self, chunk: chunk)
    expectNoDifference(children, [.some(.some(NestedOptionalChild(id: 3, name: "x"))), nil])
  }

  @Test
  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  func `Double optional dictionary values are materialised before they are written`() throws {
    let children = try self.box(
      #"{"v":{"k":{"id":3,"name":"x"},"n":null}}"#, as: [String: NestedOptionalChild??].self
    )
    expectNoDifference(children, ["k": .some(.some(NestedOptionalChild(id: 3, name: "x"))), "n": nil])
    let vectors = try self.box(#"{"v":{"k":[1,2],"n":null}}"#, as: [String: SIMD2<Double>??].self)
    expectNoDifference(vectors, ["k": .some(.some(SIMD2(1, 2))), "n": nil])
  }

  // MARK: - InlineArray

  @Test(arguments: [1, 3, Int.max])
  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  func `Optional struct elements of an InlineArray are materialised before their fields`(
    chunk: Int
  ) throws {
    var fields = OptionalInlineChildren.Partial()
    try parsePartial(#"{"children":[{"id":3,"name":"x"},null]}"#, into: &fields, chunk: chunk)
    let value = try #require(OptionalInlineChildren(streamPartial: fields))
    expectNoDifference(
      [value.children[0], value.children[1]], [NestedOptionalChild(id: 3, name: "x"), nil]
    )
  }

  @Test(arguments: [1, 3, Int.max])
  @available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *)
  func `Optional vector elements of an InlineArray keep their lanes`(chunk: Int) throws {
    var single = InlineArray<2, SIMD2<Double>?>.streamInitialValue()
    try parsePartial("[[1,2],null]", into: &single, chunk: chunk)
    expectNoDifference([single[0], single[1]], [SIMD2(1, 2), nil])

    var double = InlineArray<2, SIMD2<Double>??>.streamInitialValue()
    try parsePartial("[[1,2],null]", into: &double, chunk: chunk)
    expectNoDifference([double[0], double[1]], [.some(.some(SIMD2(1, 2))), nil])
  }
}
