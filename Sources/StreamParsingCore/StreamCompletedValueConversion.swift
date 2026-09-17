// Completion records are used only by converted containers. Source frames retain their usual
// layout and routes; the source schema is owned by these hooks and by the wrapper schema.
@usableFromInline
struct _StreamCompletedValueHooks: Sendable {
  @usableFromInline let source: StreamSchema
  @usableFromInline let begin: @Sendable (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer
  @usableFromInline let finish: @Sendable (UnsafeMutableRawPointer) -> StreamApplyResult
}

@usableFromInline
struct _StreamPendingCompletedValue {
  @usableFromInline let depth: Int
  @usableFromInline let storage: UnsafeMutableRawPointer
  @usableFromInline let hooks: _StreamCompletedValueHooks

  @usableFromInline
  init(depth: Int, storage: UnsafeMutableRawPointer, hooks: _StreamCompletedValueHooks) {
    self.depth = depth
    self.storage = storage
    self.hooks = hooks
  }
}

#if !hasFeature(Embedded)
  /// Converts a completed source representation to a model value, and a model value back to
  /// its source representation. Unlike `StreamStringConvertible`, conversion is not incremental.
  ///
  /// Use `@StreamParseableMember(completedConversion: Strategy.self)` on a model member.
  /// `convertToValue` runs once per completed occurrence; later snapshots and document EOF
  /// reuse the cached result. `convertFromValue` is used by the model's `streamPartialValue`.
  public protocol StreamCompletedValueConversion: SendableMetatype {
    associatedtype Source: StreamParseableRoot & Sendable
    associatedtype Value: Sendable

    /// Validates and converts a completed, non-null source value.
    /// - Parameter source: A borrowed view of the parsed source; it cannot escape this call.
    /// - Returns: The value cached in the partial and used when constructing the model.
    /// - Throws: A strategy-defined error if the completed source is invalid. Parsing reports
    ///   `StreamSinkFailure.Reason.conversionFailed`; the partial retains `conversionError`.
    static func convertToValue(_ source: borrowing Source.View) throws -> Value

    /// Reconstructs a source representation without invoking `convertToValue`.
    /// - Parameter value: A model value being converted into its partial representation.
    /// - Returns: A valid, completed source that converts back to a semantically equivalent value.
    ///   Its spelling need not match the original input. This operation must not fail.
    static func convertFromValue(_ value: Value) -> Source
  }

  /// Incremental source storage and a cached completed conversion.
  ///
  /// ```swift
  /// // For a member annotated with completedConversion:
  /// let received = partial.createdAt?.source
  /// let converted = partial.createdAt?.value // nil until its source value completes
  /// ```
  /// Missing/null remain outside this wrapper. A repeated key resets both source and result.
  public struct ConvertedPartial<Strategy: StreamCompletedValueConversion>:
    StreamParseableRoot, StreamContainerPartial, Sendable
  {
    public private(set) var source: Strategy.Source
    public private(set) var value: Strategy.Value?
    public private(set) var conversionError: (any Error)?
    private var stringActive = false

    public init() {
      self.source = Strategy.Source.streamInitialValue()
    }

    /// Builds a completed partial from a model value, calling only `convertFromValue`.
    public init(value: Strategy.Value) {
      self.source = Strategy.convertFromValue(value)
      self.value = value
    }

    public static func streamInitialValue() -> Self { Self() }

    public struct View: ~Copyable, ~Escapable {
      private let storage: UnsafeMutablePointer<ConvertedPartial>

      @_lifetime(borrow storage)
      fileprivate init(_ storage: UnsafeMutableRawPointer) {
        self.storage = storage.assumingMemoryBound(to: ConvertedPartial.self)
      }

      public var source: Strategy.Source.View {
        @_lifetime(borrow self)
        get {
          _overrideLifetime(
            Strategy.Source.streamView(sourceAddress(self.storage)),
            borrowing: self
          )
        }
      }

      public var value: Strategy.Value? { self.storage.pointee.value }
      public var conversionError: (any Error)? { self.storage.pointee.conversionError }
    }

    @_lifetime(borrow storage)
    public static func streamView(_ storage: UnsafeMutableRawPointer) -> View { View(storage) }

    private static func sourceAddress(_ storage: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer
    {
      sourceAddress(storage.assumingMemoryBound(to: Self.self))
    }

    private static func sourceAddress(_ storage: UnsafeMutablePointer<Self>)
      -> UnsafeMutableRawPointer
    {
      withUnsafeMutablePointer(to: &storage.pointee.source) { UnsafeMutableRawPointer($0) }
    }

    private mutating func resetSource() {
      self.source = Strategy.Source.streamInitialValue()
      self.value = nil
      self.conversionError = nil
      self.stringActive = false
    }

    private mutating func complete() -> StreamApplyResult {
      do {
        self.value = try withUnsafeMutablePointer(to: &self.source) {
          try Strategy.convertToValue(Strategy.Source.streamView(UnsafeMutableRawPointer($0)))
        }
        return .applied
      } catch {
        self.conversionError = error
        return .conversionFailed
      }
    }

    public static var streamSchema: StreamSchema {
      _streamCachedSchema(for: Self.self) {
        let source = Strategy.Source.streamSchema
        return StreamSchema(
          shape: source.shape,
          applyString: { storage, _, bytes in
            guard source.shape == .scalar else { return .unsupported }
            let p = storage.assumingMemoryBound(to: Self.self)
            if !p.pointee.stringActive {
              p.pointee.resetSource()
              p.pointee.stringActive = true
            }
            return source.applyString(
              Self.sourceAddress(storage),
              StreamSchema.wholeValueField,
              bytes
            )
          },
          applyNumber: { storage, _, bytes, info in
            guard source.shape == .scalar else { return .unsupported }
            let p = storage.assumingMemoryBound(to: Self.self)
            p.pointee.resetSource()
            let result = source.applyNumber(
              Self.sourceAddress(storage),
              StreamSchema.wholeValueField,
              bytes,
              info
            )
            return result == .applied ? p.pointee.complete() : result
          },
          applyBoolean: { storage, _, value in
            guard source.shape == .scalar else { return .unsupported }
            let p = storage.assumingMemoryBound(to: Self.self)
            p.pointee.resetSource()
            let result = source.applyBoolean(
              Self.sourceAddress(storage),
              StreamSchema.wholeValueField,
              value
            )
            return result == .applied ? p.pointee.complete() : result
          },
          finishString: { storage, _ in
            let p = storage.assumingMemoryBound(to: Self.self)
            p.pointee.stringActive = false
            let result =
              source.finishString?(Self.sourceAddress(storage), StreamSchema.wholeValueField)
              ?? .applied
            return result == .applied ? p.pointee.complete() : result
          },
          completedValue: source.shape == .scalar
            ? nil
            : _StreamCompletedValueHooks(
              source: source,
              begin: { storage in
                storage.assumingMemoryBound(to: Self.self).pointee.resetSource()
                let address = Self.sourceAddress(storage)
                source.prepareRoot(address)
                return address
              },
              finish: { storage in storage.assumingMemoryBound(to: Self.self).pointee.complete() }
            )
        )
      }
    }
  }

#endif
