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

    VK_DRIVER_FILES=/absolute/path/to/radv-bc250-fsr4.json WINEDLLOVERRIDES="version=n,b" gamescope -f -w 2560 -h 1440 -W 2560 -H 1440 -- %command% --launcher-skip

4K:

    VK_DRIVER_FILES=/absolute/path/to/radv-bc250-fsr4.json WINEDLLOVERRIDES="version=n,b" gamescope -f -w 3840 -h 2160 -W 3840 -H 2160 -- %command% --launcher-skip

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
        Experimental RADV driver.

    setup.sh
        Creates the Vulkan ICD JSON.

    run-bc250-fsr4.sh
        Runs a program using the packaged driver.

    bc250-fsr4-i24.patch
        Mesa source changes.

    mesa-commit.txt
        Mesa source revision.

    README.md
        This document.

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
