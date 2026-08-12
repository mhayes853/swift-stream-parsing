#if StreamParsingTagged
  import Tagged

  // MARK: - Conversion protocols

  // Everything forwards to the raw value, so a tagged identifier accepts exactly what its raw
  // value accepts.

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
    public mutating func streamAppend(utf8 bytes: Span<UInt8>) {
      self.rawValue.streamAppend(utf8: bytes)
    }

    public mutating func streamReserve(utf8ByteCount: Int) {
      self.rawValue.streamReserve(utf8ByteCount: utf8ByteCount)
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

  // The schema comes from the root conformance above; this is what makes a tagged object
  // enterable as a nested field.
  extension Tagged: StreamParseableObject where RawValue: StreamParseableObject {}

  // MARK: - Legacy handler registration

  extension Tagged: StreamParseable where RawValue: StreamParseable {
    public typealias Partial = Tagged<Tag, RawValue.Partial>

    public var streamPartialValue: Tagged<Tag, RawValue.Partial> {
      Tagged<Tag, RawValue.Partial>(rawValue: self.rawValue.streamPartialValue)
    }
  }

#endif
