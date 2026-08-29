<#
.SYNOPSIS
  Cross-platform mock uv for tests/install/test_install_ps1.ps1.

.DESCRIPTION
  Records every invocation (one per line) to $env:MSAGENT_TEST_UV_LOG and lets
  the test control the exit code:
    MSAGENT_TEST_UV_FAIL=1            -> always exit 1
    MSAGENT_TEST_UV_FAIL_PYPI_ONLY=1  -> exit 1 unless the args reference
                                         https://pypi.org/simple
  For `tool dir --bin` it prints $env:MSAGENT_TEST_TOOL_BIN so the installer
  resolves the tool bin directory without touching the real filesystem.
  Works under Windows PowerShell and PowerShell Core (pwsh), which lets the
  suite run on Linux CI runners too.
#>
param()

if ($env:MSAGENT_TEST_UV_LOG) {
  Add-Content -Path $env:MSAGENT_TEST_UV_LOG -Value ($args -join ' ')
}

if ($args.Count -ge 2 -and $args[0] -eq 'tool' -and $args[1] -eq 'dir') {
  Write-Output $env:MSAGENT_TEST_TOOL_BIN
}

if ($env:MSAGENT_TEST_UV_FAIL_PYPI_ONLY -eq '1') {
  if (($args -join ' ') -match 'https://pypi\.org/simple') { exit 0 } else { exit 1 }
}

if ($env:MSAGENT_TEST_UV_FAIL -eq '1') { exit 1 }
exit 0
