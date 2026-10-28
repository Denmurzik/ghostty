# e2e: milestone=M5 timeout=90 order=965
# explorer-cli: `+install-explorer-integration --dry-run` prints exactly the
# nine writes and opens no key; install then uninstall against a private
# application hive (GHOSTTY_WIN32_TEST_HIVE) exit 0; the owner's real
# HKCU\Software\Classes\...\GhosttyOpenHere keys are never touched (read-only
# `reg query` before and after gives the same answer); the sandbox keeps no
# hive files at the end. No window.
. (Join-Path $PSScriptRoot '_common.ps1')

function Invoke-ExplorerCli([string[]]$CliArgs, [hashtable]$Env = @{}) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new($script:Exe)
    $psi.Arguments = $CliArgs -join ' '  # no argument here contains a space
    $psi.WorkingDirectory = $script:Root
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables['LOCALAPPDATA'] = $script:Sbx.Local
    $psi.EnvironmentVariables['APPDATA'] = $script:Sbx.Roaming
    $psi.EnvironmentVariables['USERPROFILE'] = $script:Sbx.Home
    $psi.EnvironmentVariables.Remove('GHOSTTY_WIN32_TEST_HIVE')
    [void]$psi.EnvironmentVariables.Remove("GHOSTTY_WIN32_TEST_IPC")
    foreach ($k in $Env.Keys) { $psi.EnvironmentVariables[$k] = $Env[$k] }
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(20000)) { try { $p.Kill() } catch {}; throw "ghostty $($CliArgs -join ' ') did not exit within 20 s" }
    [pscustomobject]@{ Code = $p.ExitCode; Stdout = $out.Result; Stderr = $err.Result }
}

function Get-RealKeyState {
    $r = @()
    foreach ($k in 'Directory\shell', 'Directory\Background\shell', 'Drive\shell') {
        $eap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $out = & reg.exe query "HKCU\Software\Classes\$k\GhosttyOpenHere" 2>&1 | Out-String
        $code = $LASTEXITCODE
        $ErrorActionPreference = $eap
        $r += "$k=$code=$out"
    }
    $r -join "`n"
}

Invoke-E2eScenario 'explorer-cli' {
    $exe = (Resolve-Path -LiteralPath $script:Exe).Path
    $before = Get-RealKeyState

    $v = '"' + $exe + '"'
    $cmd = $v + ' "--working-directory=%V\."'
    $icon = $exe + ',0'
    $head = 'set Software\Classes\'
    $want = @()
    foreach ($k in 'Directory\shell\GhosttyOpenHere', 'Directory\Background\shell\GhosttyOpenHere', 'Drive\shell\GhosttyOpenHere') {
        $want += "$head$k\command\(default) = $cmd"
        $want += "$head$k\(default) = Open Ghostty here"
        $want += "$head$k\Icon = $icon"
    }

    function Split-Lines([string]$s) { @($s -split "`r?`n" | Where-Object { $_ }) }
    function Assert-Lines($Got, $Want, [string]$What) {
        $g = @(Split-Lines $Got)
        if ($g.Count -ne $Want.Count) { throw "$What : $($g.Count) lines, wanted $($Want.Count):`n$Got" }
        for ($i = 0; $i -lt $g.Count; $i++) {
            if ($g[$i] -ne $Want[$i]) { throw "$What line $($i + 1):`n  got  $($g[$i])`n  want $($Want[$i])" }
        }
    }

    # Dry run: the nine lines, exit 0, and a hive variable would be ignored (nothing is opened).
    $bogus = Join-Path $script:Sbx.Tmp 'no\such\dir\x.hive'
    $r = Invoke-ExplorerCli @('+install-explorer-integration', '--dry-run') @{ GHOSTTY_WIN32_TEST_HIVE = $bogus }
    if ($r.Code -ne 0) { throw "install --dry-run exited $($r.Code): $($r.Stderr)" }
    Assert-Lines $r.Stdout $want 'install --dry-run'

    $r = Invoke-ExplorerCli @('+uninstall-explorer-integration', '--dry-run', '--all')
    if ($r.Code -ne 0) { throw "uninstall --dry-run --all exited $($r.Code): $($r.Stderr)" }
    $lines = @(Split-Lines $r.Stdout)
    if ($lines.Count -ne 7) { throw "uninstall --dry-run --all printed $($lines.Count) lines:`n$($r.Stdout)" }
    foreach ($l in $lines) { if (-not $l.StartsWith('delete ')) { throw "not a delete line: $l" } }
    $iconPath = Join-Path (Join-Path $script:Sbx.Local 'ghostty') 'toast-icon.png'
    if ($lines[5] -ne "delete $iconPath") { throw "last line is '$($lines[5])', wanted 'delete $iconPath'" }

    # --only-this-exe dry run: three "if its command names <exe>" lines, then the AUMID/icon lines.
    $r = Invoke-ExplorerCli @('+uninstall-explorer-integration', '--dry-run', '--all', '--only-this-exe')
    if ($r.Code -ne 0) { throw "uninstall --dry-run --all --only-this-exe exited $($r.Code): $($r.Stderr)" }
    $lines = @(Split-Lines $r.Stdout)
    if ($lines.Count -ne 7) { throw "uninstall --dry-run --only-this-exe printed $($lines.Count) lines:`n$($r.Stdout)" }
    foreach ($i in 0..2) {
        if ($lines[$i] -notmatch ([regex]::Escape(" if its command names $exe") + '$')) { throw "line $($i + 1) lacks the exe condition: $($lines[$i])" }
    }

    # Private hive: install, then uninstall; both exit 0.
    $hive = Join-Path $script:Sbx.Tmp 'x.hive'
    $env_ = @{ GHOSTTY_WIN32_TEST_HIVE = $hive; GHOSTTY_WIN32_TEST_IPC = '1' }
    $r = Invoke-ExplorerCli @('+install-explorer-integration') $env_
    if ($r.Code -ne 0) { throw "install in the hive exited $($r.Code): $($r.Stdout) $($r.Stderr)" }
    Assert-Lines $r.Stdout $want 'install (hive)'
    if ($r.Stderr -notmatch 'using test hive') { throw "stderr does not announce the test hive: $($r.Stderr)" }
    $r = Invoke-ExplorerCli @('+uninstall-explorer-integration', '--all') $env_
    if ($r.Code -ne 0) { throw "uninstall in the hive exited $($r.Code): $($r.Stdout) $($r.Stderr)" }
    $lines = @(Split-Lines $r.Stdout)
    $dels = @($lines | Where-Object { $_.StartsWith('delete ') })
    if ($dels.Count -ne 7) { throw "uninstall --all (hive) printed:`n$($r.Stdout)" }

    # A second uninstall on the now empty hive reports, and still exits 0.
    $r = Invoke-ExplorerCli @('+uninstall-explorer-integration') $env_
    if ($r.Code -ne 0) { throw "second uninstall exited $($r.Code): $($r.Stdout) $($r.Stderr)" }
    if ($r.Stdout -notmatch 'not installed') { throw "second uninstall did not report 'not installed':`n$($r.Stdout)" }

    # The real registry is as it was.
    $after = Get-RealKeyState
    if ($after -ne $before) { throw "HKCU\Software\Classes GhosttyOpenHere state changed:`nbefore:`n$before`nafter:`n$after" }

    # The hive files go with the sandbox: delete them here and prove it.
    $gone = Wait-Until -TimeoutSec 10 -PollMs 200 -Condition {
        Get-ChildItem -LiteralPath $script:Sbx.Tmp -Filter '*.hive*' -Force -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
        -not (Get-ChildItem -LiteralPath $script:Sbx.Tmp -Filter '*.hive*' -Force -ErrorAction SilentlyContinue)
    }
    if (-not $gone) { throw 'hive files are still in the sandbox' }
    Write-E2eInfo 'dry-run output exact; hive install/uninstall exit 0; real keys unchanged'
}
