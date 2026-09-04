import Foundation

@testable import StreamParsingCore

// Recorders for typed routing: the key match, the field table, and the frame stack.
//
// The model below is hand-built rather than macro-generated, because the site tool depends on
// `StreamParsingCore` and the macro lives a layer up. What the macro emits is a `[StreamField]`
// and a `StreamSchema` over it, which is exactly what these are, so the table the animation draws
// is built by the shipped `StreamFieldTable.init` and matched by the shipped matcher.

// MARK: - The model

/// The nested destination the frame trace parses into.
struct TraceAddress {
  var city = StreamString()
  var zip = 0
}

struct TracePerson {
  var id = 0
  var active = false
  var name = StreamString()
  var address = TraceAddress()
  var score = 0.0
}

/// A schema and the names the animation needs for it, kept together because the schema itself has
/// no name -- it is an object, and the frames borrow it by identity.
struct NamedSchema {
  var schema: StreamSchema
  var name: String
}

enum RoutingModel {
  static let addressFields: [StreamField] = _streamFields(
    of: TraceAddress.self, prototype: TraceAddress()
  ) { root in
    [
      StreamField(
        key: "city", index: 0, kind: .streamString, optional: false,
        offset: _streamFieldOffset(&root.pointee.city, in: root)
      ),
      StreamField(
        key: "zip", index: 1, kind: .int, optional: false,
        offset: _streamFieldOffset(&root.pointee.zip, in: root)
      )
    ]
  }

  static let address = StreamSchema(shape: .object, fields: Self.addressFields)

  static let personFields: [StreamField] = _streamFields(
    of: TracePerson.self, prototype: TracePerson()
  ) { root in
    [
      StreamField(
        key: "id", index: 0, kind: .int, optional: false,
        offset: _streamFieldOffset(&root.pointee.id, in: root)
      ),
      StreamField(
        key: "active", index: 1, kind: .bool, optional: false,
        offset: _streamFieldOffset(&root.pointee.active, in: root)
      ),
      StreamField(
        key: "name", index: 2, kind: .streamString, optional: false,
        offset: _streamFieldOffset(&root.pointee.name, in: root)
      ),
      StreamField(
        key: "address", index: 3,
        route: StreamFieldRoute(.container, optional: false, schema: RoutingModel.address),
        offset: _streamFieldOffset(&root.pointee.address, in: root)
      ),
      StreamField(
        key: "score", index: 4, kind: .double, optional: false,
        offset: _streamFieldOffset(&root.pointee.score, in: root)
      )
    ]
  }

  static let person = StreamSchema(shape: .object, fields: Self.personFields)

  /// Byte size of a member of each kind, from `MemoryLayout` on the shipped types rather than
  /// from a number written here.
  static func size(of kind: StreamFieldKind) -> Int {
    switch kind {
    case .int: MemoryLayout<Int>.size
    case .bool: MemoryLayout<Bool>.size
    case .double: MemoryLayout<Double>.size
    case .streamString: MemoryLayout<StreamString>.size
    case .container: MemoryLayout<TraceAddress>.size
    default: 0
    }
  }
}

// MARK: - A sink that reports its frame stack

/// Forwards every call to a real `PartialSink` and then reads the sink's own frame stack back out.
///
/// Nothing is reconstructed here: `frames` and `frameCount` are the sink's stored properties, so
/// what the animation draws is the stack the sink kept while the parse ran.
struct FrameRecordingSink: ~Copyable, StreamParseSink {
  var inner: PartialSink
  var steps: [FrameTrace.Step] = []
  var base: UnsafeRawPointer?
  var count = 0
  var root: UnsafeRawPointer
  var rootSize: Int
  var names: [ObjectIdentifier: Int] = [:]

  var streamFailure: StreamSinkFailure? { self.inner.streamFailure }

  init(inner: consuming PartialSink, root: UnsafeRawPointer, rootSize: Int) {
    self.inner = inner
    self.root = root
    self.rootSize = rootSize
  }

  mutating func beginObject() -> StreamContainerDisposition {
    let disposition = self.inner.beginObject()
    self.snapshot("beginObject")
    return disposition
  }
  mutating func endObject() {
    self.inner.endObject()
    self.snapshot("endObject")
  }
  mutating func beginArray() -> StreamContainerDisposition {
    let disposition = self.inner.beginArray()
    self.snapshot("beginArray")
    return disposition
  }
  mutating func endArray() {
    self.inner.endArray()
    self.snapshot("endArray")
  }

  mutating func key(_ bytes: Span<UInt8>) {
    let text = RecordingSink.text(bytes)
    let offset = self.locate(bytes)
    self.inner.key(bytes)
    self.snapshot("key", text: text, offset: offset, length: text.utf8.count)
  }
  mutating func string(_ bytes: Span<UInt8>) {
    let text = RecordingSink.text(bytes)
    let offset = self.locate(bytes)
    self.inner.string(bytes)
    self.snapshot("string", text: text, offset: offset, length: text.utf8.count)
  }
  mutating func stringBegin() {
    self.inner.stringBegin()
    self.snapshot("stringBegin")
  }
  mutating func stringChunk(_ bytes: Span<UInt8>) {
    let text = RecordingSink.text(bytes)
    let offset = self.locate(bytes)
    self.inner.stringChunk(bytes)
    self.snapshot("stringChunk", text: text, offset: offset, length: text.utf8.count)
  }
  mutating func stringEnd() {
    self.inner.stringEnd()
    self.snapshot("stringEnd")
  }
  mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) {
    let text = RecordingSink.text(bytes)
    let offset = self.locate(bytes)
    self.inner.number(bytes, info: info)
    self.snapshot("number", text: text, offset: offset, length: text.utf8.count)
  }
  mutating func boolean(_ value: Bool) {
    self.inner.boolean(value)
    self.snapshot("boolean", text: value ? "true" : "false")
  }
  mutating func null() {
    self.inner.null()
    self.snapshot("null", text: "null")
  }

  private func locate(_ bytes: Span<UInt8>) -> Int? {
    guard let base = self.base else { return nil }
    var offset: Int?
    bytes.withUnsafeBufferPointer { buffer in
      guard let start = buffer.baseAddress else { return }
      let delta = UnsafeRawPointer(start) - base
      if delta >= 0 && delta + buffer.count <= self.count { offset = delta }
    }
    return offset
  }

  private mutating func snapshot(
    _ call: String, text: String? = nil, offset: Int? = nil, length: Int? = nil
  ) {
    var frames: [FrameTrace.Frame] = []
    frames.reserveCapacity(self.inner.frameCount)
    for index in 0..<self.inner.frameCount {
      let frame = self.inner.frames[index]
      let schema = frame.schema
      let delta = UnsafeRawPointer(frame.storage) - self.root
      frames.append(
        FrameTrace.Frame(
          schema: self.names[ObjectIdentifier(schema)] ?? -1,
          storageOffset: delta >= 0 && delta < self.rootSize ? delta : nil,
          pendingField: frame.pendingField,
          field: RoutingTraces.fieldName(schema, at: frame.pendingField)
        )
      )
    }
    self.steps.append(
      FrameTrace.Step(
        index: self.steps.count,
        call: call,
        text: text,
        offset: offset,
        length: length,
        frames: frames,
        // Which member the call wrote. Only a scalar writes one: a key sets the pending field and
        // a container open or close moves the stack, so neither stores anything at an offset.
        wrote: ["number", "string", "stringEnd", "boolean", "null"].contains(call)
          && !frames.isEmpty
          ? RoutingTraces.fieldName(
            self.inner.frames[self.inner.frameCount - 1].schema,
            at: self.inner.frames[self.inner.frameCount - 1].pendingField
          )
          : nil
      )
    )
  }
}

// MARK: - The recorders

enum RoutingTraces {
  /// The key an entry index names, read out of the table's packed key bytes.
  static func fieldName(_ schema: StreamSchema, at index: Int32) -> String? {
    guard index >= 0, let table = schema.fields, Int(index) < table.count else { return nil }
    let entry = table.entries[Int(index)]
    return Self.key(of: entry, in: table)
  }

  static func key(of entry: StreamFieldEntry, in table: StreamFieldTable) -> String {
    String(
      decoding: UnsafeBufferPointer(
        start: table.keyBytes + Int(entry.keyStart), count: Int(entry.keyLength)
      ),
      as: UTF8.self
    )
  }

  static func name(_ kind: StreamFieldKind) -> String {
    switch kind {
    case .custom: "custom"
    case .int: "int"
    case .int8: "int8"
    case .int16: "int16"
    case .int32: "int32"
    case .int64: "int64"
    case .uint: "uint"
    case .uint8: "uint8"
    case .uint16: "uint16"
    case .uint32: "uint32"
    case .uint64: "uint64"
    case .double: "double"
    case .float: "float"
    case .bool: "bool"
    case .streamString: "streamString"
    case .inlineString: "inlineString"
    case .container: "container"
    }
  }

  static func routing(_ schema: StreamSchema) -> String {
    switch schema.keyRouting {
    case .match: "match"
    case .dictionary: "dictionary"
    case .ignore: "ignore"
    case .table: "table"
    }
  }

  static func shape(_ schema: StreamSchema) -> String {
    switch schema.shape {
    case .object: "object"
    case .array: "array"
    case .dictionary: "dictionary"
    case .scalar: "scalar"
    }
  }

  private static func hex(_ value: UInt64) -> String {
    "0x" + String(value, radix: 16, uppercase: true).leftPadded(to: 16)
  }

  /// The eight bytes of a padded leading word, in load order.
  private static func wordBytes(_ word: UInt64) -> [UInt8] {
    (0..<8).map { UInt8(truncatingIfNeeded: word >> UInt64($0 * 8)) }
  }

  // MARK: The field match

  /// Two real tables -- one under `StreamFieldTable.indexThreshold` and one over it -- probed with
  /// real keys, every answer checked against the shipped matcher.
  static func fieldMatch() -> FieldMatchTrace {
    let threshold = StreamFieldTable.indexThreshold

    // Over the threshold: the field count is what selects the strategy, so the table is built one
    // field past it rather than at an arbitrary size. Offsets are never written -- only the match
    // runs here -- so they are the members' strides and nothing more.
    let wideKeys = [
      "id", "name", "screen_name", "location", "description", "url", "protected",
      "followers_count", "friends_count", "listed_count", "created_at", "favourites_count",
      "utc_offset", "time_zone", "geo_enabled", "verified", "statuses_count", "lang",
      "contributors_enabled", "is_translator"
    ]
    let wideFields = wideKeys.enumerated().map { index, key in
      StreamField(
        key: key, index: Int32(index), kind: .int, optional: false, offset: index * 8
      )
    }
    let wide = StreamSchema(shape: .object, fields: wideFields)

    var tables: [FieldMatchTrace.Table] = []
    var verified = true

    tables.append(
      Self.table(
        name: "TracePerson", schema: RoutingModel.person,
        probes: ["name", "score", "address", "missing"], threshold: threshold, verified: &verified
      )
    )
    tables.append(
      Self.table(
        name: "TwitterUser", schema: wide,
        // `created_at` and `favourites_count` both hash onto a bucket another entry already took,
        // so their probes walk rather than landing: a chain of one every time would leave the
        // stride undrawn and unchecked.
        // `screen_nome` is not a field anyone would declare; it is the only shape that reaches the
        // tail compare and fails it. Sharing `screen_name`'s first word *and* its length means it
        // shares its hash too, so it probes the same bucket, passes both cheap tests, and is
        // rejected by `streamFieldTailMatches` — the call the match almost never makes.
        probes: ["screen_name", "created_at", "favourites_count", "screen_nome", "missing"],
        threshold: threshold,
        verified: &verified
      )
    )

    return FieldMatchTrace(tables: tables, verified: verified)
  }

  private static func table(
    name: String, schema: StreamSchema, probes: [String], threshold: Int, verified: inout Bool
  ) -> FieldMatchTrace.Table {
    guard let table = schema.fields else {
      verified = false
      return FieldMatchTrace.Table(
        name: name, strategy: "none", threshold: threshold, entries: [], slots: [], probes: []
      )
    }
    let indexed = table.index != nil
    let slotCount = indexed ? table.indexMask + 1 : 0
    let slots = (0..<slotCount).map { table.index![$0] }

    var entries: [FieldMatchTrace.Entry] = []
    for index in 0..<table.count {
      let entry = table.entries[index]
      let hash = streamFieldHash(word: entry.keyWord, length: entry.keyLength)
      entries.append(
        FieldMatchTrace.Entry(
          index: index,
          key: Self.key(of: entry, in: table),
          keyWord: Self.hex(entry.keyWord),
          wordBytes: Self.wordBytes(entry.keyWord),
          keyLength: Int(entry.keyLength),
          kind: Self.name(entry.kind),
          offset: Int(entry.offset),
          hash: Self.hex(hash),
          bucket: indexed ? Int(truncatingIfNeeded: hash) & table.indexMask : -1
        )
      )
    }

    var recorded: [FieldMatchTrace.Probe] = []
    for probe in probes {
      recorded.append(Self.probe(probe, table: table, indexed: indexed, verified: &verified))
    }

    return FieldMatchTrace.Table(
      name: name,
      strategy: indexed ? "indexed" : "scan",
      threshold: threshold,
      entries: entries,
      slots: slots,
      probes: recorded
    )
  }

  /// One key resolved. The walk below is `streamMatchField` / `streamMatchFieldIndexed` stepped
  /// out; `shipped` is those same functions run over the same table, and `verified` is the two
  /// agreeing.
  private static func probe(
    _ key: String, table: StreamFieldTable, indexed: Bool, verified: inout Bool
  ) -> FieldMatchTrace.Probe {
    let bytes = Array(key.utf8)
    var steps: [FieldMatchTrace.Step] = []
    var mirrored: Int32 = -1
    var shipped: Int32 = -1
    var word: UInt64 = 0
    var hash: UInt64 = 0
    var bytesHash: UInt64 = 0

    bytes.withUnsafeBufferPointer { buffer in
      let span = buffer.span
      let base = UnsafeRawPointer(buffer.baseAddress!)
      // The same call `StreamField.init` makes when it packs a declared key.
      word = streamPaddedWord(base: base, from: 0, to: buffer.count)
      let length = UInt16(truncatingIfNeeded: buffer.count)
      hash = streamFieldHash(word: word, length: length)
      // The byte-wise hash a dynamic key takes instead; the two are different questions.
      bytesHash = streamHashBytes(base: base, count: buffer.count)

      /// One entry compared, exactly as both matchers compare it: the word and the length first,
      /// and the tail only for a key longer than a word whose first word already matched.
      func compare(entry index: Int, bucket: Int) -> Bool {
        let entry = table.entries + index
        let wordEqual = entry.pointee.keyWord == word
        let lengthEqual = entry.pointee.keyLength == length
        var tailChecked = false
        var tailEqual = false
        var hit = false
        if wordEqual && lengthEqual {
          if buffer.count <= 8 {
            hit = true
          } else {
            tailChecked = true
            tailEqual = streamFieldTailMatches(entry, keyBytes: table.keyBytes, span)
            hit = tailEqual
          }
        }
        steps.append(
          FieldMatchTrace.Step(
            bucket: bucket, entry: index, wordEqual: wordEqual, lengthEqual: lengthEqual,
            tailChecked: tailChecked, tailEqual: tailEqual, hit: hit
          )
        )
        return hit
      }

      if indexed, let index = table.index {
        var bucket = Int(truncatingIfNeeded: hash) & table.indexMask
        while true {
          let slot = index[bucket]
          guard slot >= 0 else {
            steps.append(
              FieldMatchTrace.Step(
                bucket: bucket, entry: -1, wordEqual: false, lengthEqual: false,
                tailChecked: false, tailEqual: false, hit: false
              )
            )
            break
          }
          if compare(entry: Int(slot), bucket: bucket) {
            mirrored = slot
            break
          }
          bucket = (bucket &+ 1) & table.indexMask
        }
        shipped = streamMatchFieldIndexed(
          table.entries, index: index, mask: table.indexMask, keyBytes: table.keyBytes, span
        )
      } else {
        var index = 0
        while index < table.count {
          if compare(entry: index, bucket: -1) {
            mirrored = Int32(index)
            break
          }
          index += 1
        }
        shipped = streamMatchField(
          table.entries, count: table.count, keyBytes: table.keyBytes, span
        )
      }
    }

    if mirrored != shipped { verified = false }
    return FieldMatchTrace.Probe(
      key: key,
      bytes: bytes,
      word: Self.hex(word),
      wordBytes: Self.wordBytes(word),
      length: bytes.count,
      hash: Self.hex(hash),
      bytesHash: Self.hex(bytesHash),
      steps: steps,
      shipped: shipped,
      mirrored: mirrored,
      verified: mirrored == shipped
    )
  }

  // MARK: The frame stack

  static func frames(sample: String) throws -> (frames: FrameTrace, views: ViewTrace) {
    let bytes = Array(sample.utf8)
    var person = TracePerson()

    var schemas: [FrameTrace.Schema] = []
    var names: [ObjectIdentifier: Int] = [:]
    for (index, named) in [
      NamedSchema(schema: RoutingModel.person, name: "TracePerson"),
      NamedSchema(schema: RoutingModel.address, name: "TraceAddress")
    ].enumerated() {
      names[ObjectIdentifier(named.schema)] = index
      schemas.append(
        FrameTrace.Schema(
          id: index,
          name: named.name,
          shape: Self.shape(named.schema),
          keyRouting: Self.routing(named.schema),
          fieldCount: named.schema.fields?.count ?? 0
        )
      )
    }

    var members: [FrameTrace.Member] = []
    for (schemaIndex, fields) in [RoutingModel.personFields, RoutingModel.addressFields].enumerated()
    {
      for field in fields {
        members.append(
          FrameTrace.Member(
            name: field.key.isEmpty ? "" : String(decoding: field.key, as: UTF8.self),
            offset: Int(field.offset),
            size: RoutingModel.size(of: field.kind),
            kind: Self.name(field.kind),
            schema: schemaIndex
          )
        )
      }
    }

    var steps: [FrameTrace.Step] = []
    var failure: StreamSinkFailure?
    try withUnsafeMutablePointer(to: &person) { root in
      var sink = FrameRecordingSink(
        inner: PartialSink(root: root, schema: RoutingModel.person),
        root: UnsafeRawPointer(root),
        rootSize: MemoryLayout<TracePerson>.size
      )
      sink.names = names
      var parser = JSONParser()
      try bytes.withUnsafeBufferPointer { buffer in
        sink.base = UnsafeRawPointer(buffer.baseAddress!)
        sink.count = buffer.count
        try parser.parse(buffer, into: &sink)
      }
      try parser.finish(into: &sink)
      steps = sink.steps
      failure = sink.streamFailure
    }

    // The whole thing is only worth drawing if the parse actually landed where it says it did.
    let expected = TracePerson(
      id: 7, active: true, name: StreamString("Ada"),
      address: TraceAddress(city: StreamString("Cairo"), zip: 11511), score: 1.5
    )
    let verified =
      failure == nil && person.id == expected.id && person.active == expected.active
      && String(person.name) == String(expected.name)
      && String(person.address.city) == String(expected.address.city)
      && person.address.zip == expected.address.zip && person.score == expected.score
      && steps.contains { $0.frames.count == 2 }

    let result =
      "TracePerson(id: \(person.id), active: \(person.active), name: \"\(String(person.name))\", "
      + "address: TraceAddress(city: \"\(String(person.address.city))\", zip: \(person.address.zip)), "
      + "score: \(person.score))"

    let frames = FrameTrace(
      sample: sample,
      bytes: bytes,
      rootSize: MemoryLayout<TracePerson>.size,
      schemas: schemas,
      members: members,
      steps: steps,
      verified: verified,
      result: result
    )

    // The same parse, read two ways: one member at a time, or the whole value.
    let values: [String] = [
      "\(person.id)", "\(person.active)", "\"\(String(person.name))\"",
      "TraceAddress(city: \"\(String(person.address.city))\", zip: \(person.address.zip))",
      "\(person.score)"
    ]
    let views = ViewTrace(
      typeName: "TracePerson",
      size: MemoryLayout<TracePerson>.size,
      stride: MemoryLayout<TracePerson>.stride,
      members: RoutingModel.personFields.enumerated().map { index, field in
        ViewTrace.Member(
          name: String(decoding: field.key, as: UTF8.self),
          offset: Int(field.offset),
          size: RoutingModel.size(of: field.kind),
          kind: Self.name(field.kind),
          value: values[index],
          // A `StreamString` that outgrew its inline bytes points at blocks the value does not
          // contain, which is the one member a copy of the storage does not fully copy.
          indirect: field.kind == .streamString
        )
      },
      verified: verified
    )

    return (frames, views)
  }
}

extension String {
  /// Zero-padded to a fixed width, for a hex word that has to line up with the one above it.
  fileprivate func leftPadded(to width: Int) -> String {
    self.count >= width ? self : String(repeating: "0", count: width - self.count) + self
  }
}
