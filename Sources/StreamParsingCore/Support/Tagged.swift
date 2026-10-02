#if Tagged
  import Tagged

  // MARK: - Conversion protocols

  // Everything forwards to the raw value, so a tagged identifier accepts what its raw value does.

  extension Tagged: StreamInitializable where RawValue: StreamInitializable {
    public static func streamInitialValue() -> Self {
      Tagged(rawValue: RawValue.streamInitialValue())
    }
  }

  // One stored property, so the raw value's schema applies to a pointer to the Tagged.
  extension Tagged: StreamParseableRoot where RawValue: StreamParseableRoot {
    public static var streamSchema: StreamSchema {
      _streamWrapperSchema(Self.self, wrapping: RawValue.self)
    }
  }

  extension Tagged: StreamStringConvertible where RawValue: StreamStringConvertible {
    @discardableResult
    public mutating func streamAppend(utf8 bytes: Span<UInt8>) -> StreamApplyResult {
      self.rawValue.streamAppend(utf8: bytes)
    }
  }

  extension Tagged: StreamNumberConvertible where RawValue: StreamNumberConvertible {
    public init?(streamParsing bytes: Span<UInt8>, info: NumberInfo) {
      guard let rawValue = RawValue(streamParsing: bytes, info: info) else { return nil }
      self.init(rawValue: rawValue)
    }
  }

  extension Tagged: StreamBooleanConvertible where RawValue: StreamBooleanConvertible {
    public init(streamParsingBoolean value: Bool) {
      self.init(rawValue: RawValue(streamParsingBoolean: value))
    }
  }

  extension Tagged: StreamNullable where RawValue: StreamNullable {
    public static func streamNullValue() -> Self {
      Tagged(rawValue: RawValue.streamNullValue())
    }
  }

  // Explicit: a conditional conformance to a refined protocol (`StreamParseableObject`) does not
  // imply one to what it refines.
  extension Tagged: StreamContainerPartial where RawValue: StreamContainerPartial {}

  // The schema comes from the root conformance above; this makes a tagged object a nested field.
  extension Tagged: StreamParseableObject where RawValue: StreamParseableObject {}

  // MARK: - Legacy handler registration

  extension Tagged: StreamParseable where RawValue: StreamParseable {
    public typealias Partial = Tagged<Tag, RawValue.Partial>

    public var streamPartialValue: Tagged<Tag, RawValue.Partial> {
      Tagged<Tag, RawValue.Partial>(rawValue: self.rawValue.streamPartialValue)
    }

    // Structure preserving in both directions, so both conversions are the raw value's, rewrapped.
    public init?(streamPartial: Tagged<Tag, RawValue.Partial>) {
      guard let rawValue = RawValue(streamPartial: streamPartial.rawValue) else { return nil }
      self.init(rawValue: rawValue)
    }

    public static func streamValueOrInitial(from partial: Tagged<Tag, RawValue.Partial>) -> Self {
      Tagged(rawValue: RawValue.streamValueOrInitial(from: partial.rawValue))
    }
  }

#endif
