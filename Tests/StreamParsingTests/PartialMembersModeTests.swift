import CustomDump
import StreamParsing
import Testing

// Both modes, in each spelling the macro reads: it sees the argument's syntax, not its value.

@StreamParseable(partialMembers: .optional)
private struct ExplicitOptionalModel: Equatable {
  var id: Int
  var name: String
}

@StreamParseable(partialMembers: PartialMembersMode.streamInitialValue)
private struct QualifiedInitialValueModel: Equatable {
  var id: Int
  var name: String
}

@StreamParseable(partialMembers: StreamParsing.PartialMembersMode.optional)
private struct ModuleQualifiedOptionalModel: Equatable {
  var id: Int
}

@Suite
struct `Partial Members Mode Tests` {
  @Test
  func `The two modes are distinct values`() {
    #expect(PartialMembersMode.optional != .streamInitialValue)
    let modes: Set<PartialMembersMode> = [.optional, .streamInitialValue, .optional]
    expectNoDifference(modes.count, 2)
  }

  @Test
  func `Optional mode leaves absent members nil`() throws {
    var stream = PartialsStream(initialValue: ExplicitOptionalModel.Partial(), from: .json())
    try stream.next(Array(#"{"id":3}"#.utf8))
    expectNoDifference(stream.current.id, 3)
    expectNoDifference(stream.current.name, nil)
    expectNoDifference(ExplicitOptionalModel(stream.current), nil)
    expectNoDifference(ModuleQualifiedOptionalModel.Partial().id, nil)
  }

  @Test
  func `Initial value mode starts members at their initial values`() throws {
    let initial = QualifiedInitialValueModel.Partial()
    expectNoDifference(initial.id, 0)
    expectNoDifference(initial.name.isEmpty, true)
    var stream = PartialsStream(initialValue: initial, from: .json())
    try stream.next(Array(#"{"id":3}"#.utf8))
    expectNoDifference(QualifiedInitialValueModel(stream.current), QualifiedInitialValueModel(id: 3, name: ""))
  }
}
