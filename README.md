# BC-250 / GFX1013 Experimental FSR 4 RADV Driver

Experimental Mesa RADV build for the AMD BC-250 / GFX1013, intended to improve the performance of FSR 4 INT8 workloads.

This is an experimental test build. It does not replace your system Mesa installation and should NOT be installed system-wide.

## What does this do?

The BC-250 is identified by Mesa as:

    AMD BC-250 (RADV GFX1013)
    PCI device ID: 0x13FE

FSR 4 can run on the BC-250, but the normal software fallback for INT8 dot-product operations is extremely expensive.

Testing showed that enabling Mesa's native accelerated dot-product path directly is NOT correct on GFX1013. The resulting v_dot4_i32_i8 instruction path produced incorrect results and caused rendering problems.

Instead, this experimental driver keeps the software fallback but optimizes the signed 4x8-bit dot-product lowering using signed i24 arithmetic and a reassociated expression.

## Current results

Representative FSR 4.1.1 shader:

    Stock fallback:
    Instructions:       64269
    Code size:          436656 bytes
    Latency:            326131
    Inverse Throughput: 306140
    Pre-Sched VGPRs:    213
    VALU:               40035

    Optimized fallback:
    Instructions:       37613
    Code size:          293824 bytes
    Latency:            125293
    Inverse Throughput: 103720
    Pre-Sched VGPRs:    157
    VALU:               36608

The optimized driver has been tested successfully with FSR 4.1.1 in Cyberpunk 2077 on the BC-250, with correct rendering and substantially improved performance.

## Requirements

- AMD BC-250 / GFX1013
- 64-bit Linux
- Vulkan
- RADV
- FSR 4 enabled separately

This package does NOT install FSR 4 or OptiScaler.

## Installation

Do NOT copy libvulkan_radeon.so into system Mesa directories.

Extract:

    tar -xzf bc250-fsr4-test.tar.gz

Enter:

    cd bc250-fsr4-test

Run:

    ./setup.sh

The script generates the Vulkan ICD JSON using the current absolute path.

## Building the driver

`libvulkan_radeon.so` is not shipped here. Build it from the patch against the
Mesa revision in `mesa-commit.txt`:

    ./build-anywhere.sh

A Docker builder image (Fedora 44, with a pristine Mesa checkout at the revision
in `mesa-commit.txt`) is built once, then each run mounts the repo and a build
cache and compiles inside a throwaway container. The result is an x86_64
(`-march=x86-64-v3 -mtune=znver2`) copy of `libvulkan_radeon.so` in the repo
root, targeting the BC-250's Zen 2 cores.

- On an ARM Mac (Apple Silicon) the container runs under QEMU emulation. This is
  slow; start Docker Desktop first.
- On an x86_64 Linux host (for example the BC-250 box itself) it builds natively,
  which is much faster.

The build output and cache live in `.build/` (gitignored), so editing the patch
and re-running `./build-anywhere.sh` only recompiles the affected objects instead of doing
a full clean rebuild. The builder image is persistent; remove it with
`./build-anywhere.sh --clean` if you no longer need it. The Mesa revision is read from
`mesa-commit.txt` on every run, so editing that file and re-running `./build-anywhere.sh`
rebuilds the image against the new revision automatically.

Either way the resulting `libvulkan_radeon.so` must be next to `setup.sh`, then
run `./setup.sh` before use.

## Verify

Run:

    ./run-bc250-fsr4.sh vulkaninfo --summary

You should see:

    AMD BC-250 (RADV GFX1013)
    Mesa 26.1.6

## Steam

After running:

    ./setup.sh

it prints the exact Steam launch option.

Example:

    VK_DRIVER_FILES=/absolute/path/to/bc250-fsr4-test/radv-bc250-fsr4.json %command%

Use the path printed on YOUR machine.

## Cyberpunk 2077 example

1440p:

    VK_DRIVER_FILES=/absolute/path/to/bc250-fsr4-test/radv-bc250-fsr4.json WINEDLLOVERRIDES="version=n,b" gamescope -f -w 2560 -h 1440 -W 2560 -H 1440 -- %command% --launcher-skip

4K:

    VK_DRIVER_FILES=/absolute/path/to/bc250-fsr4-test/radv-bc250-fsr4.json WINEDLLOVERRIDES="version=n,b" gamescope -f -w 3840 -h 2160 -W 3840 -H 2160 -- %command% --launcher-skip

WINEDLLOVERRIDES and Gamescope are not required by the RADV patch itself.

## Returning to normal RADV

Remove VK_DRIVER_FILES from the game launch options.

Your system Mesa installation remains untouched.

## Important warning

Experimental.

Tested specifically on:

    AMD BC-250
    GFX1013
    PCI ID 0x13FE

Do NOT install the included libvulkan_radeon.so system-wide.

Games may crash, display corrupted graphics, hang, or trigger a GPU reset.

## Technical details

The normal Mesa fallback for signed packed 4x8 INT8 dot products expands the operation into signed byte extraction, integer multiplication and addition.

This patch changes the signed fallback to use signed i24 multiplication and a reassociated expression that generates substantially cheaper GFX10 code.

Note: `sdot_4x8_a_b` in `nir_opt_algebraic.py` is a shared helper, so this change applies to every signed 4x8 dot-product software fallback in this build, not only FSR 4 shaders. All such products and sums stay within 24 bits, so the result is identical.

It does NOT enable the native accelerated dot-product capability.

Testing has shown that forcing:

    has_accelerated_dot_product = true

causes ACO to emit:

    v_dot4_i32_i8

on GFX1013.

A controlled runtime test showed that path is incorrect on the BC-250:

    Expected: 70
    Native v_dot4 result: 0

The optimized software fallback correctly returned:

    Expected: 70
    Result:   70

for:

    1*5 + 2*6 + 3*7 + 4*8 = 70

## Files

    libvulkan_radeon.so
        Experimental RADV driver. Not shipped here - built from the patch
        against the Mesa revision in mesa-commit.txt. The ICD JSON only
        works after this binary exists.

    setup.sh
        Creates the Vulkan ICD JSON.

    run-bc250-fsr4.sh
        Runs a program using the packaged driver.

    bc250-fsr4-i24.patch
        Mesa source changes.

    mesa-commit.txt
        Mesa source revision.

    Dockerfile
        Persistent Fedora 44 builder image (deps + pristine Mesa checkout).

    build-anywhere.sh
        Builds the builder image, then runs it against a mounted volume. Run
        this from anywhere (ARM Mac via QEMU, or an x86_64 Linux host) to
        produce libvulkan_radeon.so in the repo root. Accepts `stock`
        and/or `patch` variants as arguments.

    build-bc250.sh
        The real per-variant build inside the builder container (ENTRYPOINT).
        VARIANT=patch (default) applies the patch; VARIANT=stock builds the
        same commit unpatched as libvulkan_radeon-stock.so.

    cts-conformance.sh
        Differential Vulkan CTS harness. Builds both driver variants and
        deqp-vk in Docker, runs the caselist under each on the BC-250 GPU,
        and diffs the verdicts. Run on the BC-250 Linux host.

    Dockerfile.cts
        Image that builds VK-GL-CTS deqp-vk, plus the runtime libs the RADV
        drivers link against.

    cts/caselist-focused.txt
        --deqp-case wildcard groups for the focused conformance run.

    cts/cts-diff.py
        Parses two .qpa logs and classifies per-case changes.

    README.md
        This document.

## Conformance

`./cts-conformance.sh [--focused|--full]` runs a **differential** Khronos Vulkan
CTS comparison to prove the patch broke nothing. It:

1. Builds two RADV drivers in Docker from the exact `mesa-commit.txt`
   revision: the patched build (`libvulkan_radeon.so`) and an unpatched
   "stock" build (`libvulkan_radeon-stock.so`) - the patch is the only
   variable.
2. Builds the VK-GL-CTS `deqp-vk` binary in a separate Docker image.
3. Runs the same caselist twice on the GPU, once per driver (`stock.qpa`,
   `patched.qpa`).
4. Diffs per-case verdicts with `cts/cts-diff.py`.

Only a behavioural difference matters: `REGRESSION` (stock PASS -> patched
non-PASS) blocks with exit 1; `IMPROVEMENT` (stock FAIL -> patched PASS) is
good; `DIFFERENT` (a non-pass verdict changed) is suspicious and exits 2.
The expected result is **zero differences**, since the patch is semantically
a no-op for all inputs.

This **must run on the BC-250 Linux host** - the QEMU/Docker harness used for
building cannot execute CTS because there is no AMD GPU behind it; rendering
conformance needs the real `amdgpu` device. The host therefore needs Docker,
the `amdgpu` kernel module, and a `/dev/dri/renderD*` node (the same setup
that already runs RADV for games). Run sudo/docker as a user with access to
the GPU device if the container reports a DRM permission error.

The default `--focused` caselist (`cts/caselist-focused.txt`) covers the
groups most relevant to an INT8 shader-lowering change - `spirv_assembly`,
`compute`, `shaders`, `pipeline`, `robustness` - and excludes `wsI` tests
(the BC-250 is a compute-only card). `--full` runs all of `dEQP-VK.*`.

Per-driver log outputs land in `.cts-out/` (gitignored).

This verifies spec conformance, not FSR 4 performance or visual output.

## Testing results

Please report:

- GPU frequency
- CPU configuration
- Game
- FSR 4 version
- Resolution
- FSR quality mode
- FPS with normal RADV
- FPS with this driver
- Rendering problems
- Crashes or GPU resets

## Status

Experimental proof-of-concept.

FSR 4.1.1 has been successfully tested in Cyberpunk 2077 on the BC-250 with correct rendering and substantially improved performance.
