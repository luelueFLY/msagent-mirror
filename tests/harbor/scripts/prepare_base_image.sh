#!/usr/bin/env bash
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

# Build the Harbor task base image `ascend-profiling-eval` from the bundled
# docker/Dockerfile, then verify the runtime the dataset tasks rely on:
#   - workdir is "/" (Harbor uploads environment/ there -> /input_data)
#   - `python3` and `python3.11` are the same interpreter, Python >= 3.11
#   - pandas and the sqlite3 module import under `python3`
#   - the sqlite3 CLI is present
#   - pip works (needed to install the evaluated msagent wheel)
#   - nodejs >= 18 (reserved for optional comparison agents)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARBOR_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DOCKERFILE="$HARBOR_DIR/docker/Dockerfile"

TAG="ascend-profiling-eval"
DEBIAN_MIRROR="https://deb.debian.org"
PIP_INDEX_URL="https://pypi.org/simple"
PIP_TRUSTED_HOST=""
NO_CACHE=0

usage() {
  cat <<'EOF'
Usage: prepare_base_image.sh [options]

Builds tests/harbor/docker/Dockerfile and tags it as the dataset's
`ascend-profiling-eval` image, then verifies the expected runtime.

Options:
  --tag NAME               Image tag to build (default: ascend-profiling-eval)
  --debian-mirror URL      apt mirror for bookworm (default: https://deb.debian.org)
  --pip-index-url URL      pip index (default: https://pypi.org/simple)
  --trusted-host HOST      pip trusted host (optional)
  --no-cache               Disable Docker build cache
  -h, --help               Show this help
EOF
}

while (($#)); do
  case "$1" in
    --tag)
      TAG="${2:?--tag requires a value}"
      shift 2
      ;;
    --debian-mirror)
      DEBIAN_MIRROR="${2:?--debian-mirror requires a value}"
      shift 2
      ;;
    --pip-index-url)
      PIP_INDEX_URL="${2:?--pip-index-url requires a value}"
      shift 2
      ;;
    --trusted-host)
      PIP_TRUSTED_HOST="${2:?--trusted-host requires a value}"
      shift 2
      ;;
    --no-cache)
      NO_CACHE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required" >&2
  exit 127
fi
if [[ ! -f "$DOCKERFILE" ]]; then
  echo "Dockerfile not found: $DOCKERFILE" >&2
  exit 1
fi

BUILD_ARGS=(
  -f "$DOCKERFILE"
  -t "$TAG"
  --build-arg "DEBIAN_MIRROR=$DEBIAN_MIRROR"
  --build-arg "PIP_INDEX_URL=$PIP_INDEX_URL"
)
if [[ -n "$PIP_TRUSTED_HOST" ]]; then
  BUILD_ARGS+=(--build-arg "PIP_TRUSTED_HOST=$PIP_TRUSTED_HOST")
fi
if (( NO_CACHE )); then
  BUILD_ARGS+=(--no-cache)
fi

echo "=== Building $TAG ==="
echo "Dockerfile: $DOCKERFILE"
echo "apt mirror: $DEBIAN_MIRROR"
echo "pip index:  $PIP_INDEX_URL"
echo "trusted:    ${PIP_TRUSTED_HOST:-(none)}"
docker build "${BUILD_ARGS[@]}" "$HARBOR_DIR"
echo "Build succeeded."

# ---------------------------------------------------------------------------
# Verify the runtime expectations used by the dataset and the adapter.
# ---------------------------------------------------------------------------
echo "=== Verifying $TAG ==="
PY3="$(docker run --rm --entrypoint /bin/sh "$TAG" -c 'command -v python3')"
PY311="$(docker run --rm --entrypoint /bin/sh "$TAG" -c 'command -v python3.11')"
if [[ -z "$PY3" || -z "$PY311" ]]; then
  echo "Image must provide both python3 and python3.11" >&2
  exit 1
fi

PWD_OUT="$(docker run --rm --entrypoint /bin/sh "$TAG" -c 'pwd')"
if [[ "$PWD_OUT" != "/" ]]; then
  echo "Image workdir must be / (found: $PWD_OUT)" >&2
  exit 1
fi

VERSIONS="$(docker run --rm --entrypoint /bin/sh "$TAG" -c \
  'printf "%s\n%s\n" "$(python3 -V)" "$(python3.11 -V)"')"
V3="$(sed -n 1p <<< "$VERSIONS")"
V311="$(sed -n 2p <<< "$VERSIONS")"
if [[ "$V3" != "$V311" ]]; then
  echo "python3 and python3.11 must be the same interpreter" >&2
  echo "  python3:   $V3" >&2
  echo "  python3.11: $V311" >&2
  exit 1
fi
PY_VERSION="$(sed -E 's/^Python ([0-9]+\.[0-9]+).*/\1/' <<< "$V3")"
IFS=. read -r PY_MAJOR PY_MINOR <<< "$PY_VERSION"
if ! [[ "$PY_MAJOR" =~ ^[0-9]+$ && "$PY_MINOR" =~ ^[0-9]+$ ]] \
  || ((PY_MAJOR < 3 || (PY_MAJOR == 3 && PY_MINOR < 11))); then
  echo "Image requires Python >= 3.11; found: $PY_VERSION" >&2
  exit 1
fi

docker run --rm --entrypoint /bin/sh "$TAG" -c \
  'python3 -c "import pandas, sqlite3"' >/dev/null \
  || { echo "python3 must be able to import pandas and sqlite3" >&2; exit 1; }

docker run --rm --entrypoint /bin/sh "$TAG" -c \
  'command -v sqlite3 >/dev/null' \
  || { echo "sqlite3 CLI is missing" >&2; exit 1; }

docker run --rm --entrypoint /bin/sh "$TAG" -c \
  'python3 -m pip --version' >/dev/null \
  || { echo "pip is missing for python3" >&2; exit 1; }

NODE_VERSION="$(docker run --rm --entrypoint /bin/sh "$TAG" -c \
  'node --version' 2>/dev/null || true)"
NODE_MAJOR="$(sed 's/^v//' <<< "$NODE_VERSION" | cut -d. -f1)"
if ! [[ "$NODE_MAJOR" =~ ^[0-9]+$ ]] || (( NODE_MAJOR < 18 )); then
  echo "Node.js >= 18 is required (found: ${NODE_VERSION:-none})" >&2
  exit 1
fi

PANDAS_VER="$(docker run --rm --entrypoint /bin/sh "$TAG" -c \
  'python3 -c "import pandas; print(pandas.__version__)"')"
SQLITE_VER="$(docker run --rm --entrypoint /bin/sh "$TAG" -c \
  'sqlite3 --version' | awk '{print $1}')"
echo "Prepared $TAG: Python $PY_VERSION, pandas $PANDAS_VER, sqlite3 $SQLITE_VER, node ${NODE_VERSION#v}, workdir /"
