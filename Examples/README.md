# Examples

A small, production-shaped use of the library: a local LLM extracts calendar events from a
message as JSON, and every token it generates is parsed into a typed `Extraction.Partial` the
moment it arrives. One line is logged per token, showing the bytes that came in and the value
the parser holds afterwards.

```
#   8    +254ms  " ""               events[0]: {title: "", date: _, attendees: _}
#   9    +283ms  "Design"           events[0]: {title: "Design", date: _, attendees: _}
#  10    +307ms  " Review"          events[0]: {title: "Design Review", date: _, attendees: _}
```

The integration is a few lines in [`Demo.swift`](Sources/DemoCore/Demo.swift): an async sequence
of byte chunks goes in, and a typed snapshot comes out after each chunk. No chunk needs to be
valid JSON, or even valid UTF-8, by itself.

## Replay (no model required)

```sh
swift run replay                # a recorded generation, with its original pacing
swift run replay --speed 0.25   # slowed down
swift run replay --no-delay     # as fast as it parses
swift run replay --full         # print the whole snapshot on every line
```

`Fixtures/events.chunks` is a real generation recorded by `live --record`, preserving the
token boundaries and timing. Dimmed lines are tokens that did not change the value (keys,
punctuation, whitespace).

## Live

`live` runs [LFM2.5-230M](https://huggingface.co/LiquidAI/LFM2.5-230M-GGUF) in-process through
llama.cpp, on the CPU. A GBNF grammar constrains sampling to `Extraction`'s JSON shape.

1. Install llama.cpp (not needed on Apple platforms, which use
   [llama.swift](https://github.com/mattt/llama.swift)'s prebuilt XCFramework):
   - Arch: `sudo pacman -S llama-cpp`
   - Anything else: a llama.cpp install that provides `llama.pc` to `pkg-config`, such as
     `cmake --install` from source. Build 10549 or newer is expected.
2. `Scripts/download-model.sh` (about 150 MB, saved to `Models/`).
3. Run it:

```sh
swift run live
swift run live "Standup with Blob on Monday. Retro with Blob Jr. on Friday."
swift run live --model path/to/another.gguf --record Fixtures/mine.chunks
```

The prompt is LFM2's chat template written out by hand, so other models will run but are not
prompted correctly.

A 230M parameter model is used because it is small enough to run anywhere, not because it is a
good extractor: expect it to miss or repeat events. The grammar guarantees the JSON is well
formed, and the parsing is the point.

## Notes

- A module that applies `@StreamParseable` must enable the `Lifetimes` and `AddressableTypes`
  experimental features, as `DemoCore` does in [`Package.swift`](Package.swift).
- Off Apple platforms SwiftPM still downloads llama.swift's XCFramework (about 80 MB) without
  using it.
- The Apple path compiles against the same `llama.h` calls but has not been run on a Mac yet.
