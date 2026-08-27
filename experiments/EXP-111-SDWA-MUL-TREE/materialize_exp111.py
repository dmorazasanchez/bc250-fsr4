#!/usr/bin/env python3
import argparse
import re
from pathlib import Path

BALANCED_HELPER = r'''static bool
bc250_lower_dense_sdot4x8_one(nir_builder *b, nir_alu_instr *alu, void *data)
{
   (void)data;

   if (alu->op != nir_op_sdot_4x8_iadd)
      return false;

   if (nir_src_is_const(alu->src[0].src) || nir_src_is_const(alu->src[1].src))
      return false;

   b->cursor = nir_before_instr(&alu->instr);

   nir_def *a = nir_ssa_for_alu_src(b, alu, 0);
   nir_def *bv = nir_ssa_for_alu_src(b, alu, 1);
   nir_def *c = nir_ssa_for_alu_src(b, alu, 2);

   nir_def *p0 = nir_build_alu2(b, nir_op_imul24_relaxed,
                                nir_extract_i8_imm(b, a, 0),
                                nir_extract_i8_imm(b, bv, 0));
   nir_def *p1 = nir_build_alu2(b, nir_op_imul24_relaxed,
                                nir_extract_i8_imm(b, a, 1),
                                nir_extract_i8_imm(b, bv, 1));
   nir_def *p2 = nir_build_alu2(b, nir_op_imul24_relaxed,
                                nir_extract_i8_imm(b, a, 2),
                                nir_extract_i8_imm(b, bv, 2));
   nir_def *p3 = nir_build_alu2(b, nir_op_imul24_relaxed,
                                nir_extract_i8_imm(b, a, 3),
                                nir_extract_i8_imm(b, bv, 3));

   nir_def *r01 = nir_iadd(b, p0, p1);
   nir_def *r23 = nir_iadd(b, p2, p3);
   nir_def *r = nir_iadd(b, nir_iadd(b, r01, r23), c);

   nir_def_replace(&alu->def, r);
   return true;
}

'''

WIDE_BODY = r'''
   struct bc250_dot_density density = {0};
   nir_shader_alu_pass(nir, bc250_count_dot_density, nir_metadata_all, &density);

   if (density.sdot < 512)
      return false;

   return nir_shader_alu_pass(nir, bc250_lower_dense_sdot4x8_one,
                              nir_metadata_control_flow, NULL);
'''

HISTORY_BODY = r'''
   struct bc250_dot_density density = {0};
   nir_shader_alu_pass(nir, bc250_count_dot_density, nir_metadata_all, &density);

   const bool safe_1088 = density.sdot == 1088;
   const bool safe_1152 = density.sdot == 1152 && density.imul >= 100;
   const bool safe_2304 = density.sdot == 2304 && density.bcsel >= 16;
   const bool add_512 = density.sdot == 512;
   const bool add_2048 = density.sdot == 2048;
   const bool add_large = density.sdot > 2304;

   if (!(safe_1088 || safe_1152 || safe_2304 || add_512 || add_2048 || add_large))
      return false;

   return nir_shader_alu_pass(nir, bc250_lower_dense_sdot4x8_one,
                              nir_metadata_control_flow, NULL);
'''


def find_function(text: str, name: str):
    m = re.search(r'(^|\n)(?:static\s+)?[\w\s\*]+\b' + re.escape(name) + r'\s*\([^;]*?\)\s*\{', text, re.M | re.S)
    if not m:
        raise SystemExit(f"EXP111: function not found: {name}")
    start = m.start() + (1 if text[m.start():m.start()+1] == '\n' else 0)
    brace = text.find('{', m.start())
    depth = 0
    i = brace
    in_str = None
    esc = False
    line_comment = False
    block_comment = False
    while i < len(text):
        ch = text[i]
        nx = text[i+1] if i + 1 < len(text) else ''
        if line_comment:
            if ch == '\n': line_comment = False
        elif block_comment:
            if ch == '*' and nx == '/': block_comment = False; i += 1
        elif in_str:
            if esc: esc = False
            elif ch == '\\': esc = True
            elif ch == in_str: in_str = None
        else:
            if ch == '/' and nx == '/': line_comment = True; i += 1
            elif ch == '/' and nx == '*': block_comment = True; i += 1
            elif ch in ('"', "'"): in_str = ch
            elif ch == '{': depth += 1
            elif ch == '}':
                depth -= 1
                if depth == 0:
                    end = i + 1
                    while end < len(text) and text[end] in ' \t': end += 1
                    if end < len(text) and text[end] == '\n': end += 1
                    return start, brace, i, end
        i += 1
    raise SystemExit(f"EXP111: unterminated function: {name}")


def discover_gate(text: str):
    try:
        return 'bc250_lower_dense_sdot4x8', find_function(text, 'bc250_lower_dense_sdot4x8')
    except SystemExit:
        pass
    for m in re.finditer(r'\b(static\s+)?bool\s+(bc250_[A-Za-z0-9_]+)\s*\(', text):
        name = m.group(2)
        try:
            s, ob, cb, e = find_function(text, name)
        except SystemExit:
            continue
        body = text[ob+1:cb]
        if 'bc250_count_dot_density' in body and 'bc250_lower_dense_sdot4x8_one' in body:
            return name, (s, ob, cb, e)
    raise SystemExit('EXP111: could not discover GOD dense-SDOT gate')


def replace_body_preserve_signature(text: str, span, new_body: str):
    s, ob, cb, e = span
    # Preserve the exact GOD declaration/signature and closing/trailing text.
    # This is critical because GOD/SATAN currently passes an additional
    # force_dense_unroll argument while public V3 does not.
    replacement = text[s:ob+1] + new_body + text[cb:e]
    return text[:s] + replacement + text[e:]


def patch_radv(src: Path, mode: str):
    p = src / 'src/amd/vulkan/radv_shader.c'
    t = p.read_text()
    hs, hob, hcb, he = find_function(t, 'bc250_lower_dense_sdot4x8_one')
    t = t[:hs] + BALANCED_HELPER + t[he:]

    gate_name, gate_span = discover_gate(t)
    if mode == 'history-wide':
        t = replace_body_preserve_signature(t, gate_span, HISTORY_BODY)
    elif mode == 'wide':
        t = replace_body_preserve_signature(t, gate_span, WIDE_BODY)
    # god-gate intentionally preserves GOD's exact gate declaration AND body.

    p.write_text(t)
    return gate_name


def ensure_family_plumbing(src: Path):
    irh = src / 'src/amd/compiler/aco_ir.h'
    t = irh.read_text()
    if 'enum radeon_family family;' not in t:
        marker = '   enum amd_gfx_level gfx_level;\n'
        if marker not in t:
            raise SystemExit('EXP111: aco_ir.h gfx_level marker not found')
        t = t.replace(marker, marker + '   enum radeon_family family;\n', 1)
        irh.write_text(t)

    ircpp = src / 'src/amd/compiler/aco_ir.cpp'
    t = ircpp.read_text()
    if 'program->family = options->family;' not in t:
        marker = '   program->gfx_level = options->gfx_level;\n'
        if marker not in t:
            raise SystemExit('EXP111: aco_ir.cpp gfx_level init marker not found')
        t = t.replace(marker, marker + '   program->family = options->family;\n', 1)
        ircpp.write_text(t)


def patch_aco(src: Path, dense_threshold: int):
    p = src / 'src/amd/compiler/aco_optimizer.cpp'
    t = p.read_text()
    if 'bc250_dense_i24' in t:
        raise SystemExit('EXP111: ACO source already patched')

    struct_old = 'struct opt_ctx {\n   Program* program;'
    struct_new = 'struct opt_ctx {\n   Program* program;\n   bool bc250_dense_i24 = false;'
    if struct_old not in t:
        raise SystemExit('EXP111: opt_ctx marker not found')
    t = t.replace(struct_old, struct_new, 1)

    init_old = '   ctx.program = program;\n   ctx.info = std::vector<ssa_info>(program->peekAllocationId());'
    init_new = f'''   ctx.program = program;

   if (program->family == CHIP_GFX1013 && program->stage == compute_cs) {{
      unsigned bc250_i24_mul_count = 0;
      for (Block& block : program->blocks) {{
         for (aco_ptr<Instruction>& instr : block.instructions) {{
            if (instr->opcode == aco_opcode::v_mul_i32_i24)
               bc250_i24_mul_count++;
         }}
      }}
      ctx.bc250_dense_i24 = bc250_i24_mul_count >= {dense_threshold};
   }}

   ctx.info = std::vector<ssa_info>(program->peekAllocationId());'''
    if init_old not in t:
        raise SystemExit('EXP111: optimize() init marker not found')
    t = t.replace(init_old, init_new, 1)

    fuse_old = '      add_opt(v_mul_i32_i24, v_mad_i32_i24, 0x3, "120", pop_def_cb);'
    fuse_new = '''      if (!ctx.bc250_dense_i24) {
         add_opt(v_mul_i32_i24, v_mad_i32_i24, 0x3, "120", pop_def_cb);
      }'''
    if fuse_old not in t:
        raise SystemExit('EXP111: mul24->mad24 optimizer marker not found')
    t = t.replace(fuse_old, fuse_new, 1)

    p.write_text(t)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('source', type=Path)
    ap.add_argument('mode', choices=['god-gate', 'history-wide', 'wide'])
    ap.add_argument('--dense-threshold', type=int, default=1024)
    a = ap.parse_args()
    gate = patch_radv(a.source, a.mode)
    ensure_family_plumbing(a.source)
    patch_aco(a.source, a.dense_threshold)
    print(f'EXP111_MATERIALIZED mode={a.mode} gate={gate} dense_threshold={a.dense_threshold}')

if __name__ == '__main__':
    main()
