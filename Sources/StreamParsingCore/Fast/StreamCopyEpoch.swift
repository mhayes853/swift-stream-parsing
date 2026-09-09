import StreamParsingShims

// Where the snapshot guarantee is enforced once the open element lives inside the storage.
//
// The parser writes into its containers' blocks through raw pointers. A copy of any value that
// holds those blocks -- a `StreamArray` or `StreamDictionary` read out of a view, the whole value
// read through `PartialsStream.current` -- shares them, and a write through the old pointer would
// change the copy. Copies can only be taken between parse calls, so the parser needs to know, at
// the start of a parse call, whether one was taken since the last. A process-wide epoch answers
// that: every such copy bumps it, and `PartialsStream` compares it against the value it saw last
// time and has the sink re-point its frames (`PartialSink.reseat()`) when it moved.
//
// Process-wide rather than per stream because a view cannot reach its stream: it is a raw pointer
// into the value. The cost of the indirection is a spurious re-point when a copy was taken from
// some other stream, which is O(depth) and rare.

/// Records that a value which may share the parser's storage was copied out of a view.
///
/// Called by the container views' `value` accessors and by `PartialsStream.current`. A
/// hand-written ``StreamParseableRoot/View`` that hands out a copy of a `StreamArray` or
/// `StreamDictionary` it reads through a pointer must call this too.
@inlinable
@inline(__always)
public func _streamValueCopied() {
  stream_parsing_copy_epoch_bump()
}

@inlinable
@inline(__always)
public func _streamCopyEpoch() -> UInt64 {
  stream_parsing_copy_epoch_load()
}

// MARK: - Copy-initialising from a template

/// Copy-initialises `slot` from `template`: one `initializeWithCopy` and nothing else.
///
/// Two spellings exist and neither is right for every size. `initialize(from:count:)` is
/// `swift_arrayInitWithCopy`, a runtime call that consults the element's metadata before
/// reaching the copy witness -- on a document of thousands of small elements that detour was 7%
/// of the parse. `initialize(to: template.pointee)` specialises to the witness, but for a large
/// fixed-size struct the compiler treats the value as loadable and stages it on the stack: three
/// 6.6 KB memcpys per tweet, where one was asked for. The threshold folds per type.
@inlinable
@inline(__always)
public func _streamCopyInitialize<T>(_ slot: UnsafeMutablePointer<T>, from template: UnsafePointer<T>) {
  if MemoryLayout<T>.size > 1024 {
    slot.initialize(from: template, count: 1)
  } else {
    slot.initialize(to: template.pointee)
  }
}
