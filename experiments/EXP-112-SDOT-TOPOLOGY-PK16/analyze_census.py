#!/usr/bin/env python3
import argparse
import collections
import pathlib
import re
import sys

LINE = re.compile(
    r'EXP112_CENSUS\s+name=(?P<name>\S+)\s+'
    r'density_sdot=(?P<density>\d+)\s+'
    r'total=(?P<total>\d+)\s+'
    r'dd=(?P<dd>\d+)\s+'
    r'dc=(?P<dc>\d+)\s+'
    r'cd=(?P<cd>\d+)\s+'
    r'cc=(?P<cc>\d+)\s+'
    r'acc_zero=(?P<acc_zero>\d+)\s+'
    r'acc_const=(?P<acc_const>\d+)\s+'
    r'acc_dynamic=(?P<acc_dynamic>\d+)'
)

FIELDS = ('density', 'total', 'dd', 'dc', 'cd', 'cc',
          'acc_zero', 'acc_const', 'acc_dynamic')


def read_inputs(paths):
    if not paths:
        yield '<stdin>', sys.stdin.read()
        return
    for raw in paths:
        p = pathlib.Path(raw)
        if p.is_dir():
            for f in sorted(p.rglob('*')):
                if f.is_file() and f.stat().st_size <= 64 * 1024 * 1024:
                    try:
                        yield str(f), f.read_text(errors='ignore')
                    except OSError:
                        pass
        else:
            yield str(p), p.read_text(errors='ignore')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('paths', nargs='*', help='log files or directories; stdin if omitted')
    ap.add_argument('--min-const-pct', type=float, default=1.0,
                    help='minimum one-constant SDOT share to keep const branch alive')
    ap.add_argument('--min-const-ops', type=int, default=128,
                    help='minimum one-constant SDOT operations to keep branch alive')
    args = ap.parse_args()

    rows = []
    for source, text in read_inputs(args.paths):
        for m in LINE.finditer(text):
            d = m.groupdict()
            row = {'source': source, 'name': d.pop('name')}
            row.update({k: int(v) for k, v in d.items()})
            rows.append(row)

    if not rows:
        raise SystemExit('EXP112_CENSUS_ANALYSIS_FAIL: no EXP112_CENSUS lines found')

    # Shader compilation logs can contain repeated pipeline/cache compilations.
    # Deduplicate identical census records so a noisy run does not manufacture
    # importance for one topology.
    uniq = {}
    for r in rows:
        key = (r['name'],) + tuple(r[k] for k in FIELDS)
        uniq[key] = r
    rows = list(uniq.values())

    totals = collections.Counter()
    for r in rows:
        for k in FIELDS:
            totals[k] += r[k]

    one_const = totals['dc'] + totals['cd']
    total = totals['total']
    const_pct = (100.0 * one_const / total) if total else 0.0
    dd_pct = (100.0 * totals['dd'] / total) if total else 0.0
    zero_pct = (100.0 * totals['acc_zero'] / total) if total else 0.0

    print(f'EXP112_CENSUS_RECORDS={len(rows)}')
    for k in FIELDS:
        print(f'{k.upper()}={totals[k]}')
    print(f'ONE_CONST={one_const}')
    print(f'ONE_CONST_PCT={const_pct:.4f}')
    print(f'DD_PCT={dd_pct:.4f}')
    print(f'ACC_ZERO_PCT={zero_pct:.4f}')

    print('\n=== TOP CONSTANT-SIDED RECORDS ===')
    ranked = sorted(rows, key=lambda r: (r['dc'] + r['cd'], r['total']), reverse=True)
    for r in ranked[:20]:
        oc = r['dc'] + r['cd']
        if not oc:
            continue
        pct = 100.0 * oc / r['total'] if r['total'] else 0.0
        print(f"name={r['name']} total={r['total']} one_const={oc} ({pct:.2f}%) "
              f"dd={r['dd']} dc={r['dc']} cd={r['cd']} cc={r['cc']} "
              f"acc0={r['acc_zero']} accC={r['acc_const']} accD={r['acc_dynamic']}")

    keep = one_const >= args.min_const_ops and const_pct >= args.min_const_pct
    if keep:
        print('\nCONST_SPECIALIZATION_GATE=PASS')
        print('NEXT=build sdwa-ref const-sdwa const-fused')
    else:
        print('\nCONST_SPECIALIZATION_GATE=KILL')
        print('NEXT=do not game-test constant-specialization; move to other EXP112 topology/PK16 work')


if __name__ == '__main__':
    main()
