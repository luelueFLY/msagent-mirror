<#
.SYNOPSIS
  msAgent installer for Windows (PowerShell 5.1+).

.DESCRIPTION
  Installs mindstudio-agent (latest from PyPI) as an isolated uv tool, so it
  will not conflict with any existing Python environment. Bootstraps uv when
  missing, prefers domestic PyPI mirrors, and adds the tool bin directory to
  the user PATH.

.EXAMPLE
  irm https://raw.gitcode.com/Ascend/msagent/raw/master/scripts/install.ps1 | iex

.EXAMPLE
  $env:MSAGENT_VERSION = '26.1.0'
  irm https://raw.gitcode.com/Ascend/msagent/raw/master/scripts/install.ps1 | iex

.NOTES
  Optional env:
    MSAGENT_VERSION           exact version to install (default: latest from PyPI)
    MSAGENT_PYTHON            Python request for the isolated tool env (default: >=3.11, reuses local Python)
    MSAGENT_INDEX             PyPI index override (default: official PyPI, domestic mirrors as fallback)
    MSAGENT_NO_MODIFY_PATH    set to a non-empty value to skip PATH modification
    MSAGENT_YES               set to '1' to accept prompts without asking
    MSAGENT_NO_FALLBACK       set to '1' to disable the venv fallback
    MSAGENT_FALLBACK_VENV     venv path used by the fallback install (default: %USERPROFILE%\.msagent-venv)
    MSAGENT_NO_ASCEND_DOC_MCP  set to any value to skip Node provisioning and the ascend-doc-mcp pre-install
    MSAGENT_ASCEND_DOC_MCP_REQUIRE  abort install when Node/ascend-doc-mcp prep fails
    MSAGENT_NODE_HOME          user-local Node root (default: %USERPROFILE%\.msagent\node)
    MSAGENT_NPM_REGISTRY       npm registry for the ascend-doc-mcp pre-install (default: npmmirror, npmjs fallback)
    MSAGENT_NPM_CACHE          npm cache directory
    MSAGENT_ASCEND_DOC_MCP_PREFIX  local ascend-doc-mcp install prefix (default: %USERPROFILE%\.msagent\ascend-doc-mcp)
    UV_DEFAULT_INDEX / UV_INDEX_URL / PIP_INDEX_URL   used as a last-resort fallback
    UV_PYTHON_INSTALL_MIRROR  mirror for managed CPython downloads (domestic candidates validated for real binary content)
    UV_NATIVE_TLS             use the system certificate store for uv (default: 1, set 0 to disable)

  Uninstall:
    uv tool uninstall mindstudio-agent

  Upgrade:
    Re-run the installer; it always upgrades to the latest release.
#>

$ErrorActionPreference = 'Stop'

# PowerShell 5.1 on older Windows may not negotiate TLS 1.2 by default.
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
  # TLS 1.2 is already the default on newer systems; ignore failures here.
}

function Write-Step([string]$msg)    { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Success([string]$msg) { Write-Host "OK  $msg" -ForegroundColor Green }
function Write-Warn([string]$msg)    { Write-Host "WARN $msg" -ForegroundColor Yellow }
function Die([string]$msg)           { Write-Host "error: $msg" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
$pipCheck = Get-Command pip -ErrorAction SilentlyContinue
if ($pipCheck) {
  # Note: with $ErrorActionPreference='Stop', PowerShell 5.1 turns redirected
  # native stderr into a terminating NativeCommandError, so guard this probe.
  $pipHasMsagent = $false
  try {
    & pip show mindstudio-agent 2>$null | Out-Null
    $pipHasMsagent = ($LASTEXITCODE -eq 0)
  } catch {
    $pipHasMsagent = $false
  }
  if ($pipHasMsagent) {
    Write-Warn "mindstudio-agent is already installed via pip in this environment."
    Write-Warn "The uv tool install below is isolated and will not modify it, but the"
    Write-Warn "two executables may shadow each other on PATH. Consider: pip uninstall mindstudio-agent"
  }
}

# ---------------------------------------------------------------------------
# Index selection: explicit overrides first, then a domestic mirror chain.
# ---------------------------------------------------------------------------
function Test-Url([string]$url) {
  try {
    Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -TimeoutSec 8 | Out-Null
    return $true
  } catch { }
  try {
    Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 8 | Out-Null
    return $true
  } catch { }
  return $false
}

function Select-Index {
  # Domestic mirrors first (fast in China), official PyPI as fallback,
  # generic env vars as last resort. Mirror sync may lag weekly releases,
  # so the install is retried with official PyPI on failure (see below),
  # and the latest version is pinned from PyPI beforehand.
  if ($env:MSAGENT_INDEX) {
    $script:MsagentIndex = $env:MSAGENT_INDEX
    Write-Step "Using index from MSAGENT_INDEX: $script:MsagentIndex"
    return
  }
  $candidates = @(
    'https://mirrors.huaweicloud.com/repository/pypi/simple',
    'https://mirrors.aliyun.com/pypi/simple',
    'https://pypi.tuna.tsinghua.edu.cn/simple',
    'https://pypi.org/simple'
  )
  foreach ($c in $candidates) {
    if (Test-Url ($c + '/pip/')) {
      $script:MsagentIndex = $c
      Write-Step "Selected PyPI index: $c"
      return
    }
    Write-Warn "Index unreachable: $c (trying the next candidate)"
  }
  # All candidates are unreachable; fall back to a user-configured
  # generic index if one exists, otherwise use official PyPI.
  if ($env:UV_DEFAULT_INDEX) {
    $script:MsagentIndex = $env:UV_DEFAULT_INDEX
    Write-Step "Fallback to UV_DEFAULT_INDEX: $script:MsagentIndex"
    return
  }
  if ($env:UV_INDEX_URL) {
    $script:MsagentIndex = $env:UV_INDEX_URL
    Write-Step "Fallback to UV_INDEX_URL: $script:MsagentIndex"
    return
  }
  if ($env:PIP_INDEX_URL) {
    $script:MsagentIndex = $env:PIP_INDEX_URL
    Write-Step "Fallback to PIP_INDEX_URL: $script:MsagentIndex"
    return
  }
  $script:MsagentIndex = 'https://pypi.org/simple'
  Write-Warn "No reachable index found; defaulting to $script:MsagentIndex."
}
Select-Index

# ---------------------------------------------------------------------------
# Resolve and announce the msagent version to install. Mirror sync may lag
# weekly releases, so the latest version is pinned straight from PyPI and
# shown up front; the install is retried with official PyPI if the selected
# mirror does not have that version yet.
# ---------------------------------------------------------------------------
$script:MsagentSpec = 'mindstudio-agent'
$versionSource = 'latest from the selected index'
if ($env:MSAGENT_VERSION) {
  $script:MsagentSpec = 'mindstudio-agent==' + $env:MSAGENT_VERSION
  $versionSource = 'MSAGENT_VERSION'
} elseif (-not $env:MSAGENT_INDEX) {
  try {
    $latestVersion = (Invoke-RestMethod -Uri 'https://pypi.org/pypi/mindstudio-agent/json' -UseBasicParsing -TimeoutSec 15).info.version
    if ($latestVersion) {
      $script:MsagentSpec = 'mindstudio-agent==' + $latestVersion
      $versionSource = 'latest from PyPI'
    }
  } catch {
    # PyPI unreachable; keep the unpinned spec (mirror will serve what it has).
  }
}
Write-Step ("Will install msagent " + $script:MsagentSpec.Replace('mindstudio-agent==', '') + " ($versionSource)")

# ---------------------------------------------------------------------------
# uv bootstrap: existing uv, official installer, then pip as fallback.
# ---------------------------------------------------------------------------
$script:UvType = $null          # 'bin' or 'module'
$script:UvPath = $null
$script:UvModulePrefix = $null

function Invoke-Uv {
  param([string[]]$UvArgs)
  # Native stderr redirects become terminating errors under 'Stop' in
  # PowerShell 5.1; run native calls with 'Continue' and check exit codes.
  $oldPref = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    if ($script:UvType -eq 'bin') {
      & $script:UvPath @UvArgs
    } else {
      $head = $script:UvModulePrefix[0]
      $tail = @($script:UvModulePrefix[1..($script:UvModulePrefix.Count - 1)])
      & $head @tail @UvArgs
    }
  } finally {
    $ErrorActionPreference = $oldPref
  }
}

function Get-Uv {
  $cmd = Get-Command uv -ErrorAction SilentlyContinue
  if ($cmd) {
    $script:UvType = 'bin'
    $script:UvPath = $cmd.Source
    return
  }
  $fixed = Join-Path $env:USERPROFILE '.local\bin\uv.exe'
  if (Test-Path $fixed) {
    $script:UvType = 'bin'
    $script:UvPath = $fixed
    return
  }

  Write-Step 'uv is not installed. Bootstrapping uv...'
  try {
    Invoke-RestMethod -Uri 'https://astral.sh/uv/install.ps1' -UseBasicParsing -TimeoutSec 60 | Invoke-Expression
  } catch {
    Write-Warn ('Official uv installer failed: ' + $_.Exception.Message)
  }
  if (Test-Path $fixed) {
    $script:UvType = 'bin'
    $script:UvPath = $fixed
    return
  }
  $cmd = Get-Command uv -ErrorAction SilentlyContinue
  if ($cmd) {
    $script:UvType = 'bin'
    $script:UvPath = $cmd.Source
    return
  }

  Write-Warn "Official uv installer failed or timed out; trying pip + $script:MsagentIndex ..."
  $py = Get-Command py -ErrorAction SilentlyContinue
  if ($py) {
    $script:UvModulePrefix = @('py', '-3', '-m', 'uv')
    & py -3 -m pip install -q -U uv -i $script:MsagentIndex
    if ($LASTEXITCODE -ne 0) {
      Die "uv could not be installed. Install it manually (irm https://astral.sh/uv/install.ps1 | iex), then re-run this installer."
    }
  } else {
    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) {
      Die 'python is required to bootstrap uv via pip. Install Python 3.11+, or install uv manually, then re-run.'
    }
    $script:UvModulePrefix = @('python', '-m', 'uv')
    & python -m pip install -q -U uv -i $script:MsagentIndex
    if ($LASTEXITCODE -ne 0) {
      Die "uv could not be installed. Install it manually (irm https://astral.sh/uv/install.ps1 | iex), then re-run this installer."
    }
  }
  # Prefer the uv.exe binary if pip put it somewhere discoverable.
  $scripted = Get-ChildItem (Join-Path $env:APPDATA 'Python\Python*\Scripts\uv.exe') -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($scripted) {
    $script:UvType = 'bin'
    $script:UvPath = $scripted.FullName
  } else {
    $script:UvType = 'module'
  }
}
Get-Uv

# ---------------------------------------------------------------------------
# Use the platform's native TLS store (Windows Schannel / system CA bundle).
# Corporate proxies re-sign HTTPS with their own CA: system tools trust it,
# but uv's bundled roots reject it with "UnknownIssuer". Only an explicitly
# set UV_NATIVE_TLS wins.
# ---------------------------------------------------------------------------
if (-not $env:UV_NATIVE_TLS) {
  $env:UV_NATIVE_TLS = '1'
  Write-Step 'UV_NATIVE_TLS=1 (use the system certificate store for uv)'
}

# ---------------------------------------------------------------------------
# Managed CPython downloads: try Huawei Cloud first, then NJU, but only when
# the mirror actually serves real binary content with a trusted certificate
# (some public github-release mirrors answer HTML with HTTP 200, and corporate
# proxies may reject certificates). Otherwise leave uv's defaults (official
# source or an existing local Python) to handle it.
# ---------------------------------------------------------------------------
function Get-PythonCanary([string]$mirror) {
  # Discover one real python-build-standalone file from the mirror's own
  # directory listing (newest tag) so no tag/version is hardcoded.
  $platform = if ($env:PROCESSOR_ARCHITECTURE -match 'ARM64|ARM') { 'aarch64-pc-windows-msvc' } else { 'x86_64-pc-windows-msvc' }
  try {
    $top = (Invoke-WebRequest -Uri ($mirror + '/') -UseBasicParsing -TimeoutSec 15).Content
    $tags = @([regex]::Matches($top, '[0-9]{8}/') | ForEach-Object { $_.Value.TrimEnd('/') })
    if ($tags.Count -eq 0) { return $null }
    $tag = $tags[$tags.Count - 1]
    $dir = (Invoke-WebRequest -Uri ($mirror + '/' + $tag + '/') -UseBasicParsing -TimeoutSec 15).Content
    $pattern = 'cpython-[0-9.]+%2B[0-9]{8}-' + $platform + '-install_only[^"<]*\.tar\.gz'
    $file = [regex]::Match($dir, $pattern).Value
    if (-not $file) { return $null }
    return ($tag + '/' + $file)
  } catch {
    return $null
  }
}

function Test-PythonMirror([string]$mirror) {
  $canary = Get-PythonCanary $mirror
  if (-not $canary) { return $false }
  try {
    $resp = Invoke-WebRequest -Uri ($mirror + '/' + $canary) -Method Head -UseBasicParsing -TimeoutSec 12
    if ($resp.StatusCode -eq 200 -and $resp.Headers['Content-Type'] -notmatch 'text/html') {
      return $true
    }
  } catch { }
  return $false
}

if (-not $env:UV_PYTHON_INSTALL_MIRROR) {
  $pyMirrorOk = $false
  foreach ($mirror in @(
    'https://mirrors.huaweicloud.com/github-release/astral-sh/python-build-standalone',
    'https://mirror.nju.edu.cn/github-release/astral-sh/python-build-standalone'
  )) {
    if (Test-PythonMirror $mirror) {
      $env:UV_PYTHON_INSTALL_MIRROR = $mirror
      Write-Step "UV_PYTHON_INSTALL_MIRROR=$env:UV_PYTHON_INSTALL_MIRROR (set it yourself to override)"
      $pyMirrorOk = $true
      break
    }
    Write-Warn "Python mirror unreachable or not serving binary content: $mirror"
  }
  if (-not $pyMirrorOk) {
    Write-Warn 'Python download mirrors are not usable with a trusted certificate;'
    Write-Warn "using uv's default Python source or an existing local Python."
    Write-Warn 'To use an internal mirror, set UV_PYTHON_INSTALL_MIRROR yourself.'
    Write-Warn 'If the proxy still rejects the mirror certificate, set'
    Write-Warn '  UV_INSECURE_HOST=<mirror host>   (insecure, last resort)'
  }
}

# ---------------------------------------------------------------------------
# PATH helper
# ---------------------------------------------------------------------------
function Add-ToUserPath([string]$dir) {
  if ($env:MSAGENT_NO_MODIFY_PATH) {
    Write-Warn "Skipping PATH update (MSAGENT_NO_MODIFY_PATH set). Add $dir to PATH yourself."
    return
  }
  $current = [Environment]::GetEnvironmentVariable('Path', 'User')
  if (-not $current) {
    [Environment]::SetEnvironmentVariable('Path', $dir, 'User')
    Write-Success "Added $dir to the user PATH (open a new terminal to use msagent)."
    return
  }
  $parts = @($current.Split(';') | Where-Object { $_ -ne '' })
  if ($parts -contains $dir) {
    Write-Step "$dir is already on the user PATH."
    return
  }
  # Prepend so the freshly installed msagent wins over older pip installs.
  [Environment]::SetEnvironmentVariable('Path', ($dir + ';' + $current.TrimStart(';')), 'User')
  Write-Success "Added $dir to the user PATH (prepended; open a new terminal to use msagent)."
}

function Get-ToolBinDir {
  $out = Invoke-Uv @('tool', 'dir', '--bin') 2>$null
  $line = $out | Select-Object -Last 1
  if ($line) {
    return $line.Trim()
  }
  return (Join-Path $env:USERPROFILE '.local\bin')
}

# ---------------------------------------------------------------------------
# venv fallback (last resort when uv tool install fails)
# ---------------------------------------------------------------------------
function Invoke-VenvFallback {
  $venvDir = if ($env:MSAGENT_FALLBACK_VENV) { $env:MSAGENT_FALLBACK_VENV } else { Join-Path $env:USERPROFILE '.msagent-venv' }
  $py = Get-Command py -ErrorAction SilentlyContinue
  if (-not $py) {
    Write-Warn 'py launcher not found; cannot create the fallback venv.'
    return $false
  }
  Write-Step "Creating isolated venv at $venvDir ..."
  if (-not (Test-Path $venvDir)) {
    & py -3.11 -m venv $venvDir
    if ($LASTEXITCODE -ne 0) {
      & py -3 -m venv $venvDir
    }
    if ($LASTEXITCODE -ne 0) {
      Write-Warn 'Could not create the fallback venv.'
      return $false
    }
  }
  $pip = Join-Path $venvDir 'Scripts\pip.exe'
  if (-not (Test-Path $pip)) {
    Write-Warn 'pip not found inside the fallback venv.'
    return $false
  }
  Write-Step "Installing $script:MsagentSpec from $script:MsagentIndex into the venv..."
  & $pip install -q -U -i $script:MsagentIndex $script:MsagentSpec
  if ($LASTEXITCODE -ne 0) {
    Write-Warn 'The venv fallback install failed.'
    return $false
  }
  $script:ToolBin = Join-Path $venvDir 'Scripts'
  Add-ToUserPath $script:ToolBin
  return $true
}

# uv sometimes only links the primary tool's executables into the tool bin
# directory. The msprof-mcp MCP server is spawned by name from PATH, so make
# sure its executable (and msprof-analyze) are reachable. Best effort only:
# create a small .cmd shim that forwards to the real executable in the tool env.
function Expose-ToolExecutables {
  if (-not $script:ToolBin) { return }
  $toolsRoot = Invoke-Uv @('tool', 'dir') 2>$null | Select-Object -Last 1
  if (-not $toolsRoot) { $toolsRoot = Join-Path $env:USERPROFILE '.local\share\uv\tools' }
  $envBin = Join-Path $toolsRoot.Trim() 'mindstudio-agent\Scripts'
  if (-not (Test-Path $envBin)) { return }
  foreach ($exe in @('msprof-mcp', 'msprof-analyze')) {
    $real = Join-Path $envBin "$exe.exe"
    if (Test-Path $real) {
      $shim = Join-Path $script:ToolBin "$exe.cmd"
      if (-not (Test-Path $shim)) {
        "@echo off`r`n`"$real`" %*" | Set-Content -Path $shim -Encoding Ascii
        Write-Success "Exposed $exe via $shim"
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Optional stage: provision a user-local Node.js (npmmirror mirror) and
# pre-install @opencxd/ascend-doc-mcp into %USERPROFILE%\.msagent\ascend-doc-mcp.
# The msagent ascend-doc-mcp launcher then runs the pre-installed copy directly,
# so no global Node/npx and no on-demand npm fetch are needed on first use.
#
#   MSAGENT_NO_ASCEND_DOC_MCP=1        skip this stage entirely
#   MSAGENT_ASCEND_DOC_MCP_REQUIRE=1   abort the installer if this stage fails
#   MSAGENT_NODE_HOME                  user-local Node root (default %USERPROFILE%\.msagent\node)
#   MSAGENT_NPM_REGISTRY               npm registry (default npmmirror, npmjs fallback)
#   MSAGENT_NPM_CACHE                  npm cache dir
#   MSAGENT_ASCEND_DOC_MCP_PREFIX      local install prefix (%USERPROFILE%\.msagent\ascend-doc-mcp)
# ---------------------------------------------------------------------------
function Select-NpmRegistry {
  if ($env:MSAGENT_NPM_REGISTRY) { return $env:MSAGENT_NPM_REGISTRY }
  foreach ($candidate in @('https://registry.npmmirror.com', 'https://registry.npmjs.org')) {
    if (Test-Url $candidate) { return $candidate }
  }
  return 'https://registry.npmmirror.com'
}

function Install-UserNode {
  # Downloads the newest Node 22 LTS win-x64 zip from the npmmirror mirror
  # into the user-local Node home and returns its path on success.
  $nodeHome = $script:MsagentNodeHome
  $platform = if ([Environment]::Is64BitOperatingSystem) { 'win-x64' } else { 'win-x86' }
  $base = 'https://registry.npmmirror.com/-/binary/node/latest-v22.x/'
  try {
    $listing = (Invoke-WebRequest -Uri $base -UseBasicParsing -TimeoutSec 25).Content
  } catch {
    return $null
  }
  $rx = [regex]::new('node-v(\d+\.\d+\.\d+)-' + $platform + '\.zip')
  $best = $null
  $bestVersion = $null
  foreach ($match in $rx.Matches($listing)) {
    $version = [version]::new($match.Groups[1].Value)
    if (-not $bestVersion -or $version -gt $bestVersion) {
      $bestVersion = $version
      $best = $match.Groups[0].Value
    }
  }
  if (-not $best) { return $null }
  $url = $base + $best
  Write-Step "Downloading $best from the npmmirror Node mirror..."
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("msagent-node-" + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tmp | Out-Null
  $zip = Join-Path $tmp $best
  try {
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -TimeoutSec 600
    Expand-Archive -Path $zip -DestinationPath $tmp
    $nodeRoot = Get-ChildItem -Path $tmp -Directory -Filter 'node-v*' | Select-Object -First 1
    if (-not $nodeRoot) { throw 'node archive did not contain a node-v* directory' }
    if (Test-Path $nodeHome) { Remove-Item -Recurse -Force $nodeHome }
    New-Item -ItemType Directory -Path $nodeHome | Out-Null
    Get-ChildItem -Path $nodeRoot.FullName | Move-Item -Destination $nodeHome
  } catch {
    Write-Warn "Node download failed: $($_.Exception.Message)"
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    return $null
  }
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  if (-not (Test-Path (Join-Path $nodeHome 'node.exe'))) { return $null }
  return $nodeHome
}

function Prepare-AscendDocMcp {
  if ($env:MSAGENT_NO_ASCEND_DOC_MCP) {
    Write-Step 'Skipping ascend-doc-mcp preparation (MSAGENT_NO_ASCEND_DOC_MCP is set).'
    return $true
  }
  $script:MsagentNodeHome = if ($env:MSAGENT_NODE_HOME) { $env:MSAGENT_NODE_HOME } else { Join-Path $HOME '.msagent\node' }
  $nodeHome = $script:MsagentNodeHome
  $nodeBinDir = $null
  $nodeExe = Join-Path $nodeHome 'node.exe'
  if (Test-Path $nodeExe) {
    $nodeBinDir = $nodeHome
  } else {
    $systemNode = Get-Command node -ErrorAction SilentlyContinue
    if ($systemNode) { $nodeBinDir = Split-Path $systemNode.Source -Parent }
  }
  if (-not $nodeBinDir) {
    Write-Step 'Node.js not found; downloading a user-local copy (Node 22 LTS) from the npmmirror mirror...'
    $nodeHome = Install-UserNode
    if (-not $nodeHome) {
      Write-Warn 'Could not provision Node.js automatically. Install Node.js >= 22 from https://nodejs.org and re-run, or set MSAGENT_NODE_HOME.'
      return $false
    }
    $nodeBinDir = $nodeHome
    Write-Success "Provisioned user-local Node at $nodeHome."
  }
  if ($env:PATH -notlike "*$nodeBinDir*") {
    $env:PATH = $nodeBinDir + [IO.Path]::PathSeparator + $env:PATH
  }
  # Prefer npm.cmd: PowerShell may otherwise resolve 'npm' to npm.ps1, which
  # the machine ExecutionPolicy can block. npm.cmd runs through cmd.exe and is
  # independent of the PowerShell ExecutionPolicy.
  $npmCmd = Join-Path $nodeBinDir 'npm.cmd'
  if (-not (Test-Path -LiteralPath $npmCmd)) {
    $npmFromPath = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if ($npmFromPath) { $npmCmd = $npmFromPath.Source }
  }
  if (-not $npmCmd -or -not (Test-Path -LiteralPath $npmCmd)) {
    Write-Warn 'npm.cmd is unavailable in the provisioned Node; skipping the ascend-doc-mcp pre-install.'
    return $false
  }
  $registry = Select-NpmRegistry
  Write-Step "Pre-installing @opencxd/ascend-doc-mcp (registry: $registry)..."
  $prefix = if ($env:MSAGENT_ASCEND_DOC_MCP_PREFIX) { $env:MSAGENT_ASCEND_DOC_MCP_PREFIX } else { Join-Path $HOME '.msagent\ascend-doc-mcp' }
  $cache = if ($env:MSAGENT_NPM_CACHE) { $env:MSAGENT_NPM_CACHE } else { Join-Path $HOME '.cache\msagent\npm-cache' }
  New-Item -ItemType Directory -Force -Path $prefix, $cache | Out-Null
  # npm writes notices/warnings to stderr. Under $ErrorActionPreference='Stop'
  # those become terminating NativeCommandError records, so temporarily relax
  # EAP and merge stderr into the pipeline before discarding it.
  $npmExitCode = $null
  $previousEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & $npmCmd install --prefix $prefix --registry $registry --cache $cache --no-audit --no-fund --no-package-lock '@opencxd/ascend-doc-mcp@latest' 2>&1 | Out-Null
    $npmExitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $previousEap
  }
  if ($npmExitCode -ne 0) {
    Write-Warn "npm pre-install of @opencxd/ascend-doc-mcp failed (exit $npmExitCode, $registry); the launcher will fetch on demand."
    return $false
  }
  if (-not (Test-Path (Join-Path $prefix 'node_modules\@opencxd\ascend-doc-mcp\package.json'))) {
    Write-Warn "ascend-doc-mcp pre-install did not produce an install under $prefix."
    return $false
  }
  Write-Success "ascend-doc-mcp pre-installed locally at $prefix."
  if (Test-Path $nodeExe) {
    $nodeVersion = & (Join-Path $nodeHome 'node.exe') --version
    Write-Step "Node version: $nodeVersion"
  }
  return $true
}

# ---------------------------------------------------------------------------
# Install mindstudio-agent as an isolated uv tool (always latest, no version pin)
# ---------------------------------------------------------------------------
# Prefer any existing local Python >= 3.11 so a managed CPython is only
# downloaded when needed (downloads may fail on restricted networks).
# Set MSAGENT_PYTHON to pin an exact version, e.g. "3.11".
$pythonVersion = if ($env:MSAGENT_PYTHON) { $env:MSAGENT_PYTHON } else { '>=3.11' }

if (Get-Command msagent -ErrorAction SilentlyContinue) {
  Write-Step 'Updating existing msagent installation...'
} else {
  Write-Step "Installing $script:MsagentSpec into an isolated uv tool environment..."
}

$installArgs = @('tool', 'install', '-U', '--python', $pythonVersion, '--default-index', $script:MsagentIndex)
$withExe = if ($env:MSAGENT_WITH_EXECUTABLES_FROM) { $env:MSAGENT_WITH_EXECUTABLES_FROM } else { 'msprof-mcp' }
$installArgs += @('--with-executables-from', $withExe)
$installArgs += $script:MsagentSpec

Invoke-Uv $installArgs
$installOk = ($LASTEXITCODE -eq 0)

# Mirror sync may lag the latest weekly release; retry with official PyPI.
if (-not $installOk -and -not $env:MSAGENT_INDEX -and $script:MsagentIndex -ne 'https://pypi.org/simple') {
  Write-Warn "Install failed with $script:MsagentIndex; retrying once with official PyPI (mirror sync may lag)..."
  $installArgs = @('tool', 'install', '-U', '--python', $pythonVersion, '--default-index', 'https://pypi.org/simple')
  $installArgs += @('--with-executables-from', $withExe)
  $installArgs += $script:MsagentSpec
  Invoke-Uv $installArgs
  $installOk = ($LASTEXITCODE -eq 0)
}

if (-not $installOk) {
  # Retry once with a freshly upgraded uv: a pre-existing uv may be old or in
  # a broken state (e.g. failing managed-Python resolution on Windows).
  Write-Warn 'First install attempt failed; upgrading uv and retrying once...'
  $retryRunner = $null
  $pyRetry = Get-Command py -ErrorAction SilentlyContinue
  if ($pyRetry) {
    & py -3 -m pip install -q -U uv -i $script:MsagentIndex | Out-Null
    $retryRunner = @('py', '-3', '-m', 'uv')
  } else {
    $pythonRetry = Get-Command python -ErrorAction SilentlyContinue
    if ($pythonRetry) {
      & python -m pip install -q -U uv -i $script:MsagentIndex | Out-Null
      $retryRunner = @('python', '-m', 'uv')
    }
  }
  if ($retryRunner) {
    $script:UvType = 'module'
    $script:UvModulePrefix = $retryRunner
    Invoke-Uv $installArgs
    $installOk = ($LASTEXITCODE -eq 0)
  }
}

if (-not $installOk) {
  # The tool may exist in a broken/stale state (e.g. its Python interpreter
  # no longer matches). Remove it and retry the install from scratch once.
  Write-Warn 'Install still failing; removing any existing msagent tool and retrying once more...'
  Invoke-Uv @('tool', 'uninstall', 'mindstudio-agent') | Out-Null
  Invoke-Uv $installArgs
  $installOk = ($LASTEXITCODE -eq 0)
}

if (-not $installOk) {
  Write-Host 'error: uv tool install failed. See the output above.' -ForegroundColor Red
  if ($env:MSAGENT_NO_FALLBACK) {
    Die "MSAGENT_NO_FALLBACK is set; skipping the venv fallback. Retry after fixing the issue, or install manually into a venv."
  }
  $useFallback = if ($env:MSAGENT_YES -eq '1') { $true } else { $false }
  if (-not $useFallback) {
    $answer = Read-Host 'Try the isolated venv fallback instead? [y/N]'
    $useFallback = ($answer -match '^(y|yes)$')
  }
  if ($useFallback) {
    if (-not (Invoke-VenvFallback)) {
      Die 'The venv fallback also failed. Please retry later or open an issue at https://gitcode.com/Ascend/msagent/issues'
    }
  } else {
    Die 'Install aborted. You can retry with: irm https://raw.gitcode.com/Ascend/msagent/raw/master/scripts/install.ps1 | iex'
  }
} else {
  $script:ToolBin = Get-ToolBinDir
  Add-ToUserPath $script:ToolBin
}
if (-not $script:ToolBin) { $script:ToolBin = Get-ToolBinDir }
Expose-ToolExecutables

# Optional: provision Node and pre-install ascend-doc-mcp so the docs MCP works
# from the first run (domestic npm/node mirrors; best-effort unless required).
if (-not (Prepare-AscendDocMcp)) {
  if ($env:MSAGENT_ASCEND_DOC_MCP_REQUIRE) {
    Die 'ascend-doc-mcp preparation failed and MSAGENT_ASCEND_DOC_MCP_REQUIRE is set.'
  }
  Write-Warn 'ascend-doc-mcp preparation did not complete (non-fatal).'
  Write-Warn 'The feature needs Node.js >= 22; install it (or set MSAGENT_NODE_HOME), then re-run.'
}

# Make msagent available in the current session immediately (the user-level
# PATH change only affects newly started processes).
if ($env:PATH -notlike "*$script:ToolBin*") {
  $env:PATH = $script:ToolBin + [IO.Path]::PathSeparator + $env:PATH
  Write-Step "Updated PATH in this session; 'msagent' is ready now."
} else {
  Write-Step "'msagent' is already resolvable in this session."
}

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
$msagentExe = Join-Path $script:ToolBin 'msagent.exe'
if (Test-Path $msagentExe) {
  & $msagentExe --version
  if ($LASTEXITCODE -ne 0) {
    Die "msagent installed, but '--version' failed. Open a new terminal and re-run, or check your PATH."
  }
} elseif (Get-Command msagent -ErrorAction SilentlyContinue) {
  & msagent --version
  if ($LASTEXITCODE -ne 0) {
    Die "msagent installed, but '--version' failed. Open a new terminal and re-run, or check your PATH."
  }
} else {
  Write-Warn "msagent was installed but is not on PATH in this shell. Open a new terminal and run 'msagent --version'."
}

# Warn when an older pip-installed msagent shadows the uv tool on PATH.
$shadowMsagent = Get-Command msagent -ErrorAction SilentlyContinue
if ($shadowMsagent -and $shadowMsagent.Source -and $shadowMsagent.Source -ne $msagentExe) {
  Write-Warn "Note: 'msagent' on PATH resolves to $($shadowMsagent.Source) (possibly an older pip install)."
  Write-Warn "The uv tool install is at $msagentExe. Consider: pip uninstall mindstudio-agent"
}

$mcpExe = Join-Path $script:ToolBin 'msprof-mcp.exe'
$mcpShim = Join-Path $script:ToolBin 'msprof-mcp.cmd'
if ((Test-Path $mcpExe) -or (Test-Path $mcpShim)) {
  Write-Success 'msprof-mcp executable is available.'
} else {
  Write-Warn 'msprof-mcp is not on PATH in this shell yet; restart your shell if msagent reports it missing.'
}

Write-Success 'msagent installation complete.'
Write-Step 'Next steps:'
Write-Step '  msagent --help'
Write-Step '  msagent config --llm-provider openai --llm-model <model> ...   (see Quick Start)'
Write-Step 'Upgrade any time by re-running this installer (always installs the latest).'
Write-Step "If 'msagent' is still not found (e.g. in cmd), open a new window or run: set PATH=$script:ToolBin;%PATH%"
