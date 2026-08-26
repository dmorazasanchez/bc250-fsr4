#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Diagnostic-only BC-250 RGP pstate bypass.
 *
 * First try the public libdrm-amdgpu ABI.  Some libdrm builds bind that symbol
 * internally, so also interpose the next layer down: drmCommandWriteRead().
 * For DRM_AMDGPU_CTX (command index 0x02), fake success only for stable-pstate
 * GET/SET ops 5/6.  All other DRM commands are forwarded unchanged.
 */
typedef void *amdgpu_context_handle;
typedef int (*stable_pstate_fn)(amdgpu_context_handle, uint32_t, uint32_t, uint32_t *);
typedef int (*drm_cmd_wr_fn)(int, unsigned long, void *, unsigned long);

enum {
   DRM_AMDGPU_CTX = 0x02,
   AMDGPU_CTX_OP_GET_STABLE_PSTATE = 5,
   AMDGPU_CTX_OP_SET_STABLE_PSTATE = 6,
   AMDGPU_CTX_STABLE_PSTATE_NONE = 0,
};

struct drm_amdgpu_ctx_in_compat {
   uint32_t op;
   uint32_t flags;
   uint32_t ctx_id;
   int32_t priority;
};

union drm_amdgpu_ctx_out_compat {
   struct {
      uint32_t ctx_id;
      uint32_t pad;
   } alloc;
   struct {
      uint64_t flags;
      uint32_t hangs;
      uint32_t reset_status;
   } state;
   struct {
      uint32_t flags;
      uint32_t pad;
   } pstate;
};

union drm_amdgpu_ctx_compat {
   struct drm_amdgpu_ctx_in_compat in;
   union drm_amdgpu_ctx_out_compat out;
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

   if (op == AMDGPU_CTX_OP_GET_STABLE_PSTATE) {
      if (out_flags)
         *out_flags = AMDGPU_CTX_STABLE_PSTATE_NONE;
      if (verbose_enabled())
         fprintf(stderr, "bc250-rgp-shim: ABI bypass GET_STABLE_PSTATE -> NONE\n");
      return 0;
   }

   if (op == AMDGPU_CTX_OP_SET_STABLE_PSTATE) {
      if (verbose_enabled())
         fprintf(stderr, "bc250-rgp-shim: ABI bypass SET_STABLE_PSTATE flags=%u\n", flags);
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

int
drmCommandWriteRead(int fd, unsigned long drmCommandIndex, void *data, unsigned long size)
{
   if (drmCommandIndex == DRM_AMDGPU_CTX && data && size >= sizeof(union drm_amdgpu_ctx_compat)) {
      union drm_amdgpu_ctx_compat *ctx = (union drm_amdgpu_ctx_compat *)data;

      if (ctx->in.op == AMDGPU_CTX_OP_GET_STABLE_PSTATE) {
         memset(&ctx->out, 0, sizeof(ctx->out));
         ctx->out.pstate.flags = AMDGPU_CTX_STABLE_PSTATE_NONE;
         if (verbose_enabled())
            fprintf(stderr, "bc250-rgp-shim: DRM bypass GET_STABLE_PSTATE ctx=%u -> NONE\n",
                    ctx->in.ctx_id);
         return 0;
      }

      if (ctx->in.op == AMDGPU_CTX_OP_SET_STABLE_PSTATE) {
         if (verbose_enabled())
            fprintf(stderr, "bc250-rgp-shim: DRM bypass SET_STABLE_PSTATE ctx=%u flags=%u\n",
                    ctx->in.ctx_id, ctx->in.flags);
         return 0;
      }
   }

   static drm_cmd_wr_fn real_fn;
   if (!real_fn)
      real_fn = (drm_cmd_wr_fn)dlsym(RTLD_NEXT, "drmCommandWriteRead");

   if (!real_fn) {
      fprintf(stderr, "bc250-rgp-shim: failed to resolve real drmCommandWriteRead\n");
      return -1;
   }

   return real_fn(fd, drmCommandIndex, data, size);
}
