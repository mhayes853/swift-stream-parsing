/// Copy-initialises `slot` from `template`: one `initializeWithCopy` and nothing else.
///
/// Measured: `initialize(from:count:)` is `swift_arrayInitWithCopy`, a runtime detour worth 7% on
/// CITM's small elements; `initialize(to:)` stages anything loadable on the stack, three 6.6 KB
/// memcpys per tweet. Keep the size split — the threshold folds per type.
@inlinable
@inline(__always)
public func _streamCopyInitialize<T>(_ slot: UnsafeMutablePointer<T>, from template: UnsafePointer<T>) {
  if MemoryLayout<T>.size > 1024 {
    slot.initialize(from: template, count: 1)
  } else {
    slot.initialize(to: template.pointee)
  }
}
