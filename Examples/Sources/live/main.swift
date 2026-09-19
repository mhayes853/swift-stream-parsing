import DemoCore
import Foundation
import LlamaSource

// swift run live [--model <path.gguf>] [--record <fixture>] [--full] [message]

let examples = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

var arguments = Array(CommandLine.arguments.dropFirst())
var modelPath = examples.appendingPathComponent("Models/LFM2.5-230M-Q4_K_M.gguf").path
var recordPath: String?
var full = false
var message = """
  Hi team, quick recap. Ana Müller and José are doing the design review on 3 March. \
  Priya and Tom have the Q2 budget sync on 9 March. And the launch party 🎉 is on \
  Friday 14 March, with Ana, José, Priya and Tom all invited!
  """

@MainActor func value(for flag: String) -> String {
  guard !arguments.isEmpty else { fatalError("\(flag) needs a value") }
  return arguments.removeFirst()
}

while !arguments.isEmpty {
  let argument = arguments.removeFirst()
  switch argument {
  case "--model": modelPath = value(for: argument)
  case "--record": recordPath = value(for: argument)
  case "--full": full = true
  case "--help", "-h":
    print("usage: swift run live [--model <path.gguf>] [--record <fixture>] [--full] [message]")
    exit(0)
  default: message = argument
  }
}

guard FileManager.default.fileExists(atPath: modelPath) else {
  print("No model at \(modelPath).\nRun Scripts/download-model.sh, or pass --model <path.gguf>.")
  exit(1)
}

print("message: \(message)\n")
let chunks = try await Demo.run(LlamaSource(modelPath: modelPath, message: message), full: full)

if let recordPath {
  let header = """
    Recorded by `swift run live --record`: one line per generated token.
    model: \(URL(fileURLWithPath: modelPath).lastPathComponent)
    message: \(message.replacing("\n", with: " "))
    """
  try Fixture(chunks: chunks).serialized(header: header)
    .write(toFile: recordPath, atomically: true, encoding: .utf8)
  print("\nRecorded \(chunks.count) chunks to \(recordPath).")
}
