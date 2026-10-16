# Neural Cone Radiosity
# Ubuntu 22.04, CUDA 12.6.3, Miniconda, Python 3.12.
#
# The CUDA toolkit is the one in this image. Do not conda-install cuda-toolkit:
# that package currently resolves to CUDA 13 and breaks the build on new glibc.
# nvcc uses the image GCC 11. Clang 14 is used only to compile Mitsuba.
#
# Build (no GPU required; the arch is pinned below):
#   docker build -t neural-cone .
#
# Run:
#   docker run --gpus all -it --rm neural-cone
#
# The host needs an NVIDIA driver >= 560 and the NVIDIA Container Toolkit.
# Default GPU arch is 8.6 (RTX 3090). Override with:
#   docker build --build-arg TORCH_CUDA_ARCH_LIST=8.6 -t neural-cone .

FROM nvidia/cuda:12.6.3-devel-ubuntu22.04

ARG TORCH_CUDA_ARCH_LIST=8.6
ARG MITSUBA_REF=v3.5.2
ARG TCNN_COMMIT=3daa6e5b8b8e0fa17971a1a20acfbb3754494b38
ARG CONDA_INSTALLER=Miniconda3-py312_26.9.3-0-Linux-x86_64.sh

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    CUDA_HOME=/usr/local/cuda \
    CONDA_PLUGINS_AUTO_ACCEPT_TOS=true \
    TORCH_CUDA_ARCH_LIST=${TORCH_CUDA_ARCH_LIST} \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility,graphics

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        clang-14 \
        cmake \
        curl \
        ffmpeg \
        git \
        libc++-14-dev \
        libc++abi-14-dev \
        libjpeg-dev \
        libpng-dev \
        ninja-build \
        pkg-config \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL "https://repo.anaconda.com/miniconda/${CONDA_INSTALLER}" -o /tmp/miniconda.sh \
    && bash /tmp/miniconda.sh -b -p /opt/conda \
    && rm /tmp/miniconda.sh

ENV PATH=/opt/conda/bin:${PATH}

RUN conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main \
    && conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r \
    && conda create -n mi3 python=3.12 -y \
    && conda clean -afy

# conda env first, then the toolkit already on PATH from the base image.
ENV PATH=/opt/conda/envs/mi3/bin:${PATH} \
    LD_LIBRARY_PATH=/opt/conda/envs/mi3/lib:${LD_LIBRARY_PATH}

# Checkout origin/v3.5.2 explicitly. A same-named tag would be the upstream release.
RUN git clone https://github.com/jieruijerry/mitsuba3-old.git /opt/official-submodules/mitsuba3-old \
    && git -C /opt/official-submodules/mitsuba3-old checkout -B "${MITSUBA_REF}" "origin/${MITSUBA_REF}" \
    && git -C /opt/official-submodules/mitsuba3-old submodule update --init --recursive \
    && CC=clang-14 CXX=clang++-14 cmake -GNinja \
        -DPython_EXECUTABLE=/opt/conda/envs/mi3/bin/python \
        -DPython_ROOT_DIR=/opt/conda/envs/mi3 \
        -DMI_DEFAULT_VARIANTS="scalar_rgb;cuda_rgb" \
        -DCMAKE_BUILD_TYPE=Release \
        -S /opt/official-submodules/mitsuba3-old \
        -B /opt/official-submodules/mitsuba3-old/build \
    && cmake --build /opt/official-submodules/mitsuba3-old/build

# Matches scripts/active_mitsuba.sh when the shell starts in /opt/neural-cone.
ENV PATH=/opt/official-submodules/mitsuba3-old/build:${PATH} \
    PYTHONPATH=/opt/official-submodules/mitsuba3-old/build/python

COPY requirements.txt /tmp/requirements.txt
RUN python -m pip install --upgrade pip \
    && python -m pip install "setuptools==80.9.0" wheel ninja \
    && python -m pip install torch==2.11.0 --index-url https://download.pytorch.org/whl/cu126 \
    && python -m pip install -r /tmp/requirements.txt \
    && python -m pip install "setuptools==80.9.0" "cuda-python==12.6.2.post1" \
    && export TCNN_CUDA_ARCHITECTURES="$(printf '%s' "${TORCH_CUDA_ARCH_LIST}" | tr -d '.')" \
    && python -m pip install --no-build-isolation \
        "git+https://github.com/NVlabs/tiny-cuda-nn.git@${TCNN_COMMIT}#subdirectory=bindings/torch" \
    && python -c "import torch; v=torch.version.cuda; assert v.startswith('12.6'), v"

WORKDIR /opt/neural-cone
COPY . /opt/neural-cone

RUN printf '%s\n' \
        'source /opt/conda/etc/profile.d/conda.sh' \
        'conda activate mi3' \
        'source /opt/official-submodules/mitsuba3-old/build/setpath.sh' \
        > /root/.bashrc

CMD ["/bin/bash"]
