#!/usr/bin/env python3
import argparse
import re
from pathlib import Path

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


def find_matching_brace(text: str, open_pos: int) -> int:
    depth = 0
    i = open_pos
    state = "code"
    while i < len(text):
        c = text[i]
        n = text[i + 1] if i + 1 < len(text) else ""
        if state == "code":
            if c == '/' and n == '*':
                state = "block"; i += 2; continue
            if c == '/' and n == '/':
                state = "line"; i += 2; continue
            if c == '"':
                state = "string"; i += 1; continue
            if c == "'":
                state = "char"; i += 1; continue
            if c == '{': depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0:
                    return i
        elif state == "block":
            if c == '*' and n == '/': state = "code"; i += 2; continue
        elif state == "line":
            if c == '\n': state = "code"
        elif state == "string":
            if c == '\\': i += 2; continue
            if c == '"': state = "code"
        elif state == "char":
            if c == '\\': i += 2; continue
            if c == "'": state = "code"
        i += 1
    raise SystemExit("EXP110: unmatched function brace")


def function_span_by_name(text: str, name: str):
    # Function definitions in Mesa are formatted as return type + name(args) + {.
    pat = re.compile(r"(?m)^(?:static\s+)?(?:[A-Za-z_][\w\s\*]*\n)?" + re.escape(name) + r"\s*\([^;]*?\)\s*\{")
    m = pat.search(text)
    if not m:
        # More tolerant fallback: anchor on the function name, then walk to line start.
        nm = re.search(r"\b" + re.escape(name) + r"\s*\([^;]*?\)\s*\{", text, re.S)
        if not nm:
            raise SystemExit(f"EXP110: function not found: {name}")
        start = text.rfind("\n", 0, nm.start()) + 1
        m_start = start
        open_pos = text.find("{", nm.start(), nm.end())
    else:
        m_start = m.start()
        open_pos = text.find("{", m.start(), m.end())
    end = find_matching_brace(text, open_pos) + 1
    return m_start, end, open_pos


def discover_gate(text: str):
    # GOD/SATAN may rename or reshape the gate. Find the C function body that
    # contains both the density pass and the lowering helper call.
    for m in re.finditer(r"(?m)^([A-Za-z_][\w\s\*]*\n)?([A-Za-z_]\w*)\s*\([^;]*?\)\s*\{", text):
        name = m.group(2)
        if name == "bc250_lower_dense_sdot4x8_one":
            continue
        open_pos = text.find("{", m.start(), m.end())
        try:
            end = find_matching_brace(text, open_pos) + 1
        except SystemExit:
            continue
        body = text[open_pos:end]
        if "bc250_count_dot_density" in body and "bc250_lower_dense_sdot4x8_one" in body:
            return m.start(), end, open_pos, name
    raise SystemExit("EXP110: dense-SDOT gate function not found structurally")


def replace_span(text: str, start: int, end: int, replacement: str) -> str:
    # Preserve at most one separating newline.
    if replacement and not replacement.endswith("\n"):
        replacement += "\n"
    return text[:start] + replacement + text[end:]


def gate_signature(text: str, start: int, open_pos: int) -> str:
    return text[start:open_pos].rstrip()


def wide_gate(signature: str, two_chain: str) -> str:
    return f'''{signature}
{{
   struct bc250_dot_density density = {{0}};
   nir_shader_alu_pass(nir, bc250_count_dot_density, nir_metadata_all, &density);

   /* EXP110 wide gate: attack substantial FSR4 signed-dot families together. */
   if (density.sdot < 512)
      return false;

   const bool two_chain = {two_chain};
   return nir_shader_alu_pass(nir, bc250_lower_dense_sdot4x8_one,
                              nir_metadata_control_flow, (void *)&two_chain);
}}
'''


def history_gate(signature: str) -> str:
    return f'''{signature}
{{
   struct bc250_dot_density density = {{0}};
   nir_shader_alu_pass(nir, bc250_count_dot_density, nir_metadata_all, &density);

   /* EXP110 history-aware wide gate. Preserve two earlier full64 danger
    * buckets while broadening into 512, ED7/2048, and >2304 reductions. */
   const bool safe_1088 = density.sdot == 1088;
   const bool safe_1152 = density.sdot == 1152 && density.imul >= 100;
   const bool safe_2304 = density.sdot == 2304 && density.bcsel >= 16;
   const bool add_512 = density.sdot == 512;
   const bool add_2048 = density.sdot == 2048;
   const bool add_large = density.sdot > 2304;

   if (!(safe_1088 || safe_1152 || safe_2304 || add_512 || add_2048 || add_large))
      return false;

   const bool two_chain = safe_1152 || safe_2304 || add_2048 || add_large;
   return nir_shader_alu_pass(nir, bc250_lower_dense_sdot4x8_one,
                              nir_metadata_control_flow, (void *)&two_chain);
}}
'''


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("source", type=Path, help="Mesa source root")
    ap.add_argument("mode", choices=["god-gate-fused", "serial-wide", "dual-wide", "hybrid-wide", "history-wide"])
    args = ap.parse_args()

    path = args.source / "src/amd/vulkan/radv_shader.c"
    text = path.read_text()
    if "EXP110: fuse the original SDot accumulator" in text:
        raise SystemExit("EXP110: source already materialized")

    # Discover the gate BEFORE replacing the helper, so exact GOD/SATAN layout
    # and function naming are preserved rather than assumed from public V3.
    gs, ge, go, gate_name = discover_gate(text)
    gate_sig = gate_signature(text, gs, go)
    hs, he, _ = function_span_by_name(text, "bc250_lower_dense_sdot4x8_one")

    # Replace later span first so offsets for earlier spans remain valid.
    spans = [(hs, he, FUSED_LOWER)]
    if args.mode == "history-wide":
        spans.append((gs, ge, history_gate(gate_sig)))
    elif args.mode != "god-gate-fused":
        if args.mode == "serial-wide": expr = "false"
        elif args.mode == "dual-wide": expr = "true"
        else: expr = "density.sdot >= 1536"
        spans.append((gs, ge, wide_gate(gate_sig, expr)))

    for start, end, repl in sorted(spans, key=lambda x: x[0], reverse=True):
        text = replace_span(text, start, end, repl)

    path.write_text(text)
    print(f"EXP110_MATERIALIZED mode={args.mode} gate={gate_name} file={path}")


if __name__ == "__main__":
    main()
