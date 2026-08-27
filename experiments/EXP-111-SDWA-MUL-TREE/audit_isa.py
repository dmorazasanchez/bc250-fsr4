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
}
ISA = {
    'bfe_i32': re.compile(r'\bv_bfe_i32\b'),
    'mul_i24': re.compile(r'\bv_mul_i32_i24\b'),
    'mad_i24': re.compile(r'\bv_mad_i32_i24\b'),
    'sdwa': re.compile(r'\bsdwa\b|src_sel\s*:\s*BYTE_[0-3]|src[01]_sel\s*:\s*BYTE_[0-3]', re.I),
    'byte_sel': re.compile(r'BYTE_[0-3]', re.I),
}

def sid(p,text):
    m=HASH.search(p.name) or HASH.search(text[:4096]); return m.group(1).lower() if m else p.stem

def scan(root):
    out={}
    for p in root.rglob('*'):
        if not p.is_file() or p.stat().st_size > 64*1024*1024: continue
        try: t=p.read_text(errors='ignore')
        except OSError: continue
        vals={k:len(r.findall(t)) for k,r in ISA.items()}
        for k,r in PATTERNS.items():
            m=r.search(t)
            if m: vals[k]=int(m.group(1))
        if not any(vals.get(k,0) for k in ISA) and not any(k in vals for k in PATTERNS): continue
        s=sid(p,t)
        score=sum(1 for k in vals if vals[k])
        if s not in out or score > out[s][0]: out[s]=(score,vals,str(p))
    return {k:(v[1],v[2]) for k,v in out.items()}

def pct(n,g):
    return '' if not isinstance(n,int) or not isinstance(g,int) or g==0 else f'{(n/g-1)*100:+.3f}%'

def main():
    ap=argparse.ArgumentParser(); ap.add_argument('--god',type=Path,required=True); ap.add_argument('--candidate',action='append',required=True); ap.add_argument('--csv',type=Path,default=Path('exp111-audit.csv')); a=ap.parse_args()
    god=scan(a.god)
    if not god: raise SystemExit('No GOD shader/ISA records found')
    rows=[]
    for spec in a.candidate:
        name,path=spec.split('=',1); cand=scan(Path(path)); common=sorted(set(god)&set(cand))
        print(f'\n=== {name}: matched {len(common)}/{len(god)} GOD records ===')
        gt={k:0 for k in ISA}; nt={k:0 for k in ISA}; spill=occ=0
        for s in common:
            g,_=god[s]; n,np=cand[s]
            for k in ISA: gt[k]+=g.get(k,0); nt[k]+=n.get(k,0)
            gate='OK'
            if n.get('spilled_vgprs',0)>g.get('spilled_vgprs',0) or n.get('spilled_sgprs',0)>g.get('spilled_sgprs',0): gate='REJECT_SPILL'; spill+=1
            if 'waves' in g and 'waves' in n and n['waves']<g['waves']: gate += '+REJECT_OCC' if gate!='OK' else 'REJECT_OCC'; occ+=1
            row={'variant':name,'shader':s,'gate':gate,'path':np}
            for k in (*ISA.keys(),'instructions','valu','latency','inverse_throughput','spilled_vgprs','spilled_sgprs','waves'):
                row[k]=n.get(k,''); row['d_'+k]=pct(n.get(k),g.get(k))
            rows.append(row)
        print(f'new spill regressions: {spill}; occupancy regressions: {occ}')
        for k in ISA: print(f'{k:10s} GOD={gt[k]:8d} EXP111={nt[k]:8d} delta={nt[k]-gt[k]:+d}')
        if gt['bfe_i32'] and nt['bfe_i32'] >= gt['bfe_i32']*0.90:
            print('ENCODING_GATE=FAIL: v_bfe_i32 did not fall by at least 10%')
        elif nt['sdwa'] <= gt['sdwa']:
            print('ENCODING_GATE=WARN: SDWA markers did not increase')
        else:
            print('ENCODING_GATE=PASS')
    fields=['variant','shader','gate','path']
    for k in (*ISA.keys(),'instructions','valu','latency','inverse_throughput','spilled_vgprs','spilled_sgprs','waves'): fields += [k,'d_'+k]
    with a.csv.open('w',newline='') as f: w=csv.DictWriter(f,fieldnames=fields); w.writeheader(); w.writerows(rows)
    print(f'CSV={a.csv}')
if __name__=='__main__': main()
