import Foundation

// The shape of `Web/generated/content.json`. Everything here is derived: the doc and the source
// comments are the only places evidence is written, and this file is a projection of them. A
// field that cannot be recovered by re-running the extractor does not belong in it.

struct ContentBundle: Encodable {
  var generatedAt: String
  var doc: DocBundle
  var sources: [String: [SourceDecl]]
  var stats: Stats

  struct Stats: Encodable {
    var sectionCount: Int
    var tableCount: Int
    var codeBlockCount: Int
    var declCount: Int
    var fileCount: Int
    var verdictCounts: [String: Int]
  }
}

/// Written separately from `content.json`: the declaration bodies are the bulk of the bytes and
/// the walkthrough does not need them until a Source tab is opened.
struct SourceBundle: Encodable {
  var generatedAt: String
  var sources: [String: [SourceDecl]]
}

struct DocBundle: Encodable {
  var path: String
  var title: String
  var sections: [DocSection]
}

/// One heading and the body beneath it, addressed by a path slug that is stable against sections
/// being inserted elsewhere in the document.
struct DocSection: Encodable {
  /// `chapter-slug/section-slug`, or just `chapter-slug` for a top level heading. Path-scoped
  /// rather than document-global because titles like "Measured" and "The census" repeat, and a
  /// GitHub style `-1`/`-2` suffix would renumber every later duplicate when one is inserted.
  var path: String
  var slug: String
  var title: String
  var level: Int
  var parentPath: String?
  /// Title of the level-2 chapter this section sits under, or its own when it is one. Several
  /// subsections are called "Measured" or "The census"; standing alone in the graveyard and payload
  /// views they say nothing without it.
  var chapter: String
  var line: Int
  /// `landed`, `rejected`, `mixed`, or `neutral`, taken from the title prefix and the body's own
  /// verdict markers. This is what the graveyard view filters on.
  var verdict: String
  var markdown: String
  var summary: String
  var tables: [DocTable]
  var codeBlocks: [DocCodeBlock]
  var measurements: [Measurement]
}

struct DocTable: Encodable {
  var headers: [String]
  var rows: [[TableCell]]
  /// Index of the column holding the row label, when the first column is not numeric.
  var labelColumn: Int?
}

struct TableCell: Encodable {
  var text: String
  var bold: Bool
  /// Parsed leading number, when the cell is one. `783` for `**783 MB/s**`, `17.6` for `+17.6%`.
  var value: Double?
  var unit: String?
  /// True when the cell reads as a signed delta (`+17.6%`, `-0.2%`).
  var isDelta: Bool
}

/// A single payload's number pulled out of a table, so the payload view can ask "everything ever
/// measured on canada" without the caller re-parsing markdown.
struct Measurement: Encodable {
  var payload: String
  var rowLabel: String
  var column: String
  var value: Double
  var unit: String?
  var isDelta: Bool
}

struct DocCodeBlock: Encodable {
  var language: String
  var code: String
}

/// A declaration lifted out of the Swift sources, with the comment that explains it. The comments
/// are first class evidence here: several kernels carry their measurement table inline and it
/// appears nowhere else.
struct SourceDecl: Encodable {
  var symbol: String
  var qualifiedName: String
  var kind: String
  var file: String
  var startLine: Int
  var endLine: Int
  var attributes: [String]
  var comment: String?
  var code: String
  /// Member names, for a type declaration whose body was elided. Lets the detail view offer the
  /// members as links instead of dumping a 65 KB struct.
  var members: [String]
}
