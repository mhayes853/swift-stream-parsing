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
    #expect(self.failure(json) == .typeMismatch)
  }

  @Test(arguments: [Int.max, 7, 1])
  func `A mismatch is reported at every chunk size`(chunk: Int) {
    #expect(self.failure(#"{"count":"nope"}"#, chunk: chunk) == .typeMismatch)
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
    #expect(self.failure(json) == .typeMismatch)
  }

  @Test
  func `A number inside the destination range is accepted`() {
    #expect(self.failure(#"{"small":127}"#) == nil)
    #expect(self.failure(#"{"small":-128}"#) == nil)
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
    #expect(self.failure(json) == nil)
  }

  @Test
  func `Matching tokens are accepted`() throws {
    var value = StrictValues.Partial()
    try parsePartial(
      #"{"count":42,"name":"Blob","flag":true,"scores":[1,2],"nested":{"id":9}}"#,
      into: &value
    )
    #expect(value.count == 42)
    #expect(value.name == "Blob")
    #expect(value.flag == true)
    #expect(value.scores == [1, 2])
    #expect(value.nested?.id == 9)
  }

  // MARK: - Failure propagation

  @Test
  func `The rejection surfaces as a parsing error carrying the sink failure`() throws {
    var value = StrictValues.Partial()
    let error = #expect(throws: JSONParsingError.self) {
      try parsePartial(#"{"count":"nope"}"#, into: &value)
    }
    #expect(error?.reason == .sinkRejectedToken(StreamSinkFailure(reason: .typeMismatch)))
  }

  // The first rejection is the one reported, so an error does not get overwritten by whatever
  // the rest of the document happens to do.
  @Test
  func `The first rejection is the one reported`() {
    #expect(self.failure(#"{"count":"nope","name":42}"#) == .typeMismatch)
  }
}
