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
    let properties = Self.storedProperties(in: structDecl)
    let hasExistingPartial = Self.hasExistingPartial(in: structDecl)
    let accessModifier = Self.accessModifier(for: structDecl)

    let streamParseableExtension: ExtensionDeclSyntax
    if hasExistingPartial {
      streamParseableExtension = try ExtensionDeclSyntax(
        """
        extension \(raw: typeName): StreamParsingCore.StreamParseable {}
        """
      )
    } else {
      let partialStruct = Self.partialStructDecl(for: properties, accessModifier: accessModifier)
      streamParseableExtension = try ExtensionDeclSyntax(
        """
        extension \(raw: typeName): StreamParsingCore.StreamParseable {
          \(partialStruct)
        }
        """
      )
    }
    return [streamParseableExtension]
  }

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
    accessModifier: String?
  ) -> DeclSyntax {
    let modifierPrefix = Self.modifierPrefix(for: accessModifier)
    let propertyLines = Self.partialPropertyLines(from: properties, modifierPrefix: modifierPrefix)
    let switchCases = Self.reduceSwitchCaseLines(from: properties)
    return """
      \(raw: modifierPrefix)struct Partial: StreamParsingCore.StreamParseableReducer,
        StreamParsingCore.StreamParseable {
        \(raw: modifierPrefix)typealias Partial = Self

      \(raw: propertyLines)

        \(raw: modifierPrefix)init() {}

        \(raw: modifierPrefix)init(action: StreamAction) throws {
          self.init()
        }

        \(raw: modifierPrefix)mutating func reduce(action: StreamAction) throws {
          switch action {
      \(raw: switchCases)
          default:
            throw StreamParseableError.unsupportedAction(action)
          }
        }
      }
      """
  }

  private static func partialPropertyLines(
    from properties: [StoredProperty],
    modifierPrefix: String
  ) -> String {
    let lines = properties.map { property in
      let typeDescription = property.type.trimmedDescription
      return "  \(modifierPrefix)var \(property.name): \(typeDescription).Partial?"
    }
    return lines.joined(separator: "\n")
  }

  private static func reduceSwitchCaseLines(from properties: [StoredProperty]) -> String {
    let lines = properties.flatMap { property in
      [
        "    case .delegateKeyed(\"\(property.name)\", let action):",
        "      try _streamParsingPerformReduce(&self.\(property.name), action)"
      ]
    }

    return lines.joined(separator: "\n")
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
}
