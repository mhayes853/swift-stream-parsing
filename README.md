# Swift Stream Parsing

Stream parsing tools for Swift.

```swift
@StreamParseable
struct MyType {
  let fieldA: String
  let fieldB: Int
}

// Macro Generates Extension

extension MyType: StreamParseable {
  struct Partial {
    var fieldA: String?
    var fieldB: Int?

    init() {}

    mutating func next(from value: StreamedValue<Self>) {
      // ...
    }
  }
}

// Usage

let jsonSequence: some AsyncSequence<String, any Error> = someSequence()

let jsonPartials = "{ 'json': 'stream' }".partials(of: MyType.self, from: .json)
let asyncJSONPartials = jsonSequence.partials(of: MyType.self, from: .json)

for partial in jsonPartials {
  print(partial)
}

var stream = PartialsStream<MyType>(from: .json)

let string = "..."

var value = MyType.Partial()
for token in string {
  value = stream.next(from: token)
}
```
