import CustomDump
import StreamParsing
import Testing

func expectSetValue<T: StreamActionReducer & Equatable>(
  initial: T,
  expected: T,
  streamedValue: StreamedValue
) throws where T.StreamAction == DefaultStreamAction {
  var value = initial
  try value.reduce(action: .setValue(streamedValue))
  expectNoDifference(value, expected)
}

func expectThrowsOnNonSetValue<T: StreamActionReducer>(
  initial: T
) where T.StreamAction == DefaultStreamAction {
  var reducer = initial
  #expect(throws: Error.self) {
    try reducer.reduce(action: .delegateKeyed(key: "invalid", .setValue("bad")))
  }
}

func expectThrowsOnSetValue<T: StreamActionReducer>(
  initial: T,
  streamedValue: StreamedValue
) where T.StreamAction == DefaultStreamAction {
  var value = initial
  #expect(throws: Error.self) {
    try value.reduce(action: .setValue(streamedValue))
  }
}
