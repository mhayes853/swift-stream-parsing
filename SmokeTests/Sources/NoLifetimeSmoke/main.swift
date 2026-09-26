import StreamParsing

@StreamParseable
struct SmokePayload {
  var value: String = ""
}

var stream = PartialsStream<SmokePayload.Partial>(from: .json())
try stream.next(#"{"value":"ready"}"#.utf8)
precondition(unsafe stream.withView { unsafe $0.value?.value } == "ready")
let value = SmokePayload(streamPartial: try stream.finish())
precondition(value?.value == "ready")
