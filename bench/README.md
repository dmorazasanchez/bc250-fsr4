# INT8 dot-product micro-benchmark (GFX1013 / BC-250)

Headless Vulkan compute benchmark for the 4x8 packed integer dot ops
(`OpSDotKHR`, `OpUDotKHR`, `OpSUDotKHR` — SPV_KHR_integer_dot_product),
which is exactly the path FSR 4 INT8 uses and that `bc250-fsr4-i24.patch`
optimizes in RADV's software fallback.

## What it measures

Each kernel runs `NELEM` lanes, each accumulating a dependent chain of
16 distinct dot products per loop iteration, for 16384 iterations
(~68.7 G dots per dispatch). Operands are XOR-rotated with the loop
counter so the compiler cannot hoist or CSE the dots out of the loop.
Results are verified on the CPU against an exact per-lane simulation
(sampled lanes). GPU clocks are reported from `pp_dpm_sclk`; the host
spins the GPU for ~1.5 s before timing to ramp clocks out of idle states.

## Requirements

- spirv-tools (`spirv-as`, `spirv-val`, `spirv-dis`)
- Vulkan headers + libvulkan
- gcc

## Usage

```bash
# generate kernels (big: UNROLL=16 ITER=16384, and mini for quick correctness)
python3 gen_kernels.py 8 64 _mini   # correctness-only variant
python3 gen_kernels.py              # performance variant

gcc -O2 -Wall -o bench bench.c -lvulkan

# run against a specific driver
VK_DRIVER_FILES=/path/to/radv-bc250-fsr4.json ./bench dot_sdot.spv sdot 16384 16
# system default driver
./bench dot_sdot.spv sdot 16384 16
# fast correctness pass (no warmup, 1 rep)
./bench dot_sdot_mini.spv sdot 64 8 fast
```

Kernel kinds: `sdot`, `udot`, `sudot`.

## Measured results (BC-250, sclk pinned at 2150 MHz, 2 rounds, verify PASS)

| kernel | system RADV 26.3.0-devel | pre-v2 build (26.1.6 + sdot-only patch) | v2 build (26.1.6 + this patch) |
|--------|--------------------------|------------------------------------------|--------------------------------|
| sdot   | 648 Gdot/s               | 694 Gdot/s                               | 694 Gdot/s                     |
| udot   | 650 Gdot/s               | 650 Gdot/s                               | 696 Gdot/s                     |
| sudot  | 648 Gdot/s               | 209 Gdot/s                               | 695 Gdot/s                     |

Interpretation:

- The v2 patch makes all three dot ops uniform at ~695 Gdot/s on the
  26.1.6 base (+7% vs system Mesa 26.3.0-devel for every op).
- The sdot-only (pre-v2) build regresses sudot 3.3x on the same base;
  extending the lowering to `udot`/`sudot` fixes that hole.
- Idle-clock states inflate naive first-run numbers by 4x or more —
  always warm up and read `pp_dpm_sclk` before comparing drivers.
