#if !hasFeature(Embedded)
  extension AsyncPartialsSequence {
    /// Projects directly from the parser's borrowed view, without a whole-root snapshot.
    /// Shares the source's single-subscriber contract. Field state is only as rich as the
    /// selected representation; document completion is carried separately in `PartialUpdate`.
    public func project<Output>(
      _ transform: @escaping @Sendable (borrowing Element.View) throws -> Output
    ) -> AsyncProjectedPartialsSequence<Element, Base, Seq, Output> {
      AsyncProjectedPartialsSequence(source: self, transform: transform)
    }
  }

  extension AsyncPartialsSequence {
    /// Adds explicit document completion to the source's owned snapshots.
    public func updates() -> AsyncPartialUpdatesSequence<Element, Base, Seq> {
      AsyncPartialUpdatesSequence(source: self)
    }

    /// Filters whole snapshots, retaining the explicit final document update.
    public func removeDuplicateUpdates(
      by equivalent: @escaping @Sendable (Element, Element) -> Bool
    ) -> AsyncDistinctPartialUpdates<AsyncPartialUpdatesSequence<Element, Base, Seq>, Element> {
      self.updates().removeDuplicateUpdates(by: equivalent)
    }

    public func removeDuplicateUpdates()
      -> AsyncDistinctPartialUpdates<AsyncPartialUpdatesSequence<Element, Base, Seq>, Element>
    where Element: Equatable {
      self.removeDuplicateUpdates { $0 == $1 }
    }
  }

  /// Owned snapshots with an explicit final update; shares the source's subscription.
  public struct AsyncPartialUpdatesSequence<
    Root: StreamParseableRoot,
    Base: AsyncSequence,
    Bytes: Sequence<UInt8>
  >: AsyncSequence {
    public typealias Element = PartialUpdate<Root>
    let source: AsyncPartialsSequence<Root, Base, Bytes>

    public struct AsyncIterator: AsyncIteratorProtocol {
      @usableFromInline
      var base: AsyncPartialsSequence<Root, Base, Bytes>.AsyncIterator
      public mutating func next() async throws -> Element? {
        guard let value = try await self.base.next() else { return nil }
        return PartialUpdate(value: value, isComplete: self.base.box.hasTerminated)
      }
    }

    public func makeAsyncIterator() -> AsyncIterator {
      AsyncIterator(base: self.source.makeAsyncIterator())
    }
  }

  extension AsyncPartialUpdatesSequence: Sendable
  where Root: Sendable, Base: Sendable, Bytes: Sendable {}

  extension AsyncPartialsSequence.AsyncIterator {
    @usableFromInline
    mutating func nextProjected<Output>(
      _ transform: @Sendable (borrowing Element.View) throws -> Output
    ) async throws -> PartialUpdate<Output>? {
      guard !self.box.hasTerminated else { return nil }
      do {
        if self.box.hasClaimedSubscription == nil {
          self.box.hasClaimedSubscription = await self.subscription.claim(self.box.subscriber)
        }
        guard self.box.hasClaimedSubscription == true else {
          throw StreamParsingError.multipleSubscribers
        }
        guard let element = try await self.box.nextBaseElement() else {
          self.box.hasTerminated = true
          return PartialUpdate(
            value: try self.box.stream.finishWithView(transform),
            isComplete: true
          )
        }
        try self.box.stream.next(self.bytes(element))
        return PartialUpdate(value: try self.box.stream.withView(transform), isComplete: false)
      } catch {
        self.box.hasTerminated = true
        throw error
      }
    }
  }

  /// An async projection that retains the parser's original subscription and error semantics.
  public struct AsyncProjectedPartialsSequence<
    Root: StreamParseableRoot,
    Base: AsyncSequence,
    Bytes: Sequence<UInt8>,
    Output
  >: AsyncSequence {
    public typealias Element = PartialUpdate<Output>
    let source: AsyncPartialsSequence<Root, Base, Bytes>
    @usableFromInline
    let transform: @Sendable (borrowing Root.View) throws -> Output

    public struct AsyncIterator: AsyncIteratorProtocol {
      @usableFromInline
      var base: AsyncPartialsSequence<Root, Base, Bytes>.AsyncIterator
      @usableFromInline
      let transform: @Sendable (borrowing Root.View) throws -> Output

      public mutating func next() async throws -> Element? {
        try await self.base.nextProjected(self.transform)
      }
    }

    public func makeAsyncIterator() -> AsyncIterator {
      AsyncIterator(base: self.source.makeAsyncIterator(), transform: self.transform)
    }
  }

  extension AsyncProjectedPartialsSequence: Sendable
  where Root: Sendable, Base: Sendable, Bytes: Sendable {}

  extension AsyncSequence {
    /// Suppresses equal consecutive values but never suppresses document completion.
    public func removeDuplicateUpdates<Value>(
      by equivalent: @escaping @Sendable (Value, Value) -> Bool
    ) -> AsyncDistinctPartialUpdates<Self, Value> where Element == PartialUpdate<Value> {
      AsyncDistinctPartialUpdates(base: self, equivalent: equivalent)
    }

    public func removeDuplicateUpdates<Value: Equatable & SendableMetatype>()
      -> AsyncDistinctPartialUpdates<
        Self, Value
      >
    where Element == PartialUpdate<Value> {
      self.removeDuplicateUpdates { $0 == $1 }
    }
  }

  /// Keeps one previously emitted value; iterator copies share comparison and consumption state.
  public struct AsyncDistinctPartialUpdates<Base: AsyncSequence, Value>: AsyncSequence
  where Base.Element == PartialUpdate<Value> {
    public typealias Element = PartialUpdate<Value>
    let base: Base
    @usableFromInline
    let equivalent: @Sendable (Value, Value) -> Bool

    @usableFromInline
    final class Box {
      @usableFromInline
      var base: Base.AsyncIterator
      @usableFromInline
      var previous: Element?
      @usableFromInline
      var terminated = false
      @usableFromInline
      init(base: Base.AsyncIterator) { self.base = base }
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
      @usableFromInline
      let box: Box
      @usableFromInline
      let equivalent: @Sendable (Value, Value) -> Bool

      @inlinable
      public mutating func next() async throws -> Element? {
        guard !self.box.terminated else { return nil }
        do {
          while let update = try await self.box.base.next() {
            if !update.isComplete, let previous = self.box.previous,
              self.equivalent(previous.value, update.value)
            {
              continue
            }
            self.box.previous = update
            return update
          }
          self.box.terminated = true
          return nil
        } catch {
          self.box.terminated = true
          throw error
        }
      }
    }

    public func makeAsyncIterator() -> AsyncIterator {
      AsyncIterator(box: Box(base: self.base.makeAsyncIterator()), equivalent: self.equivalent)
    }
  }

  extension AsyncDistinctPartialUpdates: Sendable where Base: Sendable {}
#endif
