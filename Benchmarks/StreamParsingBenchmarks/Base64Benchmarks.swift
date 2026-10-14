import Benchmark
import Foundation
import StreamParsing
import StreamParsingCore

// `StreamBase64Data` beside what a base64 member could otherwise be: a `StreamString` keeping the
// text (the parser and an append, no decoding -- the floor), and `JSONDecoder` reading `Data` with
// its default base64 strategy once the whole document has arrived. One 1 MiB attachment, so the
// decoder is nearly all of the work. `Data(base64Encoded:)` alone is Foundation's decoder with no
// JSON around it.

@StreamParseable
struct Base64Attachment {
  var name: String = ""
  var contents: StreamBase64Data = StreamBase64Data()
}

@StreamParseable
struct Base64TextAttachment {
  var name: String = ""
  var contents: StreamString = StreamString()
}

private struct CodableBase64Attachment: Decodable {
  var name: String
  var contents: Data
}

private enum Base64Payloads {
  // Every byte value, in no pattern the table lookups could exploit.
  static let decoded: [UInt8] = (0..<(1 << 20)).map {
    UInt8(truncatingIfNeeded: ($0 &* 2_654_435_761) >> 13)
  }
  static let text = Data(decoded).base64EncodedString()
  static let attachment = Array(#"{"name":"blob.bin","contents":"\#(text)"}"#.utf8)
  // 2,000 short values, 0 to 189 bytes each (95 on average): what a value's fixed costs, its
  // allocations and first growth, come to when the decoding is small.
  static let small: [[UInt8]] = (0..<2_000).map { index in
    Array(decoded[(index &* 523) % 4_096..<(index &* 523) % 4_096 + (index &* 37) % 190])
  }
  static let smallArray = Array(
    ("[" + small.map { #""\#(Data($0).base64EncodedString())""# }.joined(separator: ",") + "]").utf8
  )
}

func base64Benchmarks() {
  let payload = Base64Payloads.attachment
  // Validated once at registration, outside every measured region: a payload the decoder stopped
  // accepting would otherwise time a rejection.
  let parsed = expectParses { try streamBulkDiscarding(payload, as: Base64Attachment.self) }
  precondition(parsed.contents.map { Array($0.bytes) } == Base64Payloads.decoded)

  Benchmark("Base64 1MiB - StreamBase64Data bulk", configuration: payloadConfiguration) {
    benchmark in
    measurePayloadThroughput(benchmark, payload: payload) {
      blackHole(expectParses { try streamBulkDiscarding(payload, as: Base64Attachment.self) })
    }
  }

  Benchmark("Base64 1MiB - StreamBase64Data per 1400B", configuration: payloadConfiguration) {
    benchmark in
    measurePayloadThroughput(benchmark, payload: payload) {
      blackHole(
        expectParses {
          try streamDiscardingChunks(payload, chunk: 1_400, as: Base64Attachment.self)
        }
      )
    }
  }

  let smallArray = Base64Payloads.smallArray
  let parsedSmall = expectParses {
    try streamBulkDiscarding(smallArray, as: StreamArray<StreamBase64Data>.self)
  }
  precondition(parsedSmall.map { Array($0.bytes) } == Base64Payloads.small)

  Benchmark("Base64 2000 short - StreamBase64Data bulk", configuration: payloadConfiguration) {
    benchmark in
    measurePayloadThroughput(benchmark, payload: smallArray) {
      blackHole(
        expectParses {
          try streamBulkDiscarding(smallArray, as: StreamArray<StreamBase64Data>.self)
        }
      )
    }
  }

  Benchmark("Base64 1MiB - StreamString text bulk", configuration: payloadConfiguration) {
    benchmark in
    measurePayloadThroughput(benchmark, payload: payload) {
      blackHole(expectParses { try streamBulkDiscarding(payload, as: Base64TextAttachment.self) })
    }
  }

  let json = Data(payload)
  let decoder = JSONDecoder()
  Benchmark("Base64 1MiB - JSONDecoder Data", configuration: payloadConfiguration) { benchmark in
    measurePayloadThroughput(benchmark, payload: payload) {
      blackHole(expectParses { try decoder.decode(CodableBase64Attachment.self, from: json) })
    }
  }

  let text = Base64Payloads.text
  Benchmark("Base64 1MiB - Data(base64Encoded:)", configuration: payloadConfiguration) {
    benchmark in
    measurePayloadThroughput(benchmark, payload: payload) {
      blackHole(Data(base64Encoded: text)!)
    }
  }
}
