# EXP-112 — SDOT TOPOLOGY / PK16

## Goal

EXP112 stops treating every FSR4 signed packed dot as the same problem.

EXP103/103B already killed the raw native integer-dot route on GFX1013: SDOT4/UDOT4/DOT2 are incorrect or inert. EXP110 showed that fewer NIR arithmetic operations alone do not guarantee more Cyberpunk FPS. EXP111 then proved a different mechanism: keep `v_mul_i32_i24` as VOP2 so GFX10 SDWA can absorb signed-byte extraction instead of allowing ACO to rebuild VOP3 `v_mad_i32_i24` chains.

EXP112 asks two new questions:

1. Are there important SDOT sub-populations (data×data, data×constant, constant×data, accumulator-zero, etc.) that should receive different lowering?
2. Can officially available GFX10 packed-16 ALU primitives provide any useful exact building block even though the integer DOT family is broken on GFX1013?

CODE GOD remains frozen and immutable. Every release-oriented candidate is rebuilt from the exact frozen GOD source located by the CODE GOD `libvulkan_radeon.so` SHA-256.

## Phase 1: topology census

Before promoting a new lowering, EXP112 records for each shader compilation:

- total `sdot_4x8_iadd`
- data × data (`dd`)
- data × constant (`dc`)
- constant × data (`cd`)
- constant × constant (`cc`)
- accumulator exactly zero
- accumulator constant non-zero
- accumulator dynamic

Set:

```bash
BC250_EXP112_CENSUS=1
```

The driver emits lines beginning with `EXP112_CENSUS`. If constant-sided SDOT is negligible in the real FSR4 corpus, the constant-specialization branch is killed immediately rather than game-tested.

## Candidate matrix

### `census`

Frozen GOD lowering plus topology instrumentation only. This is not an FPS candidate.

### `sdwa-ref`

EXP111 `surgical-history` reproduced exactly and instrumented with the EXP112 census. This is the primary EXP112 control.

### `const-sdwa`

Data×data retains the EXP111 balanced SDWA MUL24 tree. One-constant SDOT is also lowered to four independent `imul24_relaxed` products and a balanced add tree so the dynamic signed-byte source can be absorbed by SDWA while the constant side can fold at compile time.

This mode broadens the dense MUL24→MAD24 contraction guard to include a signed-byte × constant multiply. It must prove the intended final ISA before game testing.

### `const-fused`

Data×data stays on the EXP111 SDWA tree. One-constant SDOT instead uses four accumulator-fused `imad24_ir3` operations. This deliberately tests the opposite trade: fewer arithmetic instructions and a serial chain versus retaining explicit byte extraction/VOP3 encoding.

### `topology-auto`

Data×data uses EXP111 SDWA. One-constant SDOT uses:

- accumulator zero -> SDWA balanced tree (no final accumulator add)
- accumulator non-zero/dynamic -> fused MAD24 chain

The purpose is to use the accumulator topology rather than one global constant policy.

### `family-auto`

Same topological specialization, with shader-family density also participating in the constant policy. The initial experimental rule is conservative: smaller known-good families may use fused constant chains while large reductions prefer the shallower SDWA tree. This is a campaign candidate, not a release claim; the corpus audit decides whether the rule survives.

## Correctness

All integer transformations are exact modulo 2^32.

Every extracted signed byte is in `[-128,127]`, so each product is exactly representable by signed i24 multiply/MAD. Reassociation only changes wraparound i32 addition grouping.

Constant×constant is deliberately left to normal NIR constant folding rather than being forced through the BC250 lowering.

## Phase 2: PK16 probe

The integer DOT instructions are not the whole VOP3P/packed-ALU story. GFX10 also exposes packed 16-bit arithmetic such as `v_pk_mul_lo_u16`, `v_pk_add_i16`, and `v_pk_mad_i16`.

EXP112 will probe these independently and will not advertise any GFX1013 DOT feature bit.

Important safety/correctness constraint: two maximum signed byte products sum to 32768, which overflows signed i16. Therefore a naive packed `i16` accumulator is invalid. The first PK16 experiments are primitive/correctness probes and product-generation/reduction experiments only. A PK16 route is killed unless the complete unpack + arithmetic + horizontal reduction is bit-exact and cheaper than the current i24/SDWA path.

## Promotion gates

A candidate is not game-tested unless all applicable gates pass:

1. Vulkan device creation succeeds on BC-250.
2. Intended shader families actually change.
3. Intended ISA is present; a NIR-only change is not enough.
4. No new VGPR/SGPR spills in the full FSR4 corpus.
5. No unacceptable occupancy regression.
6. Constant-specialization is used by a meaningful number of real SDOT operations.
7. `const-sdwa` must show signed-byte SDWA selection and must not silently collapse back into the unwanted MAD24 shape.
8. Static instruction/code-size metrics are directional evidence only.
9. Controlled warmed Cyberpunk A/B remains final authority.

## Build

```bash
git clone --depth 1 --branch exp112-sdot-topology-pk16 \
  https://github.com/dmorazasanchez/bc250-fsr4.git \
  /home/david/fsr4-probes/exp112

bash /home/david/fsr4-probes/exp112/experiments/EXP-112-SDOT-TOPOLOGY-PK16/build-exp112-all.sh
```

Outputs:

```text
/home/david/fsr4-custom/investigation/experiments/EXP-112-SDOT-TOPOLOGY-PK16/
```

Build one mode only by passing it as an argument, for example:

```bash
bash experiments/EXP-112-SDOT-TOPOLOGY-PK16/build-exp112-all.sh census
bash experiments/EXP-112-SDOT-TOPOLOGY-PK16/build-exp112-all.sh sdwa-ref
```

## Immediate order

1. Build/run `census` across the FSR4 corpus.
2. If constant-sided SDOT is material, build `sdwa-ref`, `const-sdwa`, and `const-fused`.
3. Audit ISA/spills/occupancy.
4. Only then build/test `topology-auto` and `family-auto`.
5. Run the independent PK16 silicon/throughput probe after the normal ALU candidates are structurally understood.
