# Swift Stream Parsing
You are working on Swift Stream Parsing, a blazingly fast and convenient library for parsing JSON (or any format in the future) incrementally by streaming observable values from incomplete payloads. This library exist because certain problems require structured observable parsing (eg. structured output streaming from LLMs) when full JSON payloads are pending or are otherwise incomplete. 

`Decodable` and `JSONDecoder` do not work in these scenarios because they require the full output to be present, which may be expensive or impossible. 

Traditional SAX parsers also fail here, because they generally only emit completed values where as we want to emit updates down to the byte level. Furthermore, such parsers often lack a typed convenience layer. Though this library can also be used like traditional SAX parser in (mostly) pure Swift if desired.

## Basic Rules

We MUST run performance benchmarks (especially throughput) on the real world data sets after every change. Even subtle changes to a tiny number of lines of code can have a negative impact depending on how the Swift compiler handles optimizing, inlining, layout, etc. Furthermore, microbenchmarks on a single function do not guarantee E2E performance gains (and may even be losses!).

Right now, we're primarily focused on ARM for optimizations, but the parser also works on x86 and other architectures that support Swift (just a bit slower).

Some operations are better expressed in C than in Swift due to either incompatabilities (eg. Unrepresentable SIMD instructions) or data layout issues (eg. Pow 10 table for Eisel-Lemire fast float). `StreamParsingShims` is the target for that.

Perform rigourous analysis on the underlying assembly whenever you make a change to a critical parsing component, and surface those in your communications. (Also note that lower instruction count != faster code.)

Feel free to use whatever advanced features (including underscored attributes) in Swift that you need to achieve maximum performance.

Liberal comments are fine here, especially if readability must be sacrified in exchange for performance.

We have dedicated data types for streaming collections which includes dictionaries, arrays, and strings. These types prioritize speed whilst trying to keep a semblance of convenience.

The convenience layer is zero-copy by default as one can produce snapshots of the parsed data on-demand (down to the individual field level). However, various convenience APIs (such as the async sequences) will generally take a full snapshot of the value. This is because each parseable type is required to have a `~Copyable` and `~Escapable` view associated type, which generally is a container for a typed unsafe pointer to the value.

We rely on SIMD heavily to scan and process multiple bytes at a time using various known algorithms. In some cases where we don't have enough data to fill a full SIMD register, SWAR can be faster. Make sure to always benchmark SIMD vs SWAR if you consider using either approach.
