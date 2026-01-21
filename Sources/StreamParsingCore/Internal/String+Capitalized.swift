extension StringProtocol {
  var capitalized: String {
    guard let first = self.first else { return "" }
    let firstChars = String(first).uppercased()
    let remainder = String(self.dropFirst()).lowercased()
    return firstChars + remainder
  }
}
