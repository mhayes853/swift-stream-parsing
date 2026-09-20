import StreamParsing

@StreamParseable
struct Metadata: Equatable {
  var active: Bool = false
}

@StreamParseable
struct SmokePayload: Equatable {
  var title: String = ""
  var count: Int = 0
  var tags: [String] = []
  var metadata: Metadata = Metadata()
}

let json = #"{"title":"ready","count":3,"tags":["macro","unsafe","view"],"metadata":{"active":true}}"#
var stream = PartialsStream<SmokePayload.Partial>(from: .json())
try stream.next(json.utf8)

// The default view is a pointer projection. Strict memory safety requires this acknowledgement;
// the caller guarantees the view is used only while the stream lends its storage here.
let observed = unsafe stream.withView { view in
  (
    title: unsafe view.title?.value,
    count: unsafe view.count?.value,
    tagCount: unsafe view.tags?.count,
    active: unsafe view.metadata?.active?.value
  )
}
precondition(observed.title == "ready")
precondition(observed.count == 3)
precondition(observed.tagCount == 3)
precondition(observed.active == true)

let partial = try stream.finish()
let value = SmokePayload(streamPartial: partial)
precondition(
  value
    == SmokePayload(
      title: "ready",
      count: 3,
      tags: ["macro", "unsafe", "view"],
      metadata: Metadata(active: true)
    )
)
