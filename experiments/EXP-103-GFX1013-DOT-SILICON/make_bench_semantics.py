#!/usr/bin/env python3
from pathlib import Path
import sys

src = Path(sys.argv[1])
out = Path(sys.argv[2])
s = src.read_text()


def one(old: str, new: str) -> None:
    global s
    n = s.count(old)
    if n != 1:
        raise SystemExit(f"expected exactly one benchmark source match, got {n}: {old[:100]!r}")
    s = s.replace(old, new, 1)


one(
'''    for (uint32_t i = 0; i < (uint32_t)NELEM * (uint32_t)UNROLL; i++) {
        maps[0][i] = i * 2654435761u + 1u;
        maps[1][i] = i * 2246822519u + 7u;
    }
''',
'''    const char *ea = getenv("BC250_A");
    const char *eb = getenv("BC250_B");
    const uint32_t forced_a = ea ? (uint32_t)strtoul(ea, NULL, 0) : 1u;
    const uint32_t forced_b = eb ? (uint32_t)strtoul(eb, NULL, 0) : 7u;
    for (uint32_t i = 0; i < (uint32_t)NELEM * (uint32_t)UNROLL; i++) {
        maps[0][i] = forced_a;
        maps[1][i] = forced_b;
    }
''')

one(
'''    int bad = 0;
    uint32_t nsamp = NELEM < 64 ? NELEM : 64;
''',
'''    printf("SEM A=0x%08x B=0x%08x GOT=0x%08x\\n",
           maps[0][0], maps[1][0], maps[2][0]);

    int bad = 0;
    uint32_t nsamp = NELEM < 64 ? NELEM : 64;
''')

out.write_text(s)
print(f"Wrote semantics benchmark: {out}")
