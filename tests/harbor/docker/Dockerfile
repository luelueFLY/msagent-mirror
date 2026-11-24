# -------------------------------------------------------------------------
# This file is part of the MindStudio project.
# Copyright (c) 2026 Huawei Technologies Co.,Ltd.
#
# MindStudio is licensed under Mulan PSL v2.
# You can use this software according to the terms and conditions of the Mulan PSL v2.
# You may obtain a copy of Mulan PSL v2 at:
#
#          http://license.coscl.org.cn/MulanPSL2
#
# THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND,
# EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT,
# MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
# See the Mulan PSL v2 for more details.
# -------------------------------------------------------------------------

# Harbor task base image `ascend-profiling-eval`.
#
# Used by every task in the AscendProfileAnalysisBench dataset
# ([environment].docker_image). The dataset task instructions promise
# `python3 / sqlite3 / pandas`, and the msagent Harbor adapter installs the
# msagent wheel with `python3.11` into this same interpreter. Node.js is
# included as a reserved runtime for optional comparison agents that require
# it; no separate base image is needed.
#
# The image must NOT preinstall msagent or its dependencies: each Harbor trial
# pip-installs the evaluated wheel into a fresh container so every run starts
# from a clean, reproducible environment.
#
# Build with scripts/prepare_base_image.sh, or directly:
#
#   docker build -f docker/Dockerfile -t ascend-profiling-eval \
#     --build-arg DEBIAN_MIRROR=https://repo.huaweicloud.com \
#     --build-arg PIP_INDEX_URL=https://repo.huaweicloud.com/repository/pypi/simple \
#     --build-arg PIP_TRUSTED_HOST=repo.huaweicloud.com \
#     tests/harbor
#
# The official image is glibc 2.36 and accepts all manylinux_2_28 wheels
# (aarch64 pandas/numpy wheels verified), so no build toolchain is needed.

FROM python:3.11-slim-bookworm

# apt / pip mirrors. Defaults are the upstream sources; set these to a local
# mirror when building behind a restricted network.
ARG DEBIAN_MIRROR=https://deb.debian.org
ARG PIP_INDEX_URL=https://pypi.org/simple
ARG PIP_TRUSTED_HOST=

RUN sed -i "s|http://deb.debian.org|${DEBIAN_MIRROR}|g" /etc/apt/sources.list.d/debian.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates sqlite3 procps nodejs npm \
    && rm -rf /var/lib/apt/lists/*

# pip picks these up automatically (PIP_INDEX_URL / PIP_TRUSTED_HOST env vars).
ENV PIP_INDEX_URL=${PIP_INDEX_URL} \
    PIP_TRUSTED_HOST=${PIP_TRUSTED_HOST} \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# pandas (with numpy) for the agent's data analysis. Bump deliberately.
RUN python3 -m pip install --no-cache-dir pandas==3.1.1

# Harbor uploads task environment/ to the container workdir, and the adapter
# symlinks /input_data -> /workspace/input_data; keep workdir at the root.
WORKDIR /
