import CustomDump
import Testing

import StreamParsing
import StreamParsingCore

@StreamParseable
struct StrictValues: Equatable {
  var count: Int = 0
  var name: String = ""
  var flag: Bool = false
  var small: Int8 = 0
  var scores: [Int] = []
  var nested: StrictNested = StrictNested()
}

@StreamParseable
struct StrictNested: Equatable {
  var id: Int = 0
}

extension StrictNested.Partial: Equatable {}

// A key the destination does not have has always been ignored, but a key that matches a field
// which cannot hold the token is a different thing, and the registration based parser threw for
// it. The apply closures report whether they applied the token so the sink can tell those two
// apart, and the parser already knew how to surface a sink failure.
@Suite
struct `Partial sink failure tests` {
  private func failure(
    _ json: String, chunk: Int = .max
  ) -> StreamSinkFailure.Reason? {
    var value = StrictValues.Partial()
    do {
      try parsePartial(json, into: &value, chunk: chunk)
      return nil
    } catch let error as JSONParsingError {
      guard case .sinkRejectedToken(let failure) = error.reason else { return nil }
      return failure.reason
    } catch {
      return nil
    }
  }

  // MARK: - Type mismatches

  @Test(
    arguments: [
      #"{"count":"not a number"}"#,
      #"{"count":true}"#,
      #"{"name":42}"#,
      #"{"name":false}"#,
      #"{"flag":"yes"}"#,
      #"{"flag":1}"#,
      #"{"scores":"not an array"}"#,
      #"{"nested":7}"#
    ]
  )
  func `A token the matched field cannot hold is rejected`(json: String) {
    expectNoDifference(self.failure(json), .typeMismatch)
  }

  @Test(arguments: [Int.max, 7, 1])
  func `A mismatch is reported at every chunk size`(chunk: Int) {
    expectNoDifference(self.failure(#"{"count":"nope"}"#, chunk: chunk), .typeMismatch)
  }

  // MARK: - Values that do not fit

  // A magnitude the destination cannot represent is a rejection rather than a silent no-op,
  // which is what reports the overflow the registration based parser threw for.
  @Test(
    arguments: [
      #"{"small":128}"#,
      #"{"small":-129}"#,
      #"{"count":99999999999999999999999999}"#,
      #"{"small":1.5}"#
    ]
  )
  func `A number the destination cannot hold is rejected`(json: String) {
    expectNoDifference(self.failure(json), .typeMismatch)
  }

  @Test
  func `A number inside the destination range is accepted`() {
    expectNoDifference(self.failure(#"{"small":127}"#), nil)
    expectNoDifference(self.failure(#"{"small":-128}"#), nil)
  }

  // MARK: - Not failures

  // Unknown keys have always been ignored, and nothing about reporting mismatches should change
  // that. This is the distinction the whole change turns on.
  @Test(
    arguments: [
      #"{"unknown":"x"}"#,
      #"{"unknown":42}"#,
      #"{"unknown":{"deep":[1,2]}}"#,
      #"{"count":1,"unknown":true,"name":"Blob"}"#
    ]
  )
  func `A key the destination does not have is still ignored`(json: String) {
    expectNoDifference(self.failure(json), nil)
  }

  @Test
  func `Matching tokens are accepted`() throws {
    var value = StrictValues.Partial()
    try parsePartial(
      #"{"count":42,"name":"Blob","flag":true,"scores":[1,2],"nested":{"id":9}}"#,
      into: &value
    )
    expectNoDifference(value.count, 42)
    expectNoDifference(value.name, "Blob")
    expectNoDifference(value.flag, true)
    expectNoDifference(value.scores, [1, 2])
    expectNoDifference(value.nested?.id, 9)
  }

  // MARK: - Failure propagation

  @Test
  func `The rejection surfaces as a parsing error carrying the sink failure`() throws {
    var value = StrictValues.Partial()
    let error = #expect(throws: JSONParsingError.self) {
      try parsePartial(#"{"count":"nope"}"#, into: &value)
    }
    expectNoDifference(error?.reason, .sinkRejectedToken(StreamSinkFailure(reason: .typeMismatch)))
  }

  // The first rejection is the one reported, so an error does not get overwritten by whatever
  // the rest of the document happens to do.
  @Test
  func `The first rejection is the one reported`() {
    expectNoDifference(self.failure(#"{"count":"nope","name":42}"#), .typeMismatch)
  }

  // MARK: - Elements and values, not just fields

  // The complement of the shape check in `enterContainer`. That one rejects a container reaching
  // a destination that cannot hold it. This is the opposite pairing — the container shape is right
  // and the contents are not — and it also rejects, because the destination matched and then
  // refused the token.
  //
  // The tests above only ever reach an object field. An element and a dictionary value resolve
  // through different branches of `resolveScalarTarget`, so they are covered separately.

  private func failure<Root: StreamParseableRoot>(
    _ json: String, as type: Root.Type, chunk: Int = .max
  ) -> StreamSinkFailure.Reason? {
    var value = Root.streamInitialValue()
    do {
      try parsePartial(json, into: &value, chunk: chunk)
      return nil
    } catch let error as JSONParsingError {
      guard case .sinkRejectedToken(let failure) = error.reason else { return nil }
      return failure.reason
    } catch {
      return nil
    }
  }

  @Test(arguments: [Int.max, 7, 1])
  func `An array element the destination cannot hold is rejected`(chunk: Int) {
    expectNoDifference(self.failure(#"["a","b"]"#, as: StreamArray<Int>.self, chunk: chunk), .typeMismatch)
    expectNoDifference(self.failure("[true]", as: StreamArray<Int>.self, chunk: chunk), .typeMismatch)
    expectNoDifference(self.failure("[1,2]", as: StreamArray<String>.self, chunk: chunk), .typeMismatch)
    expectNoDifference(self.failure("[true]", as: StreamArray<String>.self, chunk: chunk), .typeMismatch)
    expectNoDifference(self.failure("[1]", as: StreamArray<Bool>.self, chunk: chunk), .typeMismatch)
  }

  @Test(arguments: [Int.max, 7, 1])
  func `A dictionary value the destination cannot hold is rejected`(chunk: Int) {
    let dictionary = StreamDictionary<Int>.self
    expectNoDifference(self.failure(#"{"a":"x"}"#, as: dictionary, chunk: chunk), .typeMismatch)
    expectNoDifference(self.failure(#"{"a":true}"#, as: dictionary, chunk: chunk), .typeMismatch)
    expectNoDifference(self.failure(#"{"a":1}"#, as: StreamDictionary<String>.self, chunk: chunk), .typeMismatch)
  }

  // The array field case the tests above stop short of: `{"scores":"not an array"}` rejects the
  // array itself, and this rejects an element of an array that was accepted.
  @Test(arguments: [Int.max, 7, 1])
  func `An element of an array field is rejected on its own`(chunk: Int) {
    expectNoDifference(self.failure(#"{"scores":["a"]}"#, chunk: chunk), .typeMismatch)
    expectNoDifference(self.failure(#"{"scores":[1,true]}"#, chunk: chunk), .typeMismatch)
  }

  @Test(arguments: [Int.max, 7, 1])
  func `A mismatch nested inside a container is still rejected`(chunk: Int) {
    expectNoDifference(self.failure(#"[["a"]]"#, as: StreamArray<StreamArray<Int>>.self, chunk: chunk), .typeMismatch)
    expectNoDifference(self.failure(#"{"a":["x"]}"#, as: StreamDictionary<StreamArray<Int>>.self, chunk: chunk), .typeMismatch)
  }

  // MARK: - Null, which is accepted exactly where the destination is optional

  // `null` is not special cased anywhere; it goes through `applyNull` like every other token. So
  // it lands on whether the destination has a way to represent absence, which splits the
  // containers from the macro's fields rather than arbitrarily: every member of a `Partial` is
  // optional, so null always clears one, while a `StreamArray<Int>` element is an `Int` and has
  // nowhere to put it.
  @Test(arguments: [Int.max, 7, 1])
  func `Null is rejected by a non optional element or value`(chunk: Int) {
    expectNoDifference(self.failure("[1,null]", as: StreamArray<Int>.self, chunk: chunk), .typeMismatch)
    expectNoDifference(self.failure(#"{"a":null}"#, as: StreamDictionary<Int>.self, chunk: chunk), .typeMismatch)
  }

  @Test(arguments: [Int.max, 7, 1])
  func `Null is accepted by an optional element or field`(chunk: Int) throws {
    expectNoDifference(self.failure("[null]", as: StreamArray<Int?>.self, chunk: chunk), nil)
    expectNoDifference(self.failure(#"{"count":null}"#, chunk: chunk), nil)

    var elements = StreamArray<Int?>()
    try parsePartial("[null]", into: &elements, chunk: chunk)
    expectNoDifference(elements, [nil])
  }

  // MARK: - The value itself versus its first field

  // An element's destination is the element, not its first member. Both reach a schema through
  // `applyString(storage, field, bytes)`, so while the sink named the element field 0 an object
  // arriving as an element absorbed the scalar into whichever member the type declared first:
  // this wrote "abc" into `StrictNested.id`'s neighbour and reported nothing. `[5]` was a mismatch
  // only because that member could not hold a number, which is a property of the declaration
  // order rather than of the document.
  @Test(arguments: [Int.max, 7, 1])
  func `A scalar arriving where an object is expected is rejected`(chunk: Int) {
    func elementFailure(_ json: String) -> StreamSinkFailure.Reason? {
      var elements = StreamArray<StrictNested.Partial>()
      do {
        try parsePartial(json, into: &elements, chunk: chunk)
        return nil
      } catch let error as JSONParsingError {
        guard case .sinkRejectedToken(let failure) = error.reason else { return nil }
        return failure.reason
      } catch {
        return nil
      }
    }

    for json in [#"["abc"]"#, "[5]", "[true]", "[null]"] {
      expectNoDifference(elementFailure(json), .typeMismatch, "\(json)")
    }

    var values = StreamDictionary<StrictNested.Partial>()
    #expect(throws: JSONParsingError.self) {
      try parsePartial(#"{"k":"abc"}"#, into: &values, chunk: chunk)
    }
  }

  // The same distinction on the null path, where getting it wrong lost data rather than accepting
  // it: `Optional`'s schema cleared the whole optional whatever field the null named, so a null on
  // one member of an optional element wiped the members already parsed into it.
  @Test(arguments: [Int.max, 7, 1])
  func `A null names the field it arrived under, not the whole element`(chunk: Int) throws {
    var elements = StreamArray<StrictNested.Partial?>()
    try parsePartial(#"[{"id":null}]"#, into: &elements, chunk: chunk)
    expectNoDifference(elements, [StrictNested.Partial(id: nil)])

    var values = StreamDictionary<StrictNested.Partial?>()
    try parsePartial(#"{"k":{"id":null}}"#, into: &values, chunk: chunk)
    expectNoDifference(values, ["k": StrictNested.Partial(id: nil)])

    // A null that *is* the element still clears it.
    var cleared = StreamArray<StrictNested.Partial?>()
    try parsePartial("[null]", into: &cleared, chunk: chunk)
    expectNoDifference(cleared, [nil])
  }

  // MARK: - What the partial holds when it stops

  // Resolving a target is what materialises the slot, and it happens before the token is applied,
  // so a rejected element is present holding its initial value. A rejected container leaves its
  // slot behind for the same reason.
  //
  // Parsing stops at the rejected token rather than running on to the end of the chunk, so the
  // elements after it never arrive.
  @Test(arguments: [Int.max, 7, 1])
  func `A rejected element leaves its slot at the initial value`(chunk: Int) {
    var elements = StreamArray<Int>()
    #expect(throws: JSONParsingError.self) {
      try parsePartial(#"[1,"a",3]"#, into: &elements, chunk: chunk)
    }
    expectNoDifference(elements, [1, 0], "the rejected element is present, and 3 never arrives")

    var counts = StreamDictionary<Int>()
    #expect(throws: JSONParsingError.self) {
      try parsePartial(#"{"a":"x"}"#, into: &counts, chunk: chunk)
    }
    expectNoDifference(counts, ["a": 0], "the key stays, holding the value it was materialised with")
  }
}
