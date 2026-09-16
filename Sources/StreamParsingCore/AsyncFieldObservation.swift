#if !hasFeature(Embedded)
  extension AsyncPartialsSequence {
    /// Observes a direct stored field through the source's original single subscription.
    public func observeField<Field: StreamParseableRoot>(
      _ path: KeyPath<Element, Field?>
    ) throws -> AsyncFieldObservationSequence<Element, Base, Seq, Field> {
      self.observeField(try ObservedFieldPath(path))
    }

    @_disfavoredOverload
    public func observeField<Field: StreamParseableRoot>(
      _ path: KeyPath<Element, Field>
    ) throws -> AsyncFieldObservationSequence<Element, Base, Seq, Field> {
      self.observeField(try ObservedFieldPath(path))
    }

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

    final class Box {
      var base: AsyncPartialsSequence<Root, Base, Bytes>.AsyncIterator
      var observation: FieldObservationState
      init(base: AsyncPartialsSequence<Root, Base, Bytes>.AsyncIterator, offset: Int) {
        self.base = base
        self.observation = FieldObservationState(offset: offset)
      }
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
      let box: Box
      let path: ObservedFieldPath<Root, Field>

      public mutating func next() async throws -> Element? {
        let source = self.box.base.box
        guard !source.hasTerminated else { return nil }
        do {
          if source.hasClaimedSubscription == nil {
            source.hasClaimedSubscription = await self.box.base.subscription.claim(
              source.subscriber
            )
          }
          guard source.hasClaimedSubscription == true else {
            throw StreamParsingError.multipleSubscribers
          }
          let complete: Bool
          if let element = try await source.nextBaseElement() {
            try source.stream.nextObserving(
              self.box.base.bytes(element),
              state: &self.box.observation
            )
            complete = false
          } else {
            source.hasTerminated = true
            try source.stream.finishObserving(state: &self.box.observation)
            complete = true
          }
          return PartialUpdate(
            value: try self.path.snapshot(
              from: source.stream.storage,
              phase: self.box.observation.phase
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
        box: Box(base: self.source.makeAsyncIterator(), offset: self.path.offset),
        path: self.path
      )
    }
  }

  extension AsyncFieldObservationSequence: Sendable
  where Root: Sendable, Base: Sendable, Bytes: Sendable {}
#endif
