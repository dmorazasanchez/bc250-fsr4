# EXP-103 — GFX1013 DOT SILICON

Diagnostic branch for the BC-250 / Cyan Skillfish integer-dot hardware question.

**This is not a release driver. CODE GOD remains immutable.**

## Why this experiment exists

FSR4 INT8 passes 1–13 are dominated by packed signed 4x8 dot products. On BC-250 the normal RADV path keeps integer-dot acceleration disabled and lowers signed packed dots to software integer arithmetic. A previous controlled force-native test emitted `v_dot4_i32_i8` but produced the wrong result (`0` where the CPU/software reference produced `70`).

Before doing more compiler tuning, EXP103 asks a narrower hardware question:

> Does any *other* nominal GFX10 packed integer-dot opcode execute correctly on GFX1013 even though the official target feature table disables the whole dot family?

## Important correction from source research

GFX1013 is **not** an officially supported integer-dot target in LLVM's target feature table. GFX1011/1012 and GFX1030-class targets have dot feature bits; GFX1013 does not. Historic LLVM gfx1013 MC tests also mark the integer-dot instructions unsupported.

Mesa 26.2.x nevertheless contains generic GFX10 encodings for:

- `v_dot2_i32_i16`
- `v_dot2_u32_u16`
- `v_dot4_i32_i8`
- `v_dot4_u32_u8`
- `v_dot8_i32_i4`
- `v_dot8_u32_u4`

That makes these **undocumented raw-silicon probes**, not supported features.

Mesa's normal NIR options derive SDOT4, UDOT4 and DOT2 from one coarse `has_accelerated_dot_product` flag. EXP103 deliberately does not flip that flag. Instead it preserves one family at a time using `BC250_DOT_PROBE`:

- `BC250_DOT_PROBE=sdot4` — preserve signed packed 4x8 only. Known-broken control.
- `BC250_DOT_PROBE=udot4` — preserve unsigned packed 4x8 only. Main candidate.
- `BC250_DOT_PROBE=dot2` — preserve signed/unsigned 2x16 family. Second-stage candidate.

The override is restricted to GFX1013 compute shaders.

## Why `v_dot4c_i32_i8` is no longer Priority Zero

ACO has a `v_dot4c_i32_i8` encoding, but current ACO uses the compact `dot4c` form specifically when applying DPP to a normal signed dot on GFX10/GFX10.3. FSR4's ordinary dot chain does not naturally require DPP. Therefore a simple forced SDOT does **not** independently test `dot4c`; it selects the normal VOP3 `v_dot4_i32_i8` path.

A raw `dot4c` machine-code/DPP probe is still possible later, but it is not the first useful FSR4 route.

## 4x8 gate

Build the disposable probe driver:

```bash
./experiments/EXP-103-GFX1013-DOT-SILICON/build-exp103-anywhere.sh
```

Then run the first gate on the BC-250:

```bash
./experiments/EXP-103-GFX1013-DOT-SILICON/run-exp103-4x8.sh
```

The script disables Mesa's disk shader cache and captures RADV ISA, so correctness is not accepted unless the intended native instruction is actually present.

### Expected SDOT control

The `sdot4` test is valid only if ISA contains:

```text
v_dot4_i32_i8
```

and output verification fails, reproducing the previously observed GFX1013 defect.

If SDOT unexpectedly passes, stop: the old result and the new environment must be reconciled before proceeding.

### UDOT decision

The `udot4` route survives only if both are true:

1. ISA contains `v_dot4_u32_u8`.
2. GPU output is bit-exact against the CPU reference.

If either fails, the unsigned-bias SDOT reconstruction route is killed.

If both pass, the script immediately performs five software-vs-native UDOT throughput runs:

- GOD = normal software UDOT lowering.
- EXP103 = native `v_dot4_u32_u8`.

## If UDOT survives

For signed bytes `a,b`, bias each packed byte by 128:

```text
A = a ^ 0x80808080
B = b ^ 0x80808080
```

Then exactly:

```text
sdot(a,b)
= udot(A,B)
- 128 * sum_bytes(A)
- 128 * sum_bytes(B)
+ 65536
```

No approximation is involved.

The important optimization is convolution-level amortization, not the naïve three-dot implementation. Across a convolution, the weight correction can be folded into the layer/output bias and the activation correction can be shared across output features that use the same receptive field. That is the path that could approach one native UDOT per original packed signed dot.

GFX10 also has `v_sad_u8` and `v_msad_u8` encodings. A later EXP105 probe can use SAD/MSAD to accelerate packed byte sums if UDOT is correct.

## If UDOT dies

Move to the `dot2` probe. SPIR-V's integer-dot extension permits generic 2-component 16-bit vectors through `DotProductInputAll`, allowing us to force NIR `sdot_2x16_iadd` / `udot_2x16_uadd` and see whether GFX1013's defect is specific to the 8-bit path.

The practical FSR4 comparison will be:

```text
2 x native DOT2 + byte->i16 unpack/repack
vs
4 x current signed i24 multiply/MAD arithmetic
```

DOT2 is useful only if the total unpack + dot cost beats GOD's existing fallback.

## Kill rules

- Intended native opcode absent in ISA -> invalid experiment, do not use timing.
- UDOT incorrect -> kill UDOT/bias branch.
- UDOT correct but native primitive is not materially faster than GOD software UDOT -> do not integrate into FSR4.
- DOT2 incorrect -> kill DOT2 branch.
- DOT2 correct but `2*DOT2 + unpack` cannot beat GOD signed fallback -> kill DOT2 branch.
- No static compiler metric can promote an experiment by itself. Runtime primitive or dispatch timing must move.

## Baseline

Canonical stable reference remains:

```text
/home/david/fsr4-custom/investigation/releases/CODE-GOD-2026-08-26/radv-code-god.json
```

EXP103 never modifies that release directory.
