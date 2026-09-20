import SwiftSyntax

extension TypeSyntaxProtocol {
  /// Removes every syntactically explicit optional layer, including `T?`,
  /// `Optional<T>`, and `Swift.Optional<T>`. Does not resolve type aliases.
  public var streamUnwrappedOptionalType: TypeSyntax {
    var type = TypeSyntax(self)
    while true {
      if let optional = type.as(OptionalTypeSyntax.self) {
        type = optional.wrappedType
      } else if type.streamTypeName == "Optional",
        let arguments = type.streamGenericArguments, arguments.count == 1,
        case .type(let wrapped) = arguments.first!.argument
      {
        type = wrapped
      } else {
        return type
      }
    }
  }

  /// Whether the type has a syntactically explicit optional layer.
  public var streamIsOptional: Bool {
    self.streamUnwrappedOptionalType != TypeSyntax(self)
  }

  var streamTypeName: String? {
    self.as(IdentifierTypeSyntax.self)?.name.text ?? self.as(MemberTypeSyntax.self)?.name.text
  }

  var streamGenericArguments: GenericArgumentListSyntax? {
    self.as(IdentifierTypeSyntax.self)?.genericArgumentClause?.arguments
      ?? self.as(MemberTypeSyntax.self)?.genericArgumentClause?.arguments
  }
}
