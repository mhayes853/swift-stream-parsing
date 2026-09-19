import DemoCore
import Foundation

// swift run replay [fixture] [--speed <multiplier> | --no-delay] [--full]

var arguments = Array(CommandLine.arguments.dropFirst())
var speed: Double? = 1
var path: String?
var full = false
while !arguments.isEmpty {
  let argument = arguments.removeFirst()
  switch argument {
  case "--full":
    full = true
  case "--no-delay":
    speed = nil
  case "--speed":
    guard let value = arguments.first.flatMap(Double.init), value > 0 else {
      fatalError("--speed needs a positive multiplier, e.g. --speed 0.25")
    }
    arguments.removeFirst()
    speed = value
  case "--help", "-h":
    print("usage: swift run replay [fixture] [--speed <multiplier> | --no-delay] [--full]")
    exit(0)
  default:
    path = argument
  }
}

let url = path.map { URL(fileURLWithPath: $0) }
  ?? URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Fixtures/events.chunks")
try await Demo.run(ReplaySource(fixture: Fixture(contentsOf: url), speed: speed), full: full)
