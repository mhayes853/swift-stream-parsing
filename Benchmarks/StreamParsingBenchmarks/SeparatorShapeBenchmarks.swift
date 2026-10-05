import Benchmark
import StreamParsing
import StreamParsingCore

// The same documents written in the three separator styles producers actually emit, so a change to
// the structural run can be judged on shapes the corpus does not happen to contain. The corpus
// covers these unevenly: Mesh is the only `, `-separated number array, Canada the only minified
// one, Twitter spaced the only Python-style object, and no payload is a minified array of strings
// or of literals. Which path a separator takes depends on the style -- a comma followed by
// indentation or by `space quote` sends the ladder to the block walk, a lone space before a
// number stays on the ladder, a minified comma never leaves it -- so a fusion or a walk-signal
// change can win on one style and lose on another with the corpus none the wiser.
//
// Each shape is one value tree serialized three ways, so within a shape the styles differ only in
// their separator bytes. Each style gets a raw counting row and a typed row; typed is the
// acceptance criterion, raw says whether a typed delta is the parser's.
//
//   minified   `,` and `:`             JSON.stringify(x), json.dumps(x, separators=(",", ":"))
//   spaced     `, ` and `: `           json.dumps(x), the Python default
//   indented   newline + 2 per level   JSON.stringify(x, null, 2), json.dumps(x, indent=2)

// MARK: - Serializer

enum SeparatorStyle: String, CaseIterable {
  case minified
  case spaced
  case indented
}

indirect enum SeparatorValue {
  // A number as its token text, so every style writes the same bytes for it.
  case number(String)
  // Written unescaped: the generators only produce ASCII names.
  case string(String)
  case bool(Bool)
  case null
  case array([SeparatorValue])
  case object([(String, SeparatorValue)])

  func json(_ style: SeparatorStyle) -> [UInt8] {
    var out = ""
    self.write(style, depth: 0, into: &out)
    return Array(out.utf8)
  }

  private func write(_ style: SeparatorStyle, depth: Int, into out: inout String) {
    switch self {
    case .number(let text): out += text
    case .string(let text): out += "\"\(text)\""
    case .bool(let value): out += value ? "true" : "false"
    case .null: out += "null"
    case .array(let elements):
      Self.writeContainer("[", "]", elements.count, style, depth, &out) { index, out in
        elements[index].write(style, depth: depth &+ 1, into: &out)
      }
    case .object(let members):
      Self.writeContainer("{", "}", members.count, style, depth, &out) { index, out in
        out += "\"\(members[index].0)\""
        out += style == .minified ? ":" : ": "
        members[index].1.write(style, depth: depth &+ 1, into: &out)
      }
    }
  }

  private static func writeContainer(
    _ open: String,
    _ close: String,
    _ count: Int,
    _ style: SeparatorStyle,
    _ depth: Int,
    _ out: inout String,
    element: (Int, inout String) -> Void
  ) {
    out += open
    guard count > 0 else {
      out += close
      return
    }
    for index in 0..<count {
      if index > 0 { out += style == .spaced ? ", " : "," }
      if style == .indented { out += "\n" + String(repeating: " ", count: 2 &* (depth &+ 1)) }
      element(index, &out)
    }
    if style == .indented { out += "\n" + String(repeating: " ", count: 2 &* depth) }
    out += close
  }
}

// MARK: - Shapes

// Sized so the minified form lands at 300-400 KB, the scale of the other synthetic shape rows.
enum SeparatorShapes {
  // Embedding-like values: sign, `0.`, eight digits -- the shape of Mesh and of an LLM's vectors.
  static let numbers = SeparatorValue.object([
    (
      "values",
      .array(Self.generate(count: 30_000) { digits in .number(Self.fraction(&digits, places: 8)) })
    )
  ])

  // Short identifiers: tags, enum cases, ids-as-strings.
  static let strings = SeparatorValue.object([
    (
      "values",
      .array(Self.generate(count: 30_000) { digits in .string("tag_\(digits.next() % 100_000)") })
    )
  ])

  // Flags: the literal arm's run, with nothing between the tokens but separators.
  static let literals = SeparatorValue.object([
    ("values", .array(Self.generate(count: 60_000) { digits in .bool(digits.next() & 1 == 0) }))
  ])

  // Canada's geometry: `[x, y]` pairs, where half the commas sit between a `]` and a `[`.
  static let numberPairs = SeparatorValue.object([
    (
      "values",
      .array(
        Self.generate(count: 15_000) { digits in
          .array([.number(Self.coordinate(&digits)), .number(Self.coordinate(&digits))])
        }
      )
    )
  ])

  // An API response's rows: one member per value kind, so every member separator follows a
  // number, a string, a literal, a `null` or a closing bracket.
  static let records = SeparatorValue.object([
    (
      "rows",
      .array(
        Self.generate(count: 3_000) { digits in
          let id = digits.next() % 1_000_000
          return .object([
            ("id", .number("\(id)")),
            ("name", .string("user_\(id)")),
            ("score", .number(Self.fraction(&digits, places: 4))),
            ("active", .bool(id & 1 == 0)),
            ("parent", id % 3 == 0 ? .number("\(id / 3)") : .null),
            ("tags", .array([.string("alpha"), .string("beta_\(id % 7)")]))
          ])
        }
      )
    )
  ])

  // A fixed-seed LCG, so every build writes the same documents.
  struct Digits {
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15

    mutating func next() -> UInt64 {
      self.state = self.state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return self.state &>> 33
    }
  }

  private static func generate(
    count: Int,
    _ body: (inout Digits) -> SeparatorValue
  ) -> [SeparatorValue] {
    var digits = Digits()
    return (0..<count).map { _ in body(&digits) }
  }

  private static func fraction(_ digits: inout Digits, places: Int) -> String {
    let sign = digits.next() & 1 == 0 ? "-" : ""
    var limit: UInt64 = 1
    for _ in 0..<places { limit &*= 10 }
    let value = String(digits.next() % limit)
    return "\(sign)0.\(String(repeating: "0", count: places - value.count))\(value)"
  }

  private static func coordinate(_ digits: inout Digits) -> String {
    let sign = digits.next() & 1 == 0 ? "-" : ""
    let fraction = String(digits.next() % 1_000_000)
    let padding = String(repeating: "0", count: 6 - fraction.count)
    return "\(sign)\(digits.next() % 180).\(padding)\(fraction)"
  }
}

// MARK: - Models

@StreamParseable
struct SeparatorNumbers: Equatable {
  var values: [Double] = []
}

@StreamParseable
struct SeparatorStrings: Equatable {
  var values: [String] = []
}

@StreamParseable
struct SeparatorLiterals: Equatable {
  var values: [Bool] = []
}

@StreamParseable
struct SeparatorPairs: Equatable {
  var values: [[Double]] = []
}

@StreamParseable
struct SeparatorRecord: Equatable {
  var id: Int = 0
  var name: String = ""
  var score: Double = 0
  var active: Bool = false
  var parent: Int? = nil
  var tags: [String] = []
}

@StreamParseable
struct SeparatorRecords: Equatable {
  var rows: [SeparatorRecord] = []
}

// MARK: - Rows

private func addSeparatorRows<Value: StreamPartial>(
  _ shape: String,
  _ value: SeparatorValue,
  as type: Value.Type,
  count: Int,
  fingerprint: (Value) -> (count: Int?, ends: [Any?])
) {
  var reference: String?
  for style in SeparatorStyle.allCases {
    let payload = value.json(style)
    // Every style must build the same value, or the rows are not comparing separators. The
    // partials are not `Equatable`, so each shape names its count and its end elements, and the
    // minified parse is the reference for the other two.
    let parsed = expectParses { try streamBulkDiscarding(payload, as: Value.self) }
    let seen = fingerprint(parsed)
    let ends = seen.ends.map { String(describing: $0) }.joined(separator: " ")
    precondition(seen.count == count, "Separators \(shape) \(style.rawValue): \(ends)")
    precondition(
      reference == nil || reference == ends,
      "Separators \(shape) \(style.rawValue): \(ends), minified \(reference ?? "")"
    )
    reference = ends

    let name = "Separators \(shape) \(style.rawValue)"
    Benchmark("\(name) - raw", configuration: payloadConfiguration) { benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(expectParses { try runFastParser(payload, chunk: .max) })
      }
    }
    Benchmark("\(name) - typed", configuration: payloadConfiguration) { benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(expectParses { try streamBulkDiscarding(payload, as: Value.self) })
      }
    }
  }
}

func separatorShapeBenchmarks() {
  addSeparatorRows(
    "numbers",
    SeparatorShapes.numbers,
    as: SeparatorNumbers.Partial.self,
    count: 30_000
  ) { ($0.values?.count, [$0.values?.first, $0.values?.last]) }
  addSeparatorRows(
    "strings",
    SeparatorShapes.strings,
    as: SeparatorStrings.Partial.self,
    count: 30_000
  ) { ($0.values?.count, [$0.values?.first, $0.values?.last]) }
  addSeparatorRows(
    "literals",
    SeparatorShapes.literals,
    as: SeparatorLiterals.Partial.self,
    count: 60_000
  ) { ($0.values?.count, [$0.values?.first, $0.values?.last]) }
  addSeparatorRows(
    "number pairs",
    SeparatorShapes.numberPairs,
    as: SeparatorPairs.Partial.self,
    count: 15_000
  ) { ($0.values?.count, [$0.values?.last?.first, $0.values?.last?.last]) }
  addSeparatorRows(
    "records",
    SeparatorShapes.records,
    as: SeparatorRecords.Partial.self,
    count: 3_000
  ) { ($0.rows?.count, [$0.rows?.last?.name, $0.rows?.last?.parent, $0.rows?.last?.tags?.last]) }
}
