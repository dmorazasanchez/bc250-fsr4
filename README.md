# BC-250 FSR4 v2 — Selective DP4A Breakthrough

Experimental Mesa RADV build for the **AMD BC-250 / GFX1013**, focused on improving the performance of **FSR 4 INT8** workloads without enabling the broken native packed-dot path.

**v2 is based on Mesa 26.2.0 and the EXP-028 compiler strategy.**

> Experimental software for BC-250 / GFX1013 only. Do **not** install this RADV library system-wide.

## What changed in v2?

FSR 4 can run on the BC-250, but GFX1013 does not have a functionally usable native signed packed 4x8 dot-product path.

Direct testing showed that forcing Mesa's accelerated path can emit `v_dot4_i32_i8`, but the instruction does not produce correct results on the BC-250:

    Expected: 70
    Native v_dot4 result: 0

The software fallback is correct, so this project optimizes that fallback instead.

Mesa 26.2 already lowers the signed 4x8 dot product using relaxed 24-bit integer multiplies. Reassociating the addition tree improves code generation dramatically for many FSR4 shaders, but our 64-shader capture found an important problem: **global reassociation can cause catastrophic register pressure and spilling in specific kernels.**

EXP-028 solves this selectively:

- **Constant accumulator -> keep Mesa's balanced lowering**
- **Non-constant accumulator -> use the optimized right-reassociated lowering**

This keeps the major performance wins while avoiding the worst spill regressions.

## Representative compiler results

### Hot FSR4 kernel (`8317...`)

Stock / MastaG-style lowering:

    VGPRs:              256
    Pre-Sched VGPRs:     169
    Spilled VGPRs:         0
    Subgroups/SIMD:        4
    Instructions:      16681
    Latency:          407842

v2 / EXP-028:

    VGPRs:              168
    Pre-Sched VGPRs:     138
    Spilled VGPRs:         0
    Subgroups/SIMD:        6
    Instructions:      15486
    Latency:          387788

### Pathological shader (`ed7...`)

Global reassociation:

    Pre-Sched VGPRs:    3035
    Spilled VGPRs:      2794
    Scratch size:     699392
    Instructions:      26926
    Latency:           41938

v2 / EXP-028:

    Pre-Sched VGPRs:    1555
    Spilled VGPRs:      1314
    Scratch size:     320512
    Instructions:      21750
    Latency:           35962

The selective rule restores the safe balanced lowering for this shader while retaining the reassociation win on the important hot kernels.

## Real-world testing

Tested on:

- AMD BC-250 / GFX1013
- PCI ID `0x13FE`
- Mesa 26.2.0
- FSR 4.1.1 INT8
- Cyberpunk 2077

In repeated same-scene testing, EXP-028 performed better than the previous MastaG/global-reassociation baseline while rendering correctly.

This is the current known-good performance baseline for the project.

## Clean-clone validation

The v2 branch has been rebuilt successfully from a fresh GitHub clone on the BC-250.

Validated runtime output:

    deviceName    = AMD BC-250 (RADV GFX1013)
    deviceID      = 0x13fe
    driverName    = radv
    driverVersion = 26.2.0
    driverInfo    = Mesa 26.2.0 (git-9f0a761020)

Fresh GitHub v2 build SHA256:

    435ebcac375d5e5f3382e5123cf2b3de88ccbffc08fc17b7fa73759b28b04114

Original locally tested EXP-028 build SHA256:

    49f0ceb277e90734df1c1c6dcdfef2b871481da4bd32562ec397428492513af6

The hashes differ because the reproducible builder uses a different compiler/toolchain environment from the original CachyOS host build. The Mesa revision, patch set and Meson feature configuration are the important reproducible inputs.

## Requirements

- AMD BC-250 / GFX1013
- 64-bit Linux
- Vulkan / RADV
- Docker for the reproducible build path
- FSR 4 enabled separately in the game / translation layer

This repository does **not** install FSR 4 or OptiScaler.

## Build

Clone the v2 branch:

    git clone -b v2 --single-branch https://github.com/dmorazasanchez/bc250-fsr4.git
    cd bc250-fsr4

Build:

    ./build-anywhere.sh

The resulting driver will be placed in the repository root as:

    libvulkan_radeon.so

The v2 builder mirrors the EXP-028 Meson configuration:

    -Dbuildtype=release
    -Dwrap_mode=nodownload
    -Dvulkan-drivers=amd
    -Dgallium-drivers=radeonsi
    -Dllvm=enabled

It deliberately does **not** add the old host-specific `-march=x86-64-v3 -mtune=znver2` flags.

An existing `.build/` directory is explicitly reconfigured so stale v1 Meson options are not silently reused.

## Verify

Generate the ICD and run the validation helper:

    ./setup.sh
    ./check.sh

Then verify the driver actually loads:

    ./run-bc250-fsr4.sh vulkaninfo --summary

Expected device/driver:

    AMD BC-250 (RADV GFX1013)
    Mesa 26.2.0

## Steam

Run:

    ./setup.sh

Then use the generated ICD in Steam Launch Options.

Example:

    VK_DRIVER_FILES=/absolute/path/to/bc250-fsr4/radv-bc250-fsr4.json WINEDLLOVERRIDES="version=n,b" %command% --launcher-skip

`WINEDLLOVERRIDES` is not required by the RADV patch itself; it is included here because it is useful in the tested Cyberpunk / OptiScaler setup.

Remove `VK_DRIVER_FILES` from the game launch options to return to your normal system RADV driver.

## Patch order

The v2 patched build applies:

1. `v2-patches/0001-gfx1013-compute-queue-fix.patch`
2. `bc250-fsr4-v2-selective-sdot.patch`
3. `v2-patches/0003-radv-gfx103.patch`

The optional GFX10.3 override remains disabled unless `RADV_GFX103=1` is explicitly set at runtime.

## Why not native DP4A?

Because direct runtime testing showed the native path is not functionally usable on this hardware.

The project therefore does **not** spoof accelerated packed-dot support and does not rely on `v_dot4_i32_i8`.

Instead, it optimizes Mesa's correct software signed INT8 dot-product fallback.

## Why selective reassociation?

Global reassociation looked excellent on the main hot shaders, but full-corpus profiling exposed two severe pathological cases.

The key discriminator was the accumulator consumed by `sdot_4x8_iadd`:

- constant accumulator chains were responsible for the catastrophic spill regressions
- non-constant accumulator paths retained the large reassociation benefit

The NIR algebraic rule therefore matches constant `c` first and keeps the balanced sum, then applies the reassociated form to the generic non-constant case.

See [`V2.md`](V2.md) for the detailed EXP-028 investigation and shader metrics.

## Benchmark tools

`bench/` contains a Vulkan packed-dot diagnostic benchmark derived from work contributed by **higorprado** in PR #1.

The benchmark is kept separate from the compiler patch. Historical results from the old 26.1.6 experiment are documented as historical data only; they are not the basis of the EXP-028 selective lowering.

## Files

    bc250-fsr4-v2-selective-sdot.patch
        EXP-028 selective signed 4x8 dot-product lowering.

    v2-patches/
        BC-250 base patches used by the v2 build.

    mesa-commit.txt
        Mesa source revision/tag used for the build.

    build-anywhere.sh
        Reproducible Docker build entry point.

    build-bc250.sh
        Mesa build logic executed inside the builder container.

    setup.sh
        Generates an ICD JSON pointing at the local driver.

    check.sh
        Validates the built library, dependencies and ICD JSON.

    run-bc250-fsr4.sh
        Runs a command using the packaged v2 RADV driver.

    V2.md
        Detailed EXP-028 technical notes and validation results.

    bench/
        Packed INT8 dot-product diagnostic benchmark.

## Credits

Thanks to the BC-250 community for testing, reverse-engineering and sharing hardware findings.

Special thanks to **higorprado** for PR #1, which contributed useful validation, packaging and benchmarking ideas. The global compiler reassociation from that PR is **not** used in v2; EXP-028 uses the selective signed lowering described above.

Thanks also to the MastaG BC-250 work for the compute-queue and RADV compatibility patches used as part of the base environment.

## Warning

This is experimental software.

It has been tested specifically on:

    AMD BC-250
    GFX1013
    PCI ID 0x13FE

Do **not** install `libvulkan_radeon.so` system-wide.

Games may crash, display corrupted graphics, hang or trigger a GPU reset.

## Status

**v2 / EXP-028 is runtime-validated and clean-clone build-validated on the BC-250.**

FSR 4.1.1 has been tested successfully in Cyberpunk 2077 with correct rendering and improved performance over the previous project baseline.
