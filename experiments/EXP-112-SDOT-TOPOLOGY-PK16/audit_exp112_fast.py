#!/usr/bin/env python3
import argparse, csv, pathlib, re

ISA_PATTERNS = {
    'bfe_i32': re.compile(r'\bv_bfe_i32(?:_e64)?\b', re.I),
    'mul_i24': re.compile(r'\bv_mul_i32_i24\b', re.I),
    'mul_i24_sdwa': re.compile(r'\bv_mul_i32_i24(?:_sdwa)?\b[^\n]*(?:src0_sel|src1_sel)|\bv_mul_i32_i24_sdwa\b', re.I),
    'mad_i24': re.compile(r'\bv_mad_i32_i24\b', re.I),
    'add_u32': re.compile(r'\bv_add_u32\b', re.I),
    'add3_u32': re.compile(r'\bv_add3_u32\b', re.I),
    'src0_sbyte': re.compile(r'\bsrc0_sel\s*:\s*(?:sbyte[0-3]|BYTE_[0-3](?:\s+sext)?)', re.I),
    'src1_sbyte': re.compile(r'\bsrc1_sel\s*:\s*(?:sbyte[0-3]|BYTE_[0-3](?:\s+sext)?)', re.I),
    'explicit_extract': re.compile(r'\bp_extract\b|\bextract_i8\b', re.I),
}

TEXT_SUFFIXES = {'.txt', '.log', '.asm', '.isa', '.aco', '.disasm', '.stats', '.out', '.err', '.tsv', '.csv'}
TEXT_NAMES = {'stdout', 'stderr', 'output', 'stats', 'isa', 'disasm'}


def read_tsv(root: pathlib.Path):
    p = root / 'profile.tsv'
    if not p.is_file():
        raise SystemExit(f'EXP112_FAST_AUDIT_FAIL: missing {p}')
    with p.open(newline='') as f:
        rows = list(csv.DictReader(f, delimiter='\t'))
    return rows


def to_num(v):
    try:
        if v is None or v == '':
            return None
        return float(v)
    except ValueError:
        return None


def aggregate_tsv(rows):
    sums = {}
    numeric_seen = {}
    for row in rows:
        for k, v in row.items():
            n = to_num(v)
            if n is None:
                continue
            sums[k] = sums.get(k, 0.0) + n
            numeric_seen[k] = numeric_seen.get(k, 0) + 1
    return sums, numeric_seen


def should_scan(p: pathlib.Path):
    if p.name == 'profile.tsv':
        return False
    if p.suffix.lower() in TEXT_SUFFIXES:
        return True
    if p.name.lower() in TEXT_NAMES:
        return True
    low = p.name.lower()
    return any(tok in low for tok in ('isa', 'disasm', 'aco', 'stats', 'stderr', 'stdout'))


def scan_isa(root: pathlib.Path):
    totals = {k: 0 for k in ISA_PATTERNS}
    files = []
    skipped = 0
    for p in root.rglob('*'):
        if not p.is_file():
            continue
        try:
            size = p.stat().st_size
        except OSError:
            continue
        if size > 32 * 1024 * 1024 or not should_scan(p):
            skipped += 1
            continue
        try:
            t = p.read_text(errors='ignore')
        except OSError:
            continue
        vals = {k: len(rx.findall(t)) for k, rx in ISA_PATTERNS.items()}
        if any(vals.values()):
            files.append((p, vals))
            for k, v in vals.items():
                totals[k] += v
    return totals, files, skipped


def delta_pct(n, g):
    if g == 0:
        return 'n/a'
    return f'{(n / g - 1.0) * 100:+.3f}%'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--god', type=pathlib.Path, required=True)
    ap.add_argument('--candidate', action='append', required=True, help='name=/path')
    args = ap.parse_args()

    roots = [('god', args.god)]
    for spec in args.candidate:
        name, path = spec.split('=', 1)
        roots.append((name, pathlib.Path(path)))

    data = {}
    for name, root in roots:
        print(f'FAST_AUDIT_SCAN_START name={name} root={root}', flush=True)
        rows = read_tsv(root)
        sums, seen = aggregate_tsv(rows)
        isa, isa_files, skipped = scan_isa(root)
        data[name] = (rows, sums, seen, isa, isa_files)
        print(f'FAST_AUDIT_SCAN_DONE name={name} shaders={len(rows)} isa_files={len(isa_files)} skipped_nontext={skipped}', flush=True)

    god = data['god']
    print('\n=== PROFILE.TSV AGGREGATES ===')
    interesting = ('instructions', 'valu', 'latency', 'inverse_throughput', 'code_size',
                   'vgpr', 'vgprs', 'sgpr', 'sgprs', 'spilled_vgprs', 'spilled_sgprs',
                   'waves', 'occupancy')
    keys = sorted(k for k in god[1] if any(tok in k.lower() for tok in interesting))
    if not keys:
        keys = sorted(god[1])
    for name, _ in roots:
        if name == 'god':
            continue
        print(f'\n-- {name} vs GOD --')
        for k in keys:
            g = god[1].get(k)
            n = data[name][1].get(k)
            if g is None or n is None:
                continue
            print(f'{k:28s} GOD={g:.3f} {name}={n:.3f} delta={n-g:+.3f} ({delta_pct(n,g)})')

    print('\n=== FINAL ISA COUNTS ===')
    if not any(god[3].values()):
        print('ISA_CAPTURE=ABSENT')
        print('NOTE=profiles contain no textual ISA recognized by the fast scanner; do not rerun the whole corpus yet.')
    else:
        for name, _ in roots:
            isa = data[name][3]
            print(f'\n-- {name} --')
            for k, v in isa.items():
                print(f'{k:20s} {v}')

        for name, _ in roots:
            if name == 'god':
                continue
            isa = data[name][3]
            print(f'\n-- ISA DELTA {name} vs GOD --')
            for k in ISA_PATTERNS:
                print(f'{k:20s} {isa[k]-god[3][k]:+d}')

    print('\nEXP112_FAST_AUDIT_DONE')

if __name__ == '__main__':
    main()
