# EXP-111 — SDWA MUL TREE

## Objective

One more broad FPS-focused compiler experiment after CODE GOD and EXP110 showed effectively the same Cyberpunk performance as MastaG.

This is not another scheduler/pressure micro-tweak. It tests a different hypothesis: our previous MAD24-centric signed-dot lowering may reduce NIR arithmetic count while preventing GFX10 sub-dword addressing (SDWA) from eliminating the signed-byte extraction instructions.

## Research basis

GFX10 `v_mul_i32_i24` is a VOP2 operation and has an SDWA encoding. GFX10 SDWA can select BYTE_0..BYTE_3 and sign-extend integer sub-dword operands. Mesa/ACO explicitly tracks extract operations (`label_extract`), applies SDWA during operand propagation, and separately has two integer-add combine paths that can turn `v_mul_i32_i24 + add` into VOP3 `v_mad_i32_i24`.

That interaction can be counterproductive for FSR4's software SDOT fallback: a VOP3 MAD chain can be arithmetically shorter yet retain standalone byte extraction, while a VOP2 MUL tree can potentially absorb **both** signed-byte extracts into the two SDWA source selectors.

EXP111 therefore optimizes for **final hardware ISA**, not NIR arithmetic count or static modeled latency alone.

## Transformation

For data×data packed signed SDOT:

```
p0 = mul24(extract_i8(a,0), extract_i8(b,0))
p1 = mul24(extract_i8(a,1), extract_i8(b,1))
p2 = mul24(extract_i8(a,2), extract_i8(b,2))
p3 = mul24(extract_i8(a,3), extract_i8(b,3))
r  = (p0+p1) + (p2+p3) + accumulator
```

The arithmetic is exact modulo i32. The balanced tree keeps product chains independent.

The ACO guard first identifies very large GFX1013 compute programs with at least **1024 selected `v_mul_i32_i24`**. That is deliberately far above incidental i24 use. Both Mesa contraction paths are covered:

- normal `v_add_u32 + v_mul_i32_i24 -> v_mad_i32_i24`
- carry-producing `v_add_co_u32 + v_mul_i32_i24 -> v_mad_i32_i24` when carry is dead

The normal `v_add_u32` path is the important one for NIR `iadd`; leaving it unguarded would invalidate the experiment.

## Candidates

- `surgical-history` — **preferred release-oriented candidate**. Uses the history-aware shader-family gate and rejects MUL24→MAD24 contraction only when both multiply operands are signed-byte extracts in a dot-dense GFX1013 compute program. All unrelated i24 contraction remains GOD/upstream behavior.
- `god-gate` — exact GOD family eligibility; broad contraction suppression in dot-dense programs. Clean control for whether the encoding strategy alone helps.
- `history-wide` — GOD known-good families plus 512, 2048/ED7 and >2304; preserves low-IMUL 1152/e955 and low-control 2304 exclusions from the previous full64 campaign.
- `wide` — every compute shader with >=512 packed signed dots. Aggressive bookend.

## CI proof before hardware

EXP111 does more than compile Mesa. CI injects an ACO optimizer test with two independent **signed byte extracts** feeding `v_mul_i32_i24` and requires:

1. `v_mul_i32_i24` survives.
2. source 0 becomes signed byte selector 1 (`src0_sel:sbyte1`).
3. source 1 becomes signed byte selector 2 (`src1_sel:sbyte2`).
4. no explicit `p_extract` survives.

If that dual-source SDWA proof fails, the core hypothesis is rejected before Cyberpunk testing.

## Hard corpus gates before Cyberpunk

The experiment is considered structurally successful only if the FSR4 corpus shows the intended ISA shift:

1. `v_bfe_i32` / explicit byte extraction falls materially.
2. SDWA/byte-select `v_mul_i32_i24` rises.
3. Both signed-byte source selectors are observed in real shader ISA.
4. No new VGPR/SGPR spills.
5. No unacceptable occupancy loss.
6. Focused dot-core dynamic instruction count should improve enough to offset the larger SDWA encoding size.

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

Each candidate has its own library, ICD, cache and Steam launch string. `surgical-history` is built first.

## Corpus audit

After generating GOD and candidate ACO/ISA dumps with the existing FSR4 profiler:

```bash
python3 audit_isa.py \
  --god /path/to/god-profile \
  --candidate surgical-history=/path/to/surgical-profile \
  --candidate god-gate=/path/to/god-gate-profile \
  --candidate history-wide=/path/to/history-profile \
  --candidate wide=/path/to/wide-profile
```

The audit reports BFE, plain/SDWA MUL24, MAD24, ADD/ADD3, total focused dot-core dynamic ops, focused encoding bytes, instructions, VALU, latency, inverse throughput, spills and occupancy per shader and in aggregate.

## Final authority

Only controlled Cyberpunk A/B can establish an FPS win. A candidate that merely has prettier static statistics is not promoted. The target is a repeatable FPS/frame-time improvement over frozen GOD/MastaG, with lower load/power useful as a secondary benefit.
