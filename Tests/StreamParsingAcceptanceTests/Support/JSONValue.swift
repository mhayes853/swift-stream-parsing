import Foundation
import StreamParsingCore

// A document as a plain tree, built two independent ways: by `JSONDecoder` (the oracle) and by
// the raw parser driving `TreeSink` (the subject). Numbers are compared as the correctly rounded
// `Double` each side produces -- integers past 2^53 round identically on both, and exact 64-bit
// integers are pinned separately through the typed layer.
indirect enum JSONValue: Equatable, Decodable {
  case object([String: JSONValue])
  case array([JSONValue])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  static func foundation(_ bytes: [UInt8]) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(bytes))
  }

  /// Counts of each token kind in the tree, used where a sink only counts.
  var census: Census {
    var census = Census()
    func walk(_ value: JSONValue) {
      switch value {
      case .object(let members):
        census.objects += 1
        census.keys += members.count
        members.values.forEach(walk)
      case .array(let elements):
        census.arrays += 1
        elements.forEach(walk)
      case .string: census.strings += 1
      case .number: census.numbers += 1
      case .bool: census.booleans += 1
      case .null: census.nulls += 1
      }
    }
    walk(self)
    return census
  }

  struct Census: Equatable {
    var objects = 0, arrays = 0, keys = 0, strings = 0, numbers = 0, booleans = 0, nulls = 0
  }
}

/// Rebuilds a `JSONValue` from raw parse events. Strings are accumulated as bytes and decoded
/// once at `stringEnd`, so a chunk boundary inside a UTF-8 sequence cannot be papered over by a
/// per-chunk repairing decode: the parser must hand over exactly the right bytes.
struct TreeSink: StreamParseSink {
  private enum Frame {
    case object([String: JSONValue], key: String?)
    case array([JSONValue])
  }

  private var frames = [Frame]()
  private var stringBytes = [UInt8]()
  private(set) var root: JSONValue?
  var streamFailure: StreamSinkFailure?

  mutating func beginObject() -> StreamContainerDisposition {
    self.frames.append(.object([:], key: nil))
    return .stream
  }

  mutating func endObject() {
    guard case .object(let members, _)? = self.frames.popLast() else { return }
    self.deliver(.object(members))
  }

  mutating func beginArray() -> StreamContainerDisposition {
    self.frames.append(.array([]))
    return .stream
  }

  mutating func endArray() {
    guard case .array(let elements)? = self.frames.popLast() else { return }
    self.deliver(.array(elements))
  }

  mutating func key(_ bytes: Span<UInt8>) {
    guard case .object(let members, _)? = self.frames.last else { return }
    let key = bytes.withUnsafeBufferPointer { String(decoding: $0, as: UTF8.self) }
    self.frames[self.frames.count - 1] = .object(members, key: key)
  }

  mutating func stringBegin() { self.stringBytes.removeAll(keepingCapacity: true) }

  mutating func stringChunk(_ bytes: Span<UInt8>) {
    bytes.withUnsafeBufferPointer { self.stringBytes.append(contentsOf: $0) }
  }

  mutating func stringEnd() {
    self.deliver(.string(String(decoding: self.stringBytes, as: UTF8.self)))
  }

  mutating func number(_ bytes: Span<UInt8>, info: NumberInfo) {
    let text = bytes.withUnsafeBufferPointer { String(decoding: $0, as: UTF8.self) }
    self.deliver(.number(Double(text) ?? .nan))
  }

  mutating func boolean(_ value: Bool) { self.deliver(.bool(value)) }
  mutating func null() { self.deliver(.null) }

  private mutating func deliver(_ value: JSONValue) {
    guard let frame = self.frames.popLast() else {
      self.root = value
      return
    }
    switch frame {
    case .object(var members, let key):
      members[key ?? ""] = value
      self.frames.append(.object(members, key: nil))
    case .array(var elements):
      elements.append(value)
      self.frames.append(.array(elements))
    }
  }
}

/// Drives the raw parser over `bytes` in the given chunking, without the typed layer.
func parseRaw<Sink: StreamParseSink>(
  _ bytes: [UInt8],
  into sink: inout Sink,
  chunking: Chunking = .whole,
  bufferCapacity: Int = 4096
) throws {
  var parser = JSONParser(bufferCapacity: bufferCapacity)
  try bytes.withUnsafeBufferPointer { buffer in
    for range in chunking.ranges(count: buffer.count) {
      try parser.parse(UnsafeBufferPointer(rebasing: buffer[range]), into: &sink)
    }
  }
  try parser.finish(into: &sink)
}

/// The `JSONParsingError` the raw parser reports for `bytes`, or `nil` if it accepts them.
func rawParsingError(
  _ bytes: [UInt8], chunking: Chunking = .whole, bufferCapacity: Int = 4096
) -> JSONParsingError? {
  var sink = TreeSink()
  do {
    try parseRaw(bytes, into: &sink, chunking: chunking, bufferCapacity: bufferCapacity)
    return nil
  } catch let error as JSONParsingError {
    return error
  } catch {
    return nil
  }
}
