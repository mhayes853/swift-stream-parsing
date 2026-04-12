func decodeKeyFromSnakeCase(_ key: String) -> String {
  guard !key.isEmpty else { return key }
  guard let firstNonUnderscore = key.firstIndex(where: { $0 != "_" }) else { return key }

  var lastNonUnderscore = key.index(before: key.endIndex)
  while lastNonUnderscore > firstNonUnderscore && key[lastNonUnderscore] == "_" {
    key.formIndex(before: &lastNonUnderscore)
  }

  let keyRange = firstNonUnderscore...lastNonUnderscore
  let leadingUnderscoreRange = key.startIndex..<firstNonUnderscore
  let trailingUnderscoreRange = key.index(after: lastNonUnderscore)..<key.endIndex

  let components = key[keyRange].split(separator: "_")
  let joinedString: String
  if components.count == 1 {
    joinedString = String(key[keyRange])
  } else {
    joinedString = ([components[0].lowercased()] + components[1...].map(\.capitalized)).joined()
  }

  if leadingUnderscoreRange.isEmpty && trailingUnderscoreRange.isEmpty {
    return joinedString
  } else if !leadingUnderscoreRange.isEmpty && !trailingUnderscoreRange.isEmpty {
    return String(key[leadingUnderscoreRange]) + joinedString + String(key[trailingUnderscoreRange])
  } else if !leadingUnderscoreRange.isEmpty {
    return String(key[leadingUnderscoreRange]) + joinedString
  } else {
    return joinedString + String(key[trailingUnderscoreRange])
  }
}
