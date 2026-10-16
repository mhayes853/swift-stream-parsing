import Foundation
import SwiftParser
import SwiftSyntax

// `Web/generated/library.json`: the material behind the Tests and Macros views.
//
// Both views are about the library rather than the parse path, and both follow the same rule the
// rest of the explorer does: the prose lives where it is maintained -- a test's own leading comment,
// the macro support guide, the README -- and the two hand-authored files in `Web/content/` only
// *select* and *order* it. What a test asserts is read out of the test; what a macro expands to is
// read out of the snapshot test that pins it, so a changed expansion changes the site in the same
// commit that changes the snapshot.

struct LibraryBundle: Encodable {
  var generatedAt: String
  var tests: TestIndex
  /// Referenced tests, suites and helpers, with their code and leading comments. Every test in the
  /// package is in `tests.cases`; only the ones a view cites carry their bodies, because the index
  /// is what the counts need and a body is only read when a card is opened.
  var decls: [String: SourceDecl]
  /// `assertStreamParsingMacro` pairs lifted out of the macro tests, keyed as the test is.
  var snapshots: [String: MacroSnapshot]
  /// Markdown documents other than the log, sliced by heading exactly as the log is.
  var guides: [String: DocBundle]
}

struct TestIndex: Encodable {
  var targets: [Target]
  var cases: [TestCase]

  struct Target: Encodable {
    var name: String
    var path: String
    var files: Int
    var tests: Int
    /// Declarations with `arguments:`, each of which runs once per argument.
    var parameterized: Int
  }
}

struct TestCase: Encodable {
  /// `File.swift:name`, the name without its backticks, which is how the content files cite it.
  var key: String
  /// The display name: the `@Test("…")` string when there is one, the raw identifier otherwise.
  var name: String
  var file: String
  var target: String
  var suite: String?
  var line: Int
  var parameterized: Bool
}

/// One `assertStreamParsingMacro` call: the source the macro was applied to and what it must
/// expand to (or the diagnostics it must emit). These are asserted by `swift test`, so the site
/// shows an expansion the build has already checked rather than one written out by hand.
struct MacroSnapshot: Encodable {
  var input: String
  var expansion: String?
  var diagnostics: String?
}

// MARK: - Extraction

struct TestExtractor {
  var root: String

  /// Where tests and the fixtures that stand in for them live. The smoke packages are not `@Test`
  /// suites, but they are how "it builds under Embedded Swift" and "a downstream macro links the
  /// support product" are checked, so they are citable the same way.
  var roots: [(target: String, path: String)] {
    let tests = (try? FileManager.default.contentsOfDirectory(atPath: "\(self.root)/Tests")) ?? []
    return tests.sorted().map { ($0, "Tests/\($0)") } + [
      ("SmokeTests", "SmokeTests/Sources"),
      ("SmokeTests/MacroSupport", "SmokeTests/MacroSupport/Sources")
    ]
  }

  func extract() throws -> (index: TestIndex, decls: [String: [SourceDecl]], snapshots: [String: MacroSnapshot]) {
    var targets: [TestIndex.Target] = []
    var cases: [TestCase] = []
    var decls: [String: [SourceDecl]] = [:]
    var snapshots: [String: MacroSnapshot] = [:]

    for (target, relative) in self.roots {
      let absolute = "\(self.root)/\(relative)"
      let found = try SourceExtractor(roots: [absolute]).extract()
      var testCount = 0
      var parameterized = 0
      for (rawKey, list) in found.decls {
        let key = Self.citationKey(rawKey)
        for var decl in list {
          if decl.file.hasPrefix(self.root + "/") { decl.file.removeFirst(self.root.count + 1) }
          decls[key, default: []].append(decl)
          guard let test = Self.testCase(decl, key: key, target: target) else { continue }
          cases.append(test)
          testCount += 1
          if test.parameterized { parameterized += 1 }
          if let snapshot = Self.snapshot(in: decl.code) { snapshots[key] = snapshot }
        }
      }
      targets.append(
        TestIndex.Target(
          name: target, path: relative, files: found.fileCount, tests: testCount,
          parameterized: parameterized))
    }
    cases.sort { ($0.file, $0.line) < ($1.file, $1.line) }
    return (TestIndex(targets: targets, cases: cases), decls, snapshots)
  }

  /// Raw identifiers are how most suites here name their tests (`` func `Basic`() ``), and the
  /// backticks are syntax rather than name.
  static func citationKey(_ key: String) -> String { key.replacingOccurrences(of: "`", with: "") }

  static func testCase(_ decl: SourceDecl, key: String, target: String) -> TestCase? {
    guard decl.kind == "func", let attribute = decl.attributes.first(where: { $0.hasPrefix("@Test") })
    else { return nil }
    let bare = decl.symbol.replacingOccurrences(of: "`", with: "")
    let scope = decl.qualifiedName.split(separator: ".").dropLast().last.map(String.init)
    return TestCase(
      key: key, name: Self.displayName(attribute) ?? bare, file: decl.file, target: target,
      suite: scope?.replacingOccurrences(of: "`", with: ""), line: decl.startLine,
      parameterized: attribute.contains("arguments:"))
  }

  /// `@Test("Reads a thing")` names the test by its first argument when that is a string literal.
  static func displayName(_ attribute: String) -> String? {
    let parsed = Parser.parse(source: "\(attribute) func f() {}")
    guard let function = parsed.statements.first?.item.as(FunctionDeclSyntax.self),
      let test = function.attributes.first?.as(AttributeSyntax.self),
      case .argumentList(let arguments) = test.arguments,
      let first = arguments.first, first.label == nil,
      let literal = first.expression.as(StringLiteralExprSyntax.self)
    else { return nil }
    return literal.representedLiteralValue
  }

  /// The source and expected expansion of the first macro assertion in a test body, when it has
  /// one. Only literal strings are read: an interpolated expectation is not a fixed expansion.
  static func snapshot(in code: String) -> MacroSnapshot? {
    guard code.contains("assertStreamParsingMacro") || code.contains("assertMacro") else {
      return nil
    }
    final class Finder: SyntaxVisitor {
      var found: MacroSnapshot?
      override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard self.found == nil,
          let name = node.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text,
          name == "assertStreamParsingMacro" || name == "assertMacro",
          let input = node.trailingClosure.flatMap(Finder.literal)
        else { return .visitChildren }
        var snapshot = MacroSnapshot(input: input)
        for closure in node.additionalTrailingClosures {
          switch closure.label.text {
          case "expansion": snapshot.expansion = Finder.literal(closure.closure)
          case "diagnostics": snapshot.diagnostics = Finder.literal(closure.closure)
          default: break
          }
        }
        self.found = snapshot
        return .skipChildren
      }

      static func literal(_ closure: ClosureExprSyntax) -> String? {
        closure.statements.first?.item.as(StringLiteralExprSyntax.self)?.representedLiteralValue
      }
    }
    let finder = Finder(viewMode: .sourceAccurate)
    finder.walk(Parser.parse(source: code))
    return finder.found
  }
}

// MARK: - Content

/// `Web/content/tests.json`: which tests carry the library's guarantees, in what order, and what
/// each guarantee is. The *how* of every test stays in the test's own comment.
struct TestsContent: Decodable {
  var version: Int
  var lede: [String]
  var techniques: [Technique]
  var guarantees: [Guarantee]

  /// A way the suites build an oracle -- every split, a differential against the standard library,
  /// the reference path switched back on. Named once, cited by every guarantee that uses it.
  struct Technique: Decodable {
    var id: String
    var title: String
    var detail: String
    /// The helpers that implement it, cited like tests.
    var refs: [String]
  }

  struct Guarantee: Decodable {
    var id: String
    var title: String
    /// What breaks, for a user of the library, if this stops holding.
    var why: [String]
    var technique: [String]
    /// Suites whose leading comments explain the guarantee in the words of whoever wrote the tests.
    var suites: [String]
    var tests: [String]
    /// The one test whose body is drawn on the card.
    var showcase: String
    /// Parse path nodes the guarantee protects, linked so a card opens the node.
    var node: [String]
    var viz: String?
  }
}

/// `Web/content/macros.json`: why the macro support library exists and how an expansion is put
/// together. The expansions themselves come from the snapshot tests.
struct MacrosContent: Decodable {
  var version: Int
  var lede: [String]
  var why: [Why]
  /// Drawn with the same chart as a parse path node's algorithm, and validated by the same code.
  var chart: Pipeline.Node
  var regions: [Region]
  var examples: [Example]

  struct Why: Decodable {
    var title: String
    var detail: [String]
    /// `guide:section-path`, resolved against `guides`.
    var guide: [String]
    var source: [String]
  }

  /// One kind of generated declaration. Which lines of an expansion belong to which region is
  /// decided by `Web/src/lib/macros.ts`, whose tests hold every region it emits to this list.
  struct Region: Decodable {
    var id: String
    var title: String
    var detail: String
    /// The chart step that emits it.
    var step: String
    /// The parse path node that consumes it at run time, when one does.
    var node: String?
  }

  struct Example: Decodable {
    var test: String
    var title: String
    var detail: String
  }
}

extension ReferenceReport {
  static let libraryVizKinds: Set<String> = ["chunkCuts"]

  /// The two library content files, held to the pipeline's standard: a citation that stops
  /// resolving -- a renamed test, a retitled guide section, a deleted generator function -- fails
  /// the build rather than leaving a card pointing at nothing.
  static func validateLibrary(
    tests: TestsContent, macros: MacrosContent, library: [String: [SourceDecl]],
    snapshots: [String: MacroSnapshot], guides: [String: DocBundle],
    sources: [String: [SourceDecl]], nodeIDs: Set<String>
  ) -> ReferenceReport {
    var report = ReferenceReport()
    let citable = Set(library.keys)
    let guidePaths = Set(
      guides.flatMap { id, doc in doc.sections.map { "\(id):\($0.path)" } })
    let sourceKeys = Set(sources.keys)

    func cite(_ key: String, at: String) {
      guard let found = library[key] else {
        report.errors.append(Self.referenceError(key, kind: "test or helper", at: at, in: citable))
        return
      }
      if found.count > 1 {
        report.warnings.append("\(at): '\(key)' names \(found.count) declarations; the first is shown")
      }
    }

    if tests.version != 1 { report.errors.append("tests.json: unsupported version \(tests.version)") }
    if macros.version != 1 { report.errors.append("macros.json: unsupported version \(macros.version)") }

    // Tests
    Self.reportDuplicates(tests.techniques.map(\.id), kind: "technique", into: &report)
    Self.reportDuplicates(tests.guarantees.map(\.id), kind: "guarantee", into: &report)
    let techniqueIDs = Set(tests.techniques.map(\.id))
    for technique in tests.techniques {
      let at = "tests.json technique '\(technique.id)'"
      if technique.refs.isEmpty { report.errors.append("\(at): cites no helper or test") }
      for ref in technique.refs { cite(ref, at: at) }
    }
    for guarantee in tests.guarantees {
      let at = "tests.json guarantee '\(guarantee.id)'"
      if guarantee.why.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
        report.errors.append("\(at): no 'why'")
      }
      if guarantee.tests.isEmpty { report.errors.append("\(at): cites no tests") }
      for id in guarantee.technique where !techniqueIDs.contains(id) {
        report.errors.append(Self.referenceError(id, kind: "technique", at: at, in: techniqueIDs))
      }
      for ref in guarantee.suites + guarantee.tests + [guarantee.showcase] { cite(ref, at: at) }
      for node in guarantee.node where !nodeIDs.contains(node) {
        report.errors.append(Self.referenceError(node, kind: "node", at: at, in: nodeIDs))
      }
      if let viz = guarantee.viz, !Self.libraryVizKinds.contains(viz) {
        report.errors.append("\(at): unknown viz '\(viz)'")
      }
    }

    // Macros
    for item in macros.why {
      let at = "macros.json why '\(item.title)'"
      for ref in item.guide where !guidePaths.contains(ref) {
        report.errors.append(Self.referenceError(ref, kind: "guide section", at: at, in: guidePaths))
      }
      for key in item.source where !sourceKeys.contains(key) {
        report.errors.append(Self.referenceError(key, kind: "source symbol", at: at, in: sourceKeys))
      }
      if item.guide.isEmpty && item.source.isEmpty {
        report.warnings.append("\(at): cites neither a guide section nor a declaration")
      }
    }
    let chart = macros.chart
    for key in chart.evidence.source where !sourceKeys.contains(key) {
      report.errors.append(
        Self.referenceError(key, kind: "source symbol", at: "macros.json chart", in: sourceKeys))
    }
    Self.validateSteps(chart, sourceKeys: sourceKeys, into: &report)
    let stepIDs = Set(chart.steps.map(\.id))
    Self.reportDuplicates(macros.regions.map(\.id), kind: "region", into: &report)
    for region in macros.regions {
      let at = "macros.json region '\(region.id)'"
      if !stepIDs.contains(region.step) {
        report.errors.append(Self.referenceError(region.step, kind: "chart step", at: at, in: stepIDs))
      }
      if let node = region.node, !nodeIDs.contains(node) {
        report.errors.append(Self.referenceError(node, kind: "node", at: at, in: nodeIDs))
      }
    }
    for example in macros.examples {
      let at = "macros.json example '\(example.title)'"
      cite(example.test, at: at)
      if library[example.test] != nil, snapshots[example.test]?.expansion == nil {
        report.errors.append("\(at): '\(example.test)' asserts no expansion to show")
      }
    }
    return report
  }

  /// Every key whose body a card draws. A macro example is drawn from its snapshot instead, so its
  /// test body -- the same text again, inside an assertion -- is not carried.
  static func libraryCitations(tests: TestsContent, macros: MacrosContent) -> Set<String> {
    var keys = Set<String>()
    for technique in tests.techniques { keys.formUnion(technique.refs) }
    for guarantee in tests.guarantees {
      keys.formUnion(guarantee.suites + guarantee.tests + [guarantee.showcase])
    }
    return keys
  }
}
