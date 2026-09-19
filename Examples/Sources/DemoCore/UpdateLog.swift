import Foundation
import StreamParsing

/// Prints one line per chunk: what arrived, and the typed partial value the parser holds after
/// consuming it. Nothing is redrawn or skipped, so the output doubles as a transcript.
public actor UpdateLog {
  private let colored: Bool
  private let full: Bool
  private var index = 0
  private var elapsed = Duration.zero
  private var byteCount = 0
  private var changedCount = 0
  private var pendingChunk: StreamChunk?
  private var lastRendering: String?

  /// - Parameter full: Print the whole snapshot on every line, rather than only the event
  ///   being written. Every update is a whole snapshot either way; this only affects printing.
  public init(full: Bool = false, colored: Bool = isatty(STDOUT_FILENO) != 0) {
    self.full = full
    self.colored = colored
  }

  /// Notes the chunk that the next update belongs to. The parser emits exactly one update per
  /// input chunk, in order, so pairing them needs no bookkeeping beyond "the latest one".
  public func received(_ chunk: StreamChunk) {
    self.pendingChunk = chunk
    self.elapsed += chunk.delay
    self.byteCount += chunk.bytes.count
  }

  public func parsed(_ update: PartialUpdate<Extraction.Partial>) {
    let rendering = self.full ? update.value.rendering : update.value.tailRendering
    let changed = rendering != self.lastRendering
    self.lastRendering = rendering

    if update.isComplete {
      // The final update follows the end of input rather than a chunk: the document validated.
      print(self.paint("done   \(self.time)  end of input      ", .bold) + " " + rendering)
      return
    }
    self.index += 1
    if changed { self.changedCount += 1 }
    let chunk = Self.column(Self.literal(self.pendingChunk?.bytes ?? []), width: 18)
    let prefix = "#\(Self.padded(String(self.index), 4))  \(self.time)  \(chunk)"
    // Whitespace and structural tokens do not change the value; those lines are dimmed.
    print(self.paint(prefix, changed ? .plain : .dim) + " " + self.paint(rendering, changed ? .plain : .dim))
  }

  public func summarize(_ partial: Extraction.Partial) {
    print()
    print(
      self.paint(
        "\(self.index) chunks, \(self.byteCount) bytes, \(self.changedCount) value changes in \(self.time.trimmingCharacters(in: .whitespaces))",
        .bold
      )
    )
    guard let extraction = Extraction(streamPartial: partial) else {
      print("The stream ended before every field of `Extraction` was present.")
      return
    }
    for event in extraction.events {
      let attendees = event.attendees.isEmpty ? "nobody listed" : event.attendees.joined(separator: ", ")
      print("  • \(event.title) — \(event.date) — \(attendees)")
    }
  }

  private var time: String {
    let components = self.elapsed.components
    let milliseconds = components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
    return Self.padded("+\(milliseconds)", 6) + "ms"
  }
}

extension UpdateLog {
  private enum Style { case plain, dim, bold }

  private func paint(_ text: String, _ style: Style) -> String {
    guard self.colored else { return text }
    switch style {
    case .plain: return text
    case .dim: return "\u{1B}[2m\(text)\u{1B}[0m"
    case .bold: return "\u{1B}[1m\(text)\u{1B}[0m"
    }
  }

  private static func padded(_ digits: String, _ width: Int) -> String {
    return String(repeating: " ", count: max(0, width - digits.count)) + digits
  }

  private static func column(_ text: String, width: Int) -> String {
    text + String(repeating: " ", count: max(0, width - text.count))
  }

  /// The chunk as a quoted literal. A chunk that stops inside a UTF-8 scalar is shown as hex,
  /// since there is no text to show yet; the parser takes those bytes all the same.
  private static func literal(_ bytes: [UInt8]) -> String {
    guard let text = String(validating: bytes, as: UTF8.self) else {
      return "<" + bytes.map { String($0, radix: 16) }.joined(separator: " ") + ">"
    }
    return "\"" + text.replacing("\n", with: "\\n").replacing("\t", with: "\\t") + "\""
  }
}

// MARK: - Rendering

extension Extraction.Partial {
  /// A compact description of exactly what has been parsed so far; `_` marks an absent field.
  var rendering: String {
    "{events: \(self.events.map { "[" + $0.map(\.rendering).joined(separator: ", ") + "]" } ?? "_")}"
  }
}

extension Extraction.Partial {
  /// Only the event currently being written, which is where every change lands.
  var tailRendering: String {
    guard let events = self.events else { return "events: _" }
    guard let last = events.last else { return "events: []" }
    return "events[\(events.count - 1)]: \(last.rendering)"
  }
}

extension Event.Partial {
  var rendering: String {
    let attendees = self.attendees.map { "[" + $0.map(\.rendering).joined(separator: ", ") + "]" }
    return "{title: \(self.title?.rendering ?? "_"), date: \(self.date?.rendering ?? "_"), "
      + "attendees: \(attendees ?? "_")}"
  }
}

extension StreamString {
  var rendering: String { "\"" + String(self) + "\"" }
}
