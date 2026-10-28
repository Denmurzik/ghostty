<#
.SYNOPSIS
RAM and latency rows of the tmux shim (M4 Task 15, Steps 1 and 2). ASCII only.

.DESCRIPTION
Starts a fresh Ghostty (ReleaseFast by default, Git Bash, sandboxed like every
e2e scenario, GHOSTTY_WIN32_TEST_IPC=1) through the e2e harness and measures:

  team-ram   ghostty.exe Private Bytes (the budgeted number) at three points
             of an agent-team layout driven by the real tmux.exe with fake
             teammates: `before` (one surface, 10 s idle), `team` (leader +
             2 respawned teammates in main-vertical, 30 s after the last
             respawn) and `killed30s` (both killed, 30 s idle). Also the
             private bytes of the `tmux.exe __idle` placeholder that a
             `split-window -- cat` starts.
  tmux-exe   peak private of tmux.exe (GHOSTTY_TMUX_STATS=1) for
             `display-message` and for `load-buffer -` with the 512 KiB stdin
             cap, over 20 runs each.
  latency    wall time of tmux.exe (process start to exit) over 50 runs of
             `display-message -p '#{pane_id}'`, `split-window -d -P -F
             '#{pane_id}' -- cat` and `respawn-pane -k` (a fake teammate),
             from a maximised window. Every new pane is killed and the state
             must drop back to one pane before the next run.

Rows: always to %TEMP%\ghostty-tmux-measure\rows.csv; with -Record also to
docs\windows\ram-baseline.csv (columns date,commit,optimize,adapter,scenario,
private_mb,ws_mb) and docs\windows\latency-baseline.csv (columns date,commit,
optimize,adapter,refresh_hz,conpty,variant,scenario,stage,p50_ms,p95_ms,
max_ms,n). Budgeted numbers come from a ReleaseFast build.

.PARAMETER Part
team-ram | tmux-exe | latency | all (default).

.PARAMETER Exe
The ghostty.exe to measure (default zig-out-rf\bin\ghostty.exe; tmux.exe is
the one next to it).

.PARAMETER Runs
Fresh Ghostty runs of team-ram (default 3: the median is the gated value).
#>
param(
    [ValidateSet('team-ram', 'tmux-exe', 'latency', 'all')][string]$Part = 'all',
    [string]$Exe,
    [int]$Runs = 3,
    [switch]$Record
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $Exe) { $Exe = Join-Path $repo 'zig-out-rf\bin\ghostty.exe' }
$env:GHOSTTY_E2E_EXE = (Resolve-Path -LiteralPath $Exe).Path
$optimize = if ($env:GHOSTTY_E2E_EXE -like '*zig-out-rf*') { 'ReleaseFast' } else { 'Debug' }
$e2eDir = Join-Path $PSScriptRoot 'e2e'
. (Join-Path $e2eDir '_common.ps1')
. (Join-Path $e2eDir '_tmux.ps1')
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture

$outDir = Join-Path $env:TEMP 'ghostty-tmux-measure'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$rows = Join-Path $outDir 'rows.csv'
$commit = (& git -C $repo rev-parse --short HEAD 2>$null)
if (-not $commit) { $commit = 'unknown' } elseif (& git -C $repo status --porcelain 2>$null) { $commit += '-dirty' }
$today = Get-Date -Format 'yyyy-MM-dd'
$ramCsv = Join-Path $repo 'docs\windows\ram-baseline.csv'
$latCsv = Join-Path $repo 'docs\windows\latency-baseline.csv'

function Add-RamRow([string]$Adapter, [string]$Scenario, [double]$PrivateMb, [string]$WsMb) {
    Add-RowLine "$today,$commit,$optimize,$Adapter,$Scenario,$([Math]::Round($PrivateMb, 1)),$WsMb"
}
function Add-RowLine([string]$Line) {
    Add-Content -LiteralPath $rows -Value $Line -Encoding ASCII
    Write-E2eInfo "row: $Line"
    if ($Record) { [IO.File]::AppendAllText($ramCsv, $Line + "`n", (New-Object Text.UTF8Encoding $false)) }
}
function Add-LatRow([string]$Adapter, [string]$Scenario, [double[]]$Ms) {
    $s = @($Ms | Sort-Object)
    $p50 = $s[[int][Math]::Floor(0.5 * ($s.Count - 1))]
    $p95 = $s[[int][Math]::Ceiling(0.95 * $s.Count) - 1]
    $line = '{0},{1},{2},{3},60,inbox-0,m4-tmux,{4},process,{5:F3},{6:F3},{7:F3},{8}' -f $today, $commit, $optimize, $Adapter, $Scenario, $p50, $p95, $s[-1], $s.Count
    Add-Content -LiteralPath $rows -Value $line -Encoding ASCII
    Write-E2eInfo "latency: $Scenario p50 $([Math]::Round($p50, 1)) ms, p95 $([Math]::Round($p95, 1)) ms, max $([Math]::Round($s[-1], 1)) ms (n=$($s.Count))"
    if ($Record) { [IO.File]::AppendAllText($latCsv, $line + "`n", (New-Object Text.UTF8Encoding $false)) }
    [pscustomobject]@{ P50 = $p50; P95 = $p95; Max = $s[-1] }
}
function Get-Adapter($G) {
    if (Test-Path -LiteralPath $G.Log) {
        $m = Select-String -LiteralPath $G.Log -Pattern 'd3d11 adapter=(.+?) vendor=' | Select-Object -First 1
        if ($m) { return ($m.Matches[0].Groups[1].Value -replace ',', ' ') }
    }
    'unknown'
}
function Get-GhosttyMb($G) {
    $p = Get-Process -Id $G.Pid
    [pscustomobject]@{ Private = $p.PrivateMemorySize64 / 1MB; Ws = $p.WorkingSet64 / 1MB }
}

$git = Find-GitBash
if (-not $git) { throw 'E2E-SKIP: Git Bash not found' }

Invoke-E2eScenario 'measure-tmux' {
    $sbx = $script:Sbx.Tmp

    function Get-FakeTeammate { "cd '$sbx' && env CLAUDECODE=1 '$git' -c 'exec sleep 600'" }
    function Get-Panes { @(Get-TmuxPanes $g) }
    function Wait-Panes([int]$N, [string]$What) {
        if (-not (Wait-Until -TimeoutSec 20 -PollMs 100 -Condition { @(Get-Panes).Count -eq $N })) { throw "$What : the state does not show $N panes" }
    }

    if ($Part -in 'team-ram', 'all') {
        $priv = @{ before = @(); team = @(); killed = @() }
        for ($run = 1; $run -le $Runs; $run++) {
            $g = Start-BashE2e -NoDump
            $leader = [string]@(Get-TmuxPanes $g)[0].pane
            Start-Sleep -Seconds 10
            $adapter = Get-Adapter $g
            $b = Get-GhosttyMb $g
            Add-RamRow $adapter 'm4-tmux-team:before' $b.Private ([Math]::Round($b.Ws, 1))
            $priv.before += $b.Private

            # The idle placeholder: what `split-window -- cat` starts.
            $r = Invoke-Tmux $g @('split-window', '-d', '-t', $leader, '-h', '-l', '70%', '-P', '-F', '#{pane_id}', '--', 'cat') $null 15000 $leader
            if ($r.Code -ne 0) { throw "split-window: $($r.Stderr)" }
            $p1 = $r.Stdout.Trim()
            Start-Sleep -Seconds 2
            $idle = @(Get-Process tmux -ErrorAction SilentlyContinue | Where-Object {
                    (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)").CommandLine -like '*__idle*' })
            if ($idle.Count) {
                $im = ($idle | Measure-Object PrivateMemorySize64 -Maximum).Maximum / 1MB
                Add-RamRow $adapter 'm4-tmux-idle-placeholder' $im ''
            }
            $r = Invoke-Tmux $g @('split-window', '-d', '-t', $p1, '-v', '-P', '-F', '#{pane_id}', '--', 'cat') $null 15000 $leader
            if ($r.Code -ne 0) { throw "split-window 2: $($r.Stderr)" }
            $p2 = $r.Stdout.Trim()
            foreach ($p in $p1, $p2) {
                $r = Invoke-Tmux $g @('respawn-pane', '-k', '-t', $p, '--', (Get-FakeTeammate)) $null 15000 $leader
                if ($r.Code -ne 0) { throw "respawn-pane: $($r.Stderr)" }
            }
            [void](Invoke-Tmux $g @('select-layout', '-t', '@1', 'main-vertical') $null 15000 $leader)
            [void](Invoke-Tmux $g @('resize-pane', '-t', $leader, '-x', '30%') $null 15000 $leader)
            Wait-Panes 3 'team'
            Start-Sleep -Seconds 30
            $t = Get-GhosttyMb $g
            Add-RamRow $adapter 'm4-tmux-team:team' $t.Private ([Math]::Round($t.Ws, 1))
            $priv.team += $t.Private

            foreach ($p in $p1, $p2) { [void](Invoke-Tmux $g @('kill-pane', '-t', $p) $null 15000 $leader) }
            Wait-Panes 1 'killed'
            Start-Sleep -Seconds 30
            $k = Get-GhosttyMb $g
            Add-RamRow $adapter 'm4-tmux-team:killed30s' $k.Private ([Math]::Round($k.Ws, 1))
            $priv.killed += $k.Private
            Stop-OwnGhostty
            Start-Sleep -Seconds 2
        }
        $med = { param($a) $s = @($a | Sort-Object); $s[[int][Math]::Floor(($s.Count - 1) / 2)] }
        Write-E2eInfo ('team-ram medians (MB): before {0:N1}, team {1:N1}, killed30s {2:N1}' -f (& $med $priv.before), (& $med $priv.team), (& $med $priv.killed))
    }

    if ($Part -in 'tmux-exe', 'latency', 'all') {
        $g = Start-BashE2e -NoDump
        $leader = [string]@(Get-TmuxPanes $g)[0].pane
        $adapter = Get-Adapter $g
        Start-Sleep -Seconds 3
    }

    if ($Part -in 'tmux-exe', 'all') {
        # The cap is 512 KiB of stdin; the harness's pipe adds a 3 byte UTF-8 BOM, so stay 16 bytes under.
        $big = 'x' * (512 * 1024 - 16)
        foreach ($case in @(
                @{ Name = 'display-message'; Args = @('display-message', '-p', '#{pane_id}'); Stdin = $null },
                @{ Name = 'load-buffer'; Args = @('load-buffer', '-'); Stdin = $big })) {
            $peaks = @()
            for ($i = 0; $i -lt 20; $i++) {
                $r = Invoke-Tmux $g $case.Args $case.Stdin 20000 $leader '' @{ GHOSTTY_TMUX_STATS = '1' }
                if ($r.Code -ne 0) { throw "$($case.Name): exit $($r.Code) $($r.Stderr)" }
                if ($r.Stderr -notmatch 'peak_private_kb=(\d+)') { throw "$($case.Name): no stats line in '$($r.Stderr)'" }
                $peaks += [int]$Matches[1]
            }
            $mx = ($peaks | Measure-Object -Maximum).Maximum
            Add-RamRow $adapter "m4-tmux-exe-$($case.Name)-peak" ($mx / 1024) ''
        }
    }

    if ($Part -in 'latency', 'all') {
        Add-Type -Namespace GhosttyE2e -Name Maxi -MemberDefinition '[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);' -ErrorAction SilentlyContinue
        [void][GhosttyE2e.Maxi]::ShowWindow($g.Hwnd, 3)
        Start-Sleep -Seconds 2

        # Wall time of tmux.exe from process start to exit as the kernel records it
        # (StartTime/ExitTime); the driver's own stopwatch (it includes the
        # PowerShell process spawn) is kept as the second number.
        $script:driverMs = New-Object System.Collections.Generic.List[double]
        function Measure-Ms([string[]]$A) {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $run = Start-TmuxProc $g $A $null $leader
            $r = Wait-TmuxProc $run 15000
            $sw.Stop()
            $p = $run.Process
            $script:driverMs.Add($sw.Elapsed.TotalMilliseconds)
            [pscustomobject]@{ Ms = ($p.ExitTime - $p.StartTime).TotalMilliseconds; R = $r }
        }
        Write-E2eInfo ('machine CPU load before the latency runs: {0} %' -f (Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average)
        # display-message
        $ms = @()
        for ($i = 0; $i -lt 50; $i++) {
            $m = Measure-Ms @('display-message', '-p', '#{pane_id}')
            if ($m.R.Code -ne 0) { throw "display-message: $($m.R.Stderr)" }
            $ms += $m.Ms
        }
        $dm = Add-LatRow $adapter 'tmux-display-message' $ms
        [void](Add-LatRow $adapter 'tmux-display-message-driver' $script:driverMs.ToArray())
        $script:driverMs.Clear()
        # split-window -- cat
        $ms = @()
        for ($i = 0; $i -lt 50; $i++) {
            $m = Measure-Ms @('split-window', '-d', '-P', '-F', '#{pane_id}', '--', 'cat')
            if ($m.R.Code -ne 0) { throw "split-window run ${i}: $($m.R.Stderr)" }
            $ms += $m.Ms
            [void](Invoke-Tmux $g @('kill-pane', '-t', $m.R.Stdout.Trim()) $null 15000 $leader)
            Wait-Panes 1 "after split $i"
        }
        $sp = Add-LatRow $adapter 'tmux-split-window' $ms
        [void](Add-LatRow $adapter 'tmux-split-window-driver' $script:driverMs.ToArray())
        $script:driverMs.Clear()
        # respawn-pane -k with a fake teammate, on one pane
        $r = Invoke-Tmux $g @('split-window', '-d', '-P', '-F', '#{pane_id}', '--', 'cat') $null 15000 $leader
        $pane = $r.Stdout.Trim()
        $ms = @()
        for ($i = 0; $i -lt 50; $i++) {
            $m = Measure-Ms @('respawn-pane', '-k', '-t', $pane, '--', (Get-FakeTeammate))
            if ($m.R.Code -ne 0) { throw "respawn-pane run ${i}: $($m.R.Stderr)" }
            $ms += $m.Ms
            Start-Sleep -Milliseconds 300
        }
        $rp = Add-LatRow $adapter 'tmux-respawn-pane' $ms
        [void](Add-LatRow $adapter 'tmux-respawn-pane-driver' $script:driverMs.ToArray())
        $script:driverMs.Clear()
        [void](Invoke-Tmux $g @('kill-pane', '-t', $pane) $null 15000 $leader)
        Write-E2eInfo ('machine CPU load after: {0} %' -f (Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average)
        Write-E2eInfo ("latency p95 (ms): display-message {0:N1}, split-window {1:N1}, respawn-pane {2:N1}; gates 30 / 300 / 300 on ReleaseFast ({3})" -f $dm.P95, $sp.P95, $rp.P95, $optimize)
    }
}
