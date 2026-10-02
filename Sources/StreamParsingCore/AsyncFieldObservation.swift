#if !hasFeature(Embedded)
  extension AsyncPartialsSequence {
    /// Observes an optional stored field, distinguishing missing, null, incomplete, and complete.
    ///
    /// ```swift
    /// @StreamParseable struct Response { var title: String? = nil }
    /// let titles = try chunks.partials(of: Response.self, from: .json())
    ///   .observeField(\.title)
    /// for try await update in titles {
    ///   print(update.value)      // ObservedField<StreamString>
    ///   print(update.isComplete) // True only after successful document finalization.
    /// }
    /// ```
    ///
    /// - Parameter path: A direct stored member of the partial root, registered in its schema
    ///   and `streamObservationFields`. The macro registers partial fields automatically.
    /// - Returns: A sequence of `PartialUpdate<ObservedField<Field>>` snapshots, one per input
    ///   element and one final update at EOF. It shares this source's single subscription.
    /// - Throws: `FieldObservationError.unsupportedField` if the path is unsupported, including
    ///   computed, nested, ignored, or ambiguously overlapping fields. Iteration can separately
    ///   throw upstream, parsing, subscription, or field-value errors.
    public func observeField<Field: StreamParseableRoot>(
      _ path: KeyPath<Element, Field?>
    ) throws -> AsyncFieldObservationSequence<Element, Base, Seq, Field> {
      self.observeField(try ObservedFieldPath(path))
    }

    /// Observes a nonoptional stored field, including fields initialized by the partial-member mode.
    ///
    /// ```swift
    /// @StreamParseable(partialMembers: .streamInitialValue)
    /// struct Response { var count: Int = 0 }
    /// let counts = try chunks.partials(of: Response.self, from: .json()).observeField(\.count)
    /// for try await update in counts { print(update.value, update.isComplete) }
    /// ```
    ///
    /// Initial storage values do not imply presence in the input: the observation starts as
    /// `missing`. Field completion is independent of the final document-completion update.
    ///
    /// - Parameter path: A direct nonoptional stored member registered in the root's schema
    ///   and `streamObservationFields`.
    /// - Returns: A sequence of `PartialUpdate<ObservedField<Field>>` snapshots sharing this
    ///   source's single subscription, with one update per input element and one at valid EOF.
    /// - Throws: `FieldObservationError.unsupportedField` for unsupported paths. Iteration
    ///   propagates upstream, parsing, subscription, and field-value errors.
    @_disfavoredOverload
    public func observeField<Field: StreamParseableRoot>(
      _ path: KeyPath<Element, Field>
    ) throws -> AsyncFieldObservationSequence<Element, Base, Seq, Field> {
      self.observeField(try ObservedFieldPath(path))
    }

    /// Observes a field using a previously validated selection, reusable across documents.
    ///
    /// ```swift
    /// let title = try ObservedFieldPath<Response.Partial, StreamString>(\.title)
    /// let updates = chunks.partials(of: Response.self, from: .json()).observeField(title)
    /// for try await update in updates { print(update.value, update.isComplete) }
    /// ```
    ///
    /// - Parameter path: A validated selection for this sequence's partial root.
    /// - Returns: A sequence of `PartialUpdate<ObservedField<Field>>` snapshots sharing this
    ///   source's single subscription. Each input element produces an update, followed by a
    ///   final update with `isComplete == true` after successful EOF validation. Use
    ///   `removeDuplicateUpdates()` to suppress unchanged field states while retaining EOF.
    ///
    /// This method performs no further validation and does not throw. Iteration propagates
    /// upstream, parsing, subscription, and field-value errors; after an error it returns `nil`.
    public func observeField<Field: StreamParseableRoot>(
      _ path: ObservedFieldPath<Element, Field>
    ) -> AsyncFieldObservationSequence<Element, Base, Seq, Field> {
      AsyncFieldObservationSequence(source: self, path: path)
    }
  }

  /// Owned field states and explicit document completion. Iterator copies share both the
  /// source cursor and field tracking; concurrent calls on copies are not supported.
  public struct AsyncFieldObservationSequence<
    Root: StreamParseableRoot,
    Base: AsyncSequence,
    Bytes: Sequence<UInt8>,
    Field: StreamParseableRoot
  >: AsyncSequence {
    public typealias Element = PartialUpdate<ObservedField<Field>>
    let source: AsyncPartialsSequence<Root, Base, Bytes>
    let path: ObservedFieldPath<Root, Field>

    public struct AsyncIterator: AsyncIteratorProtocol {
      let box: AsyncPartialsSequence<Root, Base, Bytes>.Box<FieldObservationState>
      let subscription: AsyncPartialsSubscription
      let bytes: @Sendable (Base.Element) -> Bytes
      let path: ObservedFieldPath<Root, Field>

      public mutating func next() async throws -> Element? {
        let source = self.box
        guard !source.hasTerminated else { return nil }
        do {
          if source.hasClaimedSubscription == nil {
            source.hasClaimedSubscription = await self.subscription.claim(
              source.subscriber
            )
          }
          guard source.hasClaimedSubscription == true else {
            throw StreamParsingError.multipleSubscribers
          }
          let complete: Bool
          if let element = try await source.nextBaseElement() {
            try source.stream.nextObserving(
              self.bytes(element),
              state: &source.state
            )
            complete = false
          } else {
            source.hasTerminated = true
            try source.stream.finishObserving(state: &source.state)
            complete = true
          }
          return PartialUpdate(
            value: try self.path.snapshot(
              from: source.stream.storage,
              phase: source.state.phase
            ),
            isComplete: complete
          )
        } catch {
          source.hasTerminated = true
          throw error
        }
      }
    }

    public func makeAsyncIterator() -> AsyncIterator {
      AsyncIterator(
        box: AsyncPartialsSequence<Root, Base, Bytes>
          .Box(
            base: self.source.base,
            stream: PartialsStream(
              initialValue: self.source.initialValue,
              from: self.source.format
            ),
            state: FieldObservationState(offset: self.path.offset)
          ),
        subscription: self.source.subscription,
        bytes: self.source.bytes,
        path: self.path
      )
    }
  }

  extension AsyncFieldObservationSequence: Sendable
  where Root: Sendable, Base: Sendable, Bytes: Sendable {}
#endif
