import CustomDump
import Testing

import StreamParsing

// A parser that emits one state per byte spends most of them emitting the state it emitted last:
// across these tests, 82% of the entries repeated their predecessor. Written out in full, a
// thirty nine byte document produced a single 3,370 character line, which said almost nothing.
//
// A run is a state and the number of consecutive positions that hold it, so what the expectation
// shows is where the value changes. The counts must cover every byte plus one for `finish()`,
// which `expectStates` checks: a run list that does not add up is an expectation that drifted,
// not a shorter document.
struct StreamedRun<Value> {
  var value: Value
  var count: Int

  static func run(_ value: Value, _ count: Int = 1) -> Self {
    Self(value: value, count: count)
  }
}

extension Array {
  func expandedStates<Value>() -> [Value] where Element == StreamedRun<Value> {
    var states = [Value]()
    states.reserveCapacity(self.reduce(0) { $0 + $1.count })
    for run in self {
      for _ in 0..<run.count { states.append(run.value) }
    }
    return states
  }
}

// Reports the byte a mismatch happened at rather than only the index, because the index alone
// does not say which token was being read.
func expectStates<Value: Equatable>(
  _ actual: [Value],
  _ runs: [StreamedRun<Value>],
  json: String,
  fileID: StaticString = #fileID,
  filePath: StaticString = #filePath,
  line: UInt = #line,
  column: UInt = #column
) {
  let bytes = Array(json.utf8)
  let expected = runs.expandedStates()
  let sourceLocation = SourceLocation(
    fileID: "\(fileID)", filePath: "\(filePath)", line: Int(line), column: Int(column)
  )

  guard expected.count == bytes.count + 1 else {
    Issue.record(
      """
      The runs cover \(expected.count) states, but \(bytes.count) bytes plus finish() is \
      \(bytes.count + 1).
      """,
      sourceLocation: sourceLocation
    )
    return
  }

  guard actual.count == expected.count else {
    Issue.record(
      "Parsed \(actual.count) states rather than \(expected.count).",
      sourceLocation: sourceLocation
    )
    return
  }

  for index in actual.indices where actual[index] != expected[index] {
    let position =
      index == bytes.count
      ? "finish()"
      : "byte \(index), '\(Character(UnicodeScalar(bytes[index])))'"
    Issue.record(
      """
      States diverged at \(position).
      \(diff(actual[index], expected[index]) ?? "expected \(expected[index]), got \(actual[index])")
      """,
      sourceLocation: sourceLocation
    )
    return
  }
}
