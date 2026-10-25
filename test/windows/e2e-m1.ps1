<#
.SYNOPSIS
Runs the M1 end-to-end scenarios (test/windows/e2e/*.ps1) against
zig-out\bin\ghostty.exe on the current desktop.

.DESCRIPTION
Each scenario is a script of its own, started in its own powershell process
(STA, for the clipboard) and prints PASS, FAIL or SKIP with its name. The
lines are also appended to %TEMP%\ghostty-e2e\results.txt, measurements to
info.txt next to it. The exit code is 1 when any scenario FAILed, otherwise
0 (SKIPs do not count).

Safety (owner's machine): every scenario runs with its own USERPROFILE,
LOCALAPPDATA, APPDATA, TEMP and XDG_CONFIG_HOME in a temporary directory;
only the Ghostty processes a scenario started are killed; keyboard layouts
added during the run are unloaded again and the original layout is
re-activated; the clipboard text is restored. A locked desktop or a session
without a foreground window SKIPs. A scenario that runs longer than its
timeout is killed with its process tree and reported as FAIL.

The scenarios send real keyboard input to the Ghostty window they started:
do not type while the run is in progress.

.PARAMETER Only
Run just these scenarios (names without .ps1).

.PARAMETER EvidenceDir
Where scenarios put PNG captures and logs of failures (frame dumps,
PrintWindow screenshots, ghostty.log). Optional.

.EXAMPLE
powershell -NoProfile -File test/windows/e2e-m1.ps1
.EXAMPLE
powershell -NoProfile -File test/windows/e2e-m1.ps1 -Only startup,render -EvidenceDir C:\tmp\evidence
#>
param(
    [string[]]$Only,
    [string]$EvidenceDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'lib\Harness.psm1') -Force

# Order matters little; the long, destructive streaming ones go last.
$all = @(
    @{ Name = 'startup'; Timeout = 120 }
    @{ Name = 'config-path'; Timeout = 90 }
    @{ Name = 'typing-us'; Timeout = 150 }
    @{ Name = 'typing-de-altgr'; Timeout = 150 }
    @{ Name = 'typing-de-deadkey'; Timeout = 150 }
    @{ Name = 'typing-ru'; Timeout = 150 }
    @{ Name = 'typing-unicode'; Timeout = 120 }
    @{ Name = 'typing-unicode-vim'; Timeout = 150 }
    @{ Name = 'ctrl-c'; Timeout = 150 }
    @{ Name = 'paste-confirm'; Timeout = 180 }
    @{ Name = 'render'; Timeout = 90 }
    @{ Name = 'resize'; Timeout = 120 }
    @{ Name = 'close-tree'; Timeout = 120 }
    @{ Name = 'shell-exit'; Timeout = 120 }
    @{ Name = 'vim-less'; Timeout = 180 }
    @{ Name = 'close-while-streaming'; Timeout = 150 }
    @{ Name = 'resize-while-streaming'; Timeout = 420 }
)
if ($Only) {
    # `powershell -File` hands over `a,b` as one string.
    $Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
    $unknown = @($Only | Where-Object { $n = $_; -not ($all | Where-Object { $_.Name -eq $n }) })
    if ($unknown.Count) { throw "unknown scenario(s): $($unknown -join ', ')" }
    $all = @($all | Where-Object { $Only -contains $_.Name })
}

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$exe = Join-Path $root 'zig-out\bin\ghostty.exe'
if (-not (Test-Path $exe)) { throw "missing $exe (run zig build first)" }

$temp = Join-Path $env:TEMP 'ghostty-e2e'
New-Item -ItemType Directory -Force -Path $temp | Out-Null
$results = Join-Path $temp 'results.txt'
$info = Join-Path $temp 'info.txt'
Remove-Item -LiteralPath $results, $info -ErrorAction SilentlyContinue

$runRoot = Join-Path $temp ('run-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
$logDir = Join-Path $runRoot '_logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

# Another session may be running GUI tests on this desktop: take turns
# through %TEMP%\gui-e2e.lock (owner name and time), waiting up to 30 minutes.
$lock = Join-Path $env:TEMP 'gui-e2e.lock'
$waited = [Diagnostics.Stopwatch]::StartNew()
while ((Test-Path $lock) -and ((Get-Item $lock).LastWriteTime -gt (Get-Date).AddHours(-2))) {
    if ($waited.Elapsed.TotalMinutes -gt 30) { throw "$lock is still held: $(Get-Content $lock -Raw)" }
    Write-Host "INFO waiting for $lock ($((Get-Content $lock -Raw).Trim()))"
    Start-Sleep -Seconds 15
}
Set-Content -LiteralPath $lock -Value "e2e-m1.ps1 $(Get-Date -Format s)" -Encoding ASCII

$env:GHOSTTY_E2E_RUNROOT = $runRoot
if ($EvidenceDir) {
    New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
    $env:GHOSTTY_E2E_EVIDENCE = (Resolve-Path $EvidenceDir).Path
}

$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$failed = 0
$lines = @()

# Whatever a killed scenario left behind in the keyboard layout list.
Save-KeyboardLayouts
try {
    foreach ($s in $all) {
        $name = $s.Name
        $script_ = Join-Path $PSScriptRoot "e2e\$name.ps1"
        if (-not (Test-Path $script_)) { throw "missing scenario script $script_" }

        $stdout = Join-Path $logDir "$name.out.txt"
        $stderr = Join-Path $logDir "$name.err.txt"

        # A scenario that fails is started once more: input-driven checks
        # share the desktop with the owner, who can take the foreground or
        # the keyboard layout at any moment. A bug fails twice; one that
        # passes the second time is reported as flaky, not hidden (info.txt).
        # Interference is retried up to twice. The long streaming scenarios
        # are not repeated.
        $once = @('close-while-streaming', 'resize-while-streaming') -contains $name
        $interference = 'lost the foreground|not typeable on the foreground layout|keyboard layout did not change|could not take the foreground'
        $earlier = @()
        $line = $null
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            $p = Start-Process -FilePath $powershell -PassThru -NoNewWindow `
                -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $script_) `
                -RedirectStandardOutput $stdout -RedirectStandardError $stderr

            $line = $null
            $timedOut = $false
            if (-not $p.WaitForExit($s.Timeout * 1000)) {
                # Kills the scenario and everything it started, Ghostty included.
                & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null
                $line = "FAIL ${name}: timed out after $($s.Timeout) s (scenario killed)"
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
            # Another window kept the foreground: a SKIP, but worth another go.
            $noFocus = $line -like 'SKIP*could not take the foreground*'
            if (($line -notlike 'FAIL*' -and -not $noFocus) -or $timedOut) { break }
            $earlier += $line
            $maxAttempts = if ($noFocus -or $line -match $interference) { 3 } elseif ($once) { 1 } else { 2 }
            if ($attempt -ge $maxAttempts) { break }
            Write-Host "INFO ${name}: attempt $attempt did not complete, trying again: $line"
            if ($noFocus) { Start-Sleep -Seconds 10 }
        }
        # A genuine failure is not erased by a later attempt that could not
        # even start for lack of the foreground.
        if ($line -like 'SKIP*') {
            $real = @($earlier | Where-Object { $_ -like 'FAIL*' -and $_ -notmatch $interference })
            if ($real.Count -gt 0) { $line = $real[-1] }
        }
        if ($earlier.Count -gt 0) {
            $note = if ($line -like 'PASS*') { "FLAKY ${name}: passed after $($earlier.Count) failed attempt(s): $($earlier -join ' | ')" }
                    else { "NOTE ${name}: failed on $($earlier.Count) attempt(s): $($earlier -join ' | ')" }
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
    Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\GHOSTTY_E2E_RUNROOT, Env:\GHOSTTY_E2E_EVIDENCE -ErrorAction SilentlyContinue
}

$pass = @($lines | Where-Object { $_ -like 'PASS*' }).Count
$skip = @($lines | Where-Object { $_ -like 'SKIP*' }).Count
Write-Output ("e2e-m1: {0} passed, {1} failed, {2} skipped of {3}" -f $pass, $failed, $skip, $lines.Count)
if ($failed -gt 0) { exit 1 }
exit 0
