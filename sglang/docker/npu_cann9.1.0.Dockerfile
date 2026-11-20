ARG CANN_VERSION=9.1.0
ARG DEVICE_TYPE=950
ARG OS=ubuntu22.04
ARG PYTHON_VERSION=py3.12

FROM quay.io/ascend/cann:$CANN_VERSION-$DEVICE_TYPE-$OS-$PYTHON_VERSION AS sgl-router-builder

ENV DEBIAN_FRONTEND=noninteractive \
    PCRE2_SYS_STATIC=1 \
    RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo \
    PATH=/usr/local/cargo/bin:${PATH}

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        cmake \
        curl \
        git \
        pkg-config \
        protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --single-branch \
        --branch main \
        https://github.com/sgl-project/sglang.git \
        /src/sglang \
    && curl --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 -sSf \
        https://sh.rustup.rs \
        | sh -s -- -y --profile minimal --default-toolchain none \
    && cd /src/sglang/sgl-router \
    # Install the toolchain pinned by sgl-router/rust-toolchain.toml.
    && rustup toolchain install \
    && cargo build --locked --release --bin sgl-router \
    && install -Dm755 target/release/sgl-router /out/sgl-router \
    && /out/sgl-router --help >/dev/null

FROM quay.io/ascend/cann:$CANN_VERSION-$DEVICE_TYPE-$OS-$PYTHON_VERSION

ARG CANN_VERSION
ARG DEVICE_TYPE

ARG PYTORCH_VERSION="2.10.0"
ARG TORCHVISION_VERSION="0.25.0"
ARG TORCHAUDIO_VERSION="2.10.0"
ARG TORCH_NPU_VERSION="2.10.0.post6"
ARG TORCH_NPU_INDEX_URL="https://ascend.devcloud.huaweicloud.com/pypi/simple/"

ARG SGLANG_TAG=main
ARG ASCEND_CANN_PATH=/usr/local/Ascend/ascend-toolkit
ARG SGLANG_KERNEL_NPU_TAG=2026.11.0.post12
ARG PIP_INSTALL="python3 -m pip install --no-cache-dir"
ARG TARGETARCH

WORKDIR /workspace

COPY --from=sgl-router-builder /out/sgl-router /usr/local/bin/sgl-router
RUN sgl-router --help >/dev/null

ENV DEBIAN_FRONTEND=noninteractive

RUN pip config set global.index-url $PIP_INDEX_URL

# Install development tools and utilities
RUN apt-get update -y && apt upgrade -y && apt-get install -y \
    unzip \
    build-essential \
    cmake \
    vim \
    wget \
    curl \
    net-tools \
    zlib1g-dev \
    lld \
    clang \
    locales \
    ccache \
    openssl \
    libssl-dev \
    pkg-config \
    libgl1-mesa-glx \
    libgl1-mesa-dri \
    ca-certificates \
    git \
    ninja-build \
    patchelf \
    libyaml-cpp-dev \
    libgflags-dev \
    libgoogle-glog-dev \
    libjsoncpp-dev \
    libunwind-dev \
    libnuma-dev \
    libasio-dev \
    libboost-dev \
    libcurl4-openssl-dev \
    libgrpc++-dev \
    libprotobuf-dev \
    protobuf-compiler-grpc \
    liburing-dev \
    libmsgpack-dev \
    libzstd-dev \
    libxxhash-dev \
    libcli11-dev \
    libibverbs-dev \
    git-lfs \
    && rm -rf /var/cache/apt/* \
    && rm -rf /var/lib/apt/lists/* \
    && update-ca-certificates \
    && locale-gen en_US.UTF-8

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

RUN git lfs install --system

RUN python3 -m pip install --no-deps cannbot-dsl==0.8.0

### Install MemFabric and MemCache
RUN ${PIP_INSTALL} memfabric-hybrid==1.5.0.dev20261119 --trusted-host ascend.devcloud.huaweicloud.com -i https://ascend.devcloud.huaweicloud.com/pypi/simple

RUN ${PIP_INSTALL} modelscope evalscope pytest blake3 deepseek-recipe msgpack

RUN ${PIP_INSTALL} https://github.com/kvcache-ai/Mooncake/releases/download/v0.3.14/mooncake_transfer_engine_memfabric-0.3.14-cp312-cp312-manylinux_2_35_$(arch).whl --force --no-deps

### Install PyTorch and PTA
RUN (${PIP_INSTALL} torch==${PYTORCH_VERSION} torchvision==${TORCHVISION_VERSION} torchaudio==${TORCHAUDIO_VERSION} --index-url https://download.pytorch.org/whl/cpu) \
    && (${PIP_INSTALL} torch-npu==${TORCH_NPU_VERSION} --extra-index-url ${TORCH_NPU_INDEX_URL})

## Install triton-ascend
RUN ${PIP_INSTALL} pybind11 && \
    if [ "$TARGETARCH" = "arm64" ]; then \
        ${PIP_INSTALL} "https://sglang-npu.obs.cn-southwest-2.myhuaweicloud.com:443/Triton-ascend/3.2.2/triton_ascend-3.2.2-cp312-cp312-manylinux_2_27_aarch64.manylinux_2_28_aarch64.whl?AccessKeyId=HPUAAPJN7IAXFCS2GDSQ&Expires=1806290330&Signature=eRq3VKjwgP/tTkObtsho%2BzIsmJM%3D"; \
    elif [ "$TARGETARCH" = "amd64" ]; then \
        ${PIP_INSTALL} https://github.com/triton-lang/triton-ascend/releases/download/v3.2.2/triton_ascend-3.2.2-cp312-cp312-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl; \
    else \
        echo "Unsupported architecture: $TARGETARCH"; \
        exit 1; \
    fi

# Install SGLang
RUN git clone https://github.com/sgl-project/sglang --branch ${SGLANG_TAG} /sgl-workspace/sglang && \
    cd /sgl-workspace/sglang/python && rm -rf pyproject.toml && mv pyproject_npu.toml pyproject.toml && \
    ${PIP_INSTALL} -v -e .[all_npu]

RUN set -eux; \
    ${PIP_INSTALL} wheel==0.45.1 pybind11 pyyaml decorator scipy attrs psutil; \
    mkdir /tmp/sgl-kernel-npu; \
    cd /tmp/sgl-kernel-npu; \
    wget \
        "https://github.com/sgl-project/sgl-kernel-npu/releases/download/${SGLANG_KERNEL_NPU_TAG}/sgl-kernel-npu-${SGLANG_KERNEL_NPU_TAG}-torch${PYTORCH_VERSION}-py312-cann${CANN_VERSION}-${DEVICE_TYPE}-$(arch).zip"; \
    unzip ./*.zip; \
    ${PIP_INSTALL} --no-deps ./sgl_kernel_npu*.whl && \
    ${PIP_INSTALL} ./deep_ep*.whl ./torch_memory_saver*.whl && \
    cd "$(python3 -m pip show deep-ep | awk '/^Location:/ {print $2}')" && \
    ln -sf deep_ep/deep_ep_cpp*.so && \
    cd / && \
    rm -rf /tmp/sgl-kernel-npu

CMD ["/bin/bash"]