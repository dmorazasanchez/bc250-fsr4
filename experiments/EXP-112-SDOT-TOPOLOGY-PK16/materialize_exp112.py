#!/usr/bin/env python3
import argparse
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
EXP111 = HERE.parent / "EXP-111-SDWA-MUL-TREE" / "materialize_exp111.py"

CENSUS_SUPPORT = r'''
struct bc250_exp112_topology {
   unsigned total;
   unsigned dd;
   unsigned dc;
   unsigned cd;
   unsigned cc;
   unsigned acc_zero;
   unsigned acc_const;
   unsigned acc_dynamic;
};

static bool
bc250_exp112_count_topology_one(nir_builder *b, nir_alu_instr *alu, void *data)
{
   (void)b;
   struct bc250_exp112_topology *t = data;

   if (alu->op != nir_op_sdot_4x8_iadd)
      return false;

   const bool a_const = nir_src_is_const(alu->src[0].src);
   const bool b_const = nir_src_is_const(alu->src[1].src);
   const bool c_const = nir_src_is_const(alu->src[2].src);

   t->total++;
   if (!a_const && !b_const)
      t->dd++;
   else if (!a_const && b_const)
      t->dc++;
   else if (a_const && !b_const)
      t->cd++;
   else
      t->cc++;

   if (!c_const) {
      t->acc_dynamic++;
   } else if (nir_src_as_uint(alu->src[2].src) == 0) {
      t->acc_zero++;
   } else {
      t->acc_const++;
   }

   return false;
}

static void
bc250_exp112_census(nir_shader *nir, unsigned density_sdot)
{
   const char *enabled = getenv("BC250_EXP112_CENSUS");
   if (!enabled || enabled[0] != '1')
      return;

   struct bc250_exp112_topology t = {0};
   nir_shader_alu_pass(nir, bc250_exp112_count_topology_one,
                       nir_metadata_all, &t);

   fprintf(stderr,
           "EXP112_CENSUS name=%s density_sdot=%u total=%u dd=%u dc=%u cd=%u cc=%u acc_zero=%u acc_const=%u acc_dynamic=%u\\n",
           nir->info.name ? nir->info.name : "<unnamed>", density_sdot,
           t.total, t.dd, t.dc, t.cd, t.cc,
           t.acc_zero, t.acc_const, t.acc_dynamic);
}

'''

LOWER_SUPPORT = r'''
static nir_def *
bc250_exp112_sdwa_tree(nir_builder *b, nir_def *a, nir_def *bv,
                        nir_def *c, bool add_accumulator)
{
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
   nir_def *r = nir_iadd(b, r01, r23);
   return add_accumulator ? nir_iadd(b, r, c) : r;
}

static nir_def *
bc250_exp112_fused_chain(nir_builder *b, nir_def *a, nir_def *bv, nir_def *c)
{
   nir_def *r = c;
   for (unsigned i = 0; i < 4; i++) {
      r = nir_imad24_ir3(b, nir_extract_i8_imm(b, a, i),
                         nir_extract_i8_imm(b, bv, i), r);
   }
   return r;
}

'''

CONST_AWARE_ACO = r'''static bool
bc250_exp112_alu_operand_constant(opt_ctx& ctx, const alu_opt_op& op_info)
{
   const Operand op = op_info.op;
   if (op.isConstant())
      return true;
   if (op.isTemp() && ctx.info[op.tempId()].is_constant())
      return true;
   return false;
}

static bool
bc250_signed_byte_mul24_operands(opt_ctx& ctx, alu_opt_info& info)
{
   if (!ctx.bc250_dense_i24 || info.operands.size() < 2)
      return false;

   const SubdwordSel a = info.operands[0].extract[0];
   const SubdwordSel b = info.operands[1].extract[0];
   const bool a_sbyte = a.size() == 1 && a.sign_extend();
   const bool b_sbyte = b.size() == 1 && b.sign_extend();
   const bool a_const = bc250_exp112_alu_operand_constant(ctx, info.operands[0]);
   const bool b_const = bc250_exp112_alu_operand_constant(ctx, info.operands[1]);

   /* EXP112: preserve the EXP111 DD case and additionally keep a VOP2 MUL24
    * when exactly one side is a signed-byte selector and the other side has
    * become an ACO constant.  This lets SDWA absorb the dynamic byte extract
    * without globally disabling unrelated MUL24->MAD24 contraction. */
   return (a_sbyte && b_sbyte) ||
          (a_sbyte && b_const) ||
          (b_sbyte && a_const);
}

'''


def find_matching_brace(text: str, open_pos: int) -> int:
    depth = 0
    state = "code"
    i = open_pos
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
            if c == '{':
                depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0:
                    return i
        elif state == "block":
            if c == '*' and n == '/':
                state = "code"; i += 2; continue
        elif state == "line":
            if c == '\n':
                state = "code"
        elif state == "string":
            if c == '\\':
                i += 2; continue
            if c == '"':
                state = "code"
        elif state == "char":
            if c == '\\':
                i += 2; continue
            if c == "'":
                state = "code"
        i += 1
    raise SystemExit("EXP112: unmatched brace")


def function_span(text: str, name: str):
    m = re.search(r'\b' + re.escape(name) + r'\s*\([^;]*?\)\s*\{', text, re.S)
    if not m:
        raise SystemExit(f"EXP112: function not found: {name}")
    start = text.rfind('\n', 0, m.start()) + 1
    # Include a preceding standalone `static <type>`/return-type line when Mesa
    # puts the return type on the line above the function name.
    prev = text.rfind('\n', 0, max(0, start - 1)) + 1
    prev_text = text[prev:start].strip()
    if prev_text and ('static' in prev_text or prev_text in {'bool', 'void'} or '*' in prev_text):
        start = prev
    open_pos = text.find('{', m.start(), m.end())
    end = find_matching_brace(text, open_pos) + 1
    while end < len(text) and text[end] in ' \t':
        end += 1
    if end < len(text) and text[end] == '\n':
        end += 1
    return start, end, open_pos


def discover_gate(text: str):
    for m in re.finditer(r'\b([A-Za-z_]\w*)\s*\([^;]*?\)\s*\{', text, re.S):
        name = m.group(1)
        if name == 'bc250_lower_dense_sdot4x8_one':
            continue
        open_pos = text.find('{', m.start(), m.end())
        try:
            end = find_matching_brace(text, open_pos) + 1
        except SystemExit:
            continue
        body = text[open_pos:end]
        if 'bc250_count_dot_density' in body and 'bc250_lower_dense_sdot4x8_one' in body:
            start = text.rfind('\n', 0, m.start()) + 1
            prev = text.rfind('\n', 0, max(0, start - 1)) + 1
            if 'static' in text[prev:start] or text[prev:start].strip() in {'bool', 'void'}:
                start = prev
            return start, end, open_pos, name
    raise SystemExit('EXP112: dense SDOT gate not found')


def ensure_stdio(text: str) -> str:
    additions = []
    if '#include <stdio.h>' not in text:
        additions.append('#include <stdio.h>')
    if '#include <stdlib.h>' not in text:
        additions.append('#include <stdlib.h>')
    if not additions:
        return text
    pos = text.find('#include')
    if pos < 0:
        raise SystemExit('EXP112: no include block found in radv_shader.c')
    return text[:pos] + '\n'.join(additions) + '\n' + text[pos:]


def helper_for(mode: str) -> str:
    if mode == 'const-sdwa':
        const_body = '''
   r = bc250_exp112_sdwa_tree(b, a, bv, c, true);
'''
    elif mode == 'const-fused':
        const_body = '''
   r = bc250_exp112_fused_chain(b, a, bv, c);
'''
    elif mode == 'topology-auto':
        const_body = '''
   const bool acc_zero = nir_src_is_const(alu->src[2].src) &&
                         nir_src_as_uint(alu->src[2].src) == 0;
   r = acc_zero ? bc250_exp112_sdwa_tree(b, a, bv, c, false)
                : bc250_exp112_fused_chain(b, a, bv, c);
'''
    elif mode == 'family-auto':
        const_body = '''
   const bool prefer_fused = data && *(const bool *)data;
   const bool acc_zero = nir_src_is_const(alu->src[2].src) &&
                         nir_src_as_uint(alu->src[2].src) == 0;
   if (acc_zero)
      r = bc250_exp112_sdwa_tree(b, a, bv, c, false);
   else if (prefer_fused)
      r = bc250_exp112_fused_chain(b, a, bv, c);
   else
      r = bc250_exp112_sdwa_tree(b, a, bv, c, true);
'''
    else:
        raise SystemExit(f'EXP112: no helper policy for {mode}')

    return r'''static bool
bc250_lower_dense_sdot4x8_one(nir_builder *b, nir_alu_instr *alu, void *data)
{
   if (alu->op != nir_op_sdot_4x8_iadd)
      return false;

   const bool a_const = nir_src_is_const(alu->src[0].src);
   const bool b_const = nir_src_is_const(alu->src[1].src);

   /* Constant×constant should already be normal NIR constant-fold territory.
    * Do not force it through BC250-specific arithmetic. */
   if (a_const && b_const)
      return false;

   b->cursor = nir_before_instr(&alu->instr);
   nir_def *a = nir_ssa_for_alu_src(b, alu, 0);
   nir_def *bv = nir_ssa_for_alu_src(b, alu, 1);
   nir_def *c = nir_ssa_for_alu_src(b, alu, 2);
   nir_def *r;

   if (!a_const && !b_const) {
      /* EXP111 control path: four independent VOP2-friendly i24 multiplies,
       * balanced reduction, and the original accumulator. */
      r = bc250_exp112_sdwa_tree(b, a, bv, c, true);
   } else {
''' + const_body + r'''   }

   nir_def_replace(&alu->def, r);
   return true;
}

'''


def inject_census_into_gate(text: str, family_auto: bool):
    gs, ge, go, gate_name = discover_gate(text)
    gate = text[gs:ge]

    density_call = re.search(
        r'nir_shader_alu_pass\(nir,\s*bc250_count_dot_density,\s*nir_metadata_all,\s*&density\s*\);',
        gate, re.S)
    if not density_call:
        raise SystemExit('EXP112: density pass call not found inside gate')

    insert_at = density_call.end()
    gate = gate[:insert_at] + '\n   bc250_exp112_census(nir, density.sdot);' + gate[insert_at:]

    if family_auto:
        lower = re.search(
            r'return\s+nir_shader_alu_pass\(nir,\s*bc250_lower_dense_sdot4x8_one,\s*'
            r'nir_metadata_control_flow,\s*NULL\s*\);', gate, re.S)
        if not lower:
            raise SystemExit('EXP112: family-auto lower pass marker not found')
        replacement = '''const bool exp112_prefer_fused_const = density.sdot < 1536;
   return nir_shader_alu_pass(nir, bc250_lower_dense_sdot4x8_one,
                              nir_metadata_control_flow,
                              (void *)&exp112_prefer_fused_const);'''
        gate = gate[:lower.start()] + replacement + gate[lower.end():]

    return text[:gs] + gate + text[ge:], gate_name


def patch_radv(src: Path, mode: str):
    p = src / 'src/amd/vulkan/radv_shader.c'
    text = p.read_text()
    if 'bc250_exp112_topology' in text:
        raise SystemExit('EXP112: radv source already patched')

    text = ensure_stdio(text)

    hs, he, _ = function_span(text, 'bc250_lower_dense_sdot4x8_one')
    support = CENSUS_SUPPORT
    if mode not in ('census', 'sdwa-ref'):
        support += LOWER_SUPPORT
        replacement = helper_for(mode)
        text = text[:hs] + support + replacement + text[he:]
    else:
        text = text[:hs] + support + text[hs:]

    text, gate_name = inject_census_into_gate(text, mode == 'family-auto')
    p.write_text(text)
    return gate_name


def patch_aco_const_guard(src: Path):
    p = src / 'src/amd/compiler/aco_optimizer.cpp'
    text = p.read_text()
    if 'bc250_exp112_alu_operand_constant' in text:
        return
    if 'bc250_signed_byte_mul24_operands' not in text:
        raise SystemExit('EXP112: EXP111 surgical ACO guard not present')
    s, e, _ = function_span(text, 'bc250_signed_byte_mul24_operands')
    text = text[:s] + CONST_AWARE_ACO + text[e:]
    p.write_text(text)


def run_exp111(src: Path):
    if not EXP111.is_file():
        raise SystemExit(f'EXP112: missing EXP111 materializer: {EXP111}')
    subprocess.run([
        sys.executable, str(EXP111), str(src), 'surgical-history',
        '--dense-threshold', '1024'
    ], check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('source', type=Path)
    ap.add_argument('mode', choices=[
        'census', 'sdwa-ref', 'const-sdwa', 'const-fused',
        'topology-auto', 'family-auto'
    ])
    args = ap.parse_args()

    src = args.source.resolve()
    required = src / 'src/amd/vulkan/radv_shader.c'
    if not required.is_file():
        raise SystemExit(f'EXP112: Mesa source root invalid: {src}')

    # Every FPS candidate starts from the same EXP111 surgical-history control.
    # `census` alone intentionally leaves frozen GOD arithmetic untouched.
    if args.mode != 'census':
        run_exp111(src)

    gate = patch_radv(src, args.mode)

    if args.mode in ('const-sdwa', 'topology-auto', 'family-auto'):
        patch_aco_const_guard(src)

    print(f'EXP112_MATERIALIZED mode={args.mode} gate={gate} source={src}')


if __name__ == '__main__':
    main()
