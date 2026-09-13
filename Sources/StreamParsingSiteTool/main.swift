import Foundation

// Builds `Web/generated/` from the two places evidence is actually written: `NEW_ARCHITECTURE.md`
// and the source comments. Run through `./Web/generate`.

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("error: \(message)\n".utf8))
  exit(1)
}

let arguments = CommandLine.arguments
let rawRoot = arguments.count > 1 ? arguments[1] : FileManager.default.currentDirectoryPath
let root = URL(fileURLWithPath: rawRoot).standardizedFileURL.path
let only = arguments.count > 2 ? arguments[2] : "all"
guard ["all", "content", "traces"].contains(only) else {
  fail("unknown mode '\(only)'; expected all, content, or traces")
}

func path(_ components: String...) -> String { ([root] + components).joined(separator: "/") }

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
let timestamp = ISO8601DateFormatter().string(from: Date())

try FileManager.default.createDirectory(
  atPath: path("Web", "generated"), withIntermediateDirectories: true)

// MARK: - Content

if only == "all" || only == "content" {
  let docPath = path("NEW_ARCHITECTURE.md")
  guard let docText = try? String(contentsOfFile: docPath, encoding: .utf8) else {
    fail("cannot read \(docPath)")
  }
  var (doc, docWarnings) = DocumentExtractor(path: "NEW_ARCHITECTURE.md", text: docText).extract()

  // Dates come from the document's own history rather than from anything written in it, so an
  // experiment is dated by the commit that recorded it and nobody has to maintain a date line.
  let history = HistoryExtractor(root: root, file: "NEW_ARCHITECTURE.md").extract()
  docWarnings += history.warnings
  for index in doc.sections.indices {
    doc.sections[index].history = history.history[doc.sections[index].path]
  }
  let dated = doc.sections.filter { $0.history != nil }.count
  if dated < doc.sections.count && !history.history.isEmpty {
    docWarnings.append("\(doc.sections.count - dated) section(s) carry no date")
  }

  let swift = try SourceExtractor(roots: [
    path("Sources", "StreamParsingCore"), path("Sources", "StreamParsing")
  ]).extract()

  var sources = swift.decls
  sources.merge(
    try CHeaderExtractor(
      path: path("Sources", "StreamParsingShims", "include", "StreamParsingShims.h")
    ).extract(), uniquingKeysWith: +)

  // Paths are stored relative to the repository root so the bundle does not embed a machine's
  // checkout location and stays byte-identical across worktrees.
  let rootPrefix = root + "/"
  for (key, declarations) in sources {
    sources[key] = declarations.map { decl in
      var copy = decl
      if copy.file.hasPrefix(rootPrefix) { copy.file.removeFirst(rootPrefix.count) }
      return copy
    }
  }

  let verdictCounts = Dictionary(grouping: doc.sections, by: \.verdict).mapValues(\.count)

  let bundle = ContentBundle(
    generatedAt: timestamp, doc: doc, sources: sources,
    stats: ContentBundle.Stats(
      sectionCount: doc.sections.count, tableCount: doc.sections.reduce(0) { $0 + $1.tables.count },
      codeBlockCount: doc.sections.reduce(0) { $0 + $1.codeBlocks.count },
      declCount: sources.values.reduce(0) { $0 + $1.count }, fileCount: swift.fileCount + 1,
      verdictCounts: verdictCounts, datedSections: dated,
      firstRecorded: doc.sections.compactMap(\.history?.recorded).min(),
      lastRecorded: doc.sections.compactMap(\.history?.revised).max()))

  // Reference validation, before anything is written: a dangling slug or a renamed symbol is a
  // build failure, not a broken link discovered in the browser.
  let pipelinePath = path("Web", "content", "pipeline.json")
  if let data = FileManager.default.contents(atPath: pipelinePath) {
    let pipeline: Pipeline
    do { pipeline = try JSONDecoder().decode(Pipeline.self, from: data) } catch {
      fail("pipeline.json is not valid: \(error)")
    }
    let asmSymbols = Set(
      ((try? FileManager.default.contentsOfDirectory(atPath: path("Web", "generated", "asm"))) ?? [])
        .filter { $0.hasSuffix(".txt") }.map { String($0.dropLast(4)) })
    let report = ReferenceReport.validate(
      pipeline, sections: doc.sections, sources: sources, asmSymbols: asmSymbols)
    for warning in docWarnings + report.warnings { print("warning: \(warning)") }
    if !report.errors.isEmpty {
      for e in report.errors { FileHandle.standardError.write(Data("error: \(e)\n".utf8)) }
      fail("\(report.errors.count) dangling reference(s) in pipeline.json")
    }
    let stepCount = pipeline.nodes.reduce(0) { $0 + $1.steps.count }
    print(
      "pipeline: \(pipeline.nodes.count) nodes across \(pipeline.stages.count) stages, all references resolve"
    )
    print(
      "steps: \(stepCount) algorithm steps across \(pipeline.nodes.count) charts, every graph reachable and terminating"
    )
  } else {
    for warning in docWarnings { print("warning: \(warning)") }
    print("note: no pipeline.json yet; skipping reference validation")
  }

  // Split on write. The declaration bodies are ~80% of the bytes and are only needed once a
  // detail panel's Source tab is opened, so the walkthrough does not wait on them.
  try encoder.encode(SourceBundle(generatedAt: timestamp, sources: bundle.sources)).write(
    to: URL(fileURLWithPath: path("Web", "generated", "sources.json")))
  var docOnly = bundle
  docOnly.sources = [:]
  try encoder.encode(docOnly).write(
    to: URL(fileURLWithPath: path("Web", "generated", "content.json")))
  print(
    """
    content.json: \(bundle.stats.sectionCount) sections, \(bundle.stats.tableCount) tables, \
    \(bundle.stats.declCount) declarations from \(bundle.stats.fileCount) files
      verdicts: \(verdictCounts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
      dated: \(dated)/\(doc.sections.count) sections over \(history.revisions.count) revisions of the log, \
    \((bundle.stats.firstRecorded ?? "?").prefix(10)) to \((bundle.stats.lastRecorded ?? "?").prefix(10))
    """)
}

// MARK: - Traces

if only == "all" || only == "traces" {
  #if arch(arm64)
    let arch = "arm64"
  #elseif arch(x86_64)
    let arch = "x86_64"
  #else
    let arch = "portable"
  #endif

  // The sink boundary onwards. Built ahead of the bundle because the skip walk takes its subtree
  // from the disposition run rather than being told where it is, and because a single literal of
  // this many recorders is more than the type checker will sit through.
  let dispositions = try SinkTraces.dispositions(
    sample: #"{"id":7,"name":"Ada","extra":[12345,-6.5e2,{"k":"a\"b"}],"score":1.5}"#,
    skipping: "extra")
  let skipRun = try SinkTraces.skipRun(for: dispositions)
  let (frames, views) = try RoutingTraces.frames(
    sample:
      #"{"id":7,"active":true,"name":"Ada","address":{"city":"Cairo","zip":11511},"score":1.5}"#)
  // Chunk sizes chosen to cross each boundary once: the inline buffer, then the first sealed
  // block, then the doubled one. What the boundaries *are* comes off the type.
  let filler = "streaming bytes arrive a chunk at a time, and the string grows to hold them; "
  let streamString = StorageTraces.streamString(
    chunks: [24, 24, 24, 200, 300, 400, 500, 200].map { count in
      String(String(repeating: filler, count: count / filler.count + 1).prefix(count))
    })
  let collections = StorageTraces.collections(
    elements: 36,
    keys: [
      "id", "text", "user", "lang", "source", "truncated", "favorited", "retweeted", "entities",
      "metadata"
    ])

  let traces = TraceBundle(
    generatedAt: timestamp, arch: arch,
    // Long enough to fill two vector blocks before the escape, so the animation shows a clean
    // block, then the block that terminates.
    stringRun: KernelTraces.stringRun(sample: #"a streaming JSON value with an \"escape\" in it"#),
    whitespace: KernelTraces.whitespace(
      sample: """
        {
          "id": 4,
          "tags": [1, 2],
          "compact":{"a":1}
        }
        """),
    containers: try ParserTraces.containers(
      sample: #"{"id":4,"tags":["a",{"k":[true]}],"ok":null}"#),
    structuralBlocks: try BlockTraces.structural(),
    number: KernelTraces.numbers(["582", "12345678", "7", "-3.1415", "1e10", "99999999999"]),
    whitespaceTable: KernelTraces.whitespaceTable(), numberTable: KernelTraces.numberTable(),
    // Two, three and four byte sequences in one block, so all three lookups have something to say
    // and the must-continue fact fires where no pair of adjacent bytes could see it.
    utf8: KernelTraces.utf8(sample: "aé\u{20AC}b\u{1F600}cd"), escapes: KernelTraces.escapes(),
    // A document with a container, both string forms, both literals and a number, so the call log
    // shows every group the protocol declares.
    sinkCalls: try SinkTraces.sinkCalls(
      sample: #"{"id":7,"tag":"a\"b","ok":true,"none":null,"xs":[1,2]}"#),
    dispositions: dispositions, skipRun: skipRun, skipBlocks: try BlockTraces.skip(),
    fieldMatch: RoutingTraces.fieldMatch(),
    frames: frames, streamString: streamString, collections: collections, views: views)

  let out = path("Web", "generated", "traces.json")
  try encoder.encode(traces).write(to: URL(fileURLWithPath: out))

  let unverified =
    [
      traces.stringRun.verified, traces.whitespaceTable.verified, traces.numberTable.verified,
      traces.utf8.verified, traces.escapes.verified, traces.containers.offsetsVerified,
      traces.structuralBlocks.verified,
      traces.sinkCalls.verified, traces.dispositions.verified, traces.skipRun.verified,
      traces.skipBlocks.verified,
      traces.fieldMatch.verified, traces.frames.verified, traces.streamString.verified,
      traces.collections.verified, traces.views.verified
    ].filter { !$0 }.count + traces.number.cases.filter { !$0.verified }.count
  print(
    """
    traces.json: \(arch); stringRun \(traces.stringRun.blocks.count) blocks, \
    whitespace \(traces.whitespace.calls.count) calls, \
    containers \(traces.containers.steps.count) steps (depth ceiling \(traces.containers.maximumDepth)), \
    structural blocks \(traces.structuralBlocks.cases.reduce(0) { $0 + $1.blocks.count }) across \
    \(traces.structuralBlocks.cases.count) cases, \
    numbers \(traces.number.cases.count) cases, \
    tables \(traces.whitespaceTable.tables.count + traces.numberTable.tables.count + traces.utf8.tables.count) \
    across whitespace/number/UTF-8, escapes \(traces.escapes.entries.count) entries
    """)
  print(
    """
    sink boundary: \(traces.sinkCalls.calls.count) sink calls, \
    dispositions \(traces.dispositions.streamed.count) streamed vs \(traces.dispositions.skipped.count) skipped, \
    skip walk \(traces.skipRun.steps.count) steps, \
    skip blocks \(traces.skipBlocks.blocks.count), \
    field match \(traces.fieldMatch.tables.count) tables \
    (\(traces.fieldMatch.tables.map { "\($0.entries.count) \($0.strategy)" }.joined(separator: ", "))), \
    frames \(traces.frames.steps.count) steps over \(traces.frames.schemas.count) schemas, \
    StreamString \(traces.streamString.steps.count) appends to \(traces.streamString.steps.last?.utf8Count ?? 0) bytes, \
    collections \(traces.collections.array.steps.count) array steps and \(traces.collections.dictionary.steps.count) keys
    """)
  if unverified > 0 {
    fail("\(unverified) trace(s) disagree with the shipped kernel — a mirror has drifted")
  }
  print("traces: every mirrored kernel agrees with the shipped function")
}
