import Foundation

/// The C shims, extracted the same way as the Swift declarations.
///
/// swift-syntax cannot read these, and a full C parser is far more than this needs: the header is
/// swift-format-adjacent in style and every exported name starts with `stream_parsing_`. The
/// comments are the point -- `stream_parsing_utf8_block_errors` carries the record of the two
/// shapes that were measured and lost, and it exists nowhere else.
struct CHeaderExtractor {
  var path: String

  func extract() throws -> [String: [SourceDecl]] {
    let text = try String(contentsOfFile: self.path, encoding: .utf8)
    let lines = text.components(separatedBy: "\n")
    let basename = self.path.lastPathComponentSlice
    var out: [String: [SourceDecl]] = [:]
    var index = 0

    while index < lines.count {
      guard let name = Self.functionName(in: lines[index]) else {
        index += 1
        continue
      }

      // Walk back over the return type and any attribute macro on their own lines.
      var declStart = index
      while declStart > 0 {
        let previous = lines[declStart - 1].trimmingCharacters(in: .whitespaces)
        guard !previous.isEmpty, !previous.hasPrefix("//"), !previous.hasPrefix("#"),
          !previous.hasSuffix("}"), !previous.hasSuffix(";"), !previous.hasSuffix("{")
        else { break }
        declStart -= 1
      }

      var commentStart = declStart
      while commentStart > 0, lines[commentStart - 1].trimmingCharacters(in: .whitespaces).hasPrefix("//") {
        commentStart -= 1
      }
      let comment =
        commentStart < declStart
        ? lines[commentStart..<declStart]
          .map { line -> String in
            var s = Substring(line.trimmingCharacters(in: .whitespaces))
            while s.hasPrefix("/") { s = s.dropFirst() }
            if s.hasPrefix(" ") { s = s.dropFirst() }
            return String(s)
          }
          .joined(separator: "\n")
        : nil

      let end = Self.declarationEnd(lines, from: index)
      out["\(basename):\(name)", default: []].append(
        SourceDecl(
          symbol: name,
          qualifiedName: name,
          kind: lines[declStart...end].contains(where: { $0.contains("{") }) ? "c-func" : "c-decl",
          file: self.path,
          startLine: declStart + 1,
          endLine: end + 1,
          attributes: lines[declStart..<index].contains(where: { $0.contains("STREAM_PARSING_SIMD_SHIM") })
            || lines[index].contains("STREAM_PARSING_SIMD_SHIM") ? ["static inline always_inline"] : [],
          comment: comment?.isEmpty == false ? comment : nil,
          code: lines[declStart...end].joined(separator: "\n"),
          members: []
        )
      )
      index = end + 1
    }
    return out
  }

  /// The exported name on a line that opens a declaration. Typedefs and macro definitions mention
  /// the prefix too, so they are excluded by shape rather than by name.
  static func functionName(in line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("#"), !trimmed.hasPrefix("typedef"),
      !trimmed.hasPrefix("return"), !trimmed.hasPrefix("extern")
    else { return nil }
    guard let open = trimmed.firstIndex(of: "(") else { return nil }
    let head = trimmed[..<open]
    guard let last = head.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "_") }).last,
      last.hasPrefix("stream_parsing_")
    else { return nil }
    return String(last)
  }

  /// A definition ends at its balanced closing brace; a prototype ends at its semicolon.
  static func declarationEnd(_ lines: [String], from index: Int) -> Int {
    var depth = 0
    var seenBrace = false
    var i = index
    while i < lines.count {
      for ch in lines[i] {
        if ch == "{" {
          depth += 1
          seenBrace = true
        } else if ch == "}" {
          depth -= 1
        }
      }
      if seenBrace, depth <= 0 { return i }
      if !seenBrace, lines[i].contains(";") { return i }
      i += 1
    }
    return min(i, lines.count - 1)
  }
}
