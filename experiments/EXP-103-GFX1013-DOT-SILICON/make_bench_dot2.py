#!/usr/bin/env python3
from pathlib import Path
import sys

src = Path(sys.argv[1])
out = Path(sys.argv[2])
s = src.read_text()


def one(old: str, new: str) -> None:
    global s
    n = s.count(old)
    if n != 1:
        raise SystemExit(f"expected exactly one benchmark source match, got {n}: {old[:80]!r}")
    s = s.replace(old, new, 1)


one(
'''static uint32_t rep(uint32_t x)
{
    uint32_t b = x & 255;
    return b | (b << 8) | (b << 16) | (b << 24);
}
''',
'''static uint32_t dot_one2(uint32_t a, uint32_t b, int as_signed, int bs_signed)
{
    int64_t s = 0;
    for (int i = 0; i < 2; i++) {
        int64_t av = as_signed ? (int16_t)((a >> (16 * i)) & 0xffff) : (uint16_t)((a >> (16 * i)) & 0xffff);
        int64_t bv = bs_signed ? (int16_t)((b >> (16 * i)) & 0xffff) : (uint16_t)((b >> (16 * i)) & 0xffff);
        s += av * bv;
    }
    return (uint32_t)s;
}

static uint32_t rep(uint32_t x)
{
    uint32_t b = x & 255;
    return b | (b << 8) | (b << 16) | (b << 24);
}

static uint32_t rep16(uint32_t x)
{
    uint32_t h = x & 65535u;
    return h | (h << 16);
}
''')

one(
'''    int as_signed = 1, bs_signed = 1;
    if (!strcmp(kind, "udot")) {
        as_signed = 0;
        bs_signed = 0;
    } else if (!strcmp(kind, "sudot")) {
        bs_signed = 0;
    }
''',
'''    int as_signed = 1, bs_signed = 1;
    const int dot2 = !strcmp(kind, "sdot2") || !strcmp(kind, "udot2");
    if (!strcmp(kind, "udot") || !strcmp(kind, "udot2")) {
        as_signed = 0;
        bs_signed = 0;
    } else if (!strcmp(kind, "sudot")) {
        bs_signed = 0;
    }
''')

one(
'''        uint32_t m = rep(i);
        for (int k = 0; k < UNROLL; k++)
            acc += dot_one(pa[k] ^ m, pb[k], as_signed, bs_signed);
''',
'''        uint32_t m = dot2 ? rep16(i) : rep(i);
        for (int k = 0; k < UNROLL; k++)
            acc += dot2 ? dot_one2(pa[k] ^ m, pb[k], as_signed, bs_signed)
                        : dot_one(pa[k] ^ m, pb[k], as_signed, bs_signed);
''')

one(
'''        fprintf(stderr, "usage: %s kernel.spv sdot|udot|sudot [ITER] [UNROLL] [fast]\\n", argv[0]);
''',
'''        fprintf(stderr, "usage: %s kernel.spv sdot|udot|sudot|sdot2|udot2 [ITER] [UNROLL] [fast]\\n", argv[0]);
''')

one(
'''    const char *kind = argv[2];
    if (strcmp(kind, "sdot") && strcmp(kind, "udot") && strcmp(kind, "sudot")) {
        fprintf(stderr, "invalid kernel kind: %s\\n", kind);
        return 2;
    }
''',
'''    const char *kind = argv[2];
    const int is_dot2 = !strcmp(kind, "sdot2") || !strcmp(kind, "udot2");
    if (strcmp(kind, "sdot") && strcmp(kind, "udot") && strcmp(kind, "sudot") &&
        strcmp(kind, "sdot2") && strcmp(kind, "udot2")) {
        fprintf(stderr, "invalid kernel kind: %s\\n", kind);
        return 2;
    }
''')

one(
'''    if (!dot_support.shaderIntegerDotProduct) {
        fprintf(stderr, "shaderIntegerDotProduct is not supported\\n");
        return 1;
    }
''',
'''    if (!dot_support.shaderIntegerDotProduct) {
        fprintf(stderr, "shaderIntegerDotProduct is not supported\\n");
        return 1;
    }
    if (is_dot2 && !features2.features.shaderInt16) {
        fprintf(stderr, "shaderInt16 is not supported\\n");
        return 1;
    }
''')

one(
'''    VkPhysicalDeviceShaderIntegerDotProductFeatures dot_enable = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_INTEGER_DOT_PRODUCT_FEATURES,
        .shaderIntegerDotProduct = VK_TRUE,
    };
    VkDeviceCreateInfo dci = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = &dot_enable,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &qci,
    };
''',
'''    VkPhysicalDeviceShaderIntegerDotProductFeatures dot_enable = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_INTEGER_DOT_PRODUCT_FEATURES,
        .shaderIntegerDotProduct = VK_TRUE,
    };
    VkPhysicalDeviceFeatures core_enable = {0};
    if (is_dot2)
        core_enable.shaderInt16 = VK_TRUE;
    VkDeviceCreateInfo dci = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = &dot_enable,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &qci,
        .pEnabledFeatures = &core_enable,
    };
''')

out.write_text(s)
print(f"Wrote DOT2 benchmark: {out}")
