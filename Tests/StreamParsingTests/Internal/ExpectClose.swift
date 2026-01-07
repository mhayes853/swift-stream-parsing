import Testing

func expectClose(
  _ actual: Double,
  _ expected: Double,
  epsilon: Double = 1e-12,
  fileID: String = #fileID,
  filePath: String = #filePath,
  column: Int = #column,
  line: Int = #line
) {
  let delta = (actual - expected).magnitude
  #expect(
    delta <= epsilon,
    Comment(rawValue: "Expected: \(expected), Actual: \(actual)"),
    sourceLocation: SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
  )
}
