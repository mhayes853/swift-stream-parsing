// Embedded Swift smoke test.
//
// This target does not depend on StreamParsingCore yet: the current core uses existentials,
// dynamic casts, metatypes and key paths, none of which Embedded Swift supports. It gains the
// dependency once the sink based core lands, at which point this file parses a small payload
// through the real parser and a hand written sink.
//
// Until then it exercises the primitives the new core is built from, so that the toolchain,
// SDK and link step are proven and wired into CI ahead of the rewrite.

/// Mirrors the run scanner the new core will use: find the next byte needing attention.
@inline(__always)
func scanStringRun(_ buffer: UnsafeBufferPointer<UInt8>, from: Int) -> Int {
  var i = from
  while i < buffer.count {
    let byte = buffer[i]
    if byte == 0x22 || byte == 0x5C || byte < 0x20 { return i }
    i += 1
  }
  return buffer.count
}

/// Mirrors the fused number scan: wrapping arithmetic plus a digit count check, rather than
/// per digit overflow checks.
@inline(__always)
func scanNumber(_ buffer: UnsafeBufferPointer<UInt8>, from: Int) -> (end: Int, magnitude: UInt64) {
  var i = from
  var magnitude: UInt64 = 0
  while i < buffer.count {
    let digit = buffer[i] &- 0x30
    if digit >= 10 { break }
    magnitude = magnitude &* 10 &+ UInt64(digit)
    i += 1
  }
  return (i, magnitude)
}

/// Mirrors the generated key matcher: zero padded leading word, no String, no hashing.
@inline(__always)
func paddedLeadingWord(_ buffer: UnsafeBufferPointer<UInt8>, from: Int, count: Int) -> UInt64 {
  var word: UInt64 = 0
  let limit = min(count, 8)
  for i in 0..<limit { word |= UInt64(buffer[from + i]) << (i * 8) }
  return word
}

@main
struct EmbeddedSmoke {
  static func main() {
    let payload: StaticString = #"{"id":4217,"name":"Blob"}"#

    payload.withUTF8Buffer { buffer in
      // Key at offset 2, length 2: "id"
      let idWord = paddedLeadingWord(buffer, from: 2, count: 2)
      precondition(idWord == 0x0000_0000_0000_6469)

      // Number starting at offset 6.
      let (numberEnd, magnitude) = scanNumber(buffer, from: 6)
      precondition(magnitude == 4217)
      precondition(numberEnd == 10)

      // String run starting after the opening quote of "Blob".
      let runEnd = scanStringRun(buffer, from: 20)
      precondition(runEnd == 23)
    }
  }
}
