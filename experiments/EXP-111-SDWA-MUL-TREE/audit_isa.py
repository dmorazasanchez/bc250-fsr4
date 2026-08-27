#!/usr/bin/env python3
import argparse, csv, re
from pathlib import Path

HASH = re.compile(r'(?:0x)?([0-9a-fA-F]{64})')
PATTERNS = {
    'instructions': re.compile(r'\binstructions?\b\s*[:= ]\s*(\d+)', re.I),
    'valu': re.compile(r'\bvalu\b\s*[:= ]\s*(\d+)', re.I),
    'latency': re.compile(r'\blatency\b\s*[:= ]\s*(\d+)', re.I),
    'inverse_throughput': re.compile(r'\binverse[_ ]throughput\b\s*[:= ]\s*(\d+)', re.I),
    'spilled_vgprs': re.compile(r'\bspilled[_ ]vgprs\b\s*[:= ]\s*(\d+)', re.I),
    'spilled_sgprs': re.compile(r'\bspilled[_ ]sgprs\b\s*[:= ]\s*(\d+)', re.I),
    'waves': re.compile(r'\b(?:waves|occupancy)\b\s*[:= ]\s*(\d+)', re.I),
    'code_size': re.compile(r'\b(?:code[_ ]size|binary[_ ]size)\b\s*[:= ]\s*(\d+)', re.I),
}

# Match ACO dumps and assembler-style output.  Important details:
# - `_sdwa` prevents a simple `\bv_mul_i32_i24\b` from matching because `_`
#   is a word character.
# - ACO commonly prints signed selectors as `sbyte0..3`; LLVM/assembler docs
#   commonly render BYTE_0..3 plus sext state.  Count both representations.
ISA = {
    'bfe_i32': re.compile(r'\bv_bfe_i32(?:_e64)?\b', re.I),
    'mul_i24_plain': re.compile(r'\bv_mul_i32_i24\b(?!_sdwa)', re.I),
    'mul_i24_sdwa': re.compile(r'\bv_mul_i32_i24_sdwa\b|\bv_mul_i32_i24\b[^\n]*(?:src0_sel|src1_sel)', re.I),
    'mad_i24': re.compile(r'\bv_mad_i32_i24\b', re.I),
    'sdwa_any': re.compile(r'\b[a-z0-9_]+_sdwa\b|\bsrc[01]_sel\s*:', re.I),
    'sbyte_src': re.compile(r'\bsrc[01]_sel\s*:\s*(?:sbyte[0-3]|BYTE_[0-3](?:\s+sext)?)', re.I),
    'src0_sbyte': re.compile(r'\bsrc0_sel\s*:\s*(?:sbyte[0-3]|BYTE_[0-3](?:\s+sext)?)', re.I),
    'src1_sbyte': re.compile(r'\bsrc1_sel\s*:\s*(?:sbyte[0-3]|BYTE_[0-3](?:\s+sext)?)', re.I),
    'explicit_extract': re.compile(r'\bp_extract\b|\bextract_i8\b', re.I),
}


def sid(p, text):
    m = HASH.search(p.name) or HASH.search(text[:4096])
    return m.group(1).lower() if m else p.stem


def scan(root):
    out = {}
    for p in root.rglob('*'):
        if not p.is_file() or p.stat().st_size > 64 * 1024 * 1024:
            continue
        try:
            t = p.read_text(errors='ignore')
        except OSError:
            continue
        vals = {k: len(r.findall(t)) for k, r in ISA.items()}
        vals['mul_i24_total'] = vals['mul_i24_plain'] + vals['mul_i24_sdwa']
        # Focused encoding-byte estimate for the instructions EXP111 directly
        # trades. GFX10 VOP2 plain/BFE are 4B; SDWA and VOP3 MAD are 8B.
        # This is not total shader code size; it quantifies the local trade.
        vals['dot_core_bytes_est'] = (
            vals['bfe_i32'] * 4 +
            vals['mul_i24_plain'] * 4 +
            vals['mul_i24_sdwa'] * 8 +
            vals['mad_i24'] * 8
        )
        for k, r in PATTERNS.items():
            m = r.search(t)
            if m:
                vals[k] = int(m.group(1))
        if not any(vals.get(k, 0) for k in ISA) and not any(k in vals for k in PATTERNS):
            continue
        s = sid(p, t)
        score = sum(1 for k, v in vals.items() if v)
        if s not in out or score > out[s][0]:
            out[s] = (score, vals, str(p))
    return {k: (v[1], v[2]) for k, v in out.items()}


def pct(n, g):
    return '' if not isinstance(n, int) or not isinstance(g, int) or g == 0 else f'{(n/g-1)*100:+.3f}%'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--god', type=Path, required=True)
    ap.add_argument('--candidate', action='append', required=True)
    ap.add_argument('--csv', type=Path, default=Path('exp111-audit.csv'))
    a = ap.parse_args()
    god = scan(a.god)
    if not god:
        raise SystemExit('No GOD shader/ISA records found')

    metric_keys = [*ISA.keys(), 'mul_i24_total', 'dot_core_bytes_est']
    rows = []
    for spec in a.candidate:
        name, path = spec.split('=', 1)
        cand = scan(Path(path))
        common = sorted(set(god) & set(cand))
        print(f'\n=== {name}: matched {len(common)}/{len(god)} GOD records ===')
        gt = {k: 0 for k in metric_keys}
        nt = {k: 0 for k in metric_keys}
        spill = occ = 0
        changed = 0
        per_shader_bfe_wins = per_shader_sdwa_wins = 0

        for s in common:
            g, _ = god[s]
            n, np = cand[s]
            for k in metric_keys:
                gt[k] += g.get(k, 0)
                nt[k] += n.get(k, 0)
            gate = 'OK'
            if n.get('spilled_vgprs', 0) > g.get('spilled_vgprs', 0) or n.get('spilled_sgprs', 0) > g.get('spilled_sgprs', 0):
                gate = 'REJECT_SPILL'; spill += 1
            if 'waves' in g and 'waves' in n and n['waves'] < g['waves']:
                gate += '+REJECT_OCC' if gate != 'OK' else 'REJECT_OCC'; occ += 1
            if n.get('bfe_i32', 0) < g.get('bfe_i32', 0):
                per_shader_bfe_wins += 1
            if n.get('mul_i24_sdwa', 0) > g.get('mul_i24_sdwa', 0):
                per_shader_sdwa_wins += 1
            if any(n.get(k) != g.get(k) for k in metric_keys):
                changed += 1

            row = {'variant': name, 'shader': s, 'gate': gate, 'path': np}
            for k in (*metric_keys, 'instructions', 'valu', 'latency', 'inverse_throughput',
                      'spilled_vgprs', 'spilled_sgprs', 'waves', 'code_size'):
                row[k] = n.get(k, '')
                row['d_' + k] = pct(n.get(k), g.get(k))
            rows.append(row)

        print(f'changed ISA records: {changed}')
        print(f'new spill regressions: {spill}; occupancy regressions: {occ}')
        print(f'shaders with fewer BFE: {per_shader_bfe_wins}; shaders with more SDWA MUL24: {per_shader_sdwa_wins}')
        for k in metric_keys:
            delta = nt[k] - gt[k]
            print(f'{k:20s} GOD={gt[k]:10d} EXP111={nt[k]:10d} delta={delta:+d}')

        # Hard structural gates. Do not mistake a source-level change for a
        # successful encoding transformation.
        if gt['bfe_i32'] and nt['bfe_i32'] >= gt['bfe_i32'] * 0.90:
            print('ENCODING_GATE=FAIL: v_bfe_i32 did not fall by at least 10%')
        elif nt['mul_i24_sdwa'] <= gt['mul_i24_sdwa']:
            print('ENCODING_GATE=FAIL: SDWA v_mul_i32_i24 did not increase')
        elif nt['src0_sbyte'] == 0 or nt['src1_sbyte'] == 0:
            print('ENCODING_GATE=FAIL: dual signed-byte selectors not observed')
        elif spill:
            print('ENCODING_GATE=FAIL: new spills')
        else:
            print('ENCODING_GATE=PASS')

    fields = ['variant', 'shader', 'gate', 'path']
    for k in (*metric_keys, 'instructions', 'valu', 'latency', 'inverse_throughput',
              'spilled_vgprs', 'spilled_sgprs', 'waves', 'code_size'):
        fields += [k, 'd_' + k]
    with a.csv.open('w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader(); w.writerows(rows)
    print(f'CSV={a.csv}')


if __name__ == '__main__':
    main()
