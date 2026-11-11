import Foundation
@_spi(Benchmarking) import StreamParsingCore

// Set STREAM_PARSING_COLLISION_REPORT=1 on any benchmark command to print this report during
// registration. It replays the production table's growth policy from the parsed insertion order,
// so measuring it adds no counters or storage to StreamDictionary itself.
func reportRealWorldDictionaryCollisions() {
  let citm = expectParses {
    try streamBulkDiscarding(Payloads.citmCatalog, as: BenchmarkCITM.Partial.self)
  }
  let gsoc = expectParses {
    try streamBulkDiscarding(
      Payloads.gsoc2018, as: StreamDictionary<BenchmarkGSoCProject.Partial>.self
    )
  }

  print("\nStreamDictionary collision report")
  reportCollisions("CITM areaNames", in: citm.areaNames)
  reportCollisions("CITM seatCategoryNames", in: citm.seatCategoryNames)
  reportCollisions("CITM events", in: citm.events)
  reportCollisions("GSoC root", in: gsoc)
}

private func reportCollisions<Value>(
  _ name: String,
  in dictionary: StreamDictionary<Value>?
) {
  guard let dictionary else {
    print("\(name): absent")
    return
  }
  reportCollisions(name, in: dictionary)
}

private func reportCollisions<Value>(_ name: String, in dictionary: StreamDictionary<Value>) {
  let statistics = probeStatistics(for: dictionary._benchmarkStoredHashes)
  let insertionRate = percentage(
    statistics.collidingInsertions, of: statistics.indexedInsertions
  )
  let placementRate = percentage(statistics.collidingPlacements, of: statistics.placements)
  let averageInsertionProbes = average(
    statistics.insertionOccupiedProbes, over: statistics.indexedInsertions
  )
  let averagePlacementProbes = average(
    statistics.placementOccupiedProbes, over: statistics.placements
  )
  print(
    """
    \(name): \(statistics.entryCount) entries, \(statistics.rebuilds) rebuilds
      insertion lookup: \(statistics.collidingInsertions)/\(statistics.indexedInsertions) collided \
    (\(insertionRate)), \(averageInsertionProbes) occupied probes/lookup, \
    max \(statistics.maximumInsertionOccupiedProbes)
      table placement: \(statistics.collidingPlacements)/\(statistics.placements) collided \
    (\(placementRate)), \(averagePlacementProbes) occupied probes/placement, \
    max \(statistics.maximumPlacementOccupiedProbes)
    """
  )
}

private struct ProbeStatistics: Hashable, Sendable {
  var entryCount: Int
  var indexedInsertions = 0
  var collidingInsertions = 0
  var insertionOccupiedProbes = 0
  var maximumInsertionOccupiedProbes = 0
  var placements = 0
  var collidingPlacements = 0
  var placementOccupiedProbes = 0
  var maximumPlacementOccupiedProbes = 0
  var rebuilds = 0

  mutating func recordPlacement(occupiedProbes: Int) {
    self.placements &+= 1
    self.placementOccupiedProbes &+= occupiedProbes
    self.maximumPlacementOccupiedProbes = max(
      self.maximumPlacementOccupiedProbes, occupiedProbes
    )
    if occupiedProbes > 0 { self.collidingPlacements &+= 1 }
  }
}

private func probeStatistics(for hashes: [UInt64]) -> ProbeStatistics {
  var statistics = ProbeStatistics(entryCount: hashes.count)
  var table = ContiguousArray<Int32>?.none

  for (slot, hash) in hashes.enumerated() {
    if let current = table {
      let occupied = occupiedProbes(in: current, hash: hash)
      statistics.indexedInsertions &+= 1
      statistics.insertionOccupiedProbes &+= occupied
      statistics.maximumInsertionOccupiedProbes = max(
        statistics.maximumInsertionOccupiedProbes, occupied
      )
      if occupied > 0 { statistics.collidingInsertions &+= 1 }
    }

    let count = slot + 1
    if table == nil {
      guard count > 8 else { continue }
      table = rebuildTable(from: hashes.prefix(count), statistics: &statistics)
    } else if count * 2 > table.unsafelyUnwrapped.count {
      table = rebuildTable(from: hashes.prefix(count), statistics: &statistics)
    } else {
      var current = table.unsafelyUnwrapped
      let occupied = claim(slot: Int32(slot), hash: hash, in: &current)
      table = current
      statistics.recordPlacement(occupiedProbes: occupied)
    }
  }
  return statistics
}

private func rebuildTable(
  from hashes: ArraySlice<UInt64>,
  statistics: inout ProbeStatistics
) -> ContiguousArray<Int32> {
  var capacity = 16
  while capacity < hashes.count * 2 { capacity &*= 2 }
  var table = ContiguousArray<Int32>(repeating: -1, count: capacity)
  statistics.rebuilds &+= 1
  for (slot, hash) in hashes.enumerated() {
    let occupied = claim(slot: Int32(slot), hash: hash, in: &table)
    statistics.recordPlacement(occupiedProbes: occupied)
  }
  return table
}

private func claim(
  slot: Int32,
  hash: UInt64,
  in table: inout ContiguousArray<Int32>
) -> Int {
  let occupied = occupiedProbes(in: table, hash: hash)
  let mask = table.count - 1
  var probe = Int(hash & UInt64(mask))
  var remaining = occupied
  while remaining > 0 {
    probe = (probe &+ 1) & mask
    remaining &-= 1
  }
  table[probe] = slot
  return occupied
}

private func occupiedProbes(in table: ContiguousArray<Int32>, hash: UInt64) -> Int {
  let mask = table.count - 1
  var probe = Int(hash & UInt64(mask))
  var occupied = 0
  while table[probe] >= 0 {
    occupied &+= 1
    probe = (probe &+ 1) & mask
  }
  return occupied
}

private func percentage(_ numerator: Int, of denominator: Int) -> String {
  guard denominator > 0 else { return "n/a" }
  return String(format: "%.1f%%", Double(numerator) / Double(denominator) * 100)
}

private func average(_ total: Int, over count: Int) -> String {
  guard count > 0 else { return "n/a" }
  return String(format: "%.3f", Double(total) / Double(count))
}
