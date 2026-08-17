FROM --platform=linux/amd64 fedora:44

RUN dnf install -y --setopt=install_weak_deps=False \
    gcc gcc-c++ make meson ninja-build pkgconf-pkg-config git flex bison byacc \
    python3 python3-mako python3-packaging python3-PyYAML python3-setuptools \
    libdrm-devel elfutils-libelf-devel zlib-devel libzstd-devel \
    libX11-devel libXext-devel libxcb-devel libxshmfence-devel \
    libXrandr-devel libXxf86vm-devel wayland-devel wayland-protocols-devel \
    libva-devel libdisplay-info-devel libunwind-devel lm_sensors-devel \
    llvm-devel libclc-devel glslang spirv-tools \
  && dnf clean all

ARG MESA_COMMIT
RUN git init /opt/mesa \
  && cd /opt/mesa \
  && git remote add origin https://gitlab.freedesktop.org/mesa/mesa.git \
  && git fetch --depth 1 origin "$MESA_COMMIT" \
  && git checkout FETCH_HEAD

ENTRYPOINT ["/bin/bash", "/workspace/build-bc250.sh"]
