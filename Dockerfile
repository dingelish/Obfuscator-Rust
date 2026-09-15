# syntax=docker/dockerfile:1

FROM ubuntu:24.04 as base

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

# Common dependencies for building
RUN apt-get update -y && \
    apt-get install --no-install-recommends -y \
    build-essential \
    cmake \
    ninja-build \
    libc6-dev \
    git \
    gcc \
    g++ \
    clang \
    perl \
    bison \
    flex \
    gperf \
    zlib1g-dev \
    libzstd-dev \
    liblzma-dev \
    libtinfo-dev \
    libxml2-dev \
    libedit-dev \
    xz-utils \
    file \
    python3 \
    gcc-mingw-w64-x86-64 \
    g++-mingw-w64-x86-64 \
    ca-certificates \
    curl \
    pkg-config \
    libstdc++6 \
    libssl-dev \
    protobuf-compiler \
    ccache && \
    rm -rf /var/lib/apt/lists/*

# Optimize CMake to use ccache
ENV CCACHE_DIR=/cache/ccache
ENV CCACHE_MAXSIZE=10G
# Use ccache by default for CMake
ENV CMAKE_C_COMPILER_LAUNCHER=ccache
ENV CMAKE_CXX_COMPILER_LAUNCHER=ccache

FROM base as builder-llvm

WORKDIR /repos

# patches
COPY ollvm22.patch /repos/ollvm22.patch

# Clone LLVM
RUN git clone --single-branch --branch rustc/22.1-2026-05-19 --depth 1 https://github.com/rust-lang/llvm-project /repos/llvm-22 && \
    cd /repos/llvm-22/ && \
    git apply --reject --ignore-whitespace ../ollvm22.patch && \
    test -z "$(find . -name '*.rej' -o -name '*.orig' -print -quit)"

WORKDIR /repos/llvm-22/

# Build custom LLVM
# Removed clang;lld from LLVM_ENABLE_PROJECTS to speed up build
# Added LLVM_OPTIMIZED_TABLEGEN=ON for faster build
RUN --mount=type=cache,target=/cache/ccache \
    --mount=type=cache,target=/cache/llvm-build \
    rm -rf /cache/llvm-build/* && \
    CC=clang CXX=clang++ cmake -G "Ninja" -S llvm -B /cache/llvm-build \
    -DCMAKE_INSTALL_PREFIX="/opt/llvm" \
    -DCMAKE_CXX_STANDARD=17 \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_ENABLE_PROJECTS="" \
    -DLLVM_TARGETS_TO_BUILD="X86" \
    -DLLVM_INSTALL_UTILS=ON \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_BUILD_TESTS=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_BUILD_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_ENABLE_BACKTRACES=OFF \
    -DLLVM_BUILD_DOCS=OFF \
    -DBUILD_SHARED_LIBS=OFF \
    -DLLVM_OPTIMIZED_TABLEGEN=ON

RUN --mount=type=cache,target=/cache/ccache \
    --mount=type=cache,target=/cache/llvm-build \
    cmake --build /cache/llvm-build -j$(nproc)

RUN --mount=type=cache,target=/cache/llvm-build \
    cmake --install /cache/llvm-build

FROM base as builder-rustc

ENV RUSTUP_HOME=/opt/rustup
ENV CARGO_HOME=/opt/cargo
ENV PATH=/opt/cargo/bin:/opt/llvm/bin:$PATH

# Install rustup
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain 1.98.1 --profile minimal

COPY --from=builder-llvm /opt/llvm /opt/llvm

# check llvm
RUN /opt/llvm/bin/llvm-config --version

RUN git clone --single-branch --branch 1.98.1 --depth 1 https://github.com/rust-lang/rust /repos/rust-1.98.1

WORKDIR /repos/rust-1.98.1/

# Config rust
RUN set -eux; \
    cat > bootstrap.toml <<'EOF'
change-id = "ignore"

[build]
target = ["x86_64-unknown-linux-gnu", "x86_64-pc-windows-gnu"]
optimized-compiler-builtins = false

[rust]
debug = false
channel = "nightly"

[llvm]
download-ci-llvm = false

[target.x86_64-unknown-linux-gnu]
llvm-config = "/opt/llvm/bin/llvm-config"
llvm-filecheck = "/opt/llvm/bin/FileCheck"
EOF

# Build rust
# Added ccache mount and cargo cache mounts
RUN --mount=type=cache,target=/cache/ccache \
    --mount=type=cache,target=/repos/rust-1.98.1/build \
    --mount=type=cache,target=/opt/cargo/registry \
    --mount=type=cache,target=/opt/cargo/git \
    python3 x.py build --target x86_64-unknown-linux-gnu,x86_64-pc-windows-gnu

WORKDIR /repos/

# Copy artifacts
RUN --mount=type=cache,target=/repos/rust-1.98.1/build \
    mkdir -p /opt/rust && \
    cp -a /repos/rust-1.98.1/build/x86_64-unknown-linux-gnu/stage1/* /opt/rust/ && \
    cp -f /opt/rustup/toolchains/1.98.1-x86_64-unknown-linux-gnu/bin/cargo /opt/rust/bin/cargo

FROM ubuntu:24.04 as runtime

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC
ENV PATH=/opt/rust/bin:$PATH

RUN apt-get update -y && \
    apt-get install --no-install-recommends -y \
    ca-certificates \
    build-essential \
    pkg-config \
    libstdc++6 \
    libgcc-s1 \
    libssl3 \
    libcurl4 \
    zlib1g \
    protobuf-compiler \
    gcc-mingw-w64-x86-64 \
    g++-mingw-w64-x86-64 && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder-rustc /opt/rust /opt/rust

WORKDIR /projects/
