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

# Run a Harbor job from a YAML config file.
#
# Reads configs/msagent.yaml, validates prerequisites, runs `harbor run`,
# then exports results via export_results.py into the configured output dir.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARBOR_ADAPTER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFIG_FILE=""
TASK_OVERRIDE=""
TASK_OVERRIDDEN=0
OUTPUT_OVERRIDE=""
OUTPUT_OVERRIDDEN=0
INSTALL_ONLY_FLAG=0

usage() {
  cat <<'EOF'
Usage: scripts/run_msagent.sh --config FILE [options]

Options:
  --config FILE        Path to configs/msagent.yaml (required)
  --task PATTERN        Override task_filter in config (e.g. "0001-*" or "" for all)
  --output-dir PATH    Override output.dir in config
  --install-only       Only build container and install wheel, skip agent run
  -h, --help            Show this help

Required host environment variable by provider:
  openai     OPENAI_API_KEY
  anthropic  ANTHROPIC_API_KEY
  google     GOOGLE_API_KEY
EOF
}

while (($#)); do
  case "$1" in
    --config)
      CONFIG_FILE="${2:?--config requires a path}"
      shift 2
      ;;
    --task)
      if (($# < 2)); then
        echo "--task requires a value" >&2
        exit 2
      fi
      TASK_OVERRIDE="$2"
      TASK_OVERRIDDEN=1
      shift 2
      ;;
    --output-dir)
      if (($# < 2)); then
        echo "--output-dir requires a value" >&2
        exit 2
      fi
      OUTPUT_OVERRIDE="$2"
      shift 2
      ;;
    --install-only)
      INSTALL_ONLY_FLAG=1
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

if [[ -z "$CONFIG_FILE" ]]; then
  echo "--config is required" >&2
  exit 2
fi
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Config file not found: $CONFIG_FILE" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Parse YAML config via Python, emit shell-safe KEY=value lines, then eval.
# Values are single-quoted with shlex.quote so $, backticks, $(...) and
# newlines in the YAML are never expanded by the eval.
# ---------------------------------------------------------------------------
eval "$(
python3 - "$CONFIG_FILE" <<'PYEOF'
import shlex
import sys

try:
    import yaml
except ImportError:
    print("PyYAML is required: pip install pyyaml", file=sys.stderr)
    sys.exit(1)

with open(sys.argv[1]) as f:
    c = yaml.safe_load(f) or {}


def emit(key, val):
    if isinstance(val, bool):
        v = "1" if val else "0"
    elif val is None:
        v = ""
    else:
        v = str(val)
    print(f"{key}={shlex.quote(v)}")


d = c.get("dataset", {})
emit("CFG_DATASET_PATH", d.get("path"))
emit("CFG_TASK_FILTER", d.get("task_filter"))

a = c.get("agent", {})
emit("CFG_WHEEL", a.get("wheel"))
emit("CFG_PYTHON_BIN", a.get("python_bin", "python"))
emit("CFG_AGENT_IMPORT", a.get("import", "msagent_harbor.agent:MsagentHarborAgent"))

m = c.get("model", {})
emit("CFG_PROVIDER", m.get("provider", "openai"))
emit("CFG_MODEL", m.get("name"))
emit("CFG_BASE_URL", m.get("base_url"))

e = c.get("environment", {})
emit("CFG_DOCKER_IMAGE", e.get("image", "ascend-profiling-eval"))
p = e.get("pip", {})
emit("CFG_PIP_INDEX_URL", p.get("index_url"))
emit("CFG_PIP_EXTRA_INDEX_URL", p.get("extra_index_url"))
emit("CFG_PIP_TRUSTED_HOST", p.get("trusted_host"))

o = c.get("output", {})
emit("CFG_OUTPUT_DIR", o.get("dir"))
emit("CFG_RUN_ID", o.get("run_id"))

h = c.get("harbor", {})
emit("CFG_N_ATTEMPTS", h.get("n_attempts", 1))
emit("CFG_HARBOR_BIN", h.get("bin", "harbor"))
emit("CFG_INSTALL_ONLY", h.get("install_only", False))

extra = h.get("extra_args") or []
for i, arg in enumerate(extra):
    emit(f"CFG_EXTRA_ARG_{i}", arg)
emit("CFG_EXTRA_ARG_COUNT", len(extra))
PYEOF
)"

# Build EXTRA_ARGS array
EXTRA_ARGS=()
for ((i = 0; i < CFG_EXTRA_ARG_COUNT; i++)); do
  var_name="CFG_EXTRA_ARG_${i}"
  EXTRA_ARGS+=("${!var_name}")
done

# Apply CLI overrides. A sentinel distinguishes "not passed" from an explicit
# empty value: `--task ""` means "run every task" (override task_filter with
# empty), which a plain [[ -n ]] check would silently ignore.
TASK_FILTER="$CFG_TASK_FILTER"
if (( TASK_OVERRIDDEN )); then
  TASK_FILTER="$TASK_OVERRIDE"
fi

OUTPUT_DIR="$CFG_OUTPUT_DIR"
if (( ! OUTPUT_OVERRIDDEN )) && [[ -n "$OUTPUT_OVERRIDE" ]]; then
  OUTPUT_DIR="$OUTPUT_OVERRIDE"
  OUTPUT_OVERRIDDEN=1
fi

INSTALL_ONLY=$((INSTALL_ONLY_FLAG || CFG_INSTALL_ONLY))

# The compact export layout (scripts/export_results.py) keys tasks by task id
# and cannot represent more than one attempt per task. Fail fast instead of
# letting a multi-attempt run burn hours of model calls before export errors.
if [[ "$CFG_N_ATTEMPTS" != 1 ]]; then
  echo "harbor.n_attempts must be 1: the export layout supports a single attempt per task" >&2
  exit 2
fi

# Relative paths in the config are resolved against the config file's
# directory, so the shipped config stays portable.
CONFIG_DIR="$(cd "$(dirname "$CONFIG_FILE")" && pwd)"
abs_from_config() {
  local v="$1"
  if [[ -n "$v" && "$v" != /* ]]; then
    echo "$CONFIG_DIR/$v"
  else
    echo "$v"
  fi
}

# ---------------------------------------------------------------------------
# Validate prerequisites
# ---------------------------------------------------------------------------
DATASET="$(abs_from_config "$CFG_DATASET_PATH")"
if [[ -z "$DATASET" || ! -d "$DATASET" ]]; then
  echo "dataset.path must name an existing directory: $DATASET" >&2
  exit 2
fi
TASKS_PATH="$DATASET"
if [[ -d "$DATASET/tasks" ]]; then
  TASKS_PATH="$DATASET/tasks"
fi

# agent.wheel may be a glob (e.g. ../../dist/mindstudio_agent-*.whl); pick
# the newest match so version bumps do not require config edits.
WHEEL="$(abs_from_config "$CFG_WHEEL")"
if [[ "$WHEEL" == *['*?']* ]]; then
  mapfile -t WHEEL_CANDIDATES < <(compgen -G "$WHEEL" | sort -V)
  if ((${#WHEEL_CANDIDATES[@]})); then
    WHEEL="${WHEEL_CANDIDATES[-1]}"
  else
    WHEEL=""
  fi
fi
if [[ -z "$WHEEL" || ! -f "$WHEEL" || "$WHEEL" != *.whl ]]; then
  echo "agent.wheel must name an existing .whl file: $CFG_WHEEL" >&2
  exit 2
fi
WHEEL="$(realpath -m "$WHEEL")"

PYTHON_BIN="$CFG_PYTHON_BIN"
AGENT_IMPORT="$CFG_AGENT_IMPORT"

PROVIDER="${CFG_PROVIDER,,}"
case "$PROVIDER" in
  openai)
    API_KEY_NAME="OPENAI_API_KEY"
    ;;
  anthropic)
    API_KEY_NAME="ANTHROPIC_API_KEY"
    ;;
  google|gemini)
    PROVIDER="google"
    API_KEY_NAME="GOOGLE_API_KEY"
    ;;
  *)
    echo "model.provider must be openai, anthropic, or google: $CFG_PROVIDER" >&2
    exit 2
    ;;
esac

MODEL="$CFG_MODEL"
if [[ -z "$MODEL" ]]; then
  echo "model.name is required" >&2
  exit 2
fi

BASE_URL="$CFG_BASE_URL"
HARBOR_BIN="$CFG_HARBOR_BIN"

API_KEY_VALUE="${!API_KEY_NAME:-}"
if (( ! INSTALL_ONLY )) && [[ -z "$API_KEY_VALUE" ]]; then
  echo "Set $API_KEY_NAME in the host environment before running Harbor" >&2
  exit 2
fi

if ! command -v "$HARBOR_BIN" >/dev/null 2>&1; then
  echo "Harbor executable not found: $HARBOR_BIN" >&2
  echo "Install with: uv tool install harbor" >&2
  exit 127
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required" >&2
  exit 127
fi

DOCKER_IMAGE="$CFG_DOCKER_IMAGE"
if ! docker image inspect "$DOCKER_IMAGE" >/dev/null 2>&1; then
  echo "Image $DOCKER_IMAGE is missing. Run scripts/prepare_base_image.sh first." >&2
  exit 1
fi

# Verify Python >= 3.11 in the container image
PYTHON_VERSION="$(docker run --rm --entrypoint /bin/sh "$DOCKER_IMAGE" -c \
  'exec "$1" -c "import sys; print(\".\".join(map(str, sys.version_info[:2])))"' \
  sh "$PYTHON_BIN")"
IFS=. read -r PYTHON_MAJOR PYTHON_MINOR <<< "$PYTHON_VERSION"
if ! [[ "$PYTHON_MAJOR" =~ ^[0-9]+$ && "$PYTHON_MINOR" =~ ^[0-9]+$ ]] \
  || ((PYTHON_MAJOR < 3 || (PYTHON_MAJOR == 3 && PYTHON_MINOR < 11))); then
  echo "$DOCKER_IMAGE must provide Python >=3.11; found: $PYTHON_VERSION" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Determine output directory and run ID
# ---------------------------------------------------------------------------
# output.dir is the PARENT directory; run_id is the subdirectory name.
# When run_id is null, auto-generate with timestamp.
if [[ -z "$CFG_RUN_ID" ]]; then
  CFG_RUN_ID="eval-$(date +%Y%m%d-%H%M%S)"
fi
RUN_ID="$CFG_RUN_ID"

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$(pwd)/harbor-output"
elif (( OUTPUT_OVERRIDDEN )); then
  # CLI override: resolve against the current working directory.
  [[ "$OUTPUT_DIR" != /* ]] && OUTPUT_DIR="$(pwd)/$OUTPUT_DIR"
else
  # Config value: resolve against the config file's directory.
  OUTPUT_DIR="$(abs_from_config "$OUTPUT_DIR")"
fi
# Resolve to absolute path, then append RUN_ID as subdirectory
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)/$RUN_ID"
if [[ -e "$OUTPUT_DIR" ]]; then
  echo "Output directory already exists: $OUTPUT_DIR" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Prepare temporary working directory
# ---------------------------------------------------------------------------
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/msagent-harbor.XXXXXX")"
HARBOR_JOB_DIR="$WORK_DIR/$RUN_ID"
KEEP_WORK_DIR=0
cleanup() {
  if (( KEEP_WORK_DIR )); then
    echo "Preserving harbor job directory: $WORK_DIR" >&2
  else
    rm -rf -- "$WORK_DIR"
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Build environment variables for harbor process
# ---------------------------------------------------------------------------
HARBOR_ENV=(
  "MSAGENT_LLM_PROVIDER=$PROVIDER"
  "MSAGENT_LLM_MODEL=$MODEL"
)
if [[ -n "$BASE_URL" ]]; then
  HARBOR_ENV+=("MSAGENT_LLM_BASE_URL=$BASE_URL")
fi
if [[ -n "$CFG_PIP_INDEX_URL" ]]; then
  HARBOR_ENV+=("PIP_INDEX_URL=$CFG_PIP_INDEX_URL")
fi
if [[ -n "$CFG_PIP_EXTRA_INDEX_URL" ]]; then
  HARBOR_ENV+=("PIP_EXTRA_INDEX_URL=$CFG_PIP_EXTRA_INDEX_URL")
fi
if [[ -n "$CFG_PIP_TRUSTED_HOST" ]]; then
  HARBOR_ENV+=("PIP_TRUSTED_HOST=$CFG_PIP_TRUSTED_HOST")
fi

# ---------------------------------------------------------------------------
# Assemble harbor run command
# ---------------------------------------------------------------------------
RUN_FLAGS=(
  --path "$TASKS_PATH"
  --agent "$AGENT_IMPORT"
  --agent-kwarg "msagent_wheel=$WHEEL"
  --agent-kwarg "msagent_python=$PYTHON_BIN"
  --model "$MODEL"
  --n-attempts "$CFG_N_ATTEMPTS"
  --job-name "$RUN_ID"
  --jobs-dir "$WORK_DIR"
)

if [[ -n "$TASK_FILTER" ]]; then
  RUN_FLAGS+=(--include-task-name "$TASK_FILTER")
fi

if (( INSTALL_ONLY )); then
  RUN_FLAGS+=(--install-only)
fi

if (( ${#EXTRA_ARGS[@]} )); then
  RUN_FLAGS+=("${EXTRA_ARGS[@]}")
fi

echo "=== Harbor Run ==="
echo "Dataset:   $DATASET"
echo "Tasks:     ${TASK_FILTER:-(all)}"
echo "Wheel:     $WHEEL"
echo "Model:     $MODEL ($PROVIDER)"
echo "Image:     $DOCKER_IMAGE"
echo "Output:    $OUTPUT_DIR"
echo "Harbor:    $($HARBOR_BIN --version 2>/dev/null || echo 'unknown')"
echo "================="

set +e
env "${HARBOR_ENV[@]}" "$HARBOR_BIN" run "${RUN_FLAGS[@]}"
HARBOR_EXIT=$?
set -e

if (( INSTALL_ONLY )); then
  exit "$HARBOR_EXIT"
fi

if [[ ! -d "$HARBOR_JOB_DIR" ]]; then
  echo "Harbor did not create a job directory: $HARBOR_JOB_DIR" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Export results
# ---------------------------------------------------------------------------
set +e
python3 "$SCRIPT_DIR/export_results.py" \
  --harbor-job-dir "$HARBOR_JOB_DIR" \
  --output-dir "$OUTPUT_DIR" \
  --dataset "$DATASET" \
  --wheel "$WHEEL" \
  --image "$DOCKER_IMAGE" \
  --provider "$PROVIDER" \
  --model "$MODEL" \
  --base-url "$BASE_URL" \
  --python-bin "$PYTHON_BIN" \
  --adapter-dir "$HARBOR_ADAPTER_DIR" \
  --harbor-bin "$HARBOR_BIN"
EXPORT_EXIT=$?
set -e

if (( EXPORT_EXIT != 0 )); then
  KEEP_WORK_DIR=1
fi

if (( HARBOR_EXIT != 0 )); then
  exit "$HARBOR_EXIT"
fi
exit "$EXPORT_EXIT"
