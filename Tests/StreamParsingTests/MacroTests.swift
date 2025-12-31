import CustomDump
import StreamParsing
import Testing

@StreamParseable
private struct MacroSimple {
  var name: String
  var age: Int
}

@StreamParseable
private struct MacroAddress {
  var city: String
  var zip: Int
}

@StreamParseable
private struct MacroPerson {
  var name: String
  var address: MacroAddress
}

@StreamParseable
private struct MacroScores {
  var name: String
  var scores: [Int]
}

@Suite
struct `Macro tests` {
  @Test
  func `Parses StreamParseable Macro Values`() throws {
    let defaultCommands: [DefaultStreamAction] = [
      .delegateKeyed(key: "name", .setValue(.string("Blob"))),
      .delegateKeyed(key: "age", .setValue(.int(42)))
    ]

    var stream = PartialsStream(
      initialValue: MacroSimple.Partial(),
      from: MockParser(defaultCommands: defaultCommands)
    )

    let partial = try stream.next([0x00, 0x01])

    expectNoDifference(partial.name, "Blob")
    expectNoDifference(partial.age, 42)
  }

  @Test
  func `Parses Nested StreamParseable Macro Values`() throws {
    let defaultCommands: [DefaultStreamAction] = [
      .delegateKeyed(key: "name", .setValue(.string("Blob"))),
      .delegateKeyed(key: "address", .delegateKeyed(key: "city", .setValue(.string("Denver")))),
      .delegateKeyed(key: "address", .delegateKeyed(key: "zip", .setValue(.int(80202))))
    ]

    var stream = PartialsStream(
      initialValue: MacroPerson.Partial(),
      from: MockParser(defaultCommands: defaultCommands)
    )

    let partial = try stream.next([0x00, 0x01, 0x02])

    expectNoDifference(partial.name, "Blob")
    expectNoDifference(partial.address?.city, "Denver")
    expectNoDifference(partial.address?.zip, 80202)
  }

  @Test
  func `Parses StreamParseable Macro Values With Array Field`() throws {
    let defaultCommands: [DefaultStreamAction] = [
      .delegateKeyed(key: "name", .setValue(.string("Blob"))),
      .delegateKeyed(key: "scores", .delegateUnkeyed(index: 0, .setValue(.int(10)))),
      .delegateKeyed(key: "scores", .delegateUnkeyed(index: 1, .setValue(.int(20))))
    ]

    var stream = PartialsStream(
      initialValue: MacroScores.Partial(),
      from: MockParser(defaultCommands: defaultCommands)
    )

    let partial = try stream.next([0x00, 0x01, 0x02])

    expectNoDifference(partial.name, "Blob")
    expectNoDifference(partial.scores, [10, 20])
  }
}
