import Foundation
import StreamParsing

// Renders a parsed value as Swift source, so a regenerated expectation stays something a reader
// can check against the grammar rather than an opaque blob. Only used by the recording mode
// behind STREAM_PARSING_RECORD.

func swiftLiteral(_ value: Any) -> String {
  if let optional = value as? OptionalProtocol {
    guard let wrapped = optional.wrappedAny else { return "nil" }
    return swiftLiteral(wrapped)
  }
  switch value {
  case let v as String: return "\"\(v.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
  case let v as Bool: return v ? "true" : "false"
  case let v as Double: return v == v.rounded() && v.magnitude < 1e15 ? "\(v)" : "\(v)"
  case let v as Float: return "\(v)"
  default: break
  }

  let mirror = Mirror(reflecting: value)
  switch mirror.displayStyle {
  case .collection:
    let elements = mirror.children.map { swiftLiteral($0.value) }
    return elements.isEmpty ? "[]" : "[\(elements.joined(separator: ", "))]"
  case .struct, .class:
    // StreamDictionary prints as a dictionary literal rather than its storage.
    if let dictionary = value as? StreamDictionaryProtocol {
      let pairs = dictionary.pairsAny.map { "\"\($0.0)\": \(swiftLiteral($0.1))" }
      return pairs.isEmpty ? "[:]" : "[\(pairs.joined(separator: ", "))]"
    }
    let arguments = mirror.children.compactMap { child -> String? in
      guard let label = child.label else { return nil }
      return "\(label): \(swiftLiteral(child.value))"
    }
    // Unqualified names collide with the generated nested type, so the literal carries enough
    // of the path to resolve inside the test module.
    var name = String(reflecting: type(of: value))
    if let dot = name.firstIndex(of: "."), name.hasPrefix("StreamParsingTests.") {
      name = String(name[name.index(after: dot)...])
    }
    return arguments.isEmpty ? "\(name)()" : "\(name)(\(arguments.joined(separator: ", ")))"
  default:
    return "\(value)"
  }
}

protocol OptionalProtocol {
  var wrappedAny: Any? { get }
}

extension Optional: OptionalProtocol {
  var wrappedAny: Any? {
    switch self {
    case .none: nil
    case .some(let wrapped): wrapped
    }
  }
}

protocol StreamDictionaryProtocol {
  var pairsAny: [(String, Any)] { get }
}

extension StreamDictionary: StreamDictionaryProtocol {
  var pairsAny: [(String, Any)] { self.map { ($0.key, $0.value as Any) } }
}
