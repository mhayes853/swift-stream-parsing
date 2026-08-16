import Benchmark
import StreamParsing
import StreamParsingCore

// Real datasets, not shapes chosen to isolate a code path.
//
// `twitter.json` was the only one of these for a long time, and it is the friendly member of its
// corpus. The rest of `yyjson_benchmark`'s set is here now because each covers something the
// synthetic payloads only approximate, and because it is the corpus every comparable parser
// publishes against, so these numbers can be read next to somebody else's.
//
//   canada           float-heavy geometry, ~2.1 MB — coordinate pairs and almost nothing else
//   citm_catalog     deep nesting and heavily repeated keys, ~1.6 MB
//   gsoc-2018        large with long string values, ~3.2 MB
//   twitterescaped   the same document as twitter with every non-ASCII byte as a \u escape
//   github_events    a small API response, ~64 KB
//   llm_message      an assistant message: long escaped markdown, tool-use objects, small ints
//
// Three of these are larger than any cache level the parse runs in, which nothing else in the
// suite was. Each carries an `unchecked` row, because validation's share is the whole reason the
// configuration exists and a real document is where that share is worth knowing.

private let realWorldPayloads: [(String, [UInt8])] = [
  ("Twitter", Payloads.twitter),
  ("Twitter escaped", Payloads.twitterEscaped),
  ("Canada", Payloads.canada),
  ("CITM catalog", Payloads.citmCatalog),
  ("GSoC 2018", Payloads.gsoc2018),
  ("GitHub events", Payloads.githubEvents),
  ("LLM message", Payloads.llmMessage),
]

func realWorldBenchmarks() {
  for (name, payload) in realWorldPayloads {
    Benchmark("Real \(name) - bulk", configuration: payloadConfiguration) { benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(expectParses { try runFastParser(payload, chunk: .max) })
      }
    }

    Benchmark("Real \(name) - bulk unchecked", configuration: payloadConfiguration) { benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(expectParses { try runFastParser(payload, chunk: .max, configuration: .unchecked) })
      }
    }

    // 16 KB is a TLS record, which is the granularity a document this size actually arrives at.
    Benchmark("Real \(name) - 16KB chunks", configuration: payloadConfiguration) { benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(expectParses { try runFastParser(payload, chunk: 16_384) })
      }
    }
  }

  // Byte by byte on the two documents whose content is hardest for the resume path — every
  // non-ASCII byte in `twitterescaped` arrives as a six byte `\u` escape — rather than on all
  // seven, where it would measure the same per-byte state machine seven times.
  for (name, payload) in [
    ("Twitter escaped", Payloads.twitterEscaped),
    ("LLM message", Payloads.llmMessage)
  ] {
    Benchmark("Real \(name) - byte by byte", configuration: payloadConfiguration) { benchmark in
      measurePayloadThroughput(benchmark, payload: payload) {
        blackHole(expectParses { try runFastParserByteAtATime(payload) })
      }
    }
  }

  // Through the convenience layer, at the chunk sizes a network read actually delivers: an MTU
  // sized read, a TLS record, and a 64 KB socket buffer. The existing chunk sweep is all powers
  // of two from 16 B, none of which is a size a socket hands over.
  for chunk in [1_400, 16_384, 65_536] {
    Benchmark(
      "Real LLM message - view read per \(chunk)B chunk",
      configuration: payloadConfiguration
    ) { benchmark in
      measurePayloadThroughput(benchmark, payload: Payloads.llmMessage) {
        blackHole(
          expectParses {
            try streamViewingChunks(
              Payloads.llmMessage,
              chunk: chunk,
              as: BenchmarkLLMMessage.Partial.self
            ) { blackHole($0.stop_reason) }
          }
        )
      }
    }

    Benchmark(
      "Real LLM message - snapshot per \(chunk)B chunk",
      configuration: payloadConfiguration
    ) { benchmark in
      measurePayloadThroughput(benchmark, payload: Payloads.llmMessage) {
        blackHole(
          expectParses {
            try streamSnapshottingChunks(
              Payloads.llmMessage,
              chunk: chunk,
              as: BenchmarkLLMMessage.Partial.self
            )
          }
        )
      }
    }
  }

  Benchmark("Real LLM message - bulk discarding", configuration: payloadConfiguration) { benchmark in
    measurePayloadThroughput(benchmark, payload: Payloads.llmMessage) {
      blackHole(
        expectParses {
          try streamBulkDiscarding(Payloads.llmMessage, as: BenchmarkLLMMessage.Partial.self)
        }
      )
    }
  }

  // The convenience layer with validation off, which is the combination a client that trusts its
  // own server would ship.
  Benchmark(
    "Real LLM message - bulk discarding unchecked",
    configuration: payloadConfiguration
  ) { benchmark in
    measurePayloadThroughput(benchmark, payload: Payloads.llmMessage) {
      blackHole(
        expectParses {
          try streamBulkDiscarding(
            Payloads.llmMessage,
            as: BenchmarkLLMMessage.Partial.self,
            format: .json(configuration: .unchecked)
          )
        }
      )
    }
  }

  Benchmark("Real Twitter - discarding", configuration: payloadConfiguration) { benchmark in
    measurePayloadThroughput(benchmark, payload: Payloads.twitter) {
      blackHole(
        expectParses { try streamDiscarding(Payloads.twitter, as: BenchmarkTwitter.Partial.self) }
      )
    }
  }

  Benchmark("Real Twitter - bulk discarding", configuration: payloadConfiguration) { benchmark in
    measurePayloadThroughput(benchmark, payload: Payloads.twitter) {
      blackHole(
        expectParses {
          try streamBulkDiscarding(Payloads.twitter, as: BenchmarkTwitter.Partial.self)
        }
      )
    }
  }

  // `BenchmarkTwitter` declares `screenName` and `followersCount`, which never match the payload's
  // snake_case keys, so it measures more of the discard path than it appears to. This variant
  // declares the keys the payload contains, keeping the write path measured alongside it.
  Benchmark(
    "Real Twitter - bulk discarding, matched keys",
    configuration: payloadConfiguration
  ) { benchmark in
    measurePayloadThroughput(benchmark, payload: Payloads.twitter) {
      blackHole(
        expectParses {
          try streamBulkDiscarding(Payloads.twitter, as: BenchmarkTwitterMatched.Partial.self)
        }
      )
    }
  }
}
