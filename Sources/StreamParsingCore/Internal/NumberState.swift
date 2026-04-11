// MARK: - NumberState

struct NumberState {
  var hasDigits = false
  var hasLeadingZero = false
  var hasFractionDigits = false
  var hasExponent = false
  var hasExponentDigits = false
  var hasDot = false
  var digitCount = 0
  var isHex = false
  var hasHexDigits = false

  mutating func reset() {
    self = NumberState()
  }
}
