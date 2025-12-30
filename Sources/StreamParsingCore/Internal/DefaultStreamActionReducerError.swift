enum DefaultStreamActionReducerError: Error {
  case unsupportedAction(DefaultStreamAction)
  case typeMismatch(expected: String, actual: StreamedValue)
  case rawValueInitializationFailed(type: String, rawValue: String)
}
