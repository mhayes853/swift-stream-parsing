import CustomDump
import Foundation
import StreamParsing
import StreamParsingCore
import Testing

// MARK: - 3. Streaming semantics
//
// What a consumer sees *before* the document ends -- the reason the library exists. A partial must
// be a faithful, monotone picture of the bytes so far: nothing invented, nothing retracted, and
// nothing a later byte can reach back and change in a snapshot already handed out.

@StreamParseable
struct StreamProfile: Equatable {
  var id: Int
  var name: String
  var isActive: Bool
}

extension StreamProfile.Partial: Equatable {}

@Suite
struct `Streaming semantics` {
  // SS-1
  // The headline behaviour from the README, pinned exactly: one partial per byte, a string visible
  // from its opening quote and extended on every content byte, a number and a literal only once
  // their token is whole, and a final completion partial.
  @Test
  func `A small object streams the documented partial after every byte`() throws {
    let json = #"{"id":4,"name":"Blob","isActive":true}"#
    let partials = try json.utf8.partials(of: StreamProfile.self, from: .json())
    typealias P = StreamProfile.Partial
    let expected: [P] =
      Array(repeating: P(), count: 7)  // {"id":4
      + [P(id: 4)]  // , -- the number's token ends here
      + Array(repeating: P(id: 4), count: 7)  // "name":
      + [P(id: 4, name: "")]  // opening quote
      + ["B", "Bl", "Blo", "Blob"].map { P(id: 4, name: StreamString($0)) }
      + Array(repeating: P(id: 4, name: "Blob"), count: 16)  // closing quote ,"isActive":tru
      + Array(repeating: P(id: 4, name: "Blob", isActive: true), count: 3)  // e, }, completion
    #expect(partials.count == json.utf8.count + 1)
    expectNoDifference(partials, expected)
  }

  // SS-2
  // Snapshots are values: taking one mid-stream and then parsing on must not alter it, and what
  // it holds must be exactly what a fresh stream given the same prefix holds -- the state is a
  // function of the bytes so far, not of how they were chunked or what came after.
  @Test(arguments: [Corpus.twitter, .citmCatalog, .githubEvents])
  func `A mid-stream snapshot equals a fresh parse of the same prefix and never changes`(
    corpus: Corpus
  ) throws {
    func check<Model: StreamParseable>(_ type: Model.Type) throws where Model.Partial: Equatable {
      let bytes = try corpus.bytes
      let ranges = Chunking.variable(seed: 21, maximum: 4096).ranges(count: bytes.count)
      let every = max(1, ranges.count / 12)
      var stream = PartialsStream<Model>(from: .json())
      var snapshots = [(end: Int, value: Model.Partial)]()
      for (index, range) in ranges.enumerated() {
        try stream.next(bytes[range])
        if index % every == 0 { snapshots.append((range.upperBound, stream.current)) }
      }
      _ = try stream.finishPartial()
      #expect(snapshots.count >= 10)
      for snapshot in snapshots {
        var fresh = PartialsStream<Model>(from: .json())
        try fresh.next(bytes[..<snapshot.end])
        if fresh.current != snapshot.value {
          Issue.record(
            "snapshot at \(snapshot.end):\n\(diff(snapshot.value, fresh.current) ?? "")"
          )
        }
      }
    }
    try onLargeStack {
      switch corpus {
      case .citmCatalog: try check(CorpusCITM.self)
      case .githubEvents: try check([CorpusGitHubEvent].self)
      default: try check(CorpusTwitterFull.self)
      }
    }
  }

  // SS-3
  // A streamed string only ever grows by appending, an array only ever grows by appending, and a
  // number is either absent or final: the rules that let a UI render a partial without flicker or
  // show a value that later gets taken back. On a real assistant message with 636 content blocks.
  @Test
  func `Streamed strings and arrays only grow, and numbers appear only once final`() throws {
    let bytes = try Corpus.llmMessage.bytes
    let final = try foundationValue(.llmMessage, as: CorpusLLMMessage.self)
    let finalTexts = final.content.map { $0.text ?? "" }
    var stream = PartialsStream<CorpusLLMMessage>(from: .json())
    var previous = [String]()
    var growths = 0
    for range in Chunking.fixed(8192).ranges(count: bytes.count) {
      try stream.next(bytes[range])
      let partial = stream.current
      let content = partial.content ?? StreamArray()
      #expect(content.count >= previous.count, "the content array lost elements")
      // Blocks before the last one seen are closed; the last one and any new ones may have moved.
      var texts = previous
      for index in max(0, previous.count - 1)..<content.count {
        let text = content[index].text.map(String.init) ?? ""
        if index < previous.count {
          #expect(text.hasPrefix(previous[index]), "block \(index) retracted bytes")
          if text.utf8.count > previous[index].utf8.count { growths += 1 }
          texts[index] = text
        } else {
          texts.append(text)
        }
        #expect(finalTexts[index].hasPrefix(text), "block \(index) holds bytes the document lacks")
      }
      previous = texts
      if let tokens = partial.usage?.output_tokens {
        #expect(tokens == final.usage.output_tokens, "a number was visible before its token ended")
      }
    }
    #expect(growths > 10)
    #expect(previous == finalTexts)
  }

  // SS-4
  // Byte by byte through every token kind, including an escape and a multi-byte scalar: nothing
  // half-formed is ever visible.
  @Test
  func `Nothing half-formed is ever visible`() throws {
    let json = #"{"id":-1234,"name":"Blöb 😀 café","isActive":false}"#
    var stream = PartialsStream<StreamProfile>(from: .json())
    let expectedName = "Blöb 😀 café"
    for byte in json.utf8 {
      try stream.next(byte)
      let partial = stream.current
      if let id = partial.id { #expect(id == -1234) }
      if let active = partial.isActive { #expect(active == false) }
      if let name = partial.name {
        let text = String(name)
        #expect(expectedName.hasPrefix(text), "\(text.debugDescription)")
        #expect(!text.unicodeScalars.contains("\u{FFFD}"))
      }
    }
    let final = try stream.finishPartial()
    expectNoDifference(final, StreamProfile.Partial(id: -1234, name: "Blöb 😀 café", isActive: false))
  }

  // SS-5
  // Field observation on a real document: the member sits `missing` through a megabyte of content
  // that precedes it, then moves forward through its states and never back, and the final update
  // is the only one that claims document completion.
  @Test
  func `Field observation moves forward only, from missing to complete`() throws {
    let bytes = try Corpus.llmMessage.bytes
    let chunks = Chunking.variable(seed: 13, maximum: 256).ranges(count: bytes.count)
      .map { bytes[$0] }
    var iterator = try chunks.partialIterator(of: CorpusLLMMessage.self, from: .json())
      .observeField(\.stop_reason).removeDuplicateUpdates()
    var states = [PartialUpdate<ObservedField<StreamString>>]()
    while let update = try iterator.next() { states.append(update) }

    func rank(_ field: ObservedField<StreamString>) -> Int {
      switch field {
      case .missing: 0
      case .null: 3
      case .incomplete: 1
      case .complete: 2
      }
    }
    #expect(states.first?.value == .missing)
    #expect(zip(states, states.dropFirst()).allSatisfy { rank($0.value) <= rank($1.value) })
    #expect(states.dropLast().allSatisfy { !$0.isComplete })
    #expect(states.last == PartialUpdate(value: .complete("end_turn"), isComplete: true))
  }

  // SS-6
  // A view reads the stream's storage in place; it must agree with the copying snapshot at every
  // point, not only at the end.
  @Test
  func `A zero-copy view agrees with the snapshot at every point`() throws {
    let bytes = try Corpus.llmMessage.bytes
    var stream = PartialsStream<CorpusLLMMessage>(from: .json())
    var checks = 0
    for range in Chunking.variable(seed: 17, maximum: 65_536).ranges(count: bytes.count) {
      try stream.next(bytes[range])
      let snapshot = stream.current
      stream.withView { view in
        #expect(view.id?.value == snapshot.id)
        #expect(view.model?.value == snapshot.model)
        // Bind the nested view before reading through it: `view.usage?.input_tokens?.value`
        // borrows a temporary `usage` view that optional chaining ends before the leaf is read,
        // which the compiler rejects as a lifetime-dependent value escaping its scope.
        switch view.usage {
        case .some(let usage):
          #expect(usage.input_tokens?.value == snapshot.usage?.input_tokens)
          #expect(usage.output_tokens?.value == snapshot.usage?.output_tokens)
        case .none:
          #expect(snapshot.usage == nil)
        }
        #expect(view.content?.value.count == snapshot.content?.count)
      }
      checks += 1
    }
    #expect(checks > 10)
  }
}
