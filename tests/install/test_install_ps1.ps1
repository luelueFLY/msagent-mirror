<#
.SYNOPSIS
  Functional tests for scripts/install.ps1 using a cross-platform mock uv
  (fake_uv.ps1).

.DESCRIPTION
  Guards the installer's decision logic (index priority, version
  pinning/announcement, PyPI fallback retry, NO_MODIFY_PATH escape hatch,
  static parse) without performing a real package install. A real-install
  smoke test lives in smoke_install.sh.
  Works under Windows PowerShell and PowerShell Core (pwsh), so it can run on
  Linux CI runners too (the nested installer is launched with the current
  interpreter).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File tests/install/test_install_ps1.ps1
  pwsh -NoProfile -File tests/install/test_install_ps1.ps1

  Exit code 0 = all checks passed.
#>

$ErrorActionPreference = 'Stop'
$script:Pass = 0
$script:Fail = 0
$script:Skip = 0

function Write-Ok([string]$msg)   { Write-Host "  [PASS] $msg"; $script:Pass++ }
function Write-Ko([string]$msg)   { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:Fail++ }
function Write-Skip([string]$msg) { Write-Host "  [SKIP] $msg"; $script:Skip++ }

$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:Installer = Join-Path $RepoRoot 'scripts\install.ps1'
$script:FakeUv = Join-Path $PSScriptRoot 'fake_uv.ps1'
$script:ShellExe = (Get-Process -Id $PID).Path

# ---------------------------------------------------------------------------
# 1. Static checks
# ---------------------------------------------------------------------------
Write-Host '== Static checks =='
$parseErrors = $null
$parseTokens = $null
[System.Management.Automation.Language.Parser]::ParseFile($script:Installer, [ref]$parseTokens, [ref]$parseErrors) | Out-Null
if ($parseErrors.Count -eq 0) { Write-Ok 'PowerShell AST parse' } else { Write-Ko 'PowerShell AST parse' }

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
function Start-IsolatedInstaller {
  param([string]$OutLog, [hashtable]$ExtraEnv)
  $script:TestHome = Join-Path $env:TEMP ("msagent-installer-test-" + [guid]::NewGuid().ToString('N'))
  $script:TestBin = Join-Path $TestHome 'bin'
  New-Item -ItemType Directory -Path $TestBin -Force | Out-Null
  $script:UvLog = Join-Path $TestHome 'uv-args.log'
  $env:MSAGENT_YES = '1'
  $env:MSAGENT_NO_MODIFY_PATH = '1'
  $env:MSAGENT_TEST_UV_LOG = $script:UvLog
  $env:MSAGENT_TEST_TOOL_BIN = $script:TestBin
  # Put the fake uv first on PATH so Get-Command uv finds it.
  $env:PATH = $script:TestHome + [IO.Path]::PathSeparator + $env:PATH
  Copy-Item $script:FakeUv (Join-Path $TestHome 'uv.ps1') -Force
  foreach ($k in $ExtraEnv.Keys) { Set-Item -Path ("Env:" + $k) -Value $ExtraEnv[$k] }
  & $script:ShellExe -NoProfile -ExecutionPolicy Bypass -File $script:Installer *>&1 | Out-File -FilePath $OutLog -Encoding utf8
}

function Stop-IsolatedInstaller {
  Remove-Item -Recurse -Force $script:TestHome -ErrorAction SilentlyContinue
  Remove-Item Env:MSAGENT_YES, Env:MSAGENT_NO_MODIFY_PATH, Env:MSAGENT_TEST_UV_LOG, Env:MSAGENT_TEST_TOOL_BIN, Env:MSAGENT_VERSION, Env:MSAGENT_INDEX, Env:MSAGENT_TEST_UV_FAIL, Env:MSAGENT_TEST_UV_FAIL_PYPI_ONLY -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# 2. Deterministic logic: MSAGENT_VERSION pin + MSAGENT_INDEX passthrough
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '== Scenario: MSAGENT_VERSION + MSAGENT_INDEX passthrough =='
$out = Join-Path $env:TEMP ("msagent-out-" + [guid]::NewGuid().ToString('N') + '.log')
Start-IsolatedInstaller -OutLog $out -ExtraEnv @{ MSAGENT_VERSION = '1.2.3'; MSAGENT_INDEX = 'https://example.invalid/simple' }
$outText = Get-Content $out -Raw
$uvArgs = Get-Content $script:UvLog -Raw -ErrorAction SilentlyContinue
if ($outText -match 'Will install msagent 1\.2\.3 \(MSAGENT_VERSION\)') { Write-Ok 'announces pinned version at start' } else { Write-Ko 'announces pinned version at start' }
if ($uvArgs -match '--default-index https://example\.invalid/simple') { Write-Ok 'passes MSAGENT_INDEX through' } else { Write-Ko 'passes MSAGENT_INDEX through' }
if ($uvArgs -match 'mindstudio-agent==1\.2\.3') { Write-Ok 'uses pinned spec' } else { Write-Ko 'uses pinned spec' }
if ($uvArgs -match '--python >=3\.11') { Write-Ok 'uses >=3.11 python request' } else { Write-Ko 'uses >=3.11 python request' }
if ($outText -match 'MSAGENT_NO_MODIFY_PATH') { Write-Ok 'honors MSAGENT_NO_MODIFY_PATH' } else { Write-Ko 'honors MSAGENT_NO_MODIFY_PATH' }
Stop-IsolatedInstaller

# ---------------------------------------------------------------------------
# 3. PyPI fallback retry (auto index chain; requires huaweicloud reachable)
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '== Scenario: PyPI fallback retry when mirror install fails =='
$hwReachable = $false
try {
  Invoke-WebRequest -Uri 'https://mirrors.huaweicloud.com/repository/pypi/simple/pip/' -Method Head -UseBasicParsing -TimeoutSec 8 | Out-Null
  $hwReachable = $true
} catch { }
if ($hwReachable) {
  $out = Join-Path $env:TEMP ("msagent-out-" + [guid]::NewGuid().ToString('N') + '.log')
  Start-IsolatedInstaller -OutLog $out -ExtraEnv @{ MSAGENT_TEST_UV_FAIL_PYPI_ONLY = '1' }
  $outText = Get-Content $out -Raw
  $uvArgs = Get-Content $script:UvLog -Raw -ErrorAction SilentlyContinue
  if ($outText -match 'retrying once with official PyPI') { Write-Ok 'fallback retry triggered' } else { Write-Ko 'fallback retry triggered' }
  if ($uvArgs -match 'https://pypi\.org/simple') { Write-Ok 'retry uses official PyPI' } else { Write-Ko 'retry uses official PyPI' }
  if ($outText -match 'Will install msagent') { Write-Ok 'announces target version' } else { Write-Ko 'announces target version' }
  Stop-IsolatedInstaller
} else {
  Write-Skip 'huaweicloud mirror unreachable in this environment'
}

# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '== Summary =='
Write-Host ("passed={0} failed={1} skipped={2}" -f $script:Pass, $script:Fail, $script:Skip)
if ($script:Fail -gt 0) { exit 1 }
exit 0
