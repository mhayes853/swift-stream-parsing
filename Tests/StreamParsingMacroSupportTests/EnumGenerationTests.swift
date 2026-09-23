import CustomDump
import StreamParsingMacroSupport
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing

@Suite
struct `StreamEnumGeneration tests` {
  @Test
  func `String Raw Values Match Exactly Then By Shortest Prefix`() throws {
    let generation = try StreamEnumGeneration(
      cases: [
        StreamParseableEnumCase(name: .identifier("live")),
        StreamParseableEnumCase(name: .identifier("livestream"), keys: ["livestream", "stream"])
      ],
      representation: .stringRawValue,
      defaultCase: .identifier("live")
    )
    let partial = try generation.partialSyntax(in: BasicMacroExpansionContext()).description
    let source = generation.conversionsSyntax().description

    expectNoDifference(partial, "typealias Partial = StreamParsingCore.StreamString")
    expectNoDifference(
      source,
      """
      var streamPartialValue: Partial {
        self.rawValue.streamPartialValue
      }

      init?(_ partial: Partial) {
        self.init(streamPartial: partial)
      }

      init?(streamPartial partial: Partial) {
        let streamCount = partial.utf8Count
        guard streamCount > 0 else {
          return nil
        }
        switch partial.paddedLeadingWord() {
        case 0x0000_0000_6576_696C where streamCount == 4:
          self = .live
          return
        case 0x6572_7473_6576_696C where streamCount == 10 && partial.paddedWord(at: 8) == 0x0000_0000_0000_6D61:
          self = .livestream
          return
        case 0x0000_6D61_6572_7473 where streamCount == 6:
          self = .livestream
          return
        default:
          break
        }
        if partial.isPrefix(of: "live") {
          self = .live
          return
        }
        if partial.isPrefix(of: "stream") {
          self = .livestream
          return
        }
        if partial.isPrefix(of: "livestream") {
          self = .livestream
          return
        }
        return nil
      }

      init(orInitial partial: Partial) {
        self = Self(streamPartial: partial) ?? .live
      }

      static func streamValueOrInitial(from partial: Partial) -> Self {
        Self(orInitial: partial)
      }
      """
    )
  }

  @Test
  func `An Empty Raw Value Keeps Zero Bytes As A Value`() throws {
    let generation = try StreamEnumGeneration(
      cases: [StreamParseableEnumCase(name: .identifier("none"), keys: [""])],
      representation: .stringRawValue
    )
    let source = generation.conversionsSyntax().description

    expectNoDifference(source.contains("guard streamCount > 0"), false)
    self.expectContains(source, "where streamCount == 0")
  }

  @Test
  func `Numeric Raw Values Convert Through Their Raw Value`() throws {
    let generation = try StreamEnumGeneration(
      cases: [StreamParseableEnumCase(name: .identifier("low")), StreamParseableEnumCase(name: .identifier("high"))],
      representation: .numericRawValue(TypeSyntax("UInt8")),
      configuration: StreamGenerationConfiguration(accessLevel: .public)
    )
    let partial = try generation.partialSyntax(in: BasicMacroExpansionContext()).description
    let source = generation.conversionsSyntax().description

    expectNoDifference(partial, "public typealias Partial = UInt8")
    expectNoDifference(
      source,
      """
      @inlinable public var streamPartialValue: Partial {
        self.rawValue
      }

      @inlinable public init?(_ partial: Partial) {
        self.init(streamPartial: partial)
      }

      @inlinable public init?(streamPartial partial: Partial) {
        self.init(rawValue: partial)
      }
      """
    )
    expectNoDifference(generation.fieldIdentifiers.isEmpty, true)
  }

  @Test
  func `Case Keyed Objects Build Payloads From Associated Values`() throws {
    let generation = try self.eventGeneration()
    let source = generation.conversionsSyntax().description

    expectNoDifference(
      source,
      """
      var streamPartialValue: Partial {
        switch self {
        case .`default`:
          return Partial(`default`: StreamParsingCore.StreamEmptyObject())
        case .event(let createdAt, let _1):
          return Partial(event: EventArguments.Partial(createdAt: StreamParsingCore.ConvertedPartial<UnixSeconds>(value: createdAt), _1: _1.streamPartialValue))
        }
      }

      init?(_ partial: Partial) {
        self.init(streamPartial: partial)
      }

      init?(streamPartial partial: Partial) {
        var streamMatched = -1
        var streamMatches = 0
        if partial.`default` != nil {
          streamMatched = 0
          streamMatches += 1
        }
        if partial.event != nil {
          streamMatched = 1
          streamMatches += 1
        }
        guard streamMatches == 1 else {
          return nil
        }
        switch streamMatched {
        case 0:
          self = .`default`
        case 1:
          guard let streamValue = EventArguments.Value(streamPartial: partial.event!) else {
            return nil
          }
          self = .event(createdAt: streamValue.createdAt, streamValue._1)
        default:
          return nil
        }
      }

      init(orInitial partial: Partial) {
        if let streamMatched = Self(streamPartial: partial) {
          self = streamMatched
          return
        }
        let streamDefaultValue = EventArguments.Value.streamValueOrInitial(
          from: partial.event ?? EventArguments.Partial.streamInitialValue()
        )
        self = .event(createdAt: streamDefaultValue.createdAt, streamDefaultValue._1)
      }

      static func streamValueOrInitial(from partial: Partial) -> Self {
        Self(orInitial: partial)
      }
      """
    )
    self.expectParses(source)
  }

  @Test
  func `Case Keyed Partials Include Payload Namespaces And A Resolved View`() throws {
    let generation = try self.eventGeneration()
    let source = try generation.partialSyntax(in: BasicMacroExpansionContext()).description

    expectNoDifference(generation.partialFields?.map(\.memberName.text), ["`default`", "event"])
    expectNoDifference(generation.partialFields?.map(\.storageType.trimmedDescription), [
      "StreamParsingCore.StreamEmptyObject.Partial?", "EventArguments.Partial?"
    ])
    expectNoDifference(generation.partialFields?.map(\.keys), [["default"], ["event", "happening"]])

    self.expectContains(source, "var `default`: StreamParsingCore.StreamEmptyObject.Partial?")
    self.expectContains(source, "var event: EventArguments.Partial?")
    self.expectContains(source, "key: \"happening\"")
    self.expectContains(source, "enum ResolvedView: ~Copyable, ~Escapable {")
    self.expectContains(source, "case event(EventArguments.Partial.View)")
    self.expectContains(
      source,
      "return _overrideLifetime(.event(EventArguments.Partial.streamView(streamAddress)), borrowing: self)"
    )
    self.expectContains(source, "enum EventArguments {")
    self.expectContains(source, "var createdAt: StreamParsingCore.ConvertedPartial<UnixSeconds>?")
    self.expectContains(source, "key: \"_1\"")
    self.expectContains(source, "struct Value: StreamParsingCore.StreamParseable {\n    var createdAt: Date\n    var _1: String")
    self.expectContains(source, "typealias Partial = EventArguments.Partial")
    self.expectContains(
      source,
      "self.createdAt = _streamConvertedValue(partial.createdAt) ?? (Date(timeIntervalSince1970: 0))"
    )
    self.expectParses(source)
  }

  @Test
  func `Primary And Payload Partials Accept Customization`() throws {
    let generation = try self.eventGeneration()
    let source = try generation.partialSyntax(
      in: BasicMacroExpansionContext(),
      partialCustomization: StreamPartialCustomization(
        conformances: [TypeSyntax("PrimaryPartialProtocol")],
        members: MemberBlockItemListSyntax { DeclSyntax("var primaryMarker: Bool { true }") }
      ),
      payloadCustomization: { info in
        #expect(info.caseName.text == "event")
        #expect(info.payloadTypeName.text == "EventArguments")
        #expect(info.fields.map(\.name.text) == ["createdAt", "_1"])
        #expect(info.partialFields.map(\.unescapedName) == ["createdAt", "_1"])
        #expect(info.partialFields.map(\.storageType.trimmedDescription) == [
          "StreamParsingCore.ConvertedPartial<UnixSeconds>?", "String.Partial?"
        ])
        #expect(info.partialFields.map(\.keys) == [["createdAt"], ["_1"]])
        let manuallyCreated = StreamEnumPayloadInfo(
          caseName: info.caseName, payloadTypeName: info.payloadTypeName, fields: info.fields
        )
        #expect(manuallyCreated.partialFields.map(\.storageType.trimmedDescription)
          == info.partialFields.map(\.storageType.trimmedDescription))
        return .generated(partial: StreamPartialCustomization(
          conformances: [TypeSyntax("PayloadPartialProtocol")],
          members: MemberBlockItemListSyntax { DeclSyntax("var payloadMarker: Bool { true }") }
        ))
      }
    ).description

    self.expectContains(source, "Sendable, PrimaryPartialProtocol")
    self.expectContains(source, "Sendable, PayloadPartialProtocol")
    self.expectContains(source, "var primaryMarker: Bool")
    self.expectContains(source, "var payloadMarker: Bool")
    self.expectParses(source)
  }

  @Test
  func `Payload Info Accepts Caller Supplied Descriptors`() {
    let descriptor = StreamPartialFieldDescriptor(
      memberName: .identifier("custom"),
      unescapedName: "custom",
      storageType: TypeSyntax("Custom.Partial?"),
      keys: ["wireKey"]
    )
    let info = StreamEnumPayloadInfo(
      caseName: .identifier("event"),
      payloadTypeName: .identifier("EventArguments"),
      fields: [],
      partialFields: [descriptor]
    )
    #expect(info.partialFields[0].memberName.text == "custom")
    #expect(info.partialFields[0].storageType.trimmedDescription == "Custom.Partial?")
    #expect(info.partialFields[0].keys == ["wireKey"])
  }

  @Test
  func `Payload Declaration Can Be Replaced`() throws {
    let generation = try self.eventGeneration()
    let source = try generation.partialSyntax(
      in: BasicMacroExpansionContext(),
      payloadCustomization: { info in
        .replacement(DeclSyntax("""
          enum \(info.payloadTypeName) {
            struct Partial { var replacementMarker = true }
            struct Value {}
          }
          """))
      }
    ).description

    self.expectContains(source, "enum EventArguments {")
    self.expectContains(source, "var replacementMarker = true")
    expectNoDifference(source.contains("struct Value: StreamParsingCore.StreamParseable"), false)
    self.expectParses(source)
  }

  @Test
  func `Unsafe Views Produce An Escapable Resolved View`() throws {
    let generation = try self.eventGeneration(
      configuration: StreamGenerationConfiguration(viewMode: .unsafe)
    )
    let source = try generation.partialSyntax(in: BasicMacroExpansionContext()).description

    self.expectContains(source, "@unsafe enum ResolvedView: ~Copyable {")
    self.expectContains(source, "return .event(EventArguments.Partial.streamView(streamAddress))")
    expectNoDifference(source.contains("_lifetime"), false)
  }

  @Test
  func `Default Payload Names Append Payload`() throws {
    let generation = try StreamEnumGeneration(
      cases: [
        StreamParseableEnumCase(
          name: .identifier("text"),
          associatedValues: [StreamParseableField(name: .wildcardToken(), type: TypeSyntax("String"))]
        )
      ],
      representation: .caseKeyedObject
    )
    let source = try generation.partialSyntax(in: BasicMacroExpansionContext()).description

    self.expectContains(source, "enum TextPayload {")
    self.expectContains(source, "var text: TextPayload.Partial?")
  }

  @Test
  func `Without A Default Case The Host Supplies The Fallback`() throws {
    let generation = try StreamEnumGeneration(
      cases: [StreamParseableEnumCase(name: .identifier("circle"))],
      representation: .caseKeyedObject
    )
    let source = generation.conversionsSyntax().description

    expectNoDifference(source.contains("orInitial"), false)
    expectNoDifference(source.contains("streamValueOrInitial"), false)
  }

  @Test
  func `Case Keyed Objects Only Inline streamPartialValue When Asked`() throws {
    let generation = try StreamEnumGeneration(
      cases: [StreamParseableEnumCase(name: .identifier("circle"))],
      representation: .caseKeyedObject,
      defaultCase: .identifier("circle"),
      configuration: StreamGenerationConfiguration(accessLevel: .public)
    )

    let automatic = generation.conversionsSyntax().description
    expectNoDifference(automatic.hasPrefix("public var streamPartialValue"), true)
    self.expectContains(automatic, "@inlinable public init?(streamPartial partial: Partial)")
    self.expectContains(automatic, "@inlinable public init(orInitial partial: Partial)")

    let always = generation.conversionsSyntax(partialValueInlining: .always).description
    expectNoDifference(always.hasPrefix("@inlinable public var streamPartialValue"), true)
  }

  @Test
  func `Empty Case Keyed Enums Still Convert`() throws {
    let generation = try StreamEnumGeneration(cases: [], representation: .caseKeyedObject)
    expectNoDifference(generation.partialFields?.count, 0)
    let partial = try generation.partialSyntax(in: BasicMacroExpansionContext()).description
    let source = generation.conversionsSyntax().description

    self.expectContains(source, "var streamPartialValue: Partial {\n  switch self {}\n}")
    expectNoDifference(partial.contains("ResolvedView"), false)
    self.expectParses(partial + "\n\n" + source)
  }

  @Test
  func `Hooks Extend The Case Keyed Partial`() throws {
    let generation = try self.eventGeneration()
    let source = try generation.partialSyntax(
      in: BasicMacroExpansionContext(),
      additionalMembers: { DeclSyntax("var lastCase: StreamParsingCore.StreamFieldID? = nil") },
      additionalViewMembers: { DeclSyntax("var marker: Int { 42 }") },
      onFieldRecognized: { partial, field in "\(partial).lastCase = \(field)" }
    )
    .description

    expectNoDifference(generation.fieldIdentifiers.map(\.name.text), ["`default`", "event"])
    self.expectContains(source, "var lastCase: StreamParsingCore.StreamFieldID? = nil")
    self.expectContains(source, "var marker: Int {")
    self.expectContains(source, "onFieldRecognized:")
    self.expectContains(source, "self.lastCase = __macro_local_21streamRecognizedField")
    self.expectParses(source)
  }

  @Test
  func `Raw Value Partials Reject Hooks`() throws {
    let generation = try StreamEnumGeneration(
      cases: [StreamParseableEnumCase(name: .identifier("live"))],
      representation: .stringRawValue
    )
    #expect(generation.partialFields == nil)
    #expect(throws: StreamObjectGenerationError.hooksRequireObjectRepresentation) {
      try generation.partialSyntax(
        in: BasicMacroExpansionContext(),
        additionalMembers: { DeclSyntax("var marker = 0") }
      )
    }
    #expect(throws: StreamObjectGenerationError.hooksRequireObjectRepresentation) {
      try generation.partialSyntax(
        in: BasicMacroExpansionContext(),
        onFieldRecognized: { partial, _ in "\(partial).marker += 1" }
      )
    }
    #expect(throws: StreamObjectGenerationError.hooksRequireObjectRepresentation) {
      try generation.partialSyntax(
        in: BasicMacroExpansionContext(),
        partialCustomization: StreamPartialCustomization(conformances: [TypeSyntax("Marker")])
      )
    }
  }

  @Test
  func `Invalid Enum Descriptions Are Rejected`() throws {
    #expect(throws: StreamObjectGenerationError.duplicateKey("on")) {
      try StreamEnumGeneration(
        cases: [
          StreamParseableEnumCase(name: .identifier("on")),
          StreamParseableEnumCase(name: .identifier("enabled"), keys: ["enabled", "on"])
        ],
        representation: .stringRawValue
      )
    }
    #expect(throws: StreamObjectGenerationError.duplicateKey("on")) {
      try StreamEnumGeneration(
        cases: [
          StreamParseableEnumCase(name: .identifier("on")),
          StreamParseableEnumCase(name: .identifier("enabled"), keys: ["on"])
        ],
        representation: .caseKeyedObject
      )
    }
    #expect(throws: StreamObjectGenerationError.missingCompletedConversionDefault(field: "at")) {
      try StreamEnumGeneration(
        cases: [
          StreamParseableEnumCase(
            name: .identifier("event"),
            associatedValues: [
              StreamParseableField(
                name: .identifier("at"),
                type: TypeSyntax("Date"),
                completedConversion: TypeSyntax("UnixSeconds")
              )
            ]
          )
        ],
        representation: .caseKeyedObject
      )
    }
    #expect(throws: StreamObjectGenerationError.incompatibleInliningAccess) {
      try StreamEnumGeneration(
        cases: [],
        representation: .stringRawValue,
        configuration: StreamGenerationConfiguration(inlining: .always)
      )
    }
    // Numeric raw values have no keys to collide.
    _ = try StreamEnumGeneration(
      cases: [
        StreamParseableEnumCase(name: .identifier("a"), keys: ["x"]),
        StreamParseableEnumCase(name: .identifier("b"), keys: ["x"])
      ],
      representation: .numericRawValue(TypeSyntax("Int"))
    )
  }

  @Test
  func `Diagnosed Cases Produce Recovery Syntax`() throws {
    let generation = StreamEnumGeneration(
      diagnosedCases: [
        StreamParseableEnumCase(name: .identifier("on")),
        StreamParseableEnumCase(name: .identifier("enabled"), keys: ["on"])
      ],
      representation: .caseKeyedObject
    )
    let partial = try generation.partialSyntax(in: BasicMacroExpansionContext()).description
    self.expectParses(partial + "\n\n" + generation.conversionsSyntax().description)
  }

  private func eventGeneration(
    configuration: StreamGenerationConfiguration = StreamGenerationConfiguration(viewMode: .lifetime)
  ) throws -> StreamEnumGeneration {
    try StreamEnumGeneration(
      cases: [
        StreamParseableEnumCase(name: .identifier("`default`")),
        StreamParseableEnumCase(
          name: .identifier("event"),
          keys: ["event", "happening"],
          associatedValues: [
            StreamParseableField(
              name: .identifier("createdAt"),
              type: TypeSyntax("Date"),
              completedConversion: TypeSyntax("UnixSeconds"),
              defaultValue: ExprSyntax("Date(timeIntervalSince1970: 0)")
            ),
            StreamParseableField(name: .wildcardToken(), type: TypeSyntax("String"))
          ],
          payloadTypeName: .identifier("EventArguments")
        )
      ],
      representation: .caseKeyedObject,
      defaultCase: .identifier("event"),
      configuration: configuration
    )
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
