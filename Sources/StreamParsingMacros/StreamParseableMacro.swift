import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public enum StreamParseableMacro: ExtensionMacro {
  public static func expansion(
    of node: AttributeSyntax,
    attachedTo declaration: some DeclGroupSyntax,
    providingExtensionsOf type: some TypeSyntaxProtocol,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [ExtensionDeclSyntax] {
    guard let structDecl = declaration.as(StructDeclSyntax.self) else {
      throw MacroExpansionErrorMessage(
        "@StreamParseable can only be applied to struct declarations."
      )
    }

    let typeName = structDecl.name.text
    let properties = self.storedProperties(in: structDecl)
    let hasExistingPartial = self.hasExistingPartial(in: structDecl)
    let accessModifier = self.accessModifier(for: structDecl)
    let membersMode = self.partialMembersMode(from: node)

    if hasExistingPartial {
      return [
        try ExtensionDeclSyntax(
          """
          extension \(raw: typeName): StreamParsingCore.StreamParseable {}
          """
        )
      ]
    }

    let partialStruct = self.partialStructDecl(
      for: properties,
      accessModifier: accessModifier,
      membersMode: membersMode
    )
    return [
      try ExtensionDeclSyntax(
        """
        extension \(raw: typeName): StreamParsingCore.StreamParseable {
          \(partialStruct)
        }
        """
      )
    ]
  }

  private static func isStatic(_ variableDecl: VariableDeclSyntax) -> Bool {
    variableDecl.modifiers.contains { $0.name.tokenKind == .keyword(.static) }
  }

  private static func hasExistingPartial(in declaration: StructDeclSyntax) -> Bool {
    declaration.memberBlock.members.contains { member in
      guard let structDecl = member.decl.as(StructDeclSyntax.self) else {
        return false
      }

      return structDecl.name.text == "Partial"
    }
  }

  private static func partialStructDecl(
    for properties: [StoredProperty],
    accessModifier: String?,
    membersMode: PartialMembersMode
  ) -> DeclSyntax {
    let modifierPrefix = self.modifierPrefix(for: accessModifier)
    let propertyLines = self.partialStructProperties(
      from: properties,
      modifierPrefix: modifierPrefix,
      membersMode: membersMode
    )
    let initializerLines = self.partialStructInitializer(
      from: properties,
      modifierPrefix: modifierPrefix,
      membersMode: membersMode
    )
    let registerHandlersLines = self.partialStructRegisterHandlers(
      from: properties,
      modifierPrefix: modifierPrefix
    )
    return """
      \(raw: modifierPrefix)struct Partial: StreamParsingCore.StreamParseableValue,
        StreamParsingCore.StreamParseable {
        \(raw: modifierPrefix)typealias Partial = Self

      \(raw: propertyLines)

        \(raw: initializerLines)

        \(raw: modifierPrefix)static func initialParseableValue() -> Self {
          Self()
        }

        \(raw: registerHandlersLines)
      }
      """
  }

  private static func partialStructProperties(
    from properties: [StoredProperty],
    modifierPrefix: String,
    membersMode: PartialMembersMode
  ) -> String {
    let lines = properties.map { property in
      let typeDescription = property.type.trimmedDescription
      let optionalSuffix = membersMode.shouldEmitOptionalMembers ? "?" : ""
      return "  \(modifierPrefix)var \(property.name): \(typeDescription).Partial\(optionalSuffix)"
    }
    return lines.joined(separator: "\n")
  }

  private static func partialStructInitializer(
    from properties: [StoredProperty],
    modifierPrefix: String,
    membersMode: PartialMembersMode
  ) -> String {
    let parameters =
      properties
      .map { property in
        let typeDescription = property.type.trimmedDescription
        let optionalSuffix = membersMode.shouldEmitOptionalMembers ? "?" : ""
        return
          "\(property.name): \(typeDescription).Partial\(optionalSuffix) = \(membersMode.defaultValueSyntax)"
      }
      .joined(separator: ",\n    ")
    let assignments =
      properties
      .map { property in
        "    self.\(property.name) = \(property.name)"
      }
      .joined(separator: "\n")
    return """
      \(modifierPrefix)init(
          \(parameters)
        ) {
      \(assignments)
        }
      """
  }

  private static func partialStructRegisterHandlers(
    from properties: [StoredProperty],
    modifierPrefix: String
  ) -> String {
    let lines =
      properties
      .map { property in
        "    handlers.registerKeyedHandler(forKey: \"\(property.name)\", \\.\(property.name))"
      }
      .joined(separator: "\n")
    return """
      \(modifierPrefix)static func registerHandlers(
          in handlers: inout some StreamParsingCore.StreamParserHandlers<Self>
        ) {
      \(lines)
        }
      """
  }

  private static func accessModifier(for declaration: StructDeclSyntax) -> String? {
    for modifier in declaration.modifiers {
      switch modifier.name.tokenKind {
      case .keyword(.public):
        return "public"
      case .keyword(.fileprivate):
        return "fileprivate"
      case .keyword(.private):
        return nil
      default:
        continue
      }
    }
    return nil
  }

  private static func modifierPrefix(for accessModifier: String?) -> String {
    accessModifier.map { "\($0) " } ?? ""
  }

  private static func partialMembersMode(from node: AttributeSyntax) -> PartialMembersMode {
    guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else { return .optional }
    let modeArgument = arguments.first { $0.label?.text == "partialMembers" } ?? arguments.first
    guard let expression = modeArgument?.expression else { return .optional }
    return PartialMembersMode.parse(from: expression) ?? .optional
  }
}

// MARK: - StoredProperty

extension StreamParseableMacro {
  private struct StoredProperty {
    let name: String
    let type: TypeSyntax
  }

  private static func storedProperties(in declaration: StructDeclSyntax) -> [StoredProperty] {
    var properties = [StoredProperty]()
    for member in declaration.memberBlock.members {
      guard
        let variableDecl = member.decl.as(VariableDeclSyntax.self),
        !self.isStatic(variableDecl)
      else {
        continue
      }

      for binding in variableDecl.bindings {
        guard !self.isComputedProperty(binding) else {
          continue
        }

        guard
          let identifierPattern = binding.pattern.as(IdentifierPatternSyntax.self),
          let type = binding.typeAnnotation?.type
        else {
          continue
        }

        properties.append(StoredProperty(name: identifierPattern.identifier.text, type: type))
      }
    }
    return properties
  }

  private static func isComputedProperty(_ binding: PatternBindingSyntax) -> Bool {
    guard let accessorBlock = binding.accessorBlock else { return false }
    switch accessorBlock.accessors {
    case .getter:
      return true
    case .accessors(let accessors):
      for accessor in accessors {
        switch accessor.accessorSpecifier.tokenKind {
        case .keyword(.get), .keyword(.set):
          return true
        default:
          continue
        }
      }
      return false
    }
  }
}

// MARK: - PartialMembersMode

extension StreamParseableMacro {
  private enum PartialMembersMode: Hashable {
    case optional
    case initialParseableValue

    var defaultValueSyntax: String {
      switch self {
      case .optional: "nil"
      case .initialParseableValue: ".initialParseableValue()"
      }
    }

    var shouldEmitOptionalMembers: Bool {
      self == .optional
    }

    static func parse(from expression: ExprSyntax) -> Self? {
      switch self.memberName(from: expression) {
      case "optional": .optional
      case "initialParseableValue": .initialParseableValue
      default: nil
      }
    }

    private static func memberName(from expression: ExprSyntax) -> String? {
      if let memberAccess = expression.as(MemberAccessExprSyntax.self) {
        return memberAccess.declName.baseName.text
      }
      if let reference = expression.as(DeclReferenceExprSyntax.self) {
        return reference.baseName.text
      }
      return nil
    }
  }
}
