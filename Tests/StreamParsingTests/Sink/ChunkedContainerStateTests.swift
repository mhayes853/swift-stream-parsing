import CustomDump
import Testing

import StreamParsing
import StreamParsingCore

@StreamParseable
struct StaleDepthModel: Equatable {
  var a: [String] = []
  var s: String = ""
  var t: Int = 0
}

@StreamParseable
struct StaleDepthInner: Equatable {
  var b: String = ""
}

@StreamParseable
struct StaleDepthNested: Equatable {
  var o: StaleDepthInner = StaleDepthInner()
  var l: [String] = []
  var n: [[String]] = []
  var m: [String: String] = [:]
  var e: String = ""
}

// The container stack across a chunk boundary.
//
// The structural run holds `depth` and `containers` in registers and writes them back only when
// it returns, so any callee it makes that reads the *fields* sees them as they were when the run
// was entered. `consumeEscapedStringInRun` was such a callee: it finished a string value with an
// escape in it and then fused the comma after it (`fuseAfterValue`), which asked the fields
// whether the enclosing container was an object or an array. A bulk parse enters the run at depth
// zero, where the fusion declines, so it never showed; a chunk that began inside an array the run
// then closed fused `,"t"` after `"x\ny"` as an array element, read the key as a string value and
// failed on the colon -- `twitter` at 4096-byte chunks, 13,921 bytes in. It no longer fuses from
// inside the run (see its comment).
//
// The sweep below is the property that would have caught it: the document's meaning -- the tree
// it builds, or the error it fails with and the byte it names -- must not depend on how the
// document is cut. Every chunk size, and every two-way split, against the whole-document parse.
@Suite
struct `Chunked container state tests` {
  // MARK: - Driving

  enum Outcome: Equatable {
    case value(TreeSink.Node?)
    case failure(String, Int)
  }

  // `ends` are the exclusive end offsets of the pieces, the last one being the document's length.
  // `nil` feeds the byte-fed entry point, which is a different dispatcher from a one-byte chunk.
  //
  // One sink is enough: every sink takes an escaped string value through
  // `coalescedEscapedStringTail`, the route that ends in `fuseAfterValue`. (This file used to run
  // a second, coalescing `TreeSink` alongside the zero-copy one, when coalescing was a per-sink
  // opt-in and the two routes were different code.)
  static func run(_ bytes: [UInt8], ends: [Int]?) -> Outcome {
    var sink = TreeSink()
    var parser = JSONParser()
    do {
      if let ends {
        try bytes.withUnsafeBufferPointer { input throws(JSONParsingError) in
          var start = 0
          for end in ends where end > start {
            try parser.parse(UnsafeBufferPointer(rebasing: input[start..<end]), into: &sink)
            start = end
          }
        }
      } else {
        for byte in bytes { try parser.parse(byte: byte, into: &sink) }
      }
      try parser.finish(into: &sink)
    } catch {
      return .failure(String(describing: error.reason), error.byteOffset)
    }
    return .value(sink.value)
  }

  static func ends(chunk: Int, count: Int) -> [Int] {
    Array(stride(from: chunk, to: count, by: chunk)) + [count]
  }

  // `parsePartial`, cut at `ends` rather than at a fixed chunk size.
  static func parseTyped<Root: StreamParseableRoot>(
    _ json: String, into value: inout Root, ends: [Int]
  ) throws {
    try withUnsafeMutablePointer(to: &value) { pointer in
      var parser = JSONParser()
      var sink = PartialSink(root: pointer)
      try Array(json.utf8).withUnsafeBufferPointer { input in
        var start = 0
        for end in ends where end > start {
          try parser.parse(UnsafeBufferPointer(rebasing: input[start..<end]), into: &sink)
          start = end
        }
      }
      try parser.finish(into: &sink)
    }
  }

  // Every chunk size and every two-way split against the whole parse.
  static func expectChunkIndependence(
    _ bytes: [UInt8], _ label: String, sourceLocation: SourceLocation = #_sourceLocation
  ) {
    let expected = Self.run(bytes, ends: [bytes.count])
    var cuts: [(String, [Int]?)] = [("byte fed", nil)]
    for chunk in 1...max(bytes.count, 1) {
      cuts.append(("chunk \(chunk)", Self.ends(chunk: chunk, count: bytes.count)))
    }
    for split in 1..<max(bytes.count, 1) {
      cuts.append(("split \(split)", [split, bytes.count]))
    }
    for (name, ends) in cuts {
      let actual = Self.run(bytes, ends: ends)
      guard actual == expected else {
        Issue.record(
          """
          \(label) \(name) disagreed with the whole parse.
          \(diff(expected, actual) ?? "")
          """,
          sourceLocation: sourceLocation
        )
        return
      }
    }
  }

  // MARK: - The reported case

  @Test
  func `An escaped value after a closed array fuses the key that follows as a key`() {
    let bytes = Array(#"{"a":[true,"b"],"s":"x\ny","t":1}"#.utf8)
    let expected = TreeSink.Node.object([
      ("a", .array([.boolean(true), .string("b")])),
      ("s", .string("x\ny")),
      ("t", .number("1")),
    ])
    expectNoDifference(Self.run(bytes, ends: [bytes.count]), .value(expected))
    expectNoDifference(Self.run(bytes, ends: [14, bytes.count]), .value(expected))
    expectNoDifference(
      Self.run(bytes, ends: Self.ends(chunk: 14, count: bytes.count)), .value(expected)
    )
  }

  // The same shape with the array's first element a string, so it has a typed home: `"qq"` is as
  // long as `true`, so the cut still lands on the closing quote of `"b"`.
  @Test(arguments: [[33], [14, 33], [7, 14, 21, 28, 33]])
  func `The reported case through the typed layer`(ends: [Int]) throws {
    var model = StaleDepthModel.Partial()
    try Self.parseTyped(#"{"a":["qq","b"],"s":"x\ny","t":1}"#, into: &model, ends: ends)
    expectNoDifference(model.a, ["qq", "b"])
    expectNoDifference(model.s, "x\ny")
    expectNoDifference(model.t, 1)
  }

  // The mirror image: the run was entered inside an *object* and the escaped value is an array
  // element, so the stale answer read the next element as a key. The cut is inside `"c"`.
  @Test(arguments: [[42], [12, 42]])
  func `An escaped element after a closed object keeps the next element a value`(
    ends: [Int]
  ) throws {
    var model = StaleDepthNested.Partial()
    try Self.parseTyped(#"{"o":{"b":"c"},"l":["x\ny","z"],"e":"end"}"#, into: &model, ends: ends)
    expectNoDifference(model.o?.b, "c")
    expectNoDifference(model.l, ["x\ny", "z"])
    expectNoDifference(model.e, "end")
  }

  // The stale answer also *accepted* a document the whole parse rejects: an array's number
  // fusion applied after a comma inside an object.
  @Test
  func `A number where a key belongs is rejected at every cut`() {
    let bytes = Array(#"{"a":["q","b"],"s":"x\ny",1}"#.utf8)
    let expected = Self.run(bytes, ends: [bytes.count])
    guard case .failure = expected else {
      Issue.record("The whole parse accepted \(String(decoding: bytes, as: UTF8.self))")
      return
    }
    Self.expectChunkIndependence(bytes, "number for a key")
  }

  // MARK: - The sweep

  // Nested containers of both kinds on both sides of every escaped string, escaped keys, and
  // enough whitespace outside the strings that a chunk of 64 or more reaches the block walk
  // (JSONParserBlocks.swift), which has two call sites of its own into the escaped-string path.
  static let documents: [(String, String)] = [
    ("reported", #"{"a":[true,"b"],"s":"x\ny","t":1}"#),
    ("object then array", #"{"o":{"b":"c"},"l":["x\ny","z",1],"e":"end"}"#),
    ("array then number", #"[["a"],"x\ny",1,{"k":"v\tw","n":2},[3,"é",4]]"#),
    ("escaped keys", #"{"a\nb":[1,{"c\"d":"e\\f"}],"g":{"hA":["i\/j",2]},"k":3}"#),
    (
      "deep alternation",
      #"{"a":[{"b":[{"c":"1\n","d":["2\t",{"e":"3\r"}]},"4\b"],"f":"5\f"},"6\""],"g":"7"}"#
    ),
    (
      "pretty",
      """
      {
        "list" : [ "x\\ny" , { "in" : "a\\tb" , "arr" : [ 1 , "c\\"d" , 2 ] } , "e\\\\f" ] ,
        "obj" : { "k" : [ "g\\u0041h" ] , "k2" : "i\\/j" , "n" : 3 } ,
        "tail" : "z\\nz"
      }
      """
    ),
    (
      "long escaped values",
      "{\"l\":[\"" + String(repeating: "abc\\n", count: 20) + "\",{\"k\":\""
        + String(repeating: "d\\te", count: 20) + "\"}],\"m\":\""
        + String(repeating: "\\u00e9x", count: 12) + "\",\"n\":[1,2]}"
    ),
    ("surrogate pairs", #"[{"a":"😀"},["😀",1],{"b":["𝄞"],"c":2}]"#),
    ("number for a key", #"{"a":["q","b"],"s":"x\ny",1}"#),
    ("string for an element", #"{"o":{"b":"c"},"l":["x\ny","z"}"#),
    ("close mismatch after escape", #"{"a":[1,"b"],"s":"x\ny"]"#),
  ]

  @Test(arguments: Self.documents.indices)
  func `A document means the same at every chunk size and split`(index: Int) {
    let (name, text) = Self.documents[index]
    Self.expectChunkIndependence(Array(text.utf8), name)
  }

  // The typed layer over the valid rows of the same shapes, through `PartialSink`.
  @Test(
    arguments: [
      #"{"o":{"b":"c\nd"},"l":["x\ny","z"],"n":[["a\tb"],["c\"",""]],"m":{"k":"v\"w","j":"u"},"e":"end\\"}"#,
      #"{"n":[["a"],["b\n"]],"o":{"b":"c"},"m":{"k":"v\tw","j":"u"},"l":["x\ny","zA"],"e":"f"}"#,
      """
      {
        "l" : [ "x\\ny" , "z" ] ,
        "o" : { "b" : "c\\\\d" } ,
        "n" : [ [ "a" , "b\\"c" ] , [ ] , [ "d\\te" ] ] ,
        "m" : { "k" : "\\u00e9\\n" , "j" : "u" } ,
        "e" : "end"
      }
      """,
    ]
  )
  func `The typed layer builds the same value at every chunk size and split`(json: String) throws {
    let count = json.utf8.count
    var whole = StaleDepthNested.Partial()
    try parsePartial(json, into: &whole)
    #expect(diff(whole, StaleDepthNested.Partial()) != nil, "the whole parse built nothing")
    var cuts = (1..<count).map { Self.ends(chunk: $0, count: count) }
    cuts += (1..<count).map { [$0, count] }
    for ends in cuts {
      var chunked = StaleDepthNested.Partial()
      do {
        try Self.parseTyped(json, into: &chunked, ends: ends)
      } catch {
        Issue.record("\(ends.prefix(3)) threw \(error)")
        return
      }
      if let difference = diff(whole, chunked) {
        Issue.record("\(ends.prefix(3)) disagreed with the whole parse.\n\(difference)")
        return
      }
    }
  }

  // MARK: - Real documents

  // A handful of chunk sizes per corpus against its bulk parse: 7 cuts every token, 64 is the
  // block walk's own size, 4096 is the chunking the reported failure was found at.
  @Test(
    arguments: ["twitter", "twitterescaped", "citm_catalog", "github_events", "gsoc-2018", "llm_message"]
  )
  func `Benchmark corpora mean the same at a handful of chunk sizes`(name: String) throws {
    let bytes = try #require(streamBenchmarkCorpus(name))
    let expected = Self.run(bytes, ends: [bytes.count])
    guard case .value = expected else {
      Issue.record("\(name) failed its bulk parse: \(expected)")
      return
    }
    for chunk in [7, 64, 4096] {
      let actual = Self.run(bytes, ends: Self.ends(chunk: chunk, count: bytes.count))
      if actual != expected {
        if case .failure(let reason, let offset) = actual {
          Issue.record("\(name) chunk \(chunk): \(reason) at \(offset)")
        } else {
          Issue.record("\(name) chunk \(chunk) built a different tree")
        }
      }
    }
  }
}
