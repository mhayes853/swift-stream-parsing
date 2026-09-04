import Foundation

// Builds `Web/generated/` from the two places evidence is actually written: `NEW_ARCHITECTURE.md`
// and the source comments. Run through `./Web/generate`.

let arguments = CommandLine.arguments
let root = arguments.count > 1 ? arguments[1] : FileManager.default.currentDirectoryPath
let only = arguments.count > 2 ? arguments[2] : "all"

func path(_ components: String...) -> String {
  ([root] + components).joined(separator: "/")
}

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("error: \(message)\n".utf8))
  exit(1)
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
let timestamp = ISO8601DateFormatter().string(from: Date())

try? FileManager.default.createDirectory(
  atPath: path("Web", "generated"), withIntermediateDirectories: true
)

// MARK: - Content

if only == "all" || only == "content" {
  let docPath = path("NEW_ARCHITECTURE.md")
  guard let docText = try? String(contentsOfFile: docPath, encoding: .utf8) else {
    fail("cannot read \(docPath)")
  }
  let (doc, docWarnings) = DocumentExtractor(path: "NEW_ARCHITECTURE.md", text: docText).extract()

  let swift = try SourceExtractor(roots: [
    path("Sources", "StreamParsingCore"),
    path("Sources", "StreamParsing")
  ]).extract()

  var sources = swift.decls
  let cDecls = try CHeaderExtractor(
    path: path("Sources", "StreamParsingShims", "include", "StreamParsingShims.h")
  ).extract()
  for (key, value) in cDecls { sources[key, default: []].append(contentsOf: value) }

  // Paths are stored relative to the repository root so the bundle does not embed a machine's
  // checkout location and stays byte-identical across worktrees.
  for key in sources.keys {
    sources[key] = sources[key]!.map { decl in
      var copy = decl
      copy.file = decl.file.replacingOccurrences(of: root + "/", with: "")
      return copy
    }
  }

  var verdictCounts: [String: Int] = [:]
  for section in doc.sections { verdictCounts[section.verdict, default: 0] += 1 }

  let bundle = ContentBundle(
    generatedAt: timestamp,
    doc: doc,
    sources: sources,
    stats: ContentBundle.Stats(
      sectionCount: doc.sections.count,
      tableCount: doc.sections.reduce(0) { $0 + $1.tables.count },
      codeBlockCount: doc.sections.reduce(0) { $0 + $1.codeBlocks.count },
      declCount: sources.values.reduce(0) { $0 + $1.count },
      fileCount: swift.fileCount + 1,
      verdictCounts: verdictCounts
    )
  )

  // Reference validation, before anything is written: a dangling slug or a renamed symbol is a
  // build failure, not a broken link discovered in the browser.
  let pipelinePath = path("Web", "content", "pipeline.json")
  if let data = FileManager.default.contents(atPath: pipelinePath) {
    let pipeline: Pipeline
    do {
      pipeline = try JSONDecoder().decode(Pipeline.self, from: data)
    } catch {
      fail("pipeline.json is not valid: \(error)")
    }
    let asmSymbols = Set(
      ((try? FileManager.default.contentsOfDirectory(atPath: path("Web", "generated", "asm"))) ?? [])
        .filter { $0.hasSuffix(".txt") }
        .map { String($0.dropLast(4)) }
    )
    let report = ReferenceReport.validate(
      pipeline, sections: doc.sections, sources: sources, asmSymbols: asmSymbols
    )
    for warning in docWarnings + report.warnings { print("warning: \(warning)") }
    if !report.errors.isEmpty {
      for e in report.errors { FileHandle.standardError.write(Data("error: \(e)\n".utf8)) }
      fail("\(report.errors.count) dangling reference(s) in pipeline.json")
    }
    let stepCount = pipeline.nodes.reduce(0) { $0 + $1.steps.count }
    print("pipeline: \(pipeline.nodes.count) nodes across \(pipeline.stages.count) stages, all references resolve")
    print("steps: \(stepCount) algorithm steps across \(pipeline.nodes.count) charts, every graph reachable and terminating")
  } else {
    for warning in docWarnings { print("warning: \(warning)") }
    print("note: no pipeline.json yet; skipping reference validation")
  }

  // Split on write. The declaration bodies are ~80% of the bytes and are only needed once a
  // detail panel's Source tab is opened, so the walkthrough does not wait on them.
  try encoder.encode(SourceBundle(generatedAt: timestamp, sources: bundle.sources))
    .write(to: URL(fileURLWithPath: path("Web", "generated", "sources.json")))
  var docOnly = bundle
  docOnly.sources = [:]
  try encoder.encode(docOnly)
    .write(to: URL(fileURLWithPath: path("Web", "generated", "content.json")))
  print(
    """
    content.json: \(bundle.stats.sectionCount) sections, \(bundle.stats.tableCount) tables, \
    \(bundle.stats.declCount) declarations from \(bundle.stats.fileCount) files
      verdicts: \(verdictCounts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
    """
  )
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

  let traces = TraceBundle(
    generatedAt: timestamp,
    arch: arch,
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
        """
    ),
    containers: try ParserTraces.containers(
      sample: #"{"id":4,"tags":["a",{"k":[true]}],"ok":null}"#
    ),
    number: KernelTraces.numbers(["582", "12345678", "7", "-3.1415", "1e10", "99999999999"]),
    whitespaceTable: KernelTraces.whitespaceTable(),
    numberTable: KernelTraces.numberTable(),
    // Two, three and four byte sequences in one block, so all three lookups have something to say
    // and the must-continue fact fires where no pair of adjacent bytes could see it.
    utf8: KernelTraces.utf8(sample: "aé\u{20AC}b\u{1F600}cd"),
    escapes: KernelTraces.escapes()
  )

  let out = path("Web", "generated", "traces.json")
  try encoder.encode(traces).write(to: URL(fileURLWithPath: out))

  let unverified =
    (traces.stringRun.verified ? 0 : 1) + traces.number.cases.filter { !$0.verified }.count
    + (traces.whitespaceTable.verified ? 0 : 1) + (traces.numberTable.verified ? 0 : 1)
    + (traces.utf8.verified ? 0 : 1) + (traces.escapes.verified ? 0 : 1)
    // The container animation points at the input while it steps, so its token offsets are held
    // to the same standard as a kernel mirror: the walk has to agree with the spans the parser
    // handed over, everywhere it handed one over.
    + (traces.containers.offsetsVerified ? 0 : 1)
  print(
    """
    traces.json: \(arch); stringRun \(traces.stringRun.blocks.count) blocks, \
    whitespace \(traces.whitespace.calls.count) calls, \
    containers \(traces.containers.steps.count) steps (depth ceiling \(traces.containers.maximumDepth)), \
    numbers \(traces.number.cases.count) cases, \
    tables \(traces.whitespaceTable.tables.count + traces.numberTable.tables.count + traces.utf8.tables.count) \
    across whitespace/number/UTF-8, escapes \(traces.escapes.entries.count) entries
    """
  )
  if unverified > 0 {
    fail("\(unverified) trace(s) disagree with the shipped kernel — a mirror has drifted")
  }
  print("traces: every mirrored kernel agrees with the shipped function")
}
