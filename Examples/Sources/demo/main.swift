// swift run demo ["a message to extract calendar events from"]
//
// A local LLM writes JSON one token at a time, and every token is parsed into a typed
// `Extraction.Partial` as it arrives. The partial is logged after each token.

import Foundation
import StreamParsing

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

#if canImport(LlamaSwift)
  import LlamaSwift
#else
  import CLlama
#endif

// MARK: - What the model is asked to produce

@StreamParseable
struct Extraction {
  var events: [Event]
}

@StreamParseable
struct Event {
  var title: String
  var date: String
  var attendees: [String]
}

// `Extraction`'s JSON shape as a llama.cpp grammar. Sampling is constrained to it, which is what
// lets a 230M parameter model be trusted to write well-formed JSON; what goes in the strings is
// still up to the model.
let grammar = #"""
  root ::= "{" ws "\"events\"" ws ":" ws "[" ws (event (ws "," ws event)*)? ws "]" ws "}"
  event ::= "{" ws "\"title\"" ws ":" ws string ws "," ws "\"date\"" ws ":" ws string ws "," ws "\"attendees\"" ws ":" ws "[" ws (string (ws "," ws string)*)? ws "]" ws "}"
  string ::= "\"" ([^"\\\x00-\x1F] | "\\" (["\\/bfnrt] | "u" [0-9a-fA-F]{4}))* "\""
  ws ::= [ \n]{0,12}
  """#

let message =
  CommandLine.arguments.dropFirst().first
  ?? """
  Hi team, quick recap. Ana Müller and José are doing the design review on 3 March. \
  Priya and Tom have the Q2 budget sync on 9 March. And the launch party 🎉 is on \
  Friday 14 March, with Ana, José, Priya and Tom all invited!
  """

let instruction =
  "List each event in this message with a short title, its date, and the names of the people "
  + "attending it."

// MARK: - Download the model on first run

let modelName = "LFM2.5-230M-Q4_K_M.gguf"
let modelsDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
  .appendingPathComponent("swift-stream-parsing-examples")
let modelURL = modelsDirectory.appendingPathComponent(modelName)

if !FileManager.default.fileExists(atPath: modelURL.path) {
  print("Downloading \(modelName) (about 150 MB) to \(modelsDirectory.path)...")
  let remote = URL(string: "https://huggingface.co/LiquidAI/LFM2.5-230M-GGUF/resolve/main/\(modelName)")!
  let (downloaded, response) = try await URLSession.shared.download(from: remote)
  guard (response as? HTTPURLResponse)?.statusCode == 200 else { fatalError("Download failed: \(response)") }
  try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
  try FileManager.default.moveItem(at: downloaded, to: modelURL)
}

// MARK: - Load the model

llama_log_set({ _, _, _ in }, nil)
llama_backend_init()
guard let model = llama_model_load_from_file(modelURL.path, llama_model_default_params()) else {
  fatalError("Could not load \(modelURL.path)")
}
var contextParameters = llama_context_default_params()
contextParameters.n_ctx = 4096
contextParameters.n_batch = 2048
guard let context = llama_init_from_model(model, contextParameters) else {
  fatalError("Could not create a llama.cpp context")
}
let vocabulary = llama_model_get_vocab(model)

let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
llama_sampler_chain_add(sampler, llama_sampler_init_grammar(vocabulary, grammar, "root"))
llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

// Format the prompt with the chat template embedded in the model file.
let messages = [llama_chat_message(role: strdup("user"), content: strdup("\(instruction)\n\n\(message)"))]
var promptBuffer = [CChar](repeating: 0, count: 4 * message.utf8.count + 1024)
let promptLength = llama_chat_apply_template(
  llama_model_chat_template(model, nil), messages, messages.count, true, &promptBuffer, Int32(promptBuffer.count)
)
guard promptLength > 0, promptLength < promptBuffer.count else { fatalError("Could not apply the chat template") }

var promptTokens = [llama_token](repeating: 0, count: Int(promptLength) + 16)
let promptTokenCount = llama_tokenize(
  vocabulary, promptBuffer, promptLength, &promptTokens, Int32(promptTokens.count), true, true
)
guard promptTokenCount > 0, promptTokenCount < contextParameters.n_batch else {
  fatalError("The message does not fit in the prompt")
}
guard llama_decode(context, llama_batch_get_one(&promptTokens, promptTokenCount)) == 0 else {
  fatalError("llama_decode failed")
}

// MARK: - Generate, parsing every token as it arrives

print("message: \(message)\n")

var stream = PartialsStream(initialValue: Extraction.Partial(), from: .json())
var piece = [CChar](repeating: 0, count: 256)

for _ in 0..<512 {
  var token = llama_sampler_sample(sampler, context, -1)
  if llama_vocab_is_eog(vocabulary, token) { break }

  // A token is raw bytes. It can stop mid-string, mid-escape, or mid-UTF-8-scalar, so the bytes
  // go to the parser as they are and never round-trip through `String`.
  let length = llama_token_to_piece(vocabulary, token, &piece, Int32(piece.count), 0, false)
  let bytes = piece[..<Int(length)].map { UInt8(bitPattern: $0) }
  try stream.next(bytes)

  // `current` is an owned snapshot of everything parsed so far.
  print(String(reflecting: String(decoding: bytes, as: UTF8.self)), "→", stream.current)

  guard llama_decode(context, llama_batch_get_one(&token, 1)) == 0 else { fatalError("llama_decode failed") }
}

// Finishing validates that the input was one complete JSON document.
let partial = try stream.finish()
print()
if let extraction = Extraction(streamPartial: partial) {
  for event in extraction.events {
    print("• \(event.title), \(event.date): \(event.attendees.joined(separator: ", "))")
  }
} else {
  print("The model stopped before every field was present.")
}
