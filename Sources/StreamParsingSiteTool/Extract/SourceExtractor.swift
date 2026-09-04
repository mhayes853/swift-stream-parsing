import Foundation
import SwiftParser
import SwiftSyntax

/// Lifts declarations out of the Swift sources, keyed `Basename.swift:symbol`.
///
/// The leading comment is captured with the code and treated as evidence in its own right. Several
/// kernels carry their measurement table inline -- the SIMD16 / SWAR / scalar comparison at the top
/// of `StreamScanners.swift`, the `X86CmovConverterPass` hazard above `streamFirstHitLane` -- and
/// those numbers appear nowhere else in the repository.
struct SourceExtractor {
  var roots: [String]

  func extract() throws -> (decls: [String: [SourceDecl]], fileCount: Int) {
    var out: [String: [SourceDecl]] = [:]
    var files = 0
    for root in self.roots {
      for path in Self.swiftFiles(under: root) {
        files += 1
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let tree = Parser.parse(source: text)
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let visitor = DeclVisitor(file: path, converter: converter)
        visitor.walk(tree)
        for decl in visitor.decls {
          out["\(decl.file.lastPathComponentSlice):\(decl.symbol)", default: []].append(decl)
        }
      }
    }
    return (out, files)
  }

  static func swiftFiles(under root: String) -> [String] {
    guard let e = FileManager.default.enumerator(atPath: root) else { return [] }
    var paths: [String] = []
    for case let name as String in e where name.hasSuffix(".swift") {
      paths.append("\(root)/\(name)")
    }
    return paths.sorted()
  }
}

extension String {
  var lastPathComponentSlice: String { (self as NSString).lastPathComponent }
}

private final class DeclVisitor: SyntaxVisitor {
  let file: String
  let converter: SourceLocationConverter
  var decls: [SourceDecl] = []
  /// Enclosing type names, so a member reads `JSONParser.consumeStructuralRun` rather than
  /// colliding with every other `parse` in the package.
  private var scope: [String] = []

  init(file: String, converter: SourceLocationConverter) {
    self.file = file
    self.converter = converter
    super.init(viewMode: .sourceAccurate)
  }

  // MARK: - Types

  override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
    self.record(node, name: node.name.text, kind: "struct", header: node.memberBlock.leftBrace, members: node.memberBlock)
    self.scope.append(node.name.text)
    return .visitChildren
  }
  override func visitPost(_ node: StructDeclSyntax) { self.scope.removeLast() }

  override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
    // Enums are small and their cases are the interesting part, so they keep their whole body.
    self.record(node, name: node.name.text, kind: "enum", header: nil, members: node.memberBlock)
    self.scope.append(node.name.text)
    return .visitChildren
  }
  override func visitPost(_ node: EnumDeclSyntax) { self.scope.removeLast() }

  override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
    self.record(node, name: node.name.text, kind: "protocol", header: nil, members: node.memberBlock)
    self.scope.append(node.name.text)
    return .visitChildren
  }
  override func visitPost(_ node: ProtocolDeclSyntax) { self.scope.removeLast() }

  override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
    self.record(node, name: node.name.text, kind: "class", header: node.memberBlock.leftBrace, members: node.memberBlock)
    self.scope.append(node.name.text)
    return .visitChildren
  }
  override func visitPost(_ node: ClassDeclSyntax) { self.scope.removeLast() }

  override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
    let name = node.extendedType.trimmedDescription
    self.record(node, name: name, kind: "extension", header: node.memberBlock.leftBrace, members: node.memberBlock)
    self.scope.append(name)
    return .visitChildren
  }
  override func visitPost(_ node: ExtensionDeclSyntax) { self.scope.removeLast() }

  // MARK: - Members

  override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
    self.record(node, name: node.name.text, kind: "func", header: nil, members: nil)
    return .skipChildren
  }

  override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
    self.record(node, name: "init", kind: "init", header: nil, members: nil)
    return .skipChildren
  }

  override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
    guard
      let name = node.bindings.first?.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
    else { return .skipChildren }
    self.record(node, name: name, kind: "var", header: nil, members: nil)
    return .skipChildren
  }

  override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
    self.record(node, name: node.name.text, kind: "typealias", header: nil, members: nil)
    return .skipChildren
  }

  // MARK: - Recording

  /// - Parameter header: when set, only the source up to this token is kept. `JSONParser` is a
  ///   65 KB struct; nobody clicking it wants the whole file back, they want its shape, and its
  ///   members are indexed individually anyway.
  private func record(
    _ node: some SyntaxProtocol, name: String, kind: String,
    header: TokenSyntax?, members: MemberBlockSyntax?
  ) {
    let start = self.converter.location(for: node.positionAfterSkippingLeadingTrivia)
    let end = self.converter.location(for: node.endPositionBeforeTrailingTrivia)

    var code = node.trimmedDescription
    if let header {
      let cut = self.converter.location(for: header.endPositionBeforeTrailingTrivia).offset
      let origin = self.converter.location(for: node.positionAfterSkippingLeadingTrivia).offset
      let whole = node.trimmedDescription
      let length = cut - origin
      if length > 0, length < whole.utf8.count {
        code = String(decoding: Array(whole.utf8)[0..<length], as: UTF8.self) + "\n  …\n}"
      }
    }

    self.decls.append(
      SourceDecl(
        symbol: name,
        qualifiedName: (self.scope + [name]).joined(separator: "."),
        kind: kind,
        file: self.file,
        startLine: start.line,
        endLine: end.line,
        attributes: Self.attributes(of: node),
        comment: Self.leadingComment(of: node),
        code: code,
        members: members.map { block in
          block.members.compactMap { Self.memberName($0.decl) }
        } ?? []
      )
    )
  }

  private static func memberName(_ decl: DeclSyntax) -> String? {
    if let f = decl.as(FunctionDeclSyntax.self) { return f.name.text }
    if let v = decl.as(VariableDeclSyntax.self) {
      return v.bindings.first?.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
    }
    if let e = decl.as(EnumCaseDeclSyntax.self) { return e.elements.first?.name.text }
    if let s = decl.as(StructDeclSyntax.self) { return s.name.text }
    if let e = decl.as(EnumDeclSyntax.self) { return e.name.text }
    return nil
  }

  private static func attributes(of node: some SyntaxProtocol) -> [String] {
    guard let withAttrs = node.asProtocol(WithAttributesSyntax.self) else { return [] }
    return withAttrs.attributes.map { $0.trimmedDescription }
  }

  /// The contiguous comment block directly above the declaration.
  ///
  /// A blank line ends a block: a comment separated from the declaration by one belongs to
  /// whatever is above it, not to this. `//` on its own is a paragraph break inside a block and is
  /// kept, because the long kernel comments use it that way.
  private static func leadingComment(of node: some SyntaxProtocol) -> String? {
    var groups: [[String]] = []
    var current: [String] = []

    func endGroup() {
      if !current.isEmpty { groups.append(current) }
      current = []
    }

    for piece in node.leadingTrivia {
      switch piece {
      case .lineComment(let t), .docLineComment(let t):
        var line = Substring(t)
        while line.hasPrefix("/") { line = line.dropFirst() }
        if line.hasPrefix(" ") { line = line.dropFirst() }
        current.append(String(line))
      case .blockComment(let t), .docBlockComment(let t):
        current.append(t)
      case .newlines(let n), .carriageReturnLineFeeds(let n):
        if n >= 2 { endGroup() }
      case .spaces, .tabs, .carriageReturns:
        continue
      default:
        endGroup()
      }
    }
    endGroup()

    guard var block = groups.last else { return nil }
    // `// MARK: -` separators are navigation, not explanation.
    while let first = block.first, first.hasPrefix("MARK:") { block.removeFirst() }
    let text = block.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }
}
