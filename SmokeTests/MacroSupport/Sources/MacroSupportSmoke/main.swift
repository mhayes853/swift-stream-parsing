import StreamParsing
import Foundation

@attached(member, names: named(Partial))
macro SupportPartial() = #externalMacro(module: "SupportMacros", type: "SupportPartialMacro")

@attached(member, names: named(Partial))
macro SupportMatcher() = #externalMacro(module: "SupportMacros", type: "SupportMatcherMacro")

@attached(member, names: named(Accumulator))
macro SupportFullPartial() =
  #externalMacro(module: "SupportMacros", type: "SupportFullPartialMacro")

@SupportPartial
struct Customer {}

@SupportMatcher
struct Lookup {}

@SupportFullPartial
public struct CustomCustomer {}

var stream = PartialsStream<Customer.Partial>(from: .json())
try stream.next(#"{"customer_name":"Ada","customer_id":42,"tags":["swift","macros"]}"#.utf8)
precondition(unsafe stream.withView { unsafe $0.name?.value } == "Ada")
precondition(unsafe stream.withView { $0.marker } == 42)
let partial = try stream.finish()
precondition(partial.id == 42)
precondition(partial.tags?.count == 2)
precondition(partial.recognizedFields == [Customer.Partial.nameField, Customer.Partial.idField, Customer.Partial.tagsField])
precondition(partial.nameWasEmpty == [true])
var tracking = Customer.Partial(tracking: .enabled)
tracking.recognizedFields.append(Customer.Partial.nameField)
precondition(tracking[0] == Customer.Partial.nameField)
tracking.resetTracking()
precondition(tracking.recognizedFields.isEmpty)

var custom = PartialsStream<CustomCustomer.Accumulator>(from: .json())
try custom.next(#"{"a\u0000":7}"#.utf8)
let customPartial = try custom.finish()
precondition(customPartial.default == 7)
precondition(customPartial.count == 1)

let keys = ["", "a", "a\0", "customer_name", "customer_id", "é", "e\u{301}", "abcdefghijklmno\0"]
for (index, key) in keys.enumerated() {
  var lookup = PartialsStream<Lookup.Partial>(from: .json())
  let data = try JSONEncoder().encode([key: index])
  for byte in data { try lookup.next([byte]) }
  let result = try lookup.finish()
  precondition(result.recognizedFields == [Lookup.Partial.identifier(at: index)])
}
for key in ["unknown", "customer_age", "customer_nam", "a\0\0", "abcdefghijklmno"] {
  var lookup = PartialsStream<Lookup.Partial>(from: .json())
  try lookup.next(JSONEncoder().encode([key: 1]))
  let result = try lookup.finish()
  precondition(result.recognizedFields.isEmpty)
}

let repeated = #"{"customer_name":"A","name":"B","unknown":{"name":"ignored"},"customer_id":1}"#
for chunked in [false, true] {
  var repeatedStream = PartialsStream<Customer.Partial>(from: .json())
  if chunked {
    for byte in repeated.utf8 { try repeatedStream.next([byte]) }
  } else {
    try repeatedStream.next(repeated.utf8)
  }
  let result = try repeatedStream.finish()
  precondition(result.recognizedFields == [Customer.Partial.nameField, Customer.Partial.nameField, Customer.Partial.idField])
  precondition(result.nameWasEmpty == [true, false])
}

var nested = PartialsStream<StreamArray<Customer.Partial?>>(from: .json())
try nested.next(#"[{"customer_id":1},null,{"name":"A"}]"#.utf8)
let nestedResult = try nested.finish()
precondition(nestedResult[0]?.recognizedFields == [Customer.Partial.idField])
precondition(nestedResult[1] == nil)
precondition(nestedResult[2]?.recognizedFields == [Customer.Partial.nameField])

var optional = PartialsStream<Customer.Partial?>(from: .json())
try optional.next(#"{"name":"A","customer_id":1}"#.utf8)
let optionalResult = try optional.finish()
precondition(optionalResult?.recognizedFields == [Customer.Partial.nameField, Customer.Partial.idField])
print("Macro support smoke passed")
