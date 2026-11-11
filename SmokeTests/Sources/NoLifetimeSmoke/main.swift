import StreamParsing

@StreamParseable
struct SmokePayload {
  var value: String = ""
}

// In a `do` block: top-level variables in `main.swift` are globals, and a global cannot be
// consumed, which `finish()` does.
do {
  var stream = PartialsStream<SmokePayload.Partial>(from: .json())
  try stream.next(#"{"value":"ready"}"#.utf8)
  precondition(unsafe stream.withView { unsafe $0.value?.value } == "ready")
  let value = SmokePayload(streamPartial: try stream.finish())
  precondition(value?.value == "ready")
}
