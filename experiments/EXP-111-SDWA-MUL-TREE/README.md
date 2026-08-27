# EXP-111 — SDWA MUL TREE

## Objective

One more broad FPS-focused compiler experiment after CODE GOD and EXP110 showed effectively the same Cyberpunk performance as MastaG.

This is not another scheduler/pressure micro-tweak. It tests a different hypothesis: our previous MAD24-centric signed-dot lowering may reduce NIR arithmetic count while preventing GFX10 sub-dword addressing (SDWA) from eliminating the signed-byte extraction instructions.

## Research basis

GFX10 `v_mul_i32_i24` is a VOP2 operation. SDWA is available on VOP1/VOP2/VOPC and can select BYTE_0..BYTE_3 with sign extension. Mesa/ACO tracks extract operations (`label_extract`) and is SDWA-aware. ACO also explicitly combines `v_mul_i32_i24 + add` into `v_mad_i32_i24`.

That interaction can be counterproductive for FSR4's software SDOT fallback: a VOP3 MAD chain can be arithmetically shorter yet retain separate byte-extraction instructions, while a VOP2 MUL tree may absorb those extracts into SDWA source selectors.

EXP111 therefore optimizes for **final hardware ISA count**, not NIR arithmetic count or static modeled latency alone.

## Transformation

For data×data packed signed SDOT:

```
p0 = mul24(extract_i8(a,0), extract_i8(b,0))
p1 = mul24(extract_i8(a,1), extract_i8(b,1))
p2 = mul24(extract_i8(a,2), extract_i8(b,2))
p3 = mul24(extract_i8(a,3), extract_i8(b,3))
r  = (p0+p1) + (p2+p3) + accumulator
```

The arithmetic is exact modulo i32. ACO's normal MUL24→MAD24 combine is suppressed only for GFX1013 compute programs that already contain at least 256 selected `v_mul_i32_i24`, so ordinary shaders keep GOD/upstream behavior.

## Candidates

- `god-gate`: exact GOD family eligibility; only encoding strategy changes.
- `history-wide`: GOD known-good families plus 512, 2048/ED7 and >2304; preserves low-IMUL 1152/e955 and low-control 2304 exclusions from the previous full64 campaign.
- `wide`: every compute shader with >=512 packed signed dots. Aggressive bookend.

## Hard gates before Cyberpunk

The experiment is considered structurally successful only if the full shader corpus shows the intended ISA shift:

1. `v_bfe_i32` / explicit byte extraction falls materially.
2. SDWA/byte-select `v_mul_i32_i24` rises.
3. No new VGPR/SGPR spills.
4. No unacceptable occupancy loss.
5. Total instructions/VALU should improve or at minimum trade favorably against dependency latency.

If `v_bfe_i32` does not fall by at least ~10% in the affected corpus, do **not** game-test that candidate; the core hypothesis did not materialize.

## Exact-GOD local build

```bash
git clone --depth 1 --branch exp111-sdwa-mul-tree \
  https://github.com/dmorazasanchez/bc250-fsr4.git \
  /home/david/fsr4-probes/exp111

bash /home/david/fsr4-probes/exp111/experiments/EXP-111-SDWA-MUL-TREE/build-exp111-all.sh
```

The builder locates the exact source tree that produced frozen CODE GOD by SHA-256 and copies it. It aborts if exact GOD source cannot be located. CODE GOD is never modified.

Outputs:

```
/home/david/fsr4-custom/investigation/experiments/EXP-111-SDWA-MUL-TREE/
```

Each candidate has its own library, ICD, cache and Steam launch string.

## Corpus audit

After generating GOD and candidate ACO/ISA dumps with the existing FSR4 profiler:

```bash
python3 audit_isa.py \
  --god /path/to/god-profile \
  --candidate god-gate=/path/to/god-gate-profile \
  --candidate history-wide=/path/to/history-profile \
  --candidate wide=/path/to/wide-profile
```

The audit reports BFE, MUL24, MAD24, SDWA markers, instructions, VALU, latency, inverse throughput, spills and occupancy per shader and in aggregate.

## Final authority

Only controlled Cyberpunk A/B can establish an FPS win. A candidate that merely has prettier static statistics is not promoted. The target is a repeatable FPS/frame-time improvement over frozen GOD/MastaG, with lower load/power useful as a secondary benefit.
