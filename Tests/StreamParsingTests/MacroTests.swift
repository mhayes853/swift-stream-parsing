import CustomDump
import StreamParsing
import Testing

@Suite
struct `Macro tests` {
  @Test
  func `Parses StreamParseable Macro Values`() throws {
    let defaultCommands: [StreamAction] = [
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
  func `Parses StreamParseable Macro Values With Initial Reduceable Members`() throws {
    let defaultCommands: [StreamAction] = [
      .delegateKeyed(key: "name", .setValue(.string("Blob"))),
      .delegateKeyed(key: "age", .setValue(.int(42)))
    ]

    var stream = PartialsStream(
      initialValue: MacroInitialReduceable.Partial(),
      from: MockParser(defaultCommands: defaultCommands)
    )

    let partial = try stream.next([0x00, 0x01])

    expectNoDifference(partial.name, "Blob")
    expectNoDifference(partial.age, 42)
  }

  @Test
  func `Parses Nested StreamParseable Macro Values`() throws {
    let defaultCommands: [StreamAction] = [
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
    let defaultCommands: [StreamAction] = [
      .delegateKeyed(key: "name", .setValue(.string("Blob"))),
      .delegateKeyed(key: "scores", .createUnkeyedValue),
      .delegateKeyed(key: "scores", .delegateUnkeyed(index: 0, .setValue(.int(10)))),
      .delegateKeyed(key: "scores", .createUnkeyedValue),
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
    let defaultCommands: [StreamAction] = [
      .delegateKeyed(key: "name", .setValue(.string("Blob"))),
      .delegateKeyed(key: "stats", .delegateKeyed(key: "level", .createKeyedValue)),
      .delegateKeyed(key: "stats", .delegateKeyed(key: "level", .setValue(.int(7)))),
      .delegateKeyed(key: "stats", .delegateKeyed(key: "score", .createKeyedValue)),
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

  @Test
  func `Parses StreamParseable Macro Values With Nested Array Field`() throws {
    let defaultCommands: [StreamAction] = [
      .delegateKeyed(key: "name", .setValue(.string("Blob"))),
      .delegateKeyed(key: "addresses", .createUnkeyedValue),
      .delegateKeyed(
        key: "addresses",
        .delegateUnkeyed(index: 0, .delegateKeyed(key: "city", .setValue(.string("Denver"))))
      ),
      .delegateKeyed(
        key: "addresses",
        .delegateUnkeyed(index: 0, .delegateKeyed(key: "zip", .setValue(.int(80202))))
      )
    ]

    var stream = PartialsStream(
      initialValue: MacroAddressList.Partial(),
      from: MockParser(defaultCommands: defaultCommands)
    )

    let partial = try stream.next([0x00, 0x01, 0x02, 0x03])

    expectNoDifference(partial.name, "Blob")
    expectNoDifference(partial.addresses?.first?.city, "Denver")
    expectNoDifference(partial.addresses?.first?.zip, 80202)
    expectNoDifference(partial.addresses?.count, 1)
  }

  @Test
  func `Parses StreamParseable Macro Values With Nested Dictionary Field`() throws {
    let defaultCommands: [StreamAction] = [
      .delegateKeyed(key: "name", .setValue(.string("Blob"))),
      .delegateKeyed(key: "addresses", .delegateKeyed(key: "home", .createKeyedValue)),
      .delegateKeyed(
        key: "addresses",
        .delegateKeyed(key: "home", .delegateKeyed(key: "city", .setValue(.string("Denver"))))
      ),
      .delegateKeyed(
        key: "addresses",
        .delegateKeyed(key: "home", .delegateKeyed(key: "zip", .setValue(.int(80202))))
      )
    ]

    var stream = PartialsStream(
      initialValue: MacroAddressBook.Partial(),
      from: MockParser(defaultCommands: defaultCommands)
    )

    let partial = try stream.next([0x00, 0x01, 0x02, 0x03])

    expectNoDifference(partial.name, "Blob")
    expectNoDifference(partial.addresses?["home"]?.city, "Denver")
    expectNoDifference(partial.addresses?["home"]?.zip, 80202)
  }

  @Test
  func `Reduces Actions On StreamParseable Macro Optional Values`() throws {
    let defaultCommands: [StreamAction] = [
      .delegateKeyed(key: "name", .setValue(.string("Blob"))),
      .delegateKeyed(key: "name", .setValue(.null))
    ]

    var stream = PartialsStream(
      initialValue: MacroOptional.Partial(),
      from: MockParser(defaultCommands: defaultCommands)
    )

    let partial = try stream.next([0x00, 0x01])

    expectNoDifference(partial.name, .some(nil))
  }

  @Test
  func `Ignores Unknown Properties For StreamParseable Macro Values`() throws {
    let defaultCommands: [StreamAction] = [
      .delegateKeyed(key: "unknown", .setValue(.string("Blob")))
    ]

    let original = MacroSimple.Partial(name: "Jane", age: 21)

    var stream = PartialsStream(
      initialValue: original,
      from: MockParser(defaultCommands: defaultCommands)
    )

    let partial = try stream.next([0x00])

    expectNoDifference(partial.name, original.name)
    expectNoDifference(partial.age, original.age)
  }
}

@StreamParseable
private struct MacroSimple {
  var name: String
  var age: Int
}

@StreamParseable(partialMembers: .initialReduceableValue)
private struct MacroInitialReduceable {
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

@StreamParseable
private struct MacroAddressList {
  var name: String
  var addresses: [MacroAddress]
}

@StreamParseable
private struct MacroAddressBook {
  var name: String
  var addresses: [String: MacroAddress]
}

@StreamParseable
private struct MacroOptional {
  var name: String?
}
