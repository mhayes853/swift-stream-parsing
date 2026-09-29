/// A selected field's state in the input document, independently of document completion.
/// `incomplete(nil)` means a token has started without a representable partial value yet.
/// Container completion means the closing delimiter arrived, not that every model member exists.
public enum ObservedField<Value> {
  case missing
  case null
  case incomplete(Value?)
  case complete(Value)
}

extension ObservedField: Equatable where Value: Equatable {}
extension ObservedField: Sendable where Value: Sendable {}

/// Failures configuring or reading a field observation.
public enum FieldObservationError: Error, Equatable, Sendable {
  /// Select a direct stored member registered in an object root's field table.
  case unsupportedField
  /// Observation must be installed before any input has been parsed.
  case alreadyStarted
  /// A custom schema accepted a non-null token but did not populate the selected member.
  case unavailableValue
}

// Key paths are not supported by Embedded Swift. The event tracker below has
// no such dependency; only the typed selection and its public drivers need this gate.
#if !hasFeature(Embedded)
  /// A validated, reusable selection of one direct stored object field.
  /// Key aliases are resolved by the schema, not the Swift property name. Computed/nested paths,
  /// ignored members, and roots without a field table throw `unsupportedField`.
  /// Validation uses `Root.streamObservationFields`; reuse a path across documents.
  public struct ObservedFieldPath<Root: StreamParseableRoot, Value: StreamParseableRoot>: Sendable {
    let offset: Int
    let optional: Bool

    public init(_ path: KeyPath<Root, Value?>) throws {
      self.offset = try Self.validate(path, optional: true)
      self.optional = true
    }

    @_disfavoredOverload
    public init(_ path: KeyPath<Root, Value>) throws {
      self.offset = try Self.validate(path, optional: false)
      self.optional = false
    }

    private static func validate(_ path: PartialKeyPath<Root>, optional: Bool) throws -> Int {
      // An offset alone is insufficient: a nested stored key path can have the same offset as
      // its containing field. Check identity against the root's direct stored paths first.
      let schema = Root.streamSchema
      guard let offset = MemoryLayout<Root>.offset(of: path),
        schema.shape == .object, let entries = schema.fieldEntries
      else {
        throw FieldObservationError.unsupportedField
      }
      let fields = Root.streamObservationFields
      guard fields.contains(path),
        fields.lazy.filter({ MemoryLayout<Root>.offset(of: $0) == offset }).count == 1
      else {
        // Zero-sized members can have equal offsets and even equal key paths. The schema
        // cannot distinguish these overlapping members, so reject them during setup.
        throw FieldObservationError.unsupportedField
      }
      for index in 0..<schema.fieldCount {
        if Int(entries[index].offset) == offset, entries[index].isOptional == optional {
          return offset
        }
      }
      throw FieldObservationError.unsupportedField
    }

    func snapshot(from root: UnsafeMutablePointer<Root>, phase: FieldObservationState.Phase)
      throws -> ObservedField<Value>
    {
      switch phase {
      case .missing: return .missing
      case .null: return .null
      case .incompleteScalar: return .incomplete(nil)
      case .incompleteValue, .complete:
        // The key path validated this exact stored type/offset. Reading only its slot avoids
        // copying the root and preserves nested Optional payloads rather than flattening them.
        let address = UnsafeRawPointer(root).advanced(by: self.offset)
        let value: Value? =
          self.optional
          ? address.assumingMemoryBound(to: Value?.self).pointee
          : .some(address.assumingMemoryBound(to: Value.self).pointee)
        if phase == .incompleteValue { return .incomplete(value) }
        guard let value else { throw FieldObservationError.unavailableValue }
        return .complete(value)
      }
    }
  }
#endif
