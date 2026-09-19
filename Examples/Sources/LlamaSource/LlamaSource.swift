import DemoCore
import Foundation

#if canImport(LlamaSwift)
  import LlamaSwift
#else
  import CLlama
#endif

/// Generates an `Extraction` as JSON with a local GGUF model, yielding one chunk per token.
///
/// Only the stable core of `llama.h` is used (load, tokenize, decode, sampler chain, token to
/// piece), because the llama.cpp build differs per platform: the system package elsewhere, and
/// llama.swift's pinned XCFramework on Apple platforms.
public struct LlamaSource: ChunkSource {
  public var modelPath: String
  public var message: String
  public var maxTokens: Int

  public init(modelPath: String, message: String, maxTokens: Int = 512) {
    self.modelPath = modelPath
    self.message = message
    self.maxTokens = maxTokens
  }

  public struct Failure: Error, CustomStringConvertible {
    public var description: String
  }

  public func chunks() -> AsyncThrowingStream<StreamChunk, any Error> {
    AsyncThrowingStream { continuation in
      // Generation is blocking, CPU-bound C code, so it gets a thread of its own rather than
      // occupying one of the cooperative pool's.
      let cancelled = CancellationFlag()
      let thread = Thread {
        do {
          try self.generate(isCancelled: { cancelled.value }) { continuation.yield($0) }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      thread.stackSize = 8 << 20
      continuation.onTermination = { _ in cancelled.value = true }
      thread.start()
    }
  }

  private func generate(isCancelled: () -> Bool, yield: (StreamChunk) -> Void) throws {
    llama_log_set({ _, _, _ in }, nil)
    llama_backend_init()
    defer { llama_backend_free() }

    guard let model = llama_model_load_from_file(self.modelPath, llama_model_default_params()) else {
      throw Failure(description: "Could not load a GGUF model from \(self.modelPath).")
    }
    defer { llama_model_free(model) }

    var contextParameters = llama_context_default_params()
    contextParameters.n_ctx = 4096
    contextParameters.n_batch = 2048
    guard let context = llama_init_from_model(model, contextParameters) else {
      throw Failure(description: "Could not create a llama.cpp context.")
    }
    defer { llama_free(context) }
    let vocabulary = llama_model_get_vocab(model)

    // The grammar guarantees the output is a JSON document of the right shape. It is what lets
    // a 230M parameter model be trusted to produce JSON at all; what goes in the strings is
    // still up to the model.
    let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
    defer { llama_sampler_free(sampler) }
    guard let grammar = llama_sampler_init_grammar(vocabulary, Self.grammar, "root") else {
      throw Failure(description: "llama.cpp rejected the GBNF grammar.")
    }
    llama_sampler_chain_add(sampler, grammar)
    llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

    let prompt = Self.prompt(for: self.message)
    var tokens = [llama_token](repeating: 0, count: prompt.utf8.count + 16)
    let tokenCount = llama_tokenize(
      vocabulary, prompt, Int32(prompt.utf8.count), &tokens, Int32(tokens.count), false, true
    )
    guard tokenCount > 0, tokenCount < contextParameters.n_batch else {
      throw Failure(description: "The message does not fit in the prompt (\(tokenCount) tokens).")
    }
    tokens.removeLast(tokens.count - Int(tokenCount))

    let clock = ContinuousClock()
    var last = clock.now
    let promptStatus = tokens.withUnsafeMutableBufferPointer {
      llama_decode(context, llama_batch_get_one($0.baseAddress, Int32($0.count)))
    }
    guard promptStatus == 0 else { throw Failure(description: "llama_decode failed (\(promptStatus)).") }

    var piece = [CChar](repeating: 0, count: 256)
    for _ in 0..<self.maxTokens {
      if isCancelled() { return }
      var token = llama_sampler_sample(sampler, context, -1)
      if llama_vocab_is_eog(vocabulary, token) { return }

      // A token's piece is raw bytes: nothing promises it ends on a UTF-8 scalar boundary, so it
      // is forwarded as bytes and never round-tripped through `String`.
      let length = llama_token_to_piece(vocabulary, token, &piece, Int32(piece.count), 0, false)
      guard length >= 0 else { throw Failure(description: "A token piece exceeded \(piece.count) bytes.") }
      let now = clock.now
      yield(StreamChunk(bytes: piece[..<Int(length)].map { UInt8(bitPattern: $0) }, delay: now - last))
      last = now

      let status = llama_decode(context, llama_batch_get_one(&token, 1))
      guard status == 0 else { throw Failure(description: "llama_decode failed (\(status)).") }
    }
  }
}

extension LlamaSource {
  /// LFM2's ChatML-style template, written out by hand: the Jinja template embedded in the GGUF
  /// can only be rendered by llama.cpp's C++ `common` library, which is not part of `llama.h`.
  static func prompt(for message: String) -> String {
    """
    <|startoftext|><|im_start|>system
    Extract every calendar event from the user's message. Reply with JSON: \
    {"events": [{"title": "...", "date": "...", "attendees": ["..."]}]}. \
    Use a short title for each event, and list each event once.<|im_end|>
    <|im_start|>user
    \(message)<|im_end|>
    <|im_start|>assistant

    """
  }

  /// `Extraction`'s JSON shape as GBNF, also by hand: llama.cpp's JSON Schema to GBNF converter
  /// lives in that same C++ `common` library.
  static let grammar = #"""
    root ::= "{" ws "\"events\"" ws ":" ws "[" ws (event (ws "," ws event)*)? ws "]" ws "}"
    event ::= "{" ws "\"title\"" ws ":" ws string ws "," ws "\"date\"" ws ":" ws string ws "," ws "\"attendees\"" ws ":" ws "[" ws (string (ws "," ws string)*)? ws "]" ws "}"
    string ::= "\"" ([^"\\\x00-\x1F] | "\\" (["\\/bfnrt] | "u" [0-9a-fA-F]{4}))* "\""
    ws ::= [ \n]{0,12}
    """#
}

private final class CancellationFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var _value = false

  var value: Bool {
    get { self.lock.withLock { self._value } }
    set { self.lock.withLock { self._value = newValue } }
  }
}
