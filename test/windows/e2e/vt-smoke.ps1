# vt-smoke: the escape-sequence screenshot cases (test/windows/vt-smoke.ps1) against zig-out\bin\ghostty.exe
# on the WARP driver; every case with a reference PNG must match it.
# e2e: milestone=M3 timeout=600 order=700
# The script runs its own scenario (name `vt-smoke`, one sandbox, one desktop-lock hold) and
# prints the PASS/FAIL/SKIP line the runner reads. GHOSTTY_E2E_EXE selects the build, as for
# every scenario: the references do not depend on it.
$ErrorActionPreference = 'Stop'
& (Join-Path (Split-Path -Parent $PSScriptRoot) 'vt-smoke.ps1') -Driver warp
