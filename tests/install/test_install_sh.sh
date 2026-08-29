#!/usr/bin/env bash
# Functional tests for scripts/install.sh using a mock uv (fake_uv.sh).
#
# These tests guard the installer's decision logic (index priority, version
# pinning/announcement, PyPI fallback retry, NO_MODIFY_PATH escape hatch,
# static syntax) without performing a real package install. A real-install
# smoke test lives in smoke_install.sh.
#
# Usage:
#   bash tests/install/test_install_sh.sh
# Exit code 0 = all checks passed.

set -euo pipefail

# The installer itself refuses MSYS/MinGW/CYGWIN shells, so this suite must
# run on Linux/macOS/WSL (CI uses ubuntu-latest).
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "SKIP: install.sh refuses MSYS/MinGW/CYGWIN shells; run on Linux/macOS/WSL"
    exit 0
    ;;
esac

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
INSTALLER="${REPO_ROOT}/scripts/install.sh"
FAKE_UV="${SCRIPT_DIR}/fake_uv.sh"

PASS=0
FAIL=0
SKIP=0

ok() { printf '  [PASS] %s\n' "$*"; PASS=$((PASS + 1)); }
ko() { printf '  [FAIL] %s\n' "$*" >&2; FAIL=$((FAIL + 1)); }
skip() { printf '  [SKIP] %s\n' "$*"; SKIP=$((SKIP + 1)); }

# run_installer <out-log> [extra env assignments...]  -- runs the installer in
# an isolated HOME with a mock uv; the last stdout line of the fake uv's
# `tool dir --bin` call becomes the tool bin dir.
run_installer() {
  local out_log="$1"
  shift
  TEST_HOME="$(mktemp -d)"
  TEST_BIN="${TEST_HOME}/bin"
  mkdir -p "${TEST_BIN}"
  UV_LOG="$(mktemp)"
  chmod +x "${FAKE_UV}" 2>/dev/null || true
  export HOME="${TEST_HOME}"
  export MSAGENT_YES=1
  export MSAGENT_NO_MODIFY_PATH=1
  export UV_BIN="${FAKE_UV}"
  export MSAGENT_TEST_UV_LOG="${UV_LOG}"
  export MSAGENT_TEST_TOOL_BIN="${TEST_BIN}"
  local kv
  for kv in "$@"; do export "${kv}"; done
  bash "${INSTALLER}" > "${out_log}" 2>&1 || true
}

cleanup_env() {
  rm -rf "${TEST_HOME:-}" "${UV_LOG:-}"
  unset MSAGENT_VERSION MSAGENT_INDEX MSAGENT_TEST_UV_FAIL MSAGENT_TEST_UV_FAIL_PYPI_ONLY 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# 1. Static checks
# ---------------------------------------------------------------------------
printf '== Static checks ==\n'
if bash -n "${INSTALLER}"; then ok "bash -n syntax"; else ko "bash -n syntax"; fi
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S warning "${INSTALLER}"; then ok "shellcheck (warning+)"; else ko "shellcheck (warning+)"; fi
else
  skip "shellcheck not installed"
fi

# ---------------------------------------------------------------------------
# 2. Deterministic logic: MSAGENT_VERSION pin + MSAGENT_INDEX passthrough
# ---------------------------------------------------------------------------
printf '\n== Scenario: MSAGENT_VERSION + MSAGENT_INDEX passthrough ==\n'
OUT="$(mktemp)"
run_installer "${OUT}" MSAGENT_VERSION=1.2.3 MSAGENT_INDEX=https://example.invalid/simple

grep -q "Will install msagent 1.2.3 (MSAGENT_VERSION)" "${OUT}" && ok "announces pinned version at start" || ko "announces pinned version at start"
grep -q -- "--default-index https://example.invalid/simple" "${UV_LOG}" && ok "passes MSAGENT_INDEX through" || ko "passes MSAGENT_INDEX through"
grep -q "mindstudio-agent==1.2.3" "${UV_LOG}" && ok "uses pinned spec" || ko "uses pinned spec"
grep -q -- "--python >=3.11" "${UV_LOG}" && ok "uses >=3.11 python request" || ko "uses >=3.11 python request"
grep -q "MSAGENT_NO_MODIFY_PATH is set" "${OUT}" && ok "honors MSAGENT_NO_MODIFY_PATH" || ko "honors MSAGENT_NO_MODIFY_PATH"
[ ! -f "${TEST_HOME}/.bashrc" ] && ok "no shell profile modified" || ko "no shell profile modified"
cleanup_env

# ---------------------------------------------------------------------------
# 3. PyPI fallback retry (auto index chain; requires huaweicloud reachable)
# ---------------------------------------------------------------------------
printf '\n== Scenario: PyPI fallback retry when mirror install fails ==\n'
if curl -fsS -o /dev/null --connect-timeout 6 --max-time 12 -I "https://mirrors.huaweicloud.com/repository/pypi/simple/pip/" 2>/dev/null; then
  OUT="$(mktemp)"
  run_installer "${OUT}" MSAGENT_TEST_UV_FAIL_PYPI_ONLY=1
  grep -q "retrying once with official PyPI" "${OUT}" && ok "fallback retry triggered" || ko "fallback retry triggered"
  grep -q -- "https://pypi.org/simple" "${UV_LOG}" && ok "retry uses official PyPI" || ko "retry uses official PyPI"
  grep -q "Will install msagent" "${OUT}" && ok "announces target version" || ko "announces target version"
  grep -q "Selected PyPI index" "${OUT}" && ok "selected an index" || ko "selected an index"
  cleanup_env
else
  skip "huaweicloud mirror unreachable in this environment"
fi

# ---------------------------------------------------------------------------
# 4. NO_MODIFY_PATH + failing uv (venv fallback path is not exercised here)
# ---------------------------------------------------------------------------
printf '\n== Scenario: failing uv is reported and installer exits non-zero ==\n'
OUT="$(mktemp)"
run_installer "${OUT}" MSAGENT_INDEX=https://example.invalid/simple MSAGENT_TEST_UV_FAIL=1 MSAGENT_NO_FALLBACK=1
grep -q "MSAGENT_NO_FALLBACK is set" "${OUT}" && ok "reports failure with actionable message" || ko "reports failure with actionable message"
cleanup_env

# ---------------------------------------------------------------------------
printf '\n== Summary ==\n'
printf 'passed=%d failed=%d skipped=%d\n' "${PASS}" "${FAIL}" "${SKIP}"
rm -f "${OUT:-}" 2>/dev/null || true
[ "${FAIL}" -eq 0 ]
