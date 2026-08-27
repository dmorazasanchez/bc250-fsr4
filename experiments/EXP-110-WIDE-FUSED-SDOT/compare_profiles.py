#!/usr/bin/env python3
"""Compare GOD and EXP110 ACO/profile dumps across the whole shader corpus.

This deliberately accepts loose text formats because the project's profiling
outputs have evolved across experiments. It scans every text-ish file below a
profile directory and extracts common shader-stat labels.
"""
import argparse
import csv
import re
from pathlib import Path

METRICS = {
    "instructions": [r"\binstructions?\b\s*[:= ]\s*(\d+)"],
    "valu": [r"\bVALU\b\s*[:= ]\s*(\d+)", r"\bvalu\b\s*[:= ]\s*(\d+)"],
    "latency": [r"\blatency\b\s*[:= ]\s*(\d+)"],
    "inverse_throughput": [r"\binverse[_ ]throughput\b\s*[:= ]\s*(\d+)"],
    "spilled_vgprs": [r"\bspilled[_ ]vgprs\b\s*[:= ]\s*(\d+)"],
    "spilled_sgprs": [r"\bspilled[_ ]sgprs\b\s*[:= ]\s*(\d+)"],
    "waves": [r"\b(?:waves|occupancy)\b\s*[:= ]\s*(\d+)"],
}
HASH_RE = re.compile(r"(?:0x)?([0-9a-fA-F]{64})")


def shader_id(path: Path, text: str) -> str:
    m = HASH_RE.search(path.name) or HASH_RE.search(text[:4096])
    if m:
        return m.group(1).lower()
    return path.stem


def scan(root: Path):
    rows = {}
    for p in root.rglob("*"):
        if not p.is_file() or p.stat().st_size > 64 * 1024 * 1024:
            continue
        try:
            text = p.read_text(errors="ignore")
        except OSError:
            continue
        vals = {}
        for key, pats in METRICS.items():
            for pat in pats:
                m = re.search(pat, text, re.I)
                if m:
                    vals[key] = int(m.group(1))
                    break
        if not vals:
            continue
        sid = shader_id(p, text)
        # Prefer the file with the richest stat set for a given shader.
        if sid not in rows or len(vals) > len(rows[sid]):
            rows[sid] = vals
    return rows


def pct(new, old):
    if old in (None, 0) or new is None:
        return ""
    return f"{(new / old - 1.0) * 100.0:+.3f}%"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--god", type=Path, required=True)
    ap.add_argument("--candidate", action="append", required=True,
                    help="NAME=/path/to/profile; repeat for each EXP110 variant")
    ap.add_argument("--csv", type=Path, default=Path("exp110-profile-comparison.csv"))
    a = ap.parse_args()

    god = scan(a.god)
    if not god:
        raise SystemExit(f"No recognizable shader stats under GOD profile: {a.god}")

    candidates = {}
    for spec in a.candidate:
        if "=" not in spec:
            raise SystemExit("--candidate must be NAME=/path")
        name, path = spec.split("=", 1)
        candidates[name] = scan(Path(path))

    fields = ["variant", "shader", "instructions", "d_instructions", "valu", "d_valu",
              "latency", "d_latency", "inverse_throughput", "d_inverse_throughput",
              "spilled_vgprs", "spilled_sgprs", "waves", "god_waves", "gate"]
    out = []

    for name, data in candidates.items():
        common = sorted(set(god) & set(data))
        print(f"\n=== {name}: matched {len(common)}/{len(god)} GOD shaders ===")
        totals = {k: [0, 0] for k in ("instructions", "valu", "latency", "inverse_throughput")}
        bad_spills = 0
        occ_regress = 0
        changed = 0
        for sid in common:
            g, n = god[sid], data[sid]
            gate = "OK"
            if n.get("spilled_vgprs", 0) > g.get("spilled_vgprs", 0) or n.get("spilled_sgprs", 0) > g.get("spilled_sgprs", 0):
                gate = "REJECT_SPILL"
                bad_spills += 1
            if "waves" in g and "waves" in n and n["waves"] < g["waves"]:
                gate = "REJECT_OCCUPANCY" if gate == "OK" else gate + "+OCCUPANCY"
                occ_regress += 1
            if any(n.get(k) != g.get(k) for k in ("instructions", "valu", "latency", "inverse_throughput")):
                changed += 1
            for k in totals:
                if k in g and k in n:
                    totals[k][0] += g[k]
                    totals[k][1] += n[k]
            out.append({
                "variant": name, "shader": sid,
                "instructions": n.get("instructions", ""), "d_instructions": pct(n.get("instructions"), g.get("instructions")),
                "valu": n.get("valu", ""), "d_valu": pct(n.get("valu"), g.get("valu")),
                "latency": n.get("latency", ""), "d_latency": pct(n.get("latency"), g.get("latency")),
                "inverse_throughput": n.get("inverse_throughput", ""), "d_inverse_throughput": pct(n.get("inverse_throughput"), g.get("inverse_throughput")),
                "spilled_vgprs": n.get("spilled_vgprs", ""), "spilled_sgprs": n.get("spilled_sgprs", ""),
                "waves": n.get("waves", ""), "god_waves": g.get("waves", ""), "gate": gate,
            })

        print(f"changed shaders: {changed}")
        print(f"new spill regressions: {bad_spills}")
        print(f"occupancy regressions (where available): {occ_regress}")
        for k, (go, ne) in totals.items():
            if go:
                print(f"{k:20s} GOD={go:12d}  EXP110={ne:12d}  delta={(ne/go-1)*100:+.3f}%")

    with a.csv.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(out)
    print(f"\nCSV={a.csv}")


if __name__ == "__main__":
    main()
