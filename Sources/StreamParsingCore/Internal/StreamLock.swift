#if !hasFeature(Embedded)
  #if canImport(Synchronization)
    import Synchronization
  #endif
  #if canImport(Darwin)
    import Darwin
  #elseif canImport(Glibc)
    import Glibc
  #elseif canImport(Musl)
    import Musl
  #elseif canImport(Android)
    import Android
  #elseif canImport(WASILibc)
    import WASILibc
  #elseif canImport(WinSDK)
    import WinSDK
  #endif

  #if canImport(Synchronization) && !canImport(Darwin)
    /// Synchronously protects a value on platforms where `Synchronization.Mutex` is available.
    ///
    /// This path intentionally includes WASI. A WASI threads SDK supplies `Synchronization`,
    /// whose `Mutex` uses the runtime's thread-aware primitive; treating all WASI builds as
    /// single-threaded would make process-wide caches unsafe under shared-everything threads.
    final class _StreamLock<Value>: Sendable {
      private let storage: Mutex<Value>

      init(_ initialValue: consuming sending Value) {
        self.storage = Mutex(initialValue)
      }

      @inline(__always)
      func withLock<Result, Failure: Error>(
        _ body: (inout sending Value) throws(Failure) -> sending Result
      ) throws(Failure) -> sending Result {
        try self.storage.withLock(body)
      }
    }
  #elseif canImport(Darwin) && canImport(Synchronization)
    /// Synchronously protects a value on Apple platforms across the package's deployment range.
    ///
    /// New OS releases use `Synchronization.Mutex`. The package still supports releases older
    /// than that module's runtime availability, where it falls back to `os_unfair_lock`.
    final class _StreamLock<Value>: Sendable {
      private let storage: _StreamDarwinLockStorage<Value>

      init(_ initialValue: consuming sending Value) {
        if #available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *) {
          self.storage = _StreamDarwinMutexLockStorage(initialValue)
        } else {
          self.storage = _StreamDarwinUnfairLockStorage(initialValue)
        }
      }

      @inline(__always)
      func withLock<Result, Failure: Error>(
        _ body: (inout sending Value) throws(Failure) -> sending Result
      ) throws(Failure) -> sending Result {
        try self.storage.withLock(body)
      }
    }

    class _StreamDarwinLockStorage<Value>: @unchecked Sendable {
      func withLock<Result, Failure: Error>(
        _ body: (inout sending Value) throws(Failure) -> sending Result
      ) throws(Failure) -> sending Result {
        fatalError("abstract")
      }
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    final class _StreamDarwinMutexLockStorage<Value>: _StreamDarwinLockStorage<Value>,
      @unchecked Sendable
    {
      private let storage: Mutex<Value>

      init(_ initialValue: consuming sending Value) {
        self.storage = Mutex(initialValue)
      }

      @inline(__always)
      override func withLock<Result, Failure: Error>(
        _ body: (inout sending Value) throws(Failure) -> sending Result
      ) throws(Failure) -> sending Result {
        try self.storage.withLock(body)
      }
    }

    final class _StreamDarwinUnfairLockStorage<Value>: _StreamDarwinLockStorage<Value>,
      @unchecked Sendable
    {
      private var value: Value
      private let lock: UnsafeMutablePointer<os_unfair_lock>

      init(_ initialValue: consuming sending Value) {
        self.value = initialValue
        self.lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        self.lock.initialize(to: os_unfair_lock())
      }

      @inline(__always)
      override func withLock<Result, Failure: Error>(
        _ body: (inout sending Value) throws(Failure) -> sending Result
      ) throws(Failure) -> sending Result {
        os_unfair_lock_lock(self.lock)
        defer { os_unfair_lock_unlock(self.lock) }
        return try body(&self.value)
      }

      deinit {
        self.lock.deinitialize(count: 1)
        self.lock.deallocate()
      }
    }
  #else
    /// Compatibility implementation for toolchains that do not provide `Synchronization`.
    final class _StreamLock<Value>: @unchecked Sendable {
      private var value: Value

      #if canImport(WinSDK)
        private let lock: UnsafeMutablePointer<SRWLOCK>
      #else
        private let lock: UnsafeMutablePointer<pthread_mutex_t>
      #endif

      init(_ initialValue: consuming sending Value) {
        self.value = initialValue
        #if canImport(WinSDK)
          self.lock = UnsafeMutablePointer<SRWLOCK>.allocate(capacity: 1)
          InitializeSRWLock(self.lock)
        #else
          self.lock = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
          pthread_mutex_init(self.lock, nil)
        #endif
      }

      @inline(__always)
      func withLock<Result, Failure: Error>(
        _ body: (inout sending Value) throws(Failure) -> sending Result
      ) throws(Failure) -> sending Result {
        #if canImport(WinSDK)
          AcquireSRWLockExclusive(self.lock)
          defer { ReleaseSRWLockExclusive(self.lock) }
        #else
          pthread_mutex_lock(self.lock)
          defer { pthread_mutex_unlock(self.lock) }
        #endif
        return try body(&self.value)
      }

      deinit {
        #if !canImport(WinSDK)
          pthread_mutex_destroy(self.lock)
        #endif
        self.lock.deallocate()
      }
    }
  #endif
#endif
