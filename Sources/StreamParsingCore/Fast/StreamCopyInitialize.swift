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
