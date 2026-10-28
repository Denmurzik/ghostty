<#
.SYNOPSIS
Runs the end-to-end scenarios (test/windows/e2e/*.ps1) against
zig-out\bin\ghostty.exe on the current desktop.

.DESCRIPTION
The scenarios are discovered: every test/windows/e2e/*.ps1 whose name does not
start with `_` carries a header in its leading comment block,

    # e2e: milestone=M1 timeout=150 order=30 [surfaces=N]

and runs in `order` (ascending). The whole run holds the desktop lock
%TEMP%\gui-e2e.lock (test/windows/README.md): a desktop that stays busy for
30 minutes SKIPs every scenario (exit 2; the SKIP lines are also written to
results.txt). `surfaces` > 4 makes the runner require 2.5 GB of free RAM (SKIP
otherwise) and, for a Debug exe, run that scenario under the team's test-lock,
the separate build/RAM lock (GHOSTTY_TEST_LOCK, default the team lock script);
the test-lock's wait is added to the timeout.

Each scenario is a script of its own, started in its own powershell process
(STA, for the clipboard) and prints PASS, FAIL or SKIP with its name. The
lines are also appended to %TEMP%\ghostty-e2e\results.txt, measurements to
info.txt next to it. Exit code: 1 when any scenario FAILed; 2 when nothing
FAILed but nothing PASSed either (every scenario SKIPped); otherwise 0.

Safety (owner's machine): every scenario runs with its own USERPROFILE,
LOCALAPPDATA, APPDATA, TEMP and XDG_CONFIG_HOME in a temporary directory;
only the Ghostty processes a scenario started are killed; keyboard layouts
added during the run are unloaded again and the original layout is
re-activated; the clipboard text is restored. A locked desktop or a session
without a foreground window SKIPs. A scenario that runs longer than its
timeout is killed with its process tree and reported as FAIL.

The scenarios send real keyboard input to the Ghostty window they started:
do not type while the run is in progress.

.PARAMETER Milestone
M1, M2, M3, M4, M5, M6 or all (default): which scenarios the headers select.

.PARAMETER Only
Run just these scenarios (names without .ps1).

.PARAMETER EvidenceDir
Where scenarios put PNG captures and logs of failures (frame dumps,
PrintWindow screenshots, ghostty.log). Optional.

.EXAMPLE
powershell -NoProfile -File test/windows/e2e.ps1 -Milestone M1
.EXAMPLE
powershell -NoProfile -File test/windows/e2e.ps1 -Only startup,render -EvidenceDir C:\tmp\evidence
#>
param(
    [ValidateSet('M1', 'M2', 'M3', 'M4', 'M5', 'M6', 'all')][string]$Milestone = 'all',
    [string[]]$Only,
    [string]$EvidenceDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# An elevated Ghostty ignores the test hive (diagnosticEnv is off for an
# elevated token), so the Explorer CLI scenarios would write and delete the
# owner's real HKCU. Refuse before anything starts.
if ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'e2e.ps1 refuses to run elevated: an elevated Ghostty would use the real HKCU instead of the test hive. Start a normal (non-admin) PowerShell.'
}

Import-Module (Join-Path $PSScriptRoot 'lib\Harness.psm1') -Force

# Discovery: the header sits in the leading comment block of each script.
$all = @()
foreach ($f in Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'e2e') -Filter '*.ps1' | Where-Object { $_.Name -notlike '_*' }) {
    $header = $null
    foreach ($l in Get-Content -LiteralPath $f.FullName -TotalCount 20) {
        if ($l -match '^#\s*e2e:\s*(.+)$') { $header = $Matches[1]; break }
        if ($l.Trim() -and $l -notmatch '^#') { break }
    }
    if (-not $header) { throw "scenario $($f.Name) has no '# e2e: milestone=.. timeout=.. order=..' header" }
    $kv = @{}
    foreach ($m in [regex]::Matches($header, '(\w+)=(\S+)')) { $kv[$m.Groups[1].Value] = $m.Groups[2].Value }
    foreach ($k in 'milestone', 'timeout', 'order') {
        if (-not $kv.ContainsKey($k)) { throw "scenario $($f.Name): header lacks $k=" }
    }
    $all += [pscustomobject]@{
        Name      = $f.BaseName
        Milestone = $kv['milestone']
        Timeout   = [int]$kv['timeout']
        Order     = [int]$kv['order']
        Surfaces  = $(if ($kv.ContainsKey('surfaces')) { [int]$kv['surfaces'] } else { 1 })
    }
}
if ($Only) {
    # `powershell -File` hands over `a,b` as one string.
    $Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
    $unknown = @($Only | Where-Object { $n = $_; -not ($all | Where-Object { $_.Name -eq $n }) })
    if ($unknown.Count) { throw "unknown scenario(s): $($unknown -join ', ')" }
    $all = @($all | Where-Object { $Only -contains $_.Name })
} elseif ($Milestone -ne 'all') {
    $all = @($all | Where-Object { $_.Milestone -eq $Milestone })
}
$all = @($all | Sort-Object Order, Name)

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$exe = Join-Path $root 'zig-out\bin\ghostty.exe'
if ($env:GHOSTTY_E2E_EXE) {
    if (-not (Test-Path -LiteralPath $env:GHOSTTY_E2E_EXE)) { throw "missing GHOSTTY_E2E_EXE=$env:GHOSTTY_E2E_EXE" }
} elseif (-not (Test-Path $exe)) { throw "missing $exe (run zig build first)" }

$temp = Join-Path $env:TEMP 'ghostty-e2e'
New-Item -ItemType Directory -Force -Path $temp | Out-Null
$results = Join-Path $temp 'results.txt'
$info = Join-Path $temp 'info.txt'
Remove-Item -LiteralPath $results, $info -ErrorAction SilentlyContinue

$runRoot = Join-Path $temp ('run-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
$logDir = Join-Path $runRoot '_logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$env:GHOSTTY_E2E_RUNROOT = $runRoot
if ($EvidenceDir) {
    New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
    $env:GHOSTTY_E2E_EVIDENCE = (Resolve-Path $EvidenceDir).Path
}

$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# Scenarios with many surfaces on a Debug exe run under the shared test-lock
# (the team's RAM gate). Release builds (zig-out-rf) are small enough not to.
$testLock = if ($env:GHOSTTY_TEST_LOCK) { $env:GHOSTTY_TEST_LOCK } else { (Join-Path $env:USERPROFILE '.claude/mods/teamlead/skills/teamlead/scripts/test-lock') }
$bashExe = $null
foreach ($c in "$env:ProgramFiles\Git\bin\bash.exe", "$env:ProgramFiles\Git\usr\bin\bash.exe") {
    if (Test-Path -LiteralPath $c) { $bashExe = $c; break }
}
$exeUnderTest = if ($env:GHOSTTY_E2E_EXE) { $env:GHOSTTY_E2E_EXE } else { $exe }
$isDebugExe = $exeUnderTest -notmatch 'zig-out-rf|zig-out\\rfs|ReleaseFast|ReleaseSafe|ReleaseSmall'
$failed = 0
$lines = @()

# Scenarios that change the clipboard keep a DPAPI-protected copy of it in
# %TEMP%\ghostty-e2e\clipboard-backup.bin plus the clipboard sequence number
# after their own last write (clipboard-backup.seq). A scenario that ends
# without restoring (killed, timed out) leaves both; after every scenario,
# and for a crashed earlier run at the start, the runner puts the clipboard
# back only while its sequence number still equals that mark. A changed
# number means the owner copied something since: nothing is overwritten and
# the backup is dropped. When the restore fails the backup is kept.
$clipBackup = Join-Path $temp 'clipboard-backup.bin'
$clipMark = Join-Path $temp 'clipboard-backup.seq'
$clipModule = Join-Path $PSScriptRoot 'lib\Clipboard.psm1'
function Restore-ClipboardBackup {
    if (-not (Test-Path $clipBackup)) { return }
    $code = @'
Import-Module $env:E2E_CLIP_MODULE -Force
$r = Restore-ClipboardBackupFile $env:E2E_CLIP_FILE $env:E2E_CLIP_MARK
switch ($r) { 'restored' { exit 0 } 'changed' { exit 2 } default { exit 1 } }
'@
    $env:E2E_CLIP_FILE = $clipBackup
    $env:E2E_CLIP_MARK = $clipMark
    $env:E2E_CLIP_MODULE = $clipModule
    & $powershell -NoProfile -STA -ExecutionPolicy Bypass -Command $code 2>&1 | Out-Null
    $rc = $LASTEXITCODE
    Remove-Item Env:\E2E_CLIP_FILE, Env:\E2E_CLIP_MARK, Env:\E2E_CLIP_MODULE -ErrorAction SilentlyContinue
    if ($rc -eq 0) { Write-Host 'INFO clipboard restored from a backup' }
    elseif ($rc -eq 2) { Write-Host 'INFO clipboard changed since the backup; backup dropped, clipboard left alone' }
    else { Write-Host "WARN could not restore the clipboard; the backup is kept in $clipBackup" }
}

# Another session may be running GUI tests on this desktop: take turns through
# %TEMP%\gui-e2e.lock (see README.md). Acquired right before the try whose
# finally releases it; the scenarios inherit it through GHOSTTY_E2E_LOCK_ID.
# A desktop that stays busy is not a failure of the product: SKIP (exit 2).
# The scenarios' timeouts only start after this.
try {
    $lockToken = Enter-GuiLock -Owner 'e2e.ps1' -TimeoutMinutes 30
} catch {
    if ($_.Exception.Message -notlike 'GUI lock * still held*') { throw }
    $busy = @(foreach ($s in $all) { "SKIP $($s.Name): $($_.Exception.Message)" })
    $busy | ForEach-Object { Write-Output $_ }
    [IO.File]::WriteAllLines($results, [string[]]$busy, (New-Object Text.UTF8Encoding $false))
    Write-Output "e2e: PASS 0, FAIL 0, SKIP $($all.Count) (desktop lock busy)"
    exit 2
}
try {
    $env:GHOSTTY_E2E_LOCK_ID = $lockToken.Id
    # Whatever a killed scenario left behind in the keyboard layout list.
    Save-KeyboardLayouts
    # A backup from a crashed earlier run, before any scenario of this one.
    Restore-ClipboardBackup
    foreach ($s in $all) {
        $name = $s.Name
        Update-GuiLock $lockToken
        $script_ = Join-Path $PSScriptRoot "e2e\$name.ps1"
        if (-not (Test-Path $script_)) { throw "missing scenario script $script_" }

        $stdout = Join-Path $logDir "$name.out.txt"
        $stderr = Join-Path $logDir "$name.err.txt"

        $timeout = $s.Timeout
        $launcher = $powershell
        $psArgs = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $script_)
        if ($s.Surfaces -gt 4) {
            $skipReason = $null
            try { Assert-FreeRam 2.5 } catch {
                if ($_.Exception.Message -notlike 'E2E-SKIP:*') { throw }
                $skipReason = $_.Exception.Message.Substring('E2E-SKIP:'.Length).Trim()
            }
            if ($skipReason) {
                $line = "SKIP ${name}: $skipReason"
                Write-Output $line
                $lines += $line
                continue
            }
            if ($isDebugExe -and $bashExe -and (Test-Path -LiteralPath $testLock)) {
                $launcher = $bashExe
                $psArgs = @($testLock, '--', ($powershell -replace '\\', '/'), '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', ('"' + ($script_ -replace '\\', '/') + '"'))
                # The lock may make the scenario wait for another test run.
                $timeout += 600
            } elseif ($isDebugExe) {
                Write-Host "WARN ${name}: test-lock not available, running without it"
            }
        }

        # Only interference from the desktop (the owner or another session
        # taking the foreground or the keyboard layout) is retried, up to
        # twice. Any other FAIL is final on the first attempt: an
        # intermittent product failure must not turn into a PASS. A scenario
        # that passes after interference is reported as FLAKY.
        $interference = 'lost the foreground|not typeable on the foreground layout|keyboard layout did not change|could not take the foreground'
        $earlier = @()
        $line = $null
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            $p = Start-Process -FilePath $launcher -PassThru -NoNewWindow `
                -ArgumentList $psArgs `
                -RedirectStandardOutput $stdout -RedirectStandardError $stderr

            $line = $null
            $timedOut = $false
            if (-not $p.WaitForExit($timeout * 1000)) {
                # Kills the scenario and everything it started, Ghostty included.
                & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null
                $line = "FAIL ${name}: timed out after $timeout s (scenario killed)"
                $timedOut = $true
            }
            $text = if (Test-Path $stdout) { Get-Content -LiteralPath $stdout -Encoding UTF8 } else { @() }
            foreach ($t in @($text)) {
                if ($t -match "^(PASS|FAIL|SKIP) $([regex]::Escape($name))(:|\s|$)") { if (-not $line) { $line = $t } }
                elseif ($t -match '^INFO ') { Write-Host $t }
            }
            if (-not $line) {
                $err = if (Test-Path $stderr) { (Get-Content -LiteralPath $stderr -Raw -Encoding UTF8) } else { '' }
                $line = "FAIL ${name}: no result (exit code $($p.ExitCode)): $("$err".Trim() -replace '\s+', ' ')"
            }
            # A killed scenario never ran its clipboard restore.
            Restore-ClipboardBackup

            $noFocus = $line -like 'SKIP*could not take the foreground*'
            $interfered = ($line -like 'FAIL*' -and $line -match $interference) -or $noFocus
            if (-not $interfered -or $timedOut) { break }
            $earlier += $line
            if ($attempt -ge 3) { break }
            Write-Host "INFO ${name}: attempt $attempt hit desktop interference, trying again: $line"
            Start-Sleep -Seconds 10
        }
        if ($earlier.Count -gt 0) {
            $note = "${name}: interference on $($earlier.Count) attempt(s): $($earlier -join ' | ')"
            if ($line -like 'PASS*') {
                $line = "FLAKY ${name}: passed after desktop interference: $($earlier -join ' | ')"
            }
            Write-Host "INFO $note"
            Add-Content -Path $info -Value "INFO $note" -Encoding UTF8
        }
        Write-Output $line
        $lines += $line
        if ($line -like 'FAIL*') { $failed++ }
    }
} finally {
    Restore-KeyboardLayouts
    # The scenarios append their own lines (one per attempt, with a BOM
    # from Windows PowerShell); results.txt keeps the final line of each.
    [IO.File]::WriteAllLines($results, [string[]]$lines, (New-Object Text.UTF8Encoding $false))
    if (Test-Path $info) {
        [IO.File]::WriteAllLines($info, [string[]]@(Get-Content -LiteralPath $info -Encoding UTF8), (New-Object Text.UTF8Encoding $false))
    }
    if ($EvidenceDir) {
        foreach ($f in $results, $info) {
            if (Test-Path $f) { Copy-Item -LiteralPath $f -Destination $EvidenceDir -Force }
        }
    }
    Exit-GuiLock $lockToken
    Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\GHOSTTY_E2E_RUNROOT, Env:\GHOSTTY_E2E_EVIDENCE, Env:\GHOSTTY_E2E_LOCK_ID -ErrorAction SilentlyContinue
}

$pass = @($lines | Where-Object { $_ -like 'PASS*' }).Count
$skip = @($lines | Where-Object { $_ -like 'SKIP*' }).Count
$flaky = @($lines | Where-Object { $_ -like 'FLAKY*' }).Count
Write-Output ("e2e: PASS {0}, FAIL {1}, SKIP {2}, FLAKY {3} (of {4}; FLAKY = passed after desktop interference)" -f $pass, $failed, $skip, $flaky, $lines.Count)
if ($failed -gt 0) { exit 1 }
# Nothing failed, but nothing passed either (every scenario SKIPped).
if ($pass + $flaky -eq 0) { exit 2 }
exit 0
