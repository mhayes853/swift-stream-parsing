import Foundation

/// Slices `NEW_ARCHITECTURE.md` into addressable sections.
///
/// The document is an engineering log ordered by when things were tried, so nothing here tries to
/// impose an architectural order on it -- that is `pipeline.json`'s job. This only makes every
/// heading addressable and pulls the structure out of the parts that are already regular: the
/// `Landed:` / `Rejected:` title convention and the measurement tables.
struct DocumentExtractor {
  var path: String
  var text: String

  func extract() -> (DocBundle, [String]) {
    var warnings: [String] = []
    let lines = self.text.components(separatedBy: "\n")

    // (level, path) of the headings currently open, so a child can name its parent.
    var stack: [(level: Int, path: String, title: String)] = []
    var sections: [DocSection] = []
    var pending: (heading: Heading, bodyStart: Int)?
    var seenPaths = Set<String>()
    var inFence = false
    var title = ""

    func closePending(endLine: Int) {
      guard let p = pending else { return }
      let body = lines[p.bodyStart..<endLine].joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      sections.append(self.makeSection(p.heading, markdown: body))
    }

    for (index, line) in lines.enumerated() {
      // Headings inside a fenced block are not headings. The doc quotes shell and markdown, so
      // this is not hypothetical.
      if line.hasPrefix("```") {
        inFence.toggle()
        continue
      }
      if inFence { continue }
      guard let level = Self.headingLevel(line) else { continue }
      let raw = String(line.dropFirst(level + 1)).trimmingCharacters(in: .whitespaces)
      if level == 1 {
        title = raw
        continue
      }

      closePending(endLine: index)

      while let last = stack.last, last.level >= level { stack.removeLast() }
      let parentPath = stack.last?.path
      let chapter = stack.first?.title ?? raw
      let slug = Self.slugify(raw)
      // Path scoped rather than document global: "Measured" and "The census" repeat across
      // chapters, and a document-wide `-1`/`-2` suffix would renumber every later duplicate the
      // moment one is inserted, silently breaking references in `pipeline.json`.
      var candidate = parentPath.map { "\($0)/\(slug)" } ?? slug
      if seenPaths.contains(candidate) {
        var n = 2
        while seenPaths.contains("\(candidate)-\(n)") { n += 1 }
        warnings.append("duplicate heading path '\(candidate)' at line \(index + 1); using -\(n)")
        candidate = "\(candidate)-\(n)"
      }
      seenPaths.insert(candidate)
      stack.append((level, candidate, raw))
      pending = (
        Heading(
          path: candidate, slug: slug, title: raw, level: level, parent: parentPath,
          chapter: chapter, line: index + 1
        ),
        index + 1
      )
    }
    closePending(endLine: lines.count)

    sections = Self.propagateVerdicts(sections)
    return (DocBundle(path: self.path, title: title, sections: sections), warnings)
  }

  struct Heading {
    var path: String
    var slug: String
    var title: String
    var level: Int
    var parent: String?
    var chapter: String
    var line: Int
  }

  private func makeSection(_ h: Heading, markdown: String) -> DocSection {
    let tables = Self.parseTables(markdown)
    return DocSection(
      path: h.path,
      slug: h.slug,
      title: h.title,
      level: h.level,
      parentPath: h.parent,
      chapter: h.chapter,
      line: h.line,
      verdict: Self.verdict(title: h.title, body: markdown),
      markdown: markdown,
      summary: Self.summarize(markdown),
      tables: tables,
      codeBlocks: Self.parseCodeBlocks(markdown),
      measurements: Self.measurements(in: tables)
    )
  }

  // MARK: - Headings

  static func headingLevel(_ line: String) -> Int? {
    guard line.hasPrefix("#") else { return nil }
    let hashes = line.prefix(while: { $0 == "#" }).count
    guard hashes <= 6, line.dropFirst(hashes).hasPrefix(" ") else { return nil }
    return hashes
  }

  static func slugify(_ raw: String) -> String {
    var out = ""
    var lastWasDash = true
    for scalar in raw.lowercased().unicodeScalars {
      if ("a"..."z").contains(String(scalar)) || ("0"..."9").contains(String(scalar)) || scalar == "_" {
        out.unicodeScalars.append(scalar)
        lastWasDash = false
      } else if !lastWasDash {
        // Every run of punctuation or whitespace collapses to one separator, so `--` and ` -- `
        // and `, ` all produce the same slug.
        out.append("-")
        lastWasDash = true
      }
    }
    while out.hasSuffix("-") { out.removeLast() }
    return out.isEmpty ? "section" : out
  }

  // MARK: - Verdicts

  static func verdict(title: String, body: String) -> String {
    let t = title.lowercased()
    let rejectedInTitle = ["rejected", "not kept", "loses outright", "left alone", "closed door"]
      .contains { t.contains($0) }
    let landedInTitle = ["landed", "retained", "and kept", "(done)", "shipped"]
      .contains { t.contains($0) }
    if rejectedInTitle && landedInTitle { return "mixed" }
    if rejectedInTitle { return "rejected" }
    if landedInTitle { return "landed" }
    // The body convention is a bare uppercase REJECTED, used when the verdict did not fit the
    // title. There is no uppercase counterpart for a win, so this test is one sided on purpose.
    if body.contains("REJECTED") { return "rejected" }
    return "neutral"
  }

  /// A chapter whose own prose carries no verdict inherits one from its children: "opposite
  /// signs" chapters exist precisely because a landed and a rejected result sit under them.
  static func propagateVerdicts(_ sections: [DocSection]) -> [DocSection] {
    var childVerdicts: [String: Set<String>] = [:]
    for s in sections where s.verdict != "neutral" {
      guard let parent = s.parentPath else { continue }
      childVerdicts[parent, default: []].insert(s.verdict)
    }
    return sections.map { section in
      guard section.verdict == "neutral", let kinds = childVerdicts[section.path] else { return section }
      var copy = section
      copy.verdict = kinds.count == 1 ? kinds.first! : "mixed"
      return copy
    }
  }

  // MARK: - Summary

  static func summarize(_ markdown: String) -> String {
    var paragraph: [String] = []
    var inFence = false
    for line in markdown.components(separatedBy: "\n") {
      if line.hasPrefix("```") { inFence.toggle(); continue }
      if inFence { continue }
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty {
        if !paragraph.isEmpty { break }
        continue
      }
      // Skip straight past tables, lists and block quotes to the first real sentence.
      if trimmed.hasPrefix("|") || trimmed.hasPrefix("-") || trimmed.hasPrefix(">")
        || trimmed.hasPrefix("*") || trimmed.hasPrefix("#")
      {
        if !paragraph.isEmpty { break }
        continue
      }
      paragraph.append(trimmed)
    }
    var text = paragraph.joined(separator: " ")
    for marker in ["**", "`", "*"] { text = text.replacingOccurrences(of: marker, with: "") }
    if text.count > 260 {
      let cut = text.prefix(260)
      let end = cut.lastIndex(of: " ").map(cut.index(after:)) ?? cut.endIndex
      text = cut[..<end].trimmingCharacters(in: .whitespaces) + "…"
    }
    return text
  }

  // MARK: - Code blocks

  static func parseCodeBlocks(_ markdown: String) -> [DocCodeBlock] {
    var blocks: [DocCodeBlock] = []
    var current: [String]?
    var language = ""
    for line in markdown.components(separatedBy: "\n") {
      if line.hasPrefix("```") {
        if let body = current {
          blocks.append(DocCodeBlock(language: language.isEmpty ? "text" : language, code: body.joined(separator: "\n")))
          current = nil
        } else {
          language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
          current = []
        }
        continue
      }
      current?.append(line)
    }
    return blocks
  }

  // MARK: - Tables

  static func parseTables(_ markdown: String) -> [DocTable] {
    var tables: [DocTable] = []
    var run: [String] = []
    var inFence = false

    func flush() {
      defer { run = [] }
      // header + separator + at least one row
      guard run.count >= 3, isSeparatorRow(run[1]) else { return }
      let headers = splitRow(run[0]).map { stripInline($0) }
      let rows = run[2...].map { splitRow($0).map(parseCell) }
      guard !headers.isEmpty else { return }
      let labelColumn = rows.allSatisfy { $0.first?.value == nil } ? 0 : nil
      tables.append(DocTable(headers: headers, rows: Array(rows), labelColumn: labelColumn))
    }

    for line in markdown.components(separatedBy: "\n") {
      if line.hasPrefix("```") { inFence.toggle(); flush(); continue }
      if inFence { continue }
      if line.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
        run.append(line)
      } else {
        flush()
      }
    }
    flush()
    return tables
  }

  static func isSeparatorRow(_ line: String) -> Bool {
    let cells = splitRow(line)
    guard !cells.isEmpty else { return false }
    return cells.allSatisfy { cell in
      let c = cell.trimmingCharacters(in: .whitespaces)
      return !c.isEmpty && c.allSatisfy { $0 == "-" || $0 == ":" } && c.contains("-")
    }
  }

  static func splitRow(_ line: String) -> [String] {
    var trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("|") { trimmed.removeFirst() }
    if trimmed.hasSuffix("|") { trimmed.removeLast() }
    return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
  }

  static func stripInline(_ s: String) -> String {
    var out = s
    for marker in ["**", "`"] { out = out.replacingOccurrences(of: marker, with: "") }
    return out.trimmingCharacters(in: .whitespaces)
  }

  static func parseCell(_ raw: String) -> TableCell {
    let bold = raw.contains("**")
    let text = stripInline(raw)
    // A number is only a number if it opens the cell: "1 byte" in a header-ish label column would
    // otherwise read as the value 1, which is exactly what it means there anyway, and a row whose
    // label happens to start with a digit is caught by `labelColumn` staying nil.
    var scanner = Substring(text)
    var signed = false
    if scanner.hasPrefix("+") || scanner.hasPrefix("-") || scanner.hasPrefix("−") {
      signed = true
      scanner = scanner.dropFirst()
    }
    let digits = scanner.prefix { $0.isNumber || $0 == "." || $0 == "," }
    guard !digits.isEmpty, digits.contains(where: { $0.isNumber }) else {
      return TableCell(text: text, bold: bold, value: nil, unit: nil, isDelta: false)
    }
    let numeric = digits.replacingOccurrences(of: ",", with: "")
    guard var value = Double(numeric) else {
      return TableCell(text: text, bold: bold, value: nil, unit: nil, isDelta: false)
    }
    if signed, text.hasPrefix("-") || text.hasPrefix("−") { value = -value }
    let unit = scanner.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
    return TableCell(
      text: text,
      bold: bold,
      value: value,
      unit: unit.isEmpty ? nil : unit,
      isDelta: signed && unit.hasPrefix("%")
    )
  }

  // MARK: - Measurements

  /// Longest match wins, so `twitterescaped` never resolves as `twitter`.
  static let payloadKeys: [(needle: String, payload: String)] = [
    ("twitterescaped", "twitterescaped"), ("twitter escaped", "twitterescaped"),
    ("citm", "citm_catalog"), ("canada", "canada"), ("gsoc", "gsoc-2018"),
    ("github", "github_events"), ("llm", "llm_message"), ("twitter", "twitter"),
    ("mesh", "mesh"), ("qwen", "qwen"), ("pretty", "pretty_printed"),
    ("matrix", "matrix"), ("unicode", "unicode_escapes")
  ]

  static func payload(for label: String) -> String? {
    let l = label.lowercased()
    return payloadKeys.first { l.contains($0.needle) }?.payload
  }

  static func measurements(in tables: [DocTable]) -> [Measurement] {
    var out: [Measurement] = []
    for table in tables {
      for row in table.rows {
        guard let label = row.first?.text, let payload = payload(for: label) else { continue }
        for (column, cell) in row.enumerated().dropFirst() {
          guard let value = cell.value, column < table.headers.count else { continue }
          out.append(
            Measurement(
              payload: payload,
              rowLabel: label,
              column: table.headers[column],
              value: value,
              unit: cell.unit,
              isDelta: cell.isDelta
            )
          )
        }
      }
      // Some tables put the payloads across the header instead of down the label column
      // ("| variant | citm | twitter | ... |"), which is the shape most of the A/B tables use.
      for (column, header) in table.headers.enumerated().dropFirst() {
        guard let payload = payload(for: header) else { continue }
        for row in table.rows {
          guard column < row.count, let value = row[column].value, let label = row.first?.text
          else { continue }
          out.append(
            Measurement(
              payload: payload,
              rowLabel: label,
              column: header,
              value: value,
              unit: row[column].unit,
              isDelta: row[column].isDelta
            )
          )
        }
      }
    }
    return out
  }
}
