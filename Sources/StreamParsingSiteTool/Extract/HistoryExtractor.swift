import Foundation

/// When each section of the log was written, and when it was last rewritten.
///
/// The dates are not hand-authored and could not be: an experiment's date is the commit that wrote
/// the experiment down, so the only place that knows it is the document's own history. This walks
/// every revision of `NEW_ARCHITECTURE.md` in order, re-runs `DocumentExtractor.walk` over each
/// one, and records for every heading path the commit it first appeared in and the last commit
/// whose body differed from the revision before it.
///
/// Two consequences worth stating rather than discovering later. A retitled heading is a new path
/// and therefore dates from the retitle -- the site says "recorded", not "measured", because that
/// is what the commit witnesses. And a revision that only moved a section down the file changes no
/// body and does not count as a revision, which is the behaviour that makes the "last revised"
/// date mean something in a document that grows at the bottom.
struct HistoryExtractor {
  var root: String
  var file: String

  struct Revision {
    var sha: String
    var date: String
    var subject: String
  }

  func extract() -> (history: [String: DocHistory], revisions: [Revision], warnings: [String]) {
    var warnings: [String] = []
    guard let log = self.git(["log", "--reverse", "--date-order", "--format=%H%x1f%aI%x1f%s", "--", self.file]) else {
      warnings.append("git is unavailable, or \(self.file) has no history here; sections will carry no dates")
      return ([:], [], warnings)
    }

    let revisions: [Revision] = log.components(separatedBy: "\n").compactMap { line in
      let parts = line.components(separatedBy: "\u{1f}")
      guard parts.count == 3, !parts[0].isEmpty else { return nil }
      return Revision(sha: parts[0], date: parts[1], subject: parts[2])
    }
    guard !revisions.isEmpty else {
      warnings.append("no commits touch \(self.file); sections will carry no dates")
      return ([:], [], warnings)
    }

    // Only the previous revision's bodies are held, because the only question asked of a revision
    // is whether a section reads differently than it did one commit ago.
    var previous: [String: String] = [:]
    var history: [String: DocHistory] = [:]

    for revision in revisions {
      guard let text = self.git(["show", "\(revision.sha):\(self.file)"]) else { continue }
      let walk = DocumentExtractor.walk(lines: text.components(separatedBy: "\n"))
      var current: [String: String] = [:]
      current.reserveCapacity(walk.entries.count)
      for entry in walk.entries { current[entry.heading.path] = entry.body }

      for (path, body) in current {
        guard var existing = history[path] else {
          history[path] = DocHistory(
            recorded: revision.date,
            recordedCommit: String(revision.sha.prefix(9)),
            recordedSubject: revision.subject,
            revised: revision.date,
            revisedCommit: String(revision.sha.prefix(9)),
            revisedSubject: revision.subject,
            revisions: 1
          )
          continue
        }
        guard previous[path] != body else { continue }
        existing.revised = revision.date
        existing.revisedCommit = String(revision.sha.prefix(9))
        existing.revisedSubject = revision.subject
        existing.revisions += 1
        history[path] = existing
      }
      previous = current
    }

    return (history, revisions, warnings)
  }

  private func git(_ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "-C", self.root] + arguments
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    // Read before waiting: a revision of this document is a quarter of a megabyte and would fill
    // the pipe buffer long before the process exits.
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
