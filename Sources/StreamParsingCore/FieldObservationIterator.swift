#if !hasFeature(Embedded)
  extension PartialIterator {
    /// Observes a direct stored field, including missing/null and token completion.
    /// Install before consuming input. The field's state follows this document's tokens;
    /// a seeded initial value alone does not make the field present in the input.
    public consuming func observeField<Field: StreamParseableRoot>(
      _ path: KeyPath<Value, Field?>
    ) throws -> FieldObservationIterator<Value, Base, Bytes, Field> {
      try self.observeField(ObservedFieldPath(path))
    }

    @_disfavoredOverload
    public consuming func observeField<Field: StreamParseableRoot>(
      _ path: KeyPath<Value, Field>
    ) throws -> FieldObservationIterator<Value, Base, Bytes, Field> {
      try self.observeField(ObservedFieldPath(path))
    }

    public consuming func observeField<Field: StreamParseableRoot>(
      _ path: ObservedFieldPath<Value, Field>
    ) throws -> FieldObservationIterator<Value, Base, Bytes, Field> {
      guard self.stream.parser.consumedByteCount == 0,
        !self.terminated, !self.stream.hasFinished, !self.stream.hasParserThrown
      else {
        throw FieldObservationError.alreadyStarted
      }
      return FieldObservationIterator(base: self, path: path)
    }
  }

  /// Emits an owned field state after each input element and once after validated EOF.
  /// Duplicate filtering compares field state as well as value. Errors terminate the iterator.
  public struct FieldObservationIterator<
    Root: StreamParseableRoot,
    Base: IteratorProtocol,
    Bytes: Sequence<UInt8>,
    Field: StreamParseableRoot
  >: ~Copyable, PartialUpdateIteratorProtocol {
    var base: PartialIterator<Root, Base, Bytes>
    let path: ObservedFieldPath<Root, Field>
    var observation: FieldObservationState

    init(base: consuming PartialIterator<Root, Base, Bytes>, path: ObservedFieldPath<Root, Field>) {
      self.base = base
      self.path = path
      self.observation = FieldObservationState(offset: path.offset)
    }

    public mutating func next() throws -> PartialUpdate<ObservedField<Field>>? {
      guard !self.base.terminated else { return nil }
      do {
        let complete: Bool
        if let element = self.base.base.next() {
          try self.base.stream.nextObserving(self.base.bytes(element), state: &self.observation)
          complete = false
        } else {
          self.base.terminated = true
          try self.base.stream.finishObserving(state: &self.observation)
          complete = true
        }
        return PartialUpdate(
          value: try self.path.snapshot(
            from: self.base.stream.storage,
            phase: self.observation.phase
          ),
          isComplete: complete
        )
      } catch {
        self.base.terminated = true
        throw error
      }
    }
  }
#endif
