# Examples

```sh
swift run demo
swift run demo "Standup with Blob on Monday. Retro with Blob Jr. on Friday."
```

A local LLM extracts calendar events from a message as JSON, and every token it generates is
parsed into a typed `Extraction.Partial` the moment it arrives. Each token is logged alongside
the partial value that results from it:

```
" \"" → Partial(events: Optional([Partial(title: Optional(""), date: nil, attendees: nil)]))
"Design" → Partial(events: Optional([Partial(title: Optional("Design"), date: nil, attendees: nil)]))
" Review" → Partial(events: Optional([Partial(title: Optional("Design Review"), date: nil, attendees: nil)]))
```

Everything is in [`main.swift`](Sources/demo/main.swift).

## Requirements

The demo runs [LFM2.5-230M](https://huggingface.co/LiquidAI/LFM2.5-230M-GGUF) in-process through
llama.cpp on the CPU, and downloads the model (about 150 MB) to the user's caches directory on
first run.

- Apple platforms need nothing else: llama.cpp comes from
  [llama.swift](https://github.com/mattt/llama.swift)'s prebuilt XCFramework. This path has not
  been run yet.
- Elsewhere, install a llama.cpp that provides `llama.pc` to `pkg-config`, for example
  `sudo pacman -S llama-cpp` on Arch.

The model is tiny so that it runs anywhere, not because it extracts well: expect it to miss or
repeat events. A grammar guarantees that the JSON it writes is well formed.

A module that applies `@StreamParseable` must enable the `Lifetimes` and `AddressableTypes`
experimental features, as [`Package.swift`](Package.swift) does.
