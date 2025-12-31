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

@StreamParseable
private struct MacroStats {
  var name: String
  var stats: [String: Int]
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
      .delegateKeyed(key: "scores", .appendArrayElement(.int(0))),
      .delegateKeyed(key: "scores", .delegateUnkeyed(index: 0, .setValue(.int(10)))),
      .delegateKeyed(key: "scores", .appendArrayElement(.int(0))),
      .delegateKeyed(key: "scores", .delegateUnkeyed(index: 1, .setValue(.int(20))))
    ]

    var stream = PartialsStream(
      initialValue: MacroScores.Partial(),
      from: MockParser(defaultCommands: defaultCommands)
    )

    let partial = try stream.next([0x00, 0x01, 0x02, 0x03, 0x04])

    expectNoDifference(partial.name, "Blob")
    expectNoDifference(partial.scores, [10, 20])
  }

  @Test
  func `Parses StreamParseable Macro Values With Dictionary Field`() throws {
    let defaultCommands: [DefaultStreamAction] = [
      .delegateKeyed(key: "name", .setValue(.string("Blob"))),
      .delegateKeyed(key: "stats", .delegateKeyed(key: "level", .createObjectValue(.int(0)))),
      .delegateKeyed(key: "stats", .delegateKeyed(key: "level", .setValue(.int(7)))),
      .delegateKeyed(key: "stats", .delegateKeyed(key: "score", .createObjectValue(.int(0)))),
      .delegateKeyed(key: "stats", .delegateKeyed(key: "score", .setValue(.int(99))))
    ]

    var stream = PartialsStream(
      initialValue: MacroStats.Partial(),
      from: MockParser(defaultCommands: defaultCommands)
    )

    let partial = try stream.next([0x00, 0x01, 0x02, 0x03, 0x04])

    expectNoDifference(partial.name, "Blob")
    expectNoDifference(partial.stats, ["level": 7, "score": 99])
  }
}
