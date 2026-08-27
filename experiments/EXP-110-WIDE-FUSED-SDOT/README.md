# EXP-110 — WIDE FUSED SDOT

## Goal

Produce the next BC-250 FSR4 release candidate by reducing the software signed-INT8 dot cost across multiple FSR4 shader families at once. This is intentionally not a one-hash experiment.

CODE GOD remains frozen and immutable. EXP110 is derived from the exact source tree that produced the frozen GOD `libvulkan_radeon.so`, located by SHA-256, then copied before modification.

## Why this is different

GFX1013 silicon probing in EXP103/103B proved the candidate native integer-dot opcodes are unusable: plain SDOT4/UDOT4 and DOT2 forms are inert/incorrect, while the compact SDOT4C encoding aliases unrelated legacy behavior. The useful path is therefore still software signed dot on ordinary GFX10 ALU.

GOD's dense signed-dot prepass already converts each packed `sdot4 + accumulator` into signed i24 arithmetic. The important remaining redundancy is that the original accumulator is added *after* the four products.

For a serial chain, the existing shape is conceptually:

```
p = mul24(a0,b0)
p = mad24(a1,b1,p)
p = mad24(a2,b2,p)
p = mad24(a3,b3,p)
r = p + c
```

Five integer ALU operations after extraction.

EXP110 uses the SDOT accumulator directly:

```
r = mad24(a0,b0,c)
r = mad24(a1,b1,r)
r = mad24(a2,b2,r)
r = mad24(a3,b3,r)
```

Four integer ALU operations. The dual-chain variant similarly drops GOD's six-operation two-chain form to five operations by seeding one chain with `c` and combining once.

The transformation is exact modulo 2^32. Each `aN`/`bN` is a sign-extended i8 in [-128,127], so its product is exactly representable by signed i24 multiply/MAD; reassociation is only integer wraparound addition/multiplication, matching NIR i32 semantics.

## Scale

The potential saving is one ALU instruction per lowered SDOT. In the audited FSR4 corpus, substantial families include roughly 512, 1088, 1152, 2048, 2304 and larger 4K+ packed-dot counts. Therefore a single shader can lose hundreds to several thousand integer ALU instructions before any secondary CSE/scheduling effect.

This does **not** imply the same percentage FPS gain. Cyberpunk remains the authority.

## Four candidates

`god-gate-fused`
: Preserve GOD's exact family eligibility/two-chain policy. Only replace the per-SDOT math with accumulator-fused serial/dual forms. This is the lowest-risk candidate and keeps all later GOD classification work intact.

`serial-wide`
: Apply the four-MAD serial form to every compute shader with at least 512 packed signed dots. Lowest instruction count and one accumulator chain.

`dual-wide`
: Apply the five-op dual-chain form to every compute shader with at least 512 packed signed dots. Trades one extra ALU against the serial form for more ILP/shorter dependency chains.

`hybrid-wide`
: Serial below 1536 SDOTs, dual at 1536+. This deliberately attacks the 512/1088/1152 families with minimum instruction count while protecting ILP/lifetimes in ED7/2304/4K+ reductions.

The wide modes are campaign candidates, not production claims. They must pass the full-corpus gates.

## Hard promotion gates

1. Correct build and Vulkan startup on BC-250.
2. No new VGPR or SGPR spills anywhere in the full 64-shader corpus.
3. No occupancy regression where occupancy data is available, unless a real-game gain is large enough to justify a deliberate exception.
4. Static totals should move in the intended direction (VALU/instructions first; latency/inverse-throughput used as directional metrics only).
5. Cyberpunk warmed A/B, same scene, same FSR4 mode, RT state, clocks, thermals and cache discipline.
6. Prefer a candidate that improves FPS/frame time. If FPS is tied, materially lower GPU/CPU load, power, or frame-time variance is still useful but is not called an FPS win.

## Build all four from exact frozen GOD

```bash
git clone --depth 1 --branch exp110-wide-fused-sdot \
  https://github.com/dmorazasanchez/bc250-fsr4.git \
  /home/david/fsr4-probes/exp110

bash /home/david/fsr4-probes/exp110/experiments/EXP-110-WIDE-FUSED-SDOT/build-exp110-all.sh
```

If automatic SHA matching cannot locate the exact GOD source tree, the script exits without modifying anything. It can then be pointed explicitly at that source with `GOD_SRC=/path/to/mesa`.

Outputs are under:

```
/home/david/fsr4-custom/investigation/experiments/EXP-110-WIDE-FUSED-SDOT/
```

Each candidate gets its own Mesa copy, build directory, ICD JSON, shader cache and `STEAM-LAUNCH-OPTIONS.txt`.

## Full-corpus comparison

Use the existing FSR4 profiler to produce one GOD profile directory and one profile directory per candidate, then compare with:

```bash
python3 compare_profiles.py \
  --god /path/to/god-profile \
  --candidate god-gate-fused=/path/to/profile-a \
  --candidate serial-wide=/path/to/profile-b \
  --candidate dual-wide=/path/to/profile-c \
  --candidate hybrid-wide=/path/to/profile-d
```

`compare_profiles.py` reports matched/changed shaders, aggregate instruction/VALU/latency/inverse-throughput deltas, new spills, occupancy regressions when present, and emits CSV for per-shader inspection.

## Release decision

Do not promote based on static modeled latency alone. The final release is whichever zero-spill candidate wins the controlled Cyberpunk A/B; if different shader families prefer different policies, the next step is to materialize a final structural hybrid rather than force one global mode.
