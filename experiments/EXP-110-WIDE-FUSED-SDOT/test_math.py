#!/usr/bin/env python3
"""Validate EXP110 SDOT/MAD24 reassociation modulo i32.

This is a source-math guard, not a performance test. It checks edge cases plus
large deterministic random coverage for both serial and dual forms.
"""
import random

MASK = 0xffffffff


def u32(x):
    return x & MASK


def i8(x):
    x &= 0xff
    return x - 256 if x & 0x80 else x


def ref(a, b, c):
    return u32(c + sum(i8(a >> (8*i)) * i8(b >> (8*i)) for i in range(4)))


def serial(a, b, c):
    r = u32(c)
    for i in range(4):
        r = u32(r + i8(a >> (8*i)) * i8(b >> (8*i)))
    return r


def dual(a, b, c):
    r01 = u32(c + i8(a) * i8(b))
    r01 = u32(r01 + i8(a >> 8) * i8(b >> 8))
    r23 = u32(i8(a >> 16) * i8(b >> 16))
    r23 = u32(r23 + i8(a >> 24) * i8(b >> 24))
    return u32(r01 + r23)


def check(a, b, c):
    r = ref(a, b, c)
    s = serial(a, b, c)
    d = dual(a, b, c)
    if r != s or r != d:
        raise AssertionError(f"mismatch a={a:#010x} b={b:#010x} c={c:#010x} ref={r:#010x} serial={s:#010x} dual={d:#010x}")


def main():
    edge_bytes = (0x00, 0x01, 0x7f, 0x80, 0x81, 0xff)
    cs = (0, 1, 0x7fffffff, 0x80000000, 0xffffffff, 0x12345678)

    # Structured packed-byte extremes.
    vals = []
    for x in edge_bytes:
        vals.append(x * 0x01010101)
    vals += [0x807f01ff, 0xff01807f, 0x7f80ff01, 0x538453d8, 0xa9728948]
    for a in vals:
        for b in vals:
            for c in cs:
                check(a, b, c)

    rng = random.Random(0xBC250110)
    for _ in range(1_000_000):
        check(rng.getrandbits(32), rng.getrandbits(32), rng.getrandbits(32))

    print("EXP110_MATH_EXACT cases=1000000+structured serial=PASS dual=PASS")


if __name__ == "__main__":
    main()
