#!/usr/bin/env bash
# Mock uv used by tests/install/test_install_sh.sh.
#
# Records every invocation (one per line) to $MSAGENT_TEST_UV_LOG and lets
# the test control the exit code:
#   MSAGENT_TEST_UV_FAIL=1            -> always exit 1
#   MSAGENT_TEST_UV_FAIL_PYPI_ONLY=1  -> exit 1 unless the args reference
#                                        https://pypi.org/simple
# For `uv tool dir --bin` it prints $MSAGENT_TEST_TOOL_BIN so the installer
# resolves the tool bin directory without touching the real filesystem.

set -u

LOG="${MSAGENT_TEST_UV_LOG:-}"
[ -n "${LOG}" ] || exit 0

printf '%s\n' "$*" >> "${LOG}"

if [ "${1:-}" = "tool" ] && [ "${2:-}" = "dir" ]; then
  printf '%s\n' "${MSAGENT_TEST_TOOL_BIN:-}"
fi

if [ "${MSAGENT_TEST_UV_FAIL_PYPI_ONLY:-0}" = "1" ]; then
  case " $* " in
    *" https://pypi.org/simple "*) exit 0 ;;
    *) exit 1 ;;
  esac
fi

[ "${MSAGENT_TEST_UV_FAIL:-0}" = "1" ] && exit 1
exit 0
