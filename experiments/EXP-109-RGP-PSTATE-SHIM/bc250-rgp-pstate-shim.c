#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

/* libdrm public ABI:
 *   int amdgpu_cs_ctx_stable_pstate(amdgpu_context_handle context,
 *                                    uint32_t op, uint32_t flags,
 *                                    uint32_t *out_flags);
 * amdgpu_context_handle is an opaque pointer.  Keep this shim independent of
 * libdrm development headers so it can be built on the BC-250 with plain gcc.
 */
typedef void *amdgpu_context_handle;
typedef int (*stable_pstate_fn)(amdgpu_context_handle, uint32_t, uint32_t, uint32_t *);

enum {
   AMDGPU_CTX_OP_GET_STABLE_PSTATE = 5,
   AMDGPU_CTX_OP_SET_STABLE_PSTATE = 6,
   AMDGPU_CTX_STABLE_PSTATE_NONE = 0,
};

static int
verbose_enabled(void)
{
   const char *v = getenv("BC250_RGP_PSTATE_SHIM_VERBOSE");
   return v && *v && *v != '0';
}

int
amdgpu_cs_ctx_stable_pstate(amdgpu_context_handle context, uint32_t op,
                            uint32_t flags, uint32_t *out_flags)
{
   (void)context;

   /* GFX1013/BC-250 rejects every stable-pstate SET request used by RADV
    * SQTT/RGP initialization.  The pstate is for clock reproducibility, not
    * for programming SQTT itself.  Pretend GET/SET succeeded and report NONE;
    * the user's existing BC-250 governor remains in control of clocks.
    *
    * This library is diagnostic-only and must only be LD_PRELOADed for RGP
    * capture.  It does not modify CODE GOD or system libdrm.
    */
   if (op == AMDGPU_CTX_OP_GET_STABLE_PSTATE) {
      if (out_flags)
         *out_flags = AMDGPU_CTX_STABLE_PSTATE_NONE;
      if (verbose_enabled())
         fprintf(stderr, "bc250-rgp-shim: bypass GET_STABLE_PSTATE -> NONE\n");
      return 0;
   }

   if (op == AMDGPU_CTX_OP_SET_STABLE_PSTATE) {
      if (verbose_enabled())
         fprintf(stderr, "bc250-rgp-shim: bypass SET_STABLE_PSTATE flags=%u\n", flags);
      return 0;
   }

   static stable_pstate_fn real_fn;
   if (!real_fn)
      real_fn = (stable_pstate_fn)dlsym(RTLD_NEXT, "amdgpu_cs_ctx_stable_pstate");

   if (!real_fn) {
      fprintf(stderr, "bc250-rgp-shim: failed to resolve real amdgpu_cs_ctx_stable_pstate\n");
      return -1;
   }

   return real_fn(context, op, flags, out_flags);
}
