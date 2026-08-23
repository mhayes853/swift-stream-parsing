import CustomDump
import Testing

import StreamParsing
import StreamParsingCore

// A schema is a shared reference rather than a value, which is what took the array-of-structs
// parse from 251 µs to 79 µs. The cost of that choice is that every concurrent parse of the same
// type touches one refcount on one cache line — named in NEW_ARCHITECTURE.md's known gaps, with
// no test and no benchmark behind it.
//
// This is the test half. It cannot prove the absence of a race, but it does put many parses of
// the same type on many threads at once with results that must all come back correct, which is
// what a schema mutated or torn by a concurrent parse would break. Run it under TSan to make the
// claim stronger: `swift test --sanitize=thread --filter "Concurrent parsing tests"`.
@Suite
struct `Concurrent parsing tests` {
  private static func payload(_ index: Int) -> [UInt8] {
    let users = (0..<16)
      .map { #"{"id":\#(index * 100 + $0),"name":"User \#($0)","email":"u\#($0)@example.com"}"# }
      .joined(separator: ",")
    return Array("{\"users\":[\(users)],\"total\":\(index)}".utf8)
  }

  // The comparison is against the same payload parsed alone, on this task, before any of the
  // concurrent ones start. A schema torn by a concurrent parse shows up as a partial that differs
  // from the one the serial parse produced, without this test having to spell out the shape.
  //
  // Partials are compared as rendered literals rather than by `==`: the generated `Partial` is
  // not `Equatable`, and a `String` is what can cross a task boundary anyway.
  private static func expected(_ index: Int) throws -> String {
    swiftLiteral(try Self.parse(Self.payload(index), chunk: .max))
  }

  private static func parse(_ bytes: [UInt8], chunk: Int) throws -> ConcurrentUserList.Partial {
    var stream = PartialsStream(initialValue: ConcurrentUserList.Partial(), from: .json())
    var index = 0
    while index < bytes.count {
      let end = Swift.min(index + chunk, bytes.count)
      try stream.next(bytes[index..<end])
      index = end
    }
    return try stream.finish()
  }

  @Test
  func `The same type parses correctly on many tasks at once`() async throws {
    let expected = try (0..<64).map { try Self.expected($0) }

    let results = await withTaskGroup(of: (Int, String?).self) { group in
      for index in 0..<64 {
        group.addTask {
          var last: String?
          for _ in 0..<32 {
            last = (try? Self.parse(Self.payload(index), chunk: 7)).map { swiftLiteral($0) }
          }
          return (index, last)
        }
      }
      var collected = [Int: String?]()
      for await (index, value) in group { collected[index] = value }
      return collected
    }

    expectNoDifference(results.count, 64)
    for index in 0..<64 {
      expectNoDifference(results[index] ?? nil, expected[index])
    }
  }

  // Every task starts from the same payload and races on the one schema, in bulk rather than in
  // chunks, so nothing but the shared reference is between them.
  @Test
  func `Concurrent bulk parses agree with a serial one`() async throws {
    let expected = try Self.expected(1)

    await withTaskGroup(of: Bool.self) { group in
      for _ in 0..<128 {
        group.addTask {
          (try? Self.parse(Self.payload(1), chunk: .max)).map { swiftLiteral($0) } == expected
        }
      }
      for await ok in group { expectNoDifference(ok, true) }
    }
  }

  // Reading a partial through a view while other tasks parse the same type, since the view path
  // reaches through the same schema the parse is driving.
  @Test
  func `Views read safely while other tasks parse the same type`() async throws {
    await withTaskGroup(of: Bool.self) { group in
      for index in 0..<32 {
        group.addTask {
          let bytes = Self.payload(index)
          var stream = PartialsStream(initialValue: ConcurrentUserList.Partial(), from: .json())
          for byte in bytes {
            guard (try? stream.next(byte)) != nil else { return false }
            stream.withView { blackHoleTotal($0.total?.value) }
          }
          return (try? stream.finish()).map { $0.total == index } ?? false
        }
      }
      for await ok in group { expectNoDifference(ok, true) }
    }
  }
}

@inline(never)
private func blackHoleTotal(_ value: Int?) {}

@StreamParseable
private struct ConcurrentUser: Equatable {
  var id: Int = 0
  var name: String = ""
  var email: String = ""
}

@StreamParseable
private struct ConcurrentUserList: Equatable {
  var users: [ConcurrentUser] = []
  var total: Int = 0
}
