import Benchmark
import StreamParsingCore

// Isolates `String.streamAppend`, which the convenience layer measurements identified as the gap:
// an 8 KB string fed byte by byte costs ~61 ns per content byte with nothing else on the path.
//
// Unlike the key table and number strategy files, these candidates are not archaeology: the
// decision they support has not been applied. `String.streamAppend` still does
// `self += String(decoding:)` (`StandardLibrary.swift`), so the `streamAppend` row below *is* the
// production path, and the other two are the replacements it is still being measured against:
//
// - `streamAppend`: production. Validates UTF-8 the parser already validated and materializes an
//   intermediate `String` per chunk.
// - `unsafe init`: `String(unsafeUninitializedCapacity:)` + memcpy, skipping the redundant
//   validation walk (the initializer still repairs, but its ASCII fast path is a memcpy).
// - `byte buffer`: append to a `[UInt8]` and materialize the `String` once at the end — the floor
//   any accumulation redesign would be buying, measured without committing to one.
//
// When one of the latter two lands in `streamAppend`, delete it from here: the production row
// will then be measuring it, and keeping the loser turns this file into archaeology too.
//
// "Fresh" is the bulk shape: one token, one append, into an empty destination. "Accumulate" is
// the chunked and byte fed shape: one destination built from many appends.
@inline(__always)
private func streamAppend(_ value: inout String, _ buffer: UnsafeBufferPointer<UInt8>) {
  value.streamAppend(utf8: Span(_unsafeElements: buffer))
}

func stringAppendBenchmarks() {
  let name = Array("User Number 42".utf8)  // 14 bytes, inline small string
  let email = Array("user42@example-mail.com".utf8)  // 23 bytes, heap allocated

  for (label, token) in [("14B inline", name), ("23B heap", email)] {
    Benchmark("String fresh \(label) - streamAppend") { benchmark in
      token.withUnsafeBufferPointer { buffer in
        for _ in benchmark.scaledIterations {
          var value = ""
          streamAppend(&value, buffer)
          blackHole(value)
        }
      }
    }

    Benchmark("String fresh \(label) - unsafe init") { benchmark in
      token.withUnsafeBufferPointer { buffer in
        for _ in benchmark.scaledIterations {
          var value = ""
          value += String(unsafeUninitializedCapacity: buffer.count) { destination in
            _ = destination.initialize(fromContentsOf: buffer)
            return buffer.count
          }
          blackHole(value)
        }
      }
    }
  }

  let body = Array(repeating: UInt8(ascii: "a"), count: 8_192)

  for chunk in [1, 64, 4_096] {
    Benchmark("String accumulate 8KB by \(chunk)B - streamAppend") { benchmark in
      body.withUnsafeBufferPointer { buffer in
        for _ in benchmark.scaledIterations {
          var value = ""
          var offset = 0
          while offset < buffer.count {
            let slice = UnsafeBufferPointer(start: buffer.baseAddress! + offset, count: chunk)
            streamAppend(&value, slice)
            offset += chunk
          }
          blackHole(value)
        }
      }
    }

    Benchmark("String accumulate 8KB by \(chunk)B - unsafe init") { benchmark in
      body.withUnsafeBufferPointer { buffer in
        for _ in benchmark.scaledIterations {
          var value = ""
          var offset = 0
          while offset < buffer.count {
            let slice = UnsafeBufferPointer(start: buffer.baseAddress! + offset, count: chunk)
            value += String(unsafeUninitializedCapacity: chunk) { destination in
              _ = destination.initialize(fromContentsOf: slice)
              return chunk
            }
            offset += chunk
          }
          blackHole(value)
        }
      }
    }

    Benchmark("String accumulate 8KB by \(chunk)B - byte buffer") { benchmark in
      body.withUnsafeBufferPointer { buffer in
        for _ in benchmark.scaledIterations {
          var bytes = [UInt8]()
          var offset = 0
          while offset < buffer.count {
            let slice = UnsafeBufferPointer(start: buffer.baseAddress! + offset, count: chunk)
            bytes.append(contentsOf: slice)
            offset += chunk
          }
          blackHole(String(decoding: bytes, as: UTF8.self))
        }
      }
    }
  }
}
