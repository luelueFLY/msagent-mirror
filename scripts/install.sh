#!/usr/bin/env bash
# =============================================================================
# msAgent installer for Linux / macOS / WSL
#
# Usage:
#   curl -LsSf https://raw.gitcode.com/Ascend/msagent/raw/master/scripts/install.sh | bash
#
# What it does:
#   1. Preflight checks (network, existing pip install, downloader availability)
#   2. Bootstraps uv (official installer first, pip + domestic mirror as fallback)
#   3. Installs mindstudio-agent (latest from PyPI) into an isolated uv tool env:
#        uv tool install -U --python 3.11 mindstudio-agent --with-executables-from msprof-mcp
#   4. Adds the tool bin directory to PATH (shell profiles, idempotent)
#   5. Verifies: msagent --version
#
# The installer never pins a version: it always installs the latest
# mindstudio-agent from PyPI, so releases do not require touching this script.
# The uv tool environment is fully isolated, so it will not conflict with any
# existing Python environment (system Python, torch, mindstudio_monitor, ...).
#
# Environment variables:
#   MSAGENT_PYTHON            Python request for the isolated tool env (default: >=3.11, reuses local Python)
#   MSAGENT_VERSION           Exact version to install, e.g. "26.1.0" (default: latest)
#   MSAGENT_INDEX             PyPI index URL override (default: official PyPI, domestic mirrors as fallback)
#   MSAGENT_NO_MODIFY_PATH    set to 1 to skip all PATH modification
#   MSAGENT_YES               set to 1 to accept prompts without asking (CI/cron)
#   MSAGENT_NO_FALLBACK       set to 1 to disable the venv fallback
#   MSAGENT_FALLBACK_VENV     venv path used by the fallback install (default: ~/.msagent-venv)
#   MSAGENT_WITH_EXECUTABLES_FROM  package whose executables are exposed too (default: msprof-mcp)
#   MSAGENT_NO_ASCEND_DOC_MCP      set to 1 to skip Node provisioning and the ascend-doc-mcp pre-install
#   MSAGENT_ASCEND_DOC_MCP_REQUIRE set to 1 to abort install when Node/ascend-doc-mcp prep fails
#   MSAGENT_NODE_HOME              user-local Node root used by ascend-doc-mcp (default: ~/.msagent/node)
#   MSAGENT_NPM_REGISTRY           npm registry for the ascend-doc-mcp pre-install (default: npmmirror, npmjs fallback)
#   MSAGENT_NPM_CACHE              npm cache directory (default: ~/.cache/msagent/npm-cache)
#   MSAGENT_ASCEND_DOC_MCP_PREFIX  local ascend-doc-mcp install prefix (default: ~/.msagent/ascend-doc-mcp)
#   UV_DEFAULT_INDEX / UV_INDEX_URL / PIP_INDEX_URL  used as a last-resort fallback
#   UV_PYTHON_INSTALL_MIRROR  mirror for managed CPython downloads (domestic candidates validated for real binary content)
#   UV_NATIVE_TLS              use the system certificate store for uv (default: 1, set 0 to disable)
#
# Uninstall:
#   uv tool uninstall mindstudio-agent
#   Optionally remove the PATH entries this installer added to your profiles.
#
# Upgrade:
#   Just re-run the installer; it always upgrades to the latest release.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
if [ -t 1 ] || [ "${FORCE_COLOR:-}" = "1" ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
fi

log_info()    { printf "${CYAN}▸${NC} %s\n" "$*"; }
log_success() { printf "${GREEN}✔${NC} %s\n" "$*"; }
log_warn()    { printf "${YELLOW}⚠${NC} %s\n" "$*" >&2; }
log_error()   { printf "${RED}✖${NC} %s\n" "$*" >&2; }

# Works both interactively and under `curl ... | bash` (reads from /dev/tty).
prompt_yn() {
  [ "${MSAGENT_YES:-0}" = "1" ] && return 0
  local answer
  printf "${YELLOW}?${NC} %s [y/N] " "$*" >&2
  if [ -t 0 ]; then
    read -r answer || return 1
  elif [ -r /dev/tty ]; then
    read -r answer < /dev/tty || return 1
  else
    log_warn "Non-interactive shell; assuming 'no'."
    return 1
  fi
  case "${answer}" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# OS / environment detection
# ---------------------------------------------------------------------------
detect_os() {
  case "$(uname -s)" in
    Darwin) OS="macos" ;;
    Linux)  OS="linux" ;;
    MINGW*|MSYS*|CYGWIN*) OS="windows" ;;
    *) OS="unknown" ;;
  esac
}
detect_os

case "${OS}" in
  linux|macos) ;;
  windows)
    log_error "This installer targets Linux, macOS, and WSL shells."
    log_error "On native Windows (PowerShell), use:"
    log_error "  irm https://raw.gitcode.com/Ascend/msagent/raw/master/scripts/install.ps1 | iex"
    exit 1
    ;;
  *)
    log_error "Unsupported operating system. Please install msagent manually:"
    log_error "  uv tool install -U mindstudio-agent"
    log_error "If uv is unavailable, see the venv fallback section in this script."
    exit 1
    ;;
esac

# macOS MDM/root installs may run without a usable HOME. Re-home to the real
# console user so uv installs into the expected profile directory.
if [ "${OS}" = "macos" ] && { [ -z "${HOME:-}" ] || [ "$(id -u)" -eq 0 ]; }; then
  CONSOLE_USER="$(stat -f '%Su' /dev/console 2>/dev/null || true)"
  if [ -n "${CONSOLE_USER}" ] && [ "${CONSOLE_USER}" != "root" ] && [ -d "/Users/${CONSOLE_USER}" ]; then
    HOME="/Users/${CONSOLE_USER}"
    export HOME
  fi
fi

# root runs: install into the invoking user's profile, then fix ownership.
if [ "$(id -u)" -eq 0 ]; then
  TARGET_USER="${SUDO_USER:-${CONSOLE_USER:-$(basename "${HOME:-root}")}}"
  if [ -z "${TARGET_USER}" ] || [ "${TARGET_USER}" = "root" ]; then
    fix_owner() { :; }
  else
    fix_owner() {
      chown -R "${TARGET_USER}" "$@" 2>/dev/null || \
        log_warn "Could not fix ownership for $*"
    }
  fi
else
  fix_owner() { :; }
fi

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  log_error "curl or wget is required to download the installer assets."
  exit 1
fi

probe_url() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsS -o /dev/null --connect-timeout 6 --max-time 12 -I "${url}" 2>/dev/null && return 0
    curl -fsS -o /dev/null --connect-timeout 6 --max-time 12 "${url}" 2>/dev/null && return 0
  elif command -v wget >/dev/null 2>&1; then
    wget -q --spider --timeout=6 --tries=1 "${url}" 2>/dev/null && return 0
  fi
  return 1
}

# Warn about an existing pip-installed msagent that may shadow the uv tool.
if command -v pip >/dev/null 2>&1 && pip show mindstudio-agent >/dev/null 2>&1; then
  log_warn "mindstudio-agent is already installed via pip in this environment."
  log_warn "The uv tool install below is isolated and will not modify it, but the"
  log_warn "two executables may shadow each other on PATH. Consider:"
  log_warn "  pip uninstall mindstudio-agent"
fi

# ---------------------------------------------------------------------------
# Index selection: domestic mirrors first (fast in China), official PyPI as
# fallback; generic env vars last resort. Mirror sync may lag weekly
# releases, so the install is retried with official PyPI on failure (see the
# install section), and the latest version is pinned from PyPI beforehand.
# ---------------------------------------------------------------------------
select_index() {
  local candidate
  if [ -n "${MSAGENT_INDEX:-}" ]; then
    INDEX="${MSAGENT_INDEX}"
    log_info "Using index from MSAGENT_INDEX: ${INDEX}"
    return 0
  fi
  for candidate in \
    "https://mirrors.huaweicloud.com/repository/pypi/simple" \
    "https://mirrors.aliyun.com/pypi/simple" \
    "https://pypi.tuna.tsinghua.edu.cn/simple" \
    "https://pypi.org/simple"; do
    if probe_url "${candidate}/pip/"; then
      INDEX="${candidate}"
      log_info "Selected PyPI index: ${candidate}"
      return 0
    fi
    log_warn "Index unreachable: ${candidate} (trying the next candidate)"
  done
  # All candidates are unreachable; fall back to a user-configured
  # generic index if one exists, otherwise use official PyPI.
  if [ -n "${UV_DEFAULT_INDEX:-}" ]; then
    INDEX="${UV_DEFAULT_INDEX}"
    log_info "Fallback to UV_DEFAULT_INDEX: ${INDEX}"
    return 0
  fi
  if [ -n "${UV_INDEX_URL:-}" ]; then
    INDEX="${UV_INDEX_URL}"
    log_info "Fallback to UV_INDEX_URL: ${INDEX}"
    return 0
  fi
  if [ -n "${PIP_INDEX_URL:-}" ]; then
    INDEX="${PIP_INDEX_URL}"
    log_info "Fallback to PIP_INDEX_URL: ${INDEX}"
    return 0
  fi
  INDEX="https://pypi.org/simple"
  log_warn "No reachable index found; defaulting to ${INDEX}."
}
select_index

# ---------------------------------------------------------------------------
# Resolve and announce the msagent version to install. Mirror sync may lag
# weekly releases, so the latest version is pinned straight from PyPI and
# shown up front; the install is retried with official PyPI if the selected
# mirror does not have that version yet.
# ---------------------------------------------------------------------------
MSAGENT_PYTHON="${MSAGENT_PYTHON:->=3.11}"
INSTALL_SPEC="mindstudio-agent"
VERSION_SOURCE="latest from the selected index"
if [ -n "${MSAGENT_VERSION:-}" ]; then
  INSTALL_SPEC="mindstudio-agent==${MSAGENT_VERSION}"
  VERSION_SOURCE="MSAGENT_VERSION"
elif [ -z "${MSAGENT_INDEX:-}" ]; then
  LATEST_VERSION=""
  if command -v curl >/dev/null 2>&1; then
    LATEST_VERSION="$(curl -fsSL --connect-timeout 6 --max-time 15 https://pypi.org/pypi/mindstudio-agent/json 2>/dev/null | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
  elif command -v wget >/dev/null 2>&1; then
    LATEST_VERSION="$(wget -qO- --timeout=15 https://pypi.org/pypi/mindstudio-agent/json 2>/dev/null | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
  fi
  if [ -n "${LATEST_VERSION}" ]; then
    INSTALL_SPEC="mindstudio-agent==${LATEST_VERSION}"
    VERSION_SOURCE="latest from PyPI"
  fi
fi
log_info "Will install msagent ${INSTALL_SPEC#mindstudio-agent==} (${VERSION_SOURCE})"

# ---------------------------------------------------------------------------
# uv bootstrap: official installer, then pip + domestic mirror as fallback.
# ---------------------------------------------------------------------------
UV_BIN="${UV_BIN:-}"
bootstrap_uv() {
  if [ -n "${UV_BIN:-}" ]; then
    if [ -x "${UV_BIN}" ] || command -v "${UV_BIN}" >/dev/null 2>&1; then
      log_info "Using uv from UV_BIN: ${UV_BIN}"
      return 0
    fi
    log_warn "UV_BIN is set but not executable: ${UV_BIN}"
    UV_BIN=""
  fi
  if command -v uv >/dev/null 2>&1; then
    UV_BIN="uv"
    return 0
  fi
  if [ -x "${HOME}/.local/bin/uv" ]; then
    UV_BIN="${HOME}/.local/bin/uv"
    return 0
  fi

  log_info "uv is not installed. Bootstrapping uv..."
  if command -v curl >/dev/null 2>&1 && curl -fsSL https://astral.sh/uv/install.sh | sh; then
    :
  elif command -v wget >/dev/null 2>&1 && wget -qO- https://astral.sh/uv/install.sh | sh; then
    :
  else
    log_warn "Official uv installer failed or timed out; trying pip + ${INDEX} ..."
    local pybin=""
    if command -v python3 >/dev/null 2>&1; then pybin="python3"
    elif command -v python >/dev/null 2>&1; then pybin="python"
    else
      log_error "python3 is required to bootstrap uv via pip."
      log_error "Install uv manually (https://docs.astral.sh/uv/getting-started/installation/) and re-run this installer."
      return 1
    fi
    local errfile
    errfile="$(mktemp)"
    if ! "${pybin}" -m pip install --user -q -U uv -i "${INDEX}" 2>"${errfile}"; then
      if grep -q "externally-managed" "${errfile}" 2>/dev/null; then
        log_warn "PEP 668 externally-managed environment detected; retrying with --break-system-packages ..."
        "${pybin}" -m pip install --user -q -U --break-system-packages uv -i "${INDEX}" || {
          cat "${errfile}" >&2
          rm -f "${errfile}"
          log_error "uv could not be installed. Install it manually and re-run this installer."
          return 1
        }
      else
        cat "${errfile}" >&2
        rm -f "${errfile}"
        log_error "uv could not be installed. Install it manually and re-run this installer."
        return 1
      fi
    fi
    rm -f "${errfile}"
  fi

  if [ -x "${HOME}/.local/bin/uv" ]; then
    UV_BIN="${HOME}/.local/bin/uv"
    return 0
  fi
  if command -v uv >/dev/null 2>&1; then
    UV_BIN="uv"
    return 0
  fi
  if [ -f "${HOME}/.local/bin/env" ]; then
    # shellcheck source=/dev/null
    . "${HOME}/.local/bin/env"
    if command -v uv >/dev/null 2>&1; then
      UV_BIN="uv"
      return 0
    fi
  fi
  log_error "uv is not available after bootstrap. Restart your shell and re-run, or add ~/.local/bin to PATH."
  return 1
}
bootstrap_uv

# ---------------------------------------------------------------------------
# Use the platform's native TLS store (Windows Schannel / system CA bundle).
# Corporate proxies re-sign HTTPS with their own CA: system tools (curl/wget)
# trust it, but uv's bundled roots reject it with "UnknownIssuer". Only an
# explicitly set UV_NATIVE_TLS wins.
# ---------------------------------------------------------------------------
if [ -z "${UV_NATIVE_TLS:-}" ]; then
  export UV_NATIVE_TLS=1
  log_info "UV_NATIVE_TLS=1 (use the system certificate store for uv)"
fi

# ---------------------------------------------------------------------------
# Managed CPython downloads: try Huawei Cloud first, then NJU, but only when
# the mirror actually serves real binary content with a trusted certificate
# (some public github-release mirrors answer HTML with HTTP 200, and corporate
# proxies may reject certificates). Otherwise leave uv's defaults (official
# source or an existing local Python) to handle it.
# ---------------------------------------------------------------------------
python_platform_triple() {
  case "$(uname -s)/$(uname -m)" in
    Linux/x86_64)  echo "x86_64-unknown-linux-gnu" ;;
    Linux/aarch64) echo "aarch64-unknown-linux-gnu" ;;
    Darwin/x86_64) echo "x86_64-apple-darwin" ;;
    Darwin/arm64)  echo "aarch64-apple-darwin" ;;
    MINGW*|MSYS*|CYGWIN*/x86_64) echo "x86_64-pc-windows-msvc" ;;
    *) echo "" ;;
  esac
}

# Discover one real python-build-standalone file on the mirror from its own
# directory listing (newest tag), e.g.
# "20260825/cpython-3.11.16+20260825-aarch64-unknown-linux-gnu-install_only.tar.gz".
# No tag or version is hardcoded, so the probe stays valid as releases move on.
python_canary_file() {
  local mirror="$1" platform tag listing file
  platform="$(python_platform_triple)"
  [ -n "${platform}" ] || return 1
  if ! command -v curl >/dev/null 2>&1; then
    return 1
  fi
  listing="$(curl -fsSL --connect-timeout 6 --max-time 15 "${mirror}/" 2>/dev/null || true)"
  tag="$(printf '%s\n' "${listing}" | grep -oE '[0-9]{8}/' | tail -1 | tr -d '/')"
  [ -n "${tag}" ] || return 1
  listing="$(curl -fsSL --connect-timeout 6 --max-time 15 "${mirror}/${tag}/" 2>/dev/null || true)"
  file="$(printf '%s\n' "${listing}" | grep -oE "cpython-[0-9.]+%2B[0-9]{8}-${platform}-install_only[^\"<]*\.tar\.gz" | head -1)"
  [ -n "${file}" ] || return 1
  printf '%s/%s\n' "${tag}" "${file}"
}

probe_python_mirror() {
  local mirror="$1" canary hdr
  canary="$(python_canary_file "${mirror}")"
  [ -n "${canary}" ] || return 1
  hdr="$(curl -fsSI --connect-timeout 6 --max-time 12 "${mirror}/${canary}" 2>/dev/null || true)"
  [ -z "${hdr}" ] && return 1
  printf '%s\n' "${hdr}" | grep -qi "content-type:.*text/html" && return 1
  return 0
}

if [ -z "${UV_PYTHON_INSTALL_MIRROR:-}" ]; then
  PY_MIRROR_OK=""
  for mirror in \
    "https://mirrors.huaweicloud.com/github-release/astral-sh/python-build-standalone" \
    "https://mirror.nju.edu.cn/github-release/astral-sh/python-build-standalone"; do
    if probe_python_mirror "${mirror}"; then
      export UV_PYTHON_INSTALL_MIRROR="${mirror}"
      log_info "UV_PYTHON_INSTALL_MIRROR=${mirror} (set it yourself to override)"
      PY_MIRROR_OK=1
      break
    fi
    log_warn "Python mirror unreachable or not serving binary content: ${mirror}"
  done
  if [ -z "${PY_MIRROR_OK:-}" ]; then
    log_warn "Python download mirrors are not usable with a trusted certificate;"
    log_warn "using uv's default Python source or an existing local Python."
    log_warn "To use an internal mirror, set UV_PYTHON_INSTALL_MIRROR yourself."
    log_warn "If the proxy still rejects the mirror certificate, set"
    log_warn "  UV_INSECURE_HOST=<mirror host>   (insecure, last resort)"
  fi
fi

# ---------------------------------------------------------------------------
# Path setup helpers (defined before use)
# ---------------------------------------------------------------------------
ORIGINAL_PATH="${PATH:-}"
TOOL_BIN_DIR="$("${UV_BIN}" tool dir --bin 2>/dev/null || true)"
[ -n "${TOOL_BIN_DIR}" ] || TOOL_BIN_DIR="${HOME}/.local/bin"
PROFILE_FILE="${HOME}/.bashrc"

path_contains() {
  case ":${ORIGINAL_PATH}:" in
    *":$1:"*) return 0 ;;
    *) return 1 ;;
  esac
}

add_to_profile() {
  local profile="$1"
  local line="export PATH=\"${TOOL_BIN_DIR}:\$PATH\""
  if [ -f "${profile}" ] && grep -qF "${line}" "${profile}" 2>/dev/null; then
    return 0
  fi
  touch "${profile}" 2>/dev/null || return 1
  printf '\n# Added by the msagent installer\n%s\n' "${line}" >> "${profile}"
  log_success "Added ${TOOL_BIN_DIR} to PATH in ${profile}"
}

setup_path() {
  if [ "${MSAGENT_NO_MODIFY_PATH:-0}" = "1" ]; then
    log_warn "MSAGENT_NO_MODIFY_PATH is set; skipping PATH modification."
    log_warn "Add ${TOOL_BIN_DIR} to PATH yourself, e.g.:"
    log_warn "  export PATH=\"${TOOL_BIN_DIR}:\$PATH\""
    return 0
  fi
  if path_contains "${TOOL_BIN_DIR}"; then
    log_info "${TOOL_BIN_DIR} is already on PATH."
    return 0
  fi
  PROFILE_FILE=""
  # fish
  if command -v fish >/dev/null 2>&1 || [ -d "${HOME}/.config/fish" ]; then
    local fish_dir="${HOME}/.config/fish/conf.d"
    mkdir -p "${fish_dir}" 2>/dev/null || true
    local fish_file="${fish_dir}/msagent-path.fish"
    if [ ! -f "${fish_file}" ]; then
      printf 'fish_add_path %s\n' "${TOOL_BIN_DIR}" > "${fish_file}" 2>/dev/null || true
      log_success "Added ${TOOL_BIN_DIR} via ${fish_file}"
    fi
  fi
  # bash/zsh: cover every profile a login or interactive shell may read.
  # Only create ~/.bashrc (safe everywhere); existing ~/.bash_profile and
  # ~/.profile are updated too so login shells pick the entry up.
  local updated=0
  local candidate
  for candidate in "${HOME}/.bashrc" "${HOME}/.bash_profile" "${HOME}/.profile"; do
    if [ -f "${candidate}" ] || [ "${candidate}" = "${HOME}/.bashrc" ]; then
      if add_to_profile "${candidate}"; then
        [ -z "${PROFILE_FILE}" ] && PROFILE_FILE="${candidate}"
        updated=1
      fi
    fi
  done
  if [ -n "${SHELL:-}" ] && [[ "${SHELL}" == *zsh* ]]; then
    local zshrc="${HOME}/.zshrc"
    [ -n "${ZDOTDIR:-}" ] && zshrc="${ZDOTDIR}/.zshrc"
    if add_to_profile "${zshrc}"; then
      [ -z "${PROFILE_FILE}" ] && PROFILE_FILE="${zshrc}"
      updated=1
    fi
  fi
  if [ "${updated}" = "1" ]; then
    log_success "Run 'source ${PROFILE_FILE}' (or open a new shell) to use msagent."
  else
    log_warn "Could not update a shell profile; add '${TOOL_BIN_DIR}' to PATH yourself."
  fi
  # uv's own shell-profile updater covers more edge cases; best effort only.
  "${UV_BIN}" tool update-shell >/dev/null 2>&1 || true
  fix_owner "${TOOL_BIN_DIR}" "${HOME}/.local/share/uv" "${HOME}/.cache/uv" 2>/dev/null || true
}

# Last-resort fallback when `uv tool install` fails: an isolated venv.
install_venv_fallback() {
  local venv_dir="${MSAGENT_FALLBACK_VENV:-${HOME}/.msagent-venv}"
  local pybin=""
  if command -v python3 >/dev/null 2>&1; then pybin="python3"
  elif command -v python >/dev/null 2>&1; then pybin="python"
  else
    log_error "python3 is required for the venv fallback."
    return 1
  fi
  log_info "Creating isolated venv at ${venv_dir} ..."
  if ! "${pybin}" -m venv "${venv_dir}" 2>/dev/null; then
    # python3-venv (ensurepip) may be missing; uv can create venvs without it.
    if [ -n "${UV_BIN:-}" ] && "${UV_BIN}" venv "${venv_dir}" 2>/dev/null; then
      log_success "Created the venv with uv (python3-venv is not installed)."
    else
      log_error "Could not create a virtualenv (python3-venv may be missing)."
      log_error "On Debian/Ubuntu, install it first:  sudo apt install python3-venv"
      log_error "or retry the recommended install path:"
      log_error "  ${UV_BIN} tool install -U --python \"${MSAGENT_PYTHON}\" --default-index \"${INDEX}\" \"${INSTALL_SPEC}\""
      log_error "If you prefer the fallback manually:"
      log_error "  ${pybin} -m venv ${venv_dir} && ${venv_dir}/bin/pip install -U -i ${INDEX} ${INSTALL_SPEC}"
      return 1
    fi
  fi
  log_info "Installing ${INSTALL_SPEC} from ${INDEX} into the venv..."
  if [ -x "${venv_dir}/bin/pip" ]; then
    "${venv_dir}/bin/pip" install -q -U -i "${INDEX}" "${INSTALL_SPEC}" || return 1
  elif [ -n "${UV_BIN:-}" ]; then
    # A venv created by uv has no pip; install with uv pip instead.
    "${UV_BIN}" pip install --python "${venv_dir}/bin/python" -q -U --index-url "${INDEX}" "${INSTALL_SPEC}" || return 1
  else
    return 1
  fi
  TOOL_BIN_DIR="${venv_dir}/bin"
  setup_path
  local vout
  vout="$("${TOOL_BIN_DIR}/msagent" --version 2>&1)" || true
  log_success "Verified: ${vout}"
  log_warn "Installed via the venv fallback (${venv_dir})."
  log_warn "Prefer 'uv tool install'; re-run this installer once uv works to switch."
}

# uv sometimes only links the primary tool's executables into the tool bin
# directory. The msprof-mcp MCP server is spawned by name from PATH, so make
# sure its executable (and msprof-analyze) are reachable. Best effort only.
expose_tool_executables() {
  local tool_env_bin
  tool_env_bin="$("${UV_BIN}" tool dir 2>/dev/null || true)/mindstudio-agent/bin"
  [ -d "${tool_env_bin}" ] || return 0
  local exe
  for exe in msprof-mcp msprof-analyze; do
    if [ -x "${tool_env_bin}/${exe}" ] && [ ! -e "${TOOL_BIN_DIR}/${exe}" ]; then
      ln -s "${tool_env_bin}/${exe}" "${TOOL_BIN_DIR}/${exe}" 2>/dev/null && \
        log_success "Exposed ${exe} via ${TOOL_BIN_DIR}/${exe}"
    fi
  done
}

# ---------------------------------------------------------------------------
# Optional stage: provision a user-local Node.js (npmmirror mirror) and
# pre-install @opencxd/ascend-doc-mcp into ~/.msagent/ascend-doc-mcp. The
# msagent ascend-doc-mcp launcher then runs the pre-installed copy directly:
# no global Node/npx and no on-demand npm fetch are needed on first use.
#
#   MSAGENT_NO_ASCEND_DOC_MCP=1        skip this stage entirely
#   MSAGENT_ASCEND_DOC_MCP_REQUIRE=1   abort the installer if this stage fails
#   MSAGENT_NODE_HOME                  user-local Node root (default ~/.msagent/node)
#   MSAGENT_NPM_REGISTRY               npm registry (default npmmirror, npmjs fallback)
#   MSAGENT_NPM_CACHE                  npm cache dir (default ~/.cache/msagent/npm-cache)
#   MSAGENT_ASCEND_DOC_MCP_PREFIX      local install prefix (~/.msagent/ascend-doc-mcp)
# ---------------------------------------------------------------------------
NODE_DOWNLOAD_BASE="https://registry.npmmirror.com/-/binary/node/latest-v22.x"

node_platform_name() {
  local arch
  case "$(uname -m)" in
    x86_64|amd64) arch="x64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) return 1 ;;
  esac
  case "$(uname -s)" in
    Darwin) printf 'darwin-%s' "${arch}" ;;
    Linux) printf 'linux-%s' "${arch}" ;;
    *) return 1 ;;
  esac
}

select_npm_registry() {
  local candidate
  if [ -n "${MSAGENT_NPM_REGISTRY:-}" ]; then
    printf '%s' "${MSAGENT_NPM_REGISTRY}"
    return 0
  fi
  for candidate in "https://registry.npmmirror.com" "https://registry.npmjs.org"; do
    if probe_url "${candidate}"; then
      printf '%s' "${candidate}"
      return 0
    fi
  done
  printf '%s' "https://registry.npmmirror.com"
}

install_user_node() {
  # Downloads the newest Node 22 LTS tarball from the npmmirror mirror into
  # NODE_HOME and echoes the path to its bin directory on success.
  local platform listing names best url tmp tarball node_root
  platform="$(node_platform_name)" || return 1
  listing="$(curl -fsSL --connect-timeout 8 --max-time 25 "${NODE_DOWNLOAD_BASE}/" 2>/dev/null || true)"
  [ -n "${listing}" ] || return 1
  names="$(printf '%s\n' "${listing}" | grep -oE "node-v[0-9]+\.[0-9]+\.[0-9]+-${platform}\.tar\.xz")"
  [ -n "${names}" ] || return 1
  best="$(printf '%s\n' "${names}" | sort -V | tail -n 1)"
  url="${NODE_DOWNLOAD_BASE}/${best}"
  log_info "Downloading ${best} from the npmmirror Node mirror..."
  tmp="$(mktemp -d)"
  tarball="${tmp}/${best}"
  if ! curl -fsSL --connect-timeout 10 --max-time 600 -o "${tarball}" "${url}"; then
    rm -rf "${tmp}"
    return 1
  fi
  if ! tar -xf "${tarball}" -C "${tmp}"; then
    rm -rf "${tmp}"
    return 1
  fi
  node_root="$(find "${tmp}" -maxdepth 1 -type d -name 'node-v*' | head -n 1)"
  [ -n "${node_root}" ] || {
    rm -rf "${tmp}"
    return 1
  }
  rm -rf "${NODE_HOME}"
  mkdir -p "${NODE_HOME}"
  mv "${node_root}"/* "${NODE_HOME}/"
  rm -rf "${tmp}"
  [ -x "${NODE_HOME}/bin/node" ] || return 1
  printf '%s' "${NODE_HOME}/bin"
}

prepare_ascend_doc_mcp() {
  local node_bin_dir registry prefix cache
  if [ "${MSAGENT_NO_ASCEND_DOC_MCP:-0}" = "1" ]; then
    log_info "Skipping ascend-doc-mcp preparation (MSAGENT_NO_ASCEND_DOC_MCP=1)."
    return 0
  fi
  NODE_HOME="${MSAGENT_NODE_HOME:-${HOME}/.msagent/node}"
  node_bin_dir=""
  if [ -x "${NODE_HOME}/bin/node" ]; then
    node_bin_dir="${NODE_HOME}/bin"
  elif command -v node >/dev/null 2>&1; then
    node_bin_dir="$(dirname "$(command -v node)")"
  else
    log_info "Node.js not found; downloading a user-local copy (Node 22 LTS) from the npmmirror mirror..."
    node_bin_dir="$(install_user_node)" || {
      log_warn "Could not provision Node.js automatically. Install Node.js >= 22"
      log_warn "(https://nodejs.org) or point MSAGENT_NODE_HOME at an existing install, then re-run."
      return 1
    }
    log_success "Provisioned user-local Node at ${NODE_HOME}."
  fi
  export PATH="${node_bin_dir}:${PATH}"

  if ! command -v npm >/dev/null 2>&1 || ! command -v npx >/dev/null 2>&1; then
    log_warn "npm/npx are unavailable under ${node_bin_dir}; skipping the ascend-doc-mcp pre-install."
    return 1
  fi

  registry="$(select_npm_registry)"
  log_info "Pre-installing @opencxd/ascend-doc-mcp (registry: ${registry})..."
  prefix="${MSAGENT_ASCEND_DOC_MCP_PREFIX:-${HOME}/.msagent/ascend-doc-mcp}"
  cache="${MSAGENT_NPM_CACHE:-${HOME}/.cache/msagent/npm-cache}"
  mkdir -p "${prefix}" "${cache}"
  if ! npm install --prefix "${prefix}" --registry "${registry}" --cache "${cache}" \
        --no-audit --no-fund --no-package-lock "@opencxd/ascend-doc-mcp@latest" >/dev/null 2>&1; then
    log_warn "npm pre-install of @opencxd/ascend-doc-mcp failed (${registry}); the launcher will fetch on demand."
    return 1
  fi
  if [ ! -f "${prefix}/node_modules/@opencxd/ascend-doc-mcp/package.json" ]; then
    log_warn "ascend-doc-mcp pre-install did not produce an install under ${prefix}."
    return 1
  fi
  log_success "ascend-doc-mcp pre-installed locally at ${prefix}."
  if [ -x "${node_bin_dir}/node" ]; then
    local node_version
    node_version="$("${node_bin_dir}/node" --version 2>/dev/null || true)"
    log_info "Node version: ${node_version}"
  fi
}

# ---------------------------------------------------------------------------
# Install mindstudio-agent as an isolated uv tool (target version resolved above)
# ---------------------------------------------------------------------------
if command -v msagent >/dev/null 2>&1; then
  log_info "Updating existing msagent installation..."
else
  log_info "Installing ${INSTALL_SPEC} into an isolated uv tool environment..."
fi

UV_TOOL_ARGS=(tool install -U --python "${MSAGENT_PYTHON}" --default-index "${INDEX}")
if [ -n "${MSAGENT_WITH_EXECUTABLES_FROM:-}" ]; then
  UV_TOOL_ARGS+=(--with-executables-from "${MSAGENT_WITH_EXECUTABLES_FROM}")
fi
UV_TOOL_ARGS+=("${INSTALL_SPEC}")

INSTALL_OK=0
if "${UV_BIN}" "${UV_TOOL_ARGS[@]}"; then
  INSTALL_OK=1
fi

# Mirror sync may lag the latest weekly release; retry with official PyPI.
if [ "${INSTALL_OK}" = "0" ] && [ -z "${MSAGENT_INDEX:-}" ] && [ "${INDEX}" != "https://pypi.org/simple" ]; then
  log_warn "Install failed with ${INDEX}; retrying once with official PyPI (mirror sync may lag)..."
  UV_TOOL_ARGS=(tool install -U --python "${MSAGENT_PYTHON}" --default-index "https://pypi.org/simple")
  if [ -n "${MSAGENT_WITH_EXECUTABLES_FROM:-}" ]; then
    UV_TOOL_ARGS+=(--with-executables-from "${MSAGENT_WITH_EXECUTABLES_FROM}")
  fi
  UV_TOOL_ARGS+=("${INSTALL_SPEC}")
  if "${UV_BIN}" "${UV_TOOL_ARGS[@]}"; then
    INSTALL_OK=1
  fi
fi

if [ "${INSTALL_OK}" = "0" ]; then
  # Retry once with a freshly upgraded uv: a pre-existing uv may be old or in
  # a broken state (e.g. failing managed-Python resolution on Windows).
  log_warn "First install attempt failed; upgrading uv and retrying once..."
  RETRY_PY=""
  if command -v python3 >/dev/null 2>&1; then RETRY_PY="python3"
  elif command -v python >/dev/null 2>&1; then RETRY_PY="python"
  fi
  if [ -n "${RETRY_PY}" ]; then
    "${RETRY_PY}" -m pip install --user -q -U uv -i "${INDEX}" 2>/dev/null || \
      "${RETRY_PY}" -m pip install --user -q -U --break-system-packages uv -i "${INDEX}" 2>/dev/null || true
  fi
  [ -x "${HOME}/.local/bin/uv" ] && UV_BIN="${HOME}/.local/bin/uv"
  if "${UV_BIN}" "${UV_TOOL_ARGS[@]}"; then
    INSTALL_OK=1
  fi
fi

if [ "${INSTALL_OK}" = "0" ]; then
  # The tool may exist in a broken/stale state (e.g. its Python interpreter
  # no longer matches). Remove it and retry the install from scratch once.
  log_warn "Install still failing; removing any existing msagent tool and retrying once more..."
  "${UV_BIN}" tool uninstall mindstudio-agent >/dev/null 2>&1 || true
  if "${UV_BIN}" "${UV_TOOL_ARGS[@]}"; then
    INSTALL_OK=1
  fi
fi

if [ "${INSTALL_OK}" = "0" ]; then
  log_error "uv tool install failed. See the error above."
  if [ "${MSAGENT_NO_FALLBACK:-0}" = "1" ]; then
    log_error "MSAGENT_NO_FALLBACK is set; skipping the venv fallback."
    log_error "Retry after fixing the issue with the recommended path:"
    log_error "  ${UV_BIN} tool install -U --python \"${MSAGENT_PYTHON}\" --default-index \"${INDEX}\" \"${INSTALL_SPEC}\""
    log_error "If you need a manual fallback instead:"
    log_error "  python3 -m venv ~/.msagent-venv && ~/.msagent-venv/bin/pip install -U -i ${INDEX} ${INSTALL_SPEC}"
    exit 1
  fi
  if prompt_yn "Try the isolated venv fallback instead?"; then
    if ! install_venv_fallback; then
      log_error "The venv fallback also failed. Please retry later or open an issue at"
      log_error "  https://gitcode.com/Ascend/msagent/issues"
      exit 1
    fi
  else
    log_error "Install aborted. You can retry with:"
    log_error "  curl -LsSf https://raw.gitcode.com/Ascend/msagent/raw/master/scripts/install.sh | bash"
    exit 1
  fi
else
  # -------------------------------------------------------------------------
  # PATH: make the tool bin directory available in new shells.
  # -------------------------------------------------------------------------
  setup_path
fi

# Ensure msprof-mcp / msprof-analyze are reachable from PATH (best effort).
expose_tool_executables

# Optional: provision Node and pre-install ascend-doc-mcp so the docs MCP works
# from the first run (domestic npm/node mirrors; best-effort unless required).
if ! prepare_ascend_doc_mcp; then
  if [ "${MSAGENT_ASCEND_DOC_MCP_REQUIRE:-0}" = "1" ]; then
    log_error "ascend-doc-mcp preparation failed and MSAGENT_ASCEND_DOC_MCP_REQUIRE=1 is set."
    exit 1
  fi
  log_warn "ascend-doc-mcp preparation did not complete (non-fatal)."
  log_warn "The feature needs Node.js >= 22; install it (or set MSAGENT_NODE_HOME), then re-run."
fi

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
MSAGENT_BIN=""
if [ -x "${TOOL_BIN_DIR}/msagent" ]; then
  MSAGENT_BIN="${TOOL_BIN_DIR}/msagent"
elif command -v msagent >/dev/null 2>&1; then
  MSAGENT_BIN="msagent"
fi

if [ -z "${MSAGENT_BIN}" ]; then
  log_warn "msagent was installed but is not on PATH in this shell."
  log_warn "Run 'source ${PROFILE_FILE}' or open a new shell, then check 'msagent --version'."
  exit 0
fi

VERSION_OUTPUT="$("${MSAGENT_BIN}" --version 2>&1)" || {
  log_error "msagent installed, but '--version' failed:"
  printf '%s\n' "${VERSION_OUTPUT}" >&2
  log_error "Try: source ~/.local/bin/env   (or open a new shell), then re-run."
  exit 1
}
log_success "Verified: ${VERSION_OUTPUT}"

# The verify above uses the absolute path, which always works. The user's
# real shell may not have the tool bin dir on PATH yet (e.g. right after
# `curl ... | bash`), so check resolvability and warn with the exact fix.
PATH_MSAGENT="$(command -v msagent 2>/dev/null || true)"
if [ -z "${PATH_MSAGENT}" ]; then
  log_warn "msagent is installed, but this shell cannot find 'msagent' on PATH yet."
  log_warn "Run the following in THIS terminal (or open a new shell):"
  log_warn "  export PATH=\"${TOOL_BIN_DIR}:\$PATH\""
  log_warn "The installer already added the PATH entry to ${PROFILE_FILE:-your shell profile} for future shells."
elif [ "${PATH_MSAGENT}" != "${TOOL_BIN_DIR}/msagent" ] && [ "${PATH_MSAGENT}" != "${TOOL_BIN_DIR}/msagent.exe" ]; then
  log_warn "Note: 'msagent' on PATH resolves to ${PATH_MSAGENT} (possibly an older pip install)."
  log_warn "The uv tool install is at ${TOOL_BIN_DIR}/msagent. Consider: pip uninstall mindstudio-agent"
fi

MSPROF_BIN=""
if [ -x "${TOOL_BIN_DIR}/msprof-mcp" ]; then
  MSPROF_BIN="${TOOL_BIN_DIR}/msprof-mcp"
elif command -v msprof-mcp >/dev/null 2>&1; then
  MSPROF_BIN="msprof-mcp"
fi
if [ -z "${MSPROF_BIN}" ]; then
  log_warn "msprof-mcp is not on PATH in this shell yet; restart your shell if msagent reports it missing."
else
  log_success "msprof-mcp executable is available."
fi

log_success "msagent installation complete."
log_info "Next steps:"
log_info "  msagent --help"
log_info "  msagent config --llm-provider openai --llm-model <model> ...   (see Quick Start)"
log_info "Upgrade any time by re-running this installer (always installs the latest)."
