enum StreamActionReducerError: Error {
  case unsupportedAction(StreamAction)
  case typeMismatch(expected: String, actual: StreamedValue)
  case rawValueInitializationFailed(type: String, rawValue: String)
}
