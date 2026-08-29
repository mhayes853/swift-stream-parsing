#!/usr/bin/env python3
"""Stage-1 census: per-corpus byte classes, index-entry counts, and per-64B-block
index density. Models the stage-2 walk as one index entry per: structural char
({}[]:,), quote (both of a pair), number start, literal start — simdjson's
structural + pseudo-structural set."""
import sys, statistics, collections

STRUCT = frozenset(b'{}[]:,')
WS = frozenset(b' \t\n\r')
DIGITS = frozenset(b'0123456789')
NUMBYTES = frozenset(b'0123456789+-.eE')

def census(path):
    data = open(path, 'rb').read()
    n = len(data)
    in_string = False
    escaped = False
    counts = collections.Counter()   # byte class -> count
    index_pos = []                   # positions stage 2 would walk
    num_lengths = []
    str_lengths = []
    cur_str_len = 0
    i = 0
    while i < n:
        b = data[i]
        if in_string:
            if escaped:
                counts['str_content'] += 1; cur_str_len += 1
                escaped = False
            elif b == 0x5C:
                counts['str_content'] += 1; cur_str_len += 1
                escaped = True
            elif b == 0x22:
                counts['quote'] += 1
                index_pos.append(i)
                str_lengths.append(cur_str_len)
                in_string = False
            else:
                counts['str_content'] += 1; cur_str_len += 1
            i += 1
        else:
            if b == 0x22:
                counts['quote'] += 1
                index_pos.append(i)
                in_string = True
                cur_str_len = 0
                i += 1
            elif b in STRUCT:
                counts['structural'] += 1
                index_pos.append(i)
                i += 1
            elif b in WS:
                counts['ws'] += 1
                i += 1
            elif b in DIGITS or b == 0x2D:
                index_pos.append(i)
                j = i
                while j < n and data[j] in NUMBYTES:
                    j += 1
                counts['number'] += j - i
                num_lengths.append(j - i)
                i = j
            elif b in b'tfn':
                index_pos.append(i)
                ln = 4 if b in b'tn' else 5
                counts['literal'] += ln
                i += ln
            else:
                counts['other'] += 1
                i += 1
    assert not in_string, path

    blocks = (n + 63) // 64
    per_block = [0] * blocks
    for p in index_pos:
        per_block[p // 64] += 1
    # blocks that are pure string interior: no index entry AND every byte is str content
    # approximation: block has 0 entries and lies between a quote pair -> compute via class map
    zero = sum(1 for c in per_block if c == 0)
    le8 = sum(1 for c in per_block if c <= 8)
    le16 = sum(1 for c in per_block if c <= 16)

    e = len(index_pos)
    pct = lambda k: 100.0 * counts[k] / n
    row = dict(
        name=path.rsplit('/', 1)[-1].removesuffix('.json'),
        kb=n / 1024,
        str_pct=pct('str_content'), quote_pct=pct('quote'),
        struct_pct=pct('structural'), ws_pct=pct('ws'),
        num_pct=pct('number'), lit_pct=pct('literal'),
        entries=e,
        entries_per_kb=e / (n / 1024),
        idx_kb_u32=e * 4 / 1024,
        idx_pct=100.0 * e * 4 / n,
        blk_mean=e / blocks,
        blk_p50=statistics.median(per_block),
        blk_p90=sorted(per_block)[int(blocks * 0.9)],
        blk_max=max(per_block),
        blk_zero_pct=100.0 * zero / blocks,
        blk_le8_pct=100.0 * le8 / blocks,
        blk_le16_pct=100.0 * le16 / blocks,
        nums=len(num_lengths),
        num_len_p50=statistics.median(num_lengths) if num_lengths else 0,
        strs=len(str_lengths),
        str_len_p50=statistics.median(str_lengths) if str_lengths else 0,
    )
    return row

def main(paths):
    rows = [census(p) for p in paths]
    cols1 = [('corpus', 'name', '{}'), ('KB', 'kb', '{:.0f}'),
             ('str%', 'str_pct', '{:.1f}'), ('quo%', 'quote_pct', '{:.1f}'),
             ('stc%', 'struct_pct', '{:.1f}'), ('ws%', 'ws_pct', '{:.1f}'),
             ('num%', 'num_pct', '{:.1f}'), ('lit%', 'lit_pct', '{:.2f}')]
    cols2 = [('corpus', 'name', '{}'), ('entries', 'entries', '{}'),
             ('ent/KB', 'entries_per_kb', '{:.0f}'), ('idx%doc', 'idx_pct', '{:.1f}'),
             ('blk_mean', 'blk_mean', '{:.1f}'), ('blk_p50', 'blk_p50', '{:.0f}'),
             ('blk_p90', 'blk_p90', '{}'), ('blk_max', 'blk_max', '{}'),
             ('blk0%', 'blk_zero_pct', '{:.0f}'), ('blk<=8%', 'blk_le8_pct', '{:.0f}'),
             ('blk<=16%', 'blk_le16_pct', '{:.0f}')]
    cols3 = [('corpus', 'name', '{}'), ('numbers', 'nums', '{}'),
             ('numlen_p50', 'num_len_p50', '{:.0f}'), ('strings', 'strs', '{}'),
             ('strlen_p50', 'str_len_p50', '{:.0f}')]
    for cols in (cols1, cols2, cols3):
        hdr = [c[0] for c in cols]
        table = [hdr] + [[c[2].format(r[c[1]]) for c in cols] for r in rows]
        widths = [max(len(t[i]) for t in table) for i in range(len(hdr))]
        for t in table:
            print('  '.join(v.rjust(w) for v, w in zip(t, widths)))
        print()

if __name__ == '__main__':
    main(sys.argv[1:])
