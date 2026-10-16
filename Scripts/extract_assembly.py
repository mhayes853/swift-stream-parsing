#!/usr/bin/env python3
"""Pin per-symbol disassembly into Web/generated/asm/.

Read from the *release benchmark binary*, not from the library, and the reason is the one the
architecture doc opens with: most of the hot kernels are `@inline(__always)` and have no standalone
symbol anywhere. What the doc's assembly numbers actually describe are the specialized functions a
concrete sink produces -- `parse` at 1284 bytes, `consumeStructural` at 1044 -- and those only exist
in a binary that instantiates one.

A symbol that resolves to nothing is reported, not silently skipped: "this was inlined away" is a
fact about the build worth seeing, and the explorer says so rather than showing an empty pane.
"""

import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY = os.path.join(ROOT, "Benchmarks/.build/out/Products/Release/StreamParsingBenchmarks")
OUT = os.path.join(ROOT, "Web/generated/asm")

# `<addr> <mnemonic> <operands>` lines, and the `0000... <symbol>:` headers between them.
SYMBOL = re.compile(r"^[0-9a-f]+\s+<(.+)>:$")
INSTRUCTION = re.compile(r"^\s*[0-9a-f]+:\s")


def wanted_symbols():
    """Every `asm` reference in pipeline.json. The pipeline file is the request list."""
    path = os.path.join(ROOT, "Web/content/pipeline.json")
    if not os.path.exists(path):
        return []
    with open(path) as f:
        pipeline = json.load(f)
    names = []
    for node in pipeline.get("nodes", []):
        names.extend(node.get("evidence", {}).get("asm", []))
    return sorted(set(names))


def disassemble():
    if not os.path.exists(BINARY):
        print(f"note: {BINARY} not built; run ./Benchmarks/bench build", file=sys.stderr)
        return {}
    raw = subprocess.run(
        ["xcrun", "llvm-objdump", "-d", "--demangle", "--no-show-raw-insn", BINARY],
        capture_output=True, text=True, check=True,
    ).stdout

    blocks, current, lines = {}, None, []
    for line in raw.splitlines():
        match = SYMBOL.match(line)
        if match:
            if current:
                blocks[current] = lines
            current, lines = match.group(1), []
            continue
        if current is not None and line.strip():
            lines.append(line)
    if current:
        blocks[current] = lines
    return blocks


def pick(blocks, symbol):
    """Match whole identifiers inside the mangled name, scoped to this package's modules.

    Swift mangling length-prefixes each identifier, so `consumeStructural` appears as
    `17consumeStructural` and `consumeStructuralRun` as `20consumeStructuralRun`. A plain substring
    search finds the second when asked for the first. A dotted reference (`JSONParser.parse`)
    requires every component, which is what keeps `parse` off `ArgumentParser.LenientParser.parse`
    -- the benchmark binary statically links plenty of other people's code.

    C shim names are unmangled and match on a word boundary instead.
    """
    parts = symbol.split(".")
    swift_forms = [f"{len(part)}{part}" for part in parts]
    c_form = re.compile(r"\b_?" + re.escape(parts[-1]) + r"\b")

    hits = [
        name for name in blocks
        if all(form in name for form in swift_forms) or c_form.search(name)
    ]
    # Everything in this package lives in one of these modules; anything else matching is a
    # coincidence in a statically linked dependency.
    scoped = [n for n in hits if "StreamParsing" in n or c_form.search(n)]
    hits = scoped or []
    if not hits:
        return None, 0
    # Shortest first: the plain function, then its generic specializations, then thunks. The count
    # is reported because "this exists in five specialized forms" is itself worth knowing.
    hits.sort(key=len)
    return hits[0], len(hits) - 1


def demangle(name):
    """Apple's llvm-objdump leaves Swift symbols mangled even with --demangle, so ask
    swift-demangle directly. Falls back to the mangled name rather than failing the pin."""
    try:
        out = subprocess.run(
            ["xcrun", "swift-demangle", "--compact", name],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
        return out or name
    except Exception:
        return name


def main():
    symbols = wanted_symbols()
    if not symbols:
        print("no asm references in pipeline.json; nothing to pin")
        return 0

    os.makedirs(OUT, exist_ok=True)
    blocks = disassemble()
    found = missing = 0

    for symbol in symbols:
        name, others = pick(blocks, symbol) if blocks else (None, 0)
        target = os.path.join(OUT, f"{symbol}.txt")
        if name is None:
            missing += 1
            with open(target, "w") as f:
                f.write(
                    f"; {symbol}\n"
                    "; No standalone symbol in the release benchmark binary.\n"
                    "; This is the expected result for an `@inline(__always)` kernel: it has no\n"
                    "; call site of its own, and its instructions live inside whichever caller the\n"
                    "; optimizer folded it into. Read the caller's listing instead.\n"
                )
            continue

        body = blocks[name]
        count = sum(1 for line in body if INSTRUCTION.match(line))
        found += 1
        with open(target, "w") as f:
            f.write(f"; {demangle(name)}\n; {name}\n; {count} instructions\n")
            if others:
                f.write(f"; {others} further specialization(s) of this symbol in the binary\n")
            f.write("; llvm-objdump -d, release benchmark binary\n\n")
            f.write("\n".join(body) + "\n")

    print(f"asm: {found} symbol(s) pinned, {missing} inlined away or absent")
    return 0


if __name__ == "__main__":
    sys.exit(main())
