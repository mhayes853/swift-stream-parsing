import StreamParsing

@attached(member, names: named(Partial))
macro SupportPartial() = #externalMacro(module: "SupportMacros", type: "SupportPartialMacro")

@attached(member, names: named(switchMatch), named(ifMatch))
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

var custom = PartialsStream<CustomCustomer.Accumulator>(from: .json())
try custom.next(#"{"a\u0000":7}"#.utf8)
let customPartial = try custom.finish()
precondition(customPartial.default == 7)

let keys = ["", "a", "a\0", "customer_name", "customer_id", "é", "e\u{301}", "abcdefghijklmno\0"]
for (index, key) in keys.enumerated() {
  let bytes = Array(key.utf8)
  precondition(Lookup.switchMatch(bytes.span) == index)
  precondition(Lookup.ifMatch(bytes.span) == index)
}
for key in ["unknown", "customer_age", "customer_nam", "a\0\0", "abcdefghijklmno"] {
  let bytes = Array(key.utf8)
  precondition(Lookup.switchMatch(bytes.span) == -1)
  precondition(Lookup.ifMatch(bytes.span) == -1)
}
print("Macro support smoke passed")
