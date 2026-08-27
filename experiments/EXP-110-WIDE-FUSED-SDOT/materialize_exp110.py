#!/usr/bin/env python3
import argparse
from pathlib import Path

LOWER_ONE_START = "static bool\nbc250_lower_dense_sdot4x8_one("
LOWER_GATE_START = "static bool\nbc250_lower_dense_sdot4x8(nir_shader *nir)"
OPTIMIZE_START = "\nvoid\nradv_optimize_nir("

FUSED_LOWER = r'''static bool
bc250_lower_dense_sdot4x8_one(nir_builder *b, nir_alu_instr *alu, void *data)
{
   const bool two_chain = data && *(const bool *)data;

   if (alu->op != nir_op_sdot_4x8_iadd)
      return false;

   if (nir_src_is_const(alu->src[0].src) || nir_src_is_const(alu->src[1].src))
      return false;

   b->cursor = nir_before_instr(&alu->instr);

   nir_def *a = nir_ssa_for_alu_src(b, alu, 0);
   nir_def *bv = nir_ssa_for_alu_src(b, alu, 1);
   nir_def *c = nir_ssa_for_alu_src(b, alu, 2);
   nir_def *r;

   /* EXP110: fuse the original SDot accumulator directly into MAD24.
    * This is exactly equivalent modulo 2^32 because each extracted i8
    * multiplicand is a signed integer in [-128,127], well inside i24.
    *
    * Old one-chain shape: MUL + MAD + MAD + MAD + ADD(c) = 5 ALU.
    * New serial shape:    MAD(c) + MAD + MAD + MAD          = 4 ALU.
    *
    * Old two-chain shape: 2 MUL + 2 MAD + 2 ADD            = 6 ALU.
    * New dual shape:      MUL + 3 MAD + ADD                = 5 ALU.
    */
   if (two_chain) {
      nir_def *r01 = nir_imad24_ir3(b, nir_extract_i8_imm(b, a, 0),
                                     nir_extract_i8_imm(b, bv, 0), c);
      r01 = nir_imad24_ir3(b, nir_extract_i8_imm(b, a, 1),
                           nir_extract_i8_imm(b, bv, 1), r01);

      nir_def *r23 = nir_build_alu2(b, nir_op_imul24_relaxed,
                                    nir_extract_i8_imm(b, a, 2),
                                    nir_extract_i8_imm(b, bv, 2));
      r23 = nir_imad24_ir3(b, nir_extract_i8_imm(b, a, 3),
                           nir_extract_i8_imm(b, bv, 3), r23);
      r = nir_iadd(b, r01, r23);
   } else {
      r = c;
      for (unsigned i = 0; i < 4; i++) {
         r = nir_imad24_ir3(b, nir_extract_i8_imm(b, a, i),
                            nir_extract_i8_imm(b, bv, i), r);
      }
   }

   nir_def_replace(&alu->def, r);
   return true;
}

'''

WIDE_GATE_TEMPLATE = r'''static bool
bc250_lower_dense_sdot4x8(nir_shader *nir)
{{
   struct bc250_dot_density density = {{0}};
   nir_shader_alu_pass(nir, bc250_count_dot_density, nir_metadata_all, &density);

   /* EXP110 wide gate.  The original tiny kernels stay on GOD's deferred
    * software fallback.  FSR4's substantial INT8 families start at 512
    * packed signed dots in the audited corpus, including 512/1088/1152,
    * ED7's 2048 family, 2304, and the larger 4K+ reductions.
    *
    * This is deliberately a campaign candidate, not a production claim:
    * full-corpus zero-spill/occupancy audit and Cyberpunk A/B decide whether
    * a wide family is retained in the final hybrid.
    */
   if (density.sdot < 512)
      return false;

   const bool two_chain = {two_chain};
   return nir_shader_alu_pass(nir, bc250_lower_dense_sdot4x8_one,
                              nir_metadata_control_flow, (void *)&two_chain);
}}

'''


def replace_between(text: str, start: str, end: str, replacement: str) -> str:
    i = text.find(start)
    if i < 0:
        raise SystemExit(f"EXP110: start marker not found: {start!r}")
    j = text.find(end, i)
    if j < 0:
        raise SystemExit(f"EXP110: end marker not found: {end!r}")
    return text[:i] + replacement + text[j:]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("source", type=Path, help="Mesa source root")
    ap.add_argument("mode", choices=["god-gate-fused", "serial-wide", "dual-wide", "hybrid-wide"])
    args = ap.parse_args()

    path = args.source / "src/amd/vulkan/radv_shader.c"
    text = path.read_text()

    if "EXP110: fuse the original SDot accumulator" in text:
        raise SystemExit("EXP110: source already materialized")

    # Preserve every GOD change outside the one SDot lowering helper.
    text = replace_between(text, LOWER_ONE_START, LOWER_GATE_START, FUSED_LOWER)

    if args.mode != "god-gate-fused":
        if args.mode == "serial-wide":
            expr = "false"
        elif args.mode == "dual-wide":
            expr = "true"
        else:
            # Low/medium reductions get the minimum-instruction serial chain.
            # Large reductions use the shorter-lifetime dual chain to defend
            # occupancy and expose independent MAD work to ACO.
            expr = "density.sdot >= 1536"

        wide = WIDE_GATE_TEMPLATE.format(two_chain=expr)
        text = replace_between(text, LOWER_GATE_START, OPTIMIZE_START, wide)

    path.write_text(text)
    print(f"EXP110_MATERIALIZED mode={args.mode} file={path}")


if __name__ == "__main__":
    main()
