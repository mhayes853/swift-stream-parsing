import Foundation
import MacroTesting
import SnapshotTesting
import StreamParsingMacros
import Testing

/// Keeps the existing lifetime-view snapshots authoritative while checking the unsafe expansion
/// selected by the default package traits. This transformation is intentionally limited to the
/// generated view surface; all parsing/schema output is compared byte-for-byte as before.
private func expectedViewExpansion(_ source: String) -> String {
#if LifetimeView
  source
#else
  let lines = source.components(separatedBy: "\n")
  var transformed = [String]()
  transformed.reserveCapacity(lines.count)
  var index = 0

  while index < lines.count {
    let line = lines[index]
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    let indentation = String(line.prefix(while: { $0 == " " || $0 == "\t" }))

    if trimmed == "@_lifetime(borrow storage)" || trimmed == "@_lifetime(borrow self)" {
      index += 1
      continue
    }

    if trimmed.contains("struct View: ~Copyable, ~Escapable {") {
      transformed.append(
        indentation + "@unsafe "
          + trimmed.replacingOccurrences(
            of: "struct View: ~Copyable, ~Escapable {",
            with: "struct View: ~Copyable {"
          )
      )
      index += 1
      continue
    }

    if trimmed.contains("enum ResolvedView: ~Copyable, ~Escapable {") {
      transformed.append(
        indentation + "@unsafe "
          + trimmed.replacingOccurrences(
            of: "enum ResolvedView: ~Copyable, ~Escapable {",
            with: "enum ResolvedView: ~Copyable {"
          )
      )
      index += 1
      continue
    }

    if trimmed.contains("static func streamView(") {
      transformed.append(indentation + "@unsafe")
    }

    let singleLineOverride = "return _overrideLifetime("
    if trimmed.hasPrefix(singleLineOverride), trimmed.hasSuffix(", borrowing: self)") {
      let start = trimmed.index(trimmed.startIndex, offsetBy: singleLineOverride.count)
      let end = trimmed.index(trimmed.endIndex, offsetBy: -", borrowing: self)".count)
      transformed.append(indentation + "return " + trimmed[start..<end])
      index += 1
      continue
    }

    if trimmed == "return _overrideLifetime(", index + 3 < lines.count {
      let expression = lines[index + 1].trimmingCharacters(in: .whitespaces)
      let borrowing = lines[index + 2].trimmingCharacters(in: .whitespaces)
      let close = lines[index + 3].trimmingCharacters(in: .whitespaces)
      if expression.hasSuffix(","), borrowing == "borrowing: self", close == ")" {
        transformed.append(indentation + "return " + expression.dropLast())
        index += 4
        continue
      }
    }

    if trimmed.contains("One case's borrowed, mid-stream view") {
      transformed.append(
        line.replacingOccurrences(
          of: "One case's borrowed, mid-stream view",
          with: "One case's unsafe mid-stream view"
        )
      )
      index += 1
      continue
    }

    if trimmed == "/// than one case's key has arrived yet." {
      transformed.append(indentation + "/// than one case's key has arrived yet. Do not retain it across parser mutation.")
      index += 1
      continue
    }

    transformed.append(line)
    index += 1
  }

  return transformed.joined(separator: "\n")
#endif
}

func assertStreamParsingMacro(
  _ originalSource: () -> String,
  diagnostics diagnosedSource: (() -> String)? = nil,
  fixes fixedSource: (() -> String)? = nil,
  expansion expandedSource: (() -> String)? = nil,
  fileID: StaticString = #fileID,
  file filePath: StaticString = #filePath,
  function: StaticString = #function,
  line: UInt = #line,
  column: UInt = #column
) {
  MacroTesting.assertMacro(
    of: originalSource,
    diagnostics: diagnosedSource,
    fixes: fixedSource,
    expansion: expandedSource.map { expected in { expectedViewExpansion(expected()) } },
    fileID: fileID,
    file: filePath,
    function: function,
    line: line,
    column: column
  )
}

@MainActor
@Suite(
  .serialized,
  .macros(
    [
      "StreamParseable": StreamParseableMacro.self,
      "StreamParseableMember": StreamParseableMemberMacro.self,
      "StreamParseableIgnored": StreamParseableIgnoredMacro.self
    ],
    record: .failed
  )
) struct BaseTestSuite {}
