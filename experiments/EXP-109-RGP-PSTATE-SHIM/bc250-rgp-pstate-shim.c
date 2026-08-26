#define _GNU_SOURCE
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <unistd.h>

/* EXP109 v3: intercept the actual libc ioctl boundary.
 *
 * libdrm-amdgpu may bind its own wrappers internally, so LD_PRELOAD of
 * amdgpu_cs_ctx_stable_pstate() or drmCommandWriteRead() is not reliable.
 * Every DRM request ultimately crosses ioctl(2), which is the stable boundary.
 *
 * We short-circuit only the AMDGPU context ioctl (DRM command index 0x02),
 * and only AMDGPU_CTX_OP_GET/SET_STABLE_PSTATE (ops 5/6). All other ioctls
 * are forwarded directly to the real kernel syscall.
 */

enum {
   DRM_COMMAND_BASE_LOCAL = 0x40,
   DRM_AMDGPU_CTX_LOCAL = 0x02,
   AMDGPU_CTX_OP_GET_STABLE_PSTATE_LOCAL = 5,
   AMDGPU_CTX_OP_SET_STABLE_PSTATE_LOCAL = 6,
   AMDGPU_CTX_STABLE_PSTATE_NONE_LOCAL = 0,
};

struct drm_amdgpu_ctx_in_local {
   uint32_t op;
   uint32_t flags;
   uint32_t ctx_id;
   int32_t priority;
};

union drm_amdgpu_ctx_out_local {
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

union drm_amdgpu_ctx_local {
   struct drm_amdgpu_ctx_in_local in;
   union drm_amdgpu_ctx_out_local out;
};

_Static_assert(sizeof(union drm_amdgpu_ctx_local) == 16,
               "unexpected drm_amdgpu_ctx ABI size");

static int
verbose_enabled(void)
{
   const char *v = getenv("BC250_RGP_PSTATE_SHIM_VERBOSE");
   return v && *v && *v != '0';
}

int
ioctl(int fd, unsigned long request, ...)
{
   va_list ap;
   void *arg;

   va_start(ap, request);
   arg = va_arg(ap, void *);
   va_end(ap);

   /* drmCommandWriteRead(DRM_AMDGPU_CTX, ...) builds an _IOWR request with:
    *   type = 'd'
    *   nr   = DRM_COMMAND_BASE + DRM_AMDGPU_CTX = 0x42
    *   size = sizeof(union drm_amdgpu_ctx) = 16
    */
   if (arg && _IOC_TYPE(request) == 'd' &&
       _IOC_NR(request) == DRM_COMMAND_BASE_LOCAL + DRM_AMDGPU_CTX_LOCAL &&
       _IOC_SIZE(request) == sizeof(union drm_amdgpu_ctx_local)) {
      union drm_amdgpu_ctx_local *ctx = arg;
      const uint32_t op = ctx->in.op;

      if (op == AMDGPU_CTX_OP_GET_STABLE_PSTATE_LOCAL) {
         const uint32_t ctx_id = ctx->in.ctx_id;
         ctx->out.pstate.flags = AMDGPU_CTX_STABLE_PSTATE_NONE_LOCAL;
         ctx->out.pstate.pad = 0;
         if (verbose_enabled())
            fprintf(stderr,
                    "bc250-rgp-shim: ioctl bypass GET_STABLE_PSTATE ctx=%u -> NONE\n",
                    ctx_id);
         return 0;
      }

      if (op == AMDGPU_CTX_OP_SET_STABLE_PSTATE_LOCAL) {
         if (verbose_enabled())
            fprintf(stderr,
                    "bc250-rgp-shim: ioctl bypass SET_STABLE_PSTATE ctx=%u flags=%u\n",
                    ctx->in.ctx_id, ctx->in.flags);
         return 0;
      }
   }

   /* Bypass libc symbol lookup entirely for the forwarding path. This avoids
    * recursion and works even when libdrm hides/binds its helper symbols.
    */
   return (int)syscall(SYS_ioctl, fd, request, arg);
}
