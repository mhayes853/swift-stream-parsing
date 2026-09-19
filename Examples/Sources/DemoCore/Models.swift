import StreamParsing

/// What the model is asked to produce: every calendar event mentioned in a message.
@StreamParseable
public struct Extraction: Sendable {
  public var events: [Event]
}

@StreamParseable
public struct Event: Sendable {
  public var title: String
  public var date: String
  public var attendees: [String]
}
