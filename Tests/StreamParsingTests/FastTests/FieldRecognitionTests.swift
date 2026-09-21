import StreamParsingCore
import Testing

private struct RecognitionStorage {
  var value = false
  var other = false
  var recognized: [StreamFieldID] = []
  var valuesAtRecognition: [Bool] = []
}

@Suite
struct FieldRecognitionTests {
  @Test(arguments: [false, true], [false, true])
  func recognitionUsesLogicalIdentity(table: Bool, enabled: Bool) {
    let valueOffset = MemoryLayout<RecognitionStorage>.offset(of: \.value)!
    let otherOffset = MemoryLayout<RecognitionStorage>.offset(of: \.other)!
    let fields = [
      StreamField(key: "value", index: 17, kind: .bool, optional: false, offset: valueOffset),
      StreamField(key: "alias", index: 17, kind: .bool, optional: false, offset: valueOffset),
      StreamField(key: "other", index: 42, kind: .bool, optional: false, offset: otherOffset),
    ]
    let recognition: (@Sendable (UnsafeMutableRawPointer, StreamFieldID) -> Void)?
    if enabled {
      recognition = { storage, field in
        let p = storage.assumingMemoryBound(to: RecognitionStorage.self)
        p.pointee.recognized.append(field)
        p.pointee.valuesAtRecognition.append(p.pointee.value)
      }
    } else {
      recognition = nil
    }
    let schema = StreamSchema(
      shape: .object,
      matchField: { key in
        if recognitionKeyEquals(key, "value") || recognitionKeyEquals(key, "alias") { return 17 }
        if recognitionKeyEquals(key, "other") { return 42 }
        return -1
      },
      onFieldRecognized: recognition,
      applyBoolean: { storage, field, value in
        let p = storage.assumingMemoryBound(to: RecognitionStorage.self)
        if field == 17 { p.pointee.value = value }
        else if field == 42 { p.pointee.other = value }
        else { return .unsupported }
        return .applied
      },
      fields: table ? fields : []
    )
    var value = RecognitionStorage()
    withUnsafeMutablePointer(to: &value) { storage in
      var sink = PartialSink(root: storage, schema: schema)
      _ = sink.beginObject()
      for key in ["value", "alias", "other", "unknown", "value"] {
        let bytes = Array(key.utf8)
        sink.key(bytes.span)
        sink.boolean(true)
      }
      sink.endObject()
      #expect(sink.streamFailure == nil)
    }
    #expect(value.value)
    #expect(value.other)
    #expect(value.recognized == (enabled
      ? [_streamFieldID(17), _streamFieldID(17), _streamFieldID(42), _streamFieldID(17)] : []))
    #expect(value.valuesAtRecognition == (enabled ? [false, true, true, true] : []))
    #expect(Set(value.recognized).count == (enabled ? 2 : 0))
  }

  @Test(arguments: [false, true])
  func recognitionDoesNotImplySuccessfulApplication(table: Bool) {
    let schema = StreamSchema(
      shape: .object,
      matchField: { _ in 17 },
      onFieldRecognized: { storage, field in
        storage.assumingMemoryBound(to: RecognitionStorage.self).pointee.recognized.append(field)
      },
      fields: table ? [StreamField(
        key: "value", index: 17, kind: .bool, optional: false,
        offset: MemoryLayout<RecognitionStorage>.offset(of: \.value)!
      )] : []
    )
    var value = RecognitionStorage()
    withUnsafeMutablePointer(to: &value) { storage in
      var sink = PartialSink(root: storage, schema: schema)
      _ = sink.beginObject()
      let key = Array("value".utf8)
      sink.key(key.span)
      #expect(storage.pointee.recognized == [_streamFieldID(17)])
      let text = Array("wrong type".utf8)
      sink.string(text.span)
      #expect(sink.streamFailure != nil)
      #expect(storage.pointee.recognized.count == 1)
      sink.endObject()
    }
  }
}

private func recognitionKeyEquals(_ key: Span<UInt8>, _ string: String) -> Bool {
  let bytes = Array(string.utf8)
  guard key.count == bytes.count else { return false }
  for index in bytes.indices {
    if key[index] != bytes[index] { return false }
  }
  return true
}
