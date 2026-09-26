import CustomDump
import StreamParsingMacroSupport
import SwiftParser
import SwiftSyntax
import Testing

@Suite
struct `StreamObjectGeneration conversion tests` {
  @Test
  func `Conversions Cover Both Directions`() throws {
    let generation = try StreamObjectGeneration(
      fields: [
        StreamParseableField(name: .identifier("name"), type: TypeSyntax("String")),
        StreamParseableField(name: .identifier("tags"), type: TypeSyntax("[String: Int]?")),
        StreamParseableField(
          name: .identifier("createdAt"),
          type: TypeSyntax("Date"),
          keys: ["created_at"],
          completedConversion: TypeSyntax("UnixSeconds"),
          defaultValue: ExprSyntax("Date(timeIntervalSince1970: 0)")
        ),
        StreamParseableField(
          name: .identifier("updatedAt"),
          type: TypeSyntax("Date?"),
          keys: ["updated_at"],
          completedConversion: TypeSyntax("UnixSeconds")
        )
      ],
      configuration: StreamGenerationConfiguration(accessLevel: .public)
    )

    let source = try generation.conversionsSyntax(
      unparsedMembers: [
        StreamUnparsedMember(name: .identifier("cache")),
        StreamUnparsedMember(name: .identifier("retries"), value: IntegerLiteralExprSyntax(3))
      ]
    )
    .description

    expectNoDifference(
      source,
      """
      @inlinable public var streamPartialValue: Partial {
        Partial(
          name: self.name.streamPartialValue,
          tags: self.tags.map { StreamParsingCore.StreamDictionary($0.mapValues(\\.streamPartialValue)) },
          createdAt: StreamParsingCore.ConvertedPartial<UnixSeconds>(value: self.createdAt),
          updatedAt: self.updatedAt.map { StreamParsingCore.ConvertedPartial<UnixSeconds>(value: $0) }
        )
      }

      @inlinable public init?(_ partial: Partial) {
        self.init(streamPartial: partial)
      }

      public init?(streamPartial partial: Partial) {
        guard
          let name = Self._streamValue({ $0.name }, partial.name),
          let tags = Self._streamValue({ $0.tags }, partial.tags),
          let createdAt = _streamConvertedValue(partial.createdAt),
          let updatedAt = _streamOptionalConvertedValue(partial.updatedAt)
        else {
          return nil
        }
        self.name = name
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.cache = nil
        self.retries = 3
      }

      public init(orInitial partial: Partial) {
        self.name = Self._streamValueOrInitial({ $0.name }, partial.name)
        self.tags = Self._streamValueOrInitial({ $0.tags }, partial.tags)
        self.createdAt = _streamConvertedValue(partial.createdAt) ?? (Date(timeIntervalSince1970: 0))
        self.updatedAt = _streamConvertedValue(partial.updatedAt) ?? (nil)
        self.cache = nil
        self.retries = 3
      }

      @inlinable public static func streamValueOrInitial(from partial: Partial) -> Self {
        Self(orInitial: partial)
      }
      """
    )
  }

  @Test
  func `Stream Initial Value Members Make The Unlabelled Initializer Total`() throws {
    let generation = try StreamObjectGeneration(
      fields: [self.field("value")],
      partialMembers: .streamInitialValue
    )
    let source = try generation.conversionsSyntax().description

    self.expectContains(source, "init(_ partial: Partial) {\n  self.init(orInitial: partial)\n}")
    expectNoDifference(source.contains("init?(_ partial"), false)
    self.expectContains(source, "init?(streamPartial partial: Partial)")
  }

  @Test
  func `Custom Partial Names Emit A Partial Alias`() throws {
    let generation = try StreamObjectGeneration(
      fields: [self.field("value")],
      configuration: StreamGenerationConfiguration(
        accessLevel: .package,
        names: StreamGeneratedNames(partialType: .identifier("Accumulator"))
      )
    )
    let source = try generation.conversionsSyntax().description

    expectNoDifference(source.hasPrefix("package typealias Partial = Accumulator\n\n"), true)
  }

  @Test
  func `Partial Value Inlining Overrides Only The Getter`() throws {
    let generation = try StreamObjectGeneration(
      fields: [self.field("value")],
      configuration: StreamGenerationConfiguration(accessLevel: .public)
    )

    let never = try generation.conversionsSyntax(partialValueInlining: .never).description
    expectNoDifference(never.hasPrefix("public var streamPartialValue: Partial {"), true)
    self.expectContains(never, "@inlinable public init?(_ partial: Partial)")
    self.expectContains(never, "@inlinable public static func streamValueOrInitial")

    let internalGeneration = try StreamObjectGeneration(fields: [self.field("value")])
    let always = try internalGeneration.conversionsSyntax(partialValueInlining: .always)
      .description
    expectNoDifference(always.hasPrefix("@inlinable var streamPartialValue: Partial {"), true)
    expectNoDifference(always.contains("@inlinable init?(_ partial"), false)
  }

  @Test
  func `Empty Objects Produce Valid Conversions`() throws {
    let generation = try StreamObjectGeneration(fields: [])
    let source = try generation.conversionsSyntax(
      unparsedMembers: [StreamUnparsedMember(name: .identifier("cache"))]
    )
    .description

    self.expectContains(source, "var streamPartialValue: Partial {\n  Partial()\n}")
    self.expectContains(source, "init?(streamPartial partial: Partial) {\n  self.cache = nil\n}")
    self.expectContains(source, "init(orInitial partial: Partial) {\n  self.cache = nil\n}")
    self.expectParses(source)
  }

  @Test
  func `Escaped Member Names Stay Escaped`() throws {
    let generation = try StreamObjectGeneration(fields: [self.field("`default`")])
    let source = try generation.conversionsSyntax(
      unparsedMembers: [StreamUnparsedMember(name: .identifier("`init`"))]
    )
    .description

    self.expectContains(source, "`default`: self.`default`.streamPartialValue")
    self.expectContains(source, "let `default` = Self._streamValue({ $0.`default` }, partial.`default`)")
    self.expectContains(source, "self.`init` = nil")
    self.expectParses(source)
  }

  @Test
  func `Invalid Conversion Descriptions Are Rejected`() throws {
    let converted = StreamParseableField(
      name: .identifier("createdAt"),
      type: TypeSyntax("Date"),
      keys: ["created_at"],
      completedConversion: TypeSyntax("UnixSeconds")
    )
    #expect(
      throws: StreamObjectGenerationError.missingCompletedConversionDefault(field: "createdAt")
    ) {
      try StreamObjectGeneration(fields: [converted]).conversionsSyntax()
    }

    let generation = try StreamObjectGeneration(fields: [self.field("value")])
    #expect(throws: StreamObjectGenerationError.duplicateField("value")) {
      try generation.conversionsSyntax(
        unparsedMembers: [StreamUnparsedMember(name: .identifier("value"))]
      )
    }
  }

  @Test
  func `Diagnosed Fields Produce Recovery Conversions`() throws {
    let converted = StreamParseableField(
      name: .identifier("createdAt"),
      type: TypeSyntax("Date"),
      keys: ["created_at"],
      completedConversion: TypeSyntax("UnixSeconds")
    )
    let source = try StreamObjectGeneration(diagnosedFields: [converted]).conversionsSyntax()
      .description

    self.expectContains(source, "self.createdAt = _streamConvertedValue(partial.createdAt) ?? (nil)")
    self.expectParses(source)
  }

  private func field(_ name: String) -> StreamParseableField {
    StreamParseableField(name: .identifier(name), type: TypeSyntax("Int"))
  }

  private func expectParses(
    _ source: String,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
  ) {
    #expect(
      !Parser.parse(source: "extension Model {\n\(source)\n}").hasError,
      sourceLocation: sourceLocation
    )
  }

  private func expectContains(
    _ source: String,
    _ expected: String,
    sourceLocation: Testing.SourceLocation = #_sourceLocation
  ) {
    #expect(source.contains(expected), "Missing: \(expected)", sourceLocation: sourceLocation)
  }
}
