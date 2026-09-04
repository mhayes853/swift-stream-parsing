import Foundation

/// `Web/content/pipeline.json`: the only hand-authored file in the explorer.
///
/// It holds the architectural ordering the document does not have (the doc is a log, ordered by
/// when things were tried), the short teaching prose per node, and *references* into the evidence.
/// It never holds a measurement or a copy of an explanation -- those resolve out of the doc and
/// the source comments, and a reference that stops resolving fails the build.
struct Pipeline: Decodable {
  var version: Int
  var stages: [Stage]
  var nodes: [Node]

  struct Stage: Decodable {
    var id: String
    var title: String
    var blurb: String
  }

  struct Node: Decodable {
    var id: String
    var stage: String
    var title: String
    var kicker: String
    var prose: [String]
    /// The animation this node drives, when it has one. Absent for nodes that are evidence only.
    var viz: String?
    var evidence: Evidence
    /// One sentence on *how* this node reaches the things it calls -- the switch it dispatches
    /// through, the loop it stays inside, the order it runs them in. The flow chart shows it when
    /// the node is under the cursor, which is where the question "why are there four arrows here"
    /// actually gets asked.
    var invokes: String?
    /// Whether the arrows out of this node are numbered. `ordered` means `next` is written in the
    /// order the source runs or tests them, and the chart numbers them; `unordered` means there is
    /// no order to claim -- protocol methods, or a choice made by a member's type.
    var ordering: Ordering?
    var next: [Edge]
    /// The control flow *inside* this node, drawn in its own panel the same way the pipeline is
    /// drawn on the page. The pipeline graph says which functions reach which; this says what the
    /// one function does, and it is the only place a branch inside a kernel is written down.
    ///
    /// Required, and required to be a real graph: `validate` rejects a node without one, a step
    /// nothing reaches, and a graph with no step that ends it.
    var steps: [Step]

    enum Ordering: String, Decodable { case ordered, unordered }
  }

  /// One step of a node's own algorithm: an instruction, a test, or a call it makes.
  struct Step: Decodable {
    var id: String
    var title: String
    /// The short label under the title -- a width, a cost, an attribute.
    var kicker: String?
    /// What this step does, and why it is spelled the way it is. The one place a measurement may
    /// be quoted rather than resolved, because it is quoting the source comment beside it.
    var detail: String
    /// `File.swift:symbol`, validated exactly as `evidence.source` is -- and required to *be* one
    /// of the node's own, so clicking a step and opening the Source tab lands on the same thing.
    var source: String?
    var ordering: Node.Ordering?
    var next: [Edge]

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self.id = try c.decode(String.self, forKey: .id)
      self.title = try c.decode(String.self, forKey: .title)
      self.kicker = try c.decodeIfPresent(String.self, forKey: .kicker)
      self.detail = try c.decode(String.self, forKey: .detail)
      self.source = try c.decodeIfPresent(String.self, forKey: .source)
      self.ordering = try c.decodeIfPresent(Node.Ordering.self, forKey: .ordering)
      self.next = try c.decodeIfPresent([Edge].self, forKey: .next) ?? []
    }
    enum CodingKeys: String, CodingKey { case id, title, kicker, detail, source, ordering, next }
  }

  /// A labelled edge. The chart draws `next` as arrows, so an unlabelled arrow is a step nobody
  /// explained -- `label` is therefore required, and `validate` rejects an empty one.
  struct Edge: Decodable {
    /// Node id this arrow points at.
    var to: String
    /// How to read this arrow. `step` runs unconditionally and is numbered by its position in
    /// `next`; `branch` is taken only when `when` holds; `return` hands control back to a node
    /// that already ran; `detail` zooms into the same work rather than moving through it.
    var kind: Kind
    /// Drawn on the arrow itself, so it has to survive being small: a condition or a verb phrase.
    var label: String
    /// The full circumstance, shown on hover. Optional, but `branch` without one is a warning:
    /// a fork whose condition is unwritten is the thing this file exists to record.
    var when: String?

    enum Kind: String, Decodable { case step, branch, `return`, detail }

    init(from decoder: Decoder) throws {
      // A bare `"node-id"` still decodes, as an unconditional step. Cheap, and it keeps a
      // hand-edit from failing the build before the author gets to the labels.
      if let single = try? decoder.singleValueContainer(), let to = try? single.decode(String.self) {
        self.to = to
        self.kind = .step
        self.label = ""
        return
      }
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self.to = try c.decode(String.self, forKey: .to)
      self.kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .step
      self.label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
      self.when = try c.decodeIfPresent(String.self, forKey: .when)
    }
    enum CodingKeys: String, CodingKey { case to, kind, label, when }
  }

  struct Evidence: Decodable {
    var doc: [String]
    var source: [String]
    var asm: [String]

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      self.doc = try c.decodeIfPresent([String].self, forKey: .doc) ?? []
      self.source = try c.decodeIfPresent([String].self, forKey: .source) ?? []
      self.asm = try c.decodeIfPresent([String].self, forKey: .asm) ?? []
    }
    enum CodingKeys: String, CodingKey { case doc, source, asm }
  }
}

extension Pipeline {
  /// Mirrors the `VizKind` union in `Web/src/types.ts` and the switch in `Web/src/viz/index.tsx`.
  static let vizKinds: Set<String> = [
    "stringRun", "whitespace", "containers", "number",
    "movemask", "whitespaceTable", "numberTable", "utf8", "escapes"
  ]
}

struct ReferenceReport {
  var errors: [String] = []
  var warnings: [String] = []

  /// Fails on a dangling doc slug or symbol, warns on missing assembly.
  ///
  /// This is what keeps the explorer honest: renaming a kernel or retitling a chapter breaks the
  /// build here rather than leaving a node in the UI pointing at nothing.
  static func validate(
    _ pipeline: Pipeline,
    sections: [DocSection],
    sources: [String: [SourceDecl]],
    asmSymbols: Set<String>
  ) -> ReferenceReport {
    var report = ReferenceReport()
    let paths = Set(sections.map(\.path))
    let stageIDs = Set(pipeline.stages.map(\.id))
    let nodeIDs = Set(pipeline.nodes.map(\.id))

    for node in pipeline.nodes {
      let at = "node '\(node.id)'"
      if !stageIDs.contains(node.stage) {
        report.errors.append("\(at): unknown stage '\(node.stage)'")
      }
      // A typo here would silently render nothing, since the switch in `viz/index.tsx` is
      // exhaustive over the kinds it knows and returns undefined for anything else.
      if let viz = node.viz, !Pipeline.vizKinds.contains(viz) {
        report.errors.append(
          "\(at): unknown viz '\(viz)' (known: \(Pipeline.vizKinds.sorted().joined(separator: ", ")))"
        )
      }
      for edge in node.next {
        if !nodeIDs.contains(edge.to) {
          report.errors.append("\(at): 'next' points at unknown node '\(edge.to)'")
        }
        // An arrow with no label is a claim the chart cannot make good on.
        if edge.label.trimmingCharacters(in: .whitespaces).isEmpty {
          report.errors.append("\(at): edge -> '\(edge.to)' has no 'label'")
        }
        if edge.kind == .branch, (edge.when ?? "").isEmpty {
          report.warnings.append("\(at): branch -> '\(edge.to)' does not say when it is taken")
        }
      }
      if node.next.count > 1, node.ordering == nil {
        report.warnings.append("\(at): fans out to \(node.next.count) nodes without saying whether they are ordered")
      }
      if node.next.count > 1, (node.invokes ?? "").isEmpty {
        report.warnings.append("\(at): fans out to \(node.next.count) nodes with no 'invokes' note")
      }
      for slug in node.evidence.doc where !paths.contains(slug) {
        let near = Self.nearest(slug, in: paths)
        report.errors.append(
          "\(at): doc section '\(slug)' does not resolve\(near.map { " (closest: '\($0)')" } ?? "")"
        )
      }
      for key in node.evidence.source where sources[key] == nil {
        let near = Self.nearest(key, in: Set(sources.keys))
        report.errors.append(
          "\(at): source symbol '\(key)' does not resolve\(near.map { " (closest: '\($0)')" } ?? "")"
        )
      }
      for symbol in node.evidence.asm where !asmSymbols.contains(symbol) {
        report.warnings.append("\(at): no assembly snapshot for '\(symbol)'; run ./Web/generate asm")
      }
      if node.prose.isEmpty {
        report.warnings.append("\(at): no teaching prose")
      }
      Self.validateSteps(node, sources: sources, into: &report)
    }

    for node in pipeline.nodes where node.evidence.doc.isEmpty && node.evidence.source.isEmpty {
      report.warnings.append("node '\(node.id)': no evidence attached")
    }
    return report
  }

  /// The node's own algorithm graph, held to the same standard as the pipeline graph above.
  ///
  /// Every detail panel draws one, so "this node has no chart" is a build error rather than a
  /// blank space. The three structural checks are what stop a graph from *looking* like an
  /// algorithm without being one: an arrow into nothing, a step nothing reaches, and a graph with
  /// no way out. The last is the interesting one -- several of these kernels are loops, and a loop
  /// drawn with no exit is a claim about the code that is not true of any of them.
  static func validateSteps(
    _ node: Pipeline.Node, sources: [String: [SourceDecl]], into report: inout ReferenceReport
  ) {
    let at = "node '\(node.id)'"
    guard node.steps.count >= 2 else {
      report.errors.append(
        "\(at): needs a 'steps' graph of at least two steps; every detail panel draws one"
      )
      return
    }
    var ids = Set<String>()
    for step in node.steps where !ids.insert(step.id).inserted {
      report.errors.append("\(at): duplicate step id '\(step.id)'")
    }
    // A step may only cite source the node already claims, so following it into the Source tab
    // lands on a declaration that is actually listed there.
    let owned = Set(node.evidence.source)
    for step in node.steps {
      let where_ = "\(at) step '\(step.id)'"
      if let symbol = step.source {
        if sources[symbol] == nil {
          let near = Self.nearest(symbol, in: Set(sources.keys))
          report.errors.append(
            "\(where_): source '\(symbol)' does not resolve\(near.map { " (closest: '\($0)')" } ?? "")"
          )
        } else if !owned.contains(symbol) {
          report.errors.append(
            "\(where_): source '\(symbol)' is not in the node's own evidence.source"
          )
        }
      }
      if step.detail.trimmingCharacters(in: .whitespaces).isEmpty {
        report.errors.append("\(where_): no 'detail'")
      }
      for edge in step.next {
        if !ids.contains(edge.to) {
          report.errors.append("\(where_): points at unknown step '\(edge.to)'")
        }
        if edge.label.trimmingCharacters(in: .whitespaces).isEmpty {
          report.errors.append("\(where_): edge -> '\(edge.to)' has no 'label'")
        }
        if edge.kind == .branch, (edge.when ?? "").isEmpty {
          report.warnings.append("\(where_): branch -> '\(edge.to)' does not say when it is taken")
        }
      }
      if step.next.count > 1, step.ordering == nil {
        report.warnings.append(
          "\(where_): fans out to \(step.next.count) steps without saying whether they are ordered"
        )
      }
    }

    // Reachability from the entry, which is the first step by construction.
    let byID = Dictionary(uniqueKeysWithValues: node.steps.map { ($0.id, $0) })
    var seen: Set<String> = [node.steps[0].id]
    var stack = [node.steps[0].id]
    while let current = stack.popLast() {
      for edge in byID[current]?.next ?? [] where seen.insert(edge.to).inserted {
        stack.append(edge.to)
      }
    }
    for step in node.steps where !seen.contains(step.id) {
      report.errors.append(
        "\(at): step '\(step.id)' is unreachable from '\(node.steps[0].id)'"
      )
    }
    if !node.steps.contains(where: { $0.next.isEmpty }) {
      report.errors.append("\(at): no step ends the algorithm; every path loops forever")
    }
  }

  /// Cheap suggestion for a mistyped or renamed reference: longest shared prefix, then closest
  /// length. Enough to point at the rename that caused the break.
  static func nearest(_ needle: String, in haystack: Set<String>) -> String? {
    let target = Array(needle)
    var best: String?
    var bestShared = 3
    for candidate in haystack {
      let chars = Array(candidate)
      var shared = 0
      while shared < chars.count, shared < target.count, chars[shared] == target[shared] {
        shared += 1
      }
      if shared > bestShared {
        bestShared = shared
        best = candidate
      }
    }
    return best
  }
}
