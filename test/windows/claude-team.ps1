<#
.SYNOPSIS
Real Claude Code agent-team runs against Ghostty's tmux shim (M4 Task 15
Step 3, SPEC 15.6b). Not an e2e scenario: it uses the owner's login. ASCII only.

.DESCRIPTION
Each run (sequential) starts a ReleaseFast Ghostty with Git Bash through the
e2e harness and drives one real Claude Code (test/windows/lib/ClaudeRun.psm1:
sonnet, the owner's shared login for this one Ghostty only, CLI flags only,
10 minute time box) with the real tmux.exe: Ghostty itself sets TMUX,
TMUX_PANE and PATH. Only GHOSTTY_TMUX_TRACE (into the sandbox) is added.
A run passes when ALL of these hold:

  1. 3 tmux panes, main-vertical: the leader is 30 % (+- 1 cell) of the
     content width (state `tmux.panes`, surface rects);
  2. each teammate pane is titled with its name (state surface titles);
  3. both teammates' messages are in the inbox files under
     <config dir>\teams\<team>\ (read-only; the config dir is
     CLAUDE_CONFIG_DIR if set, else %USERPROFILE%\.claude): the teammates
     report to team-lead, so team-lead's inbox holds a message from each;
  4. after /exit only the leader pane remains and no claude.exe, tmux.exe or
     sleep.exe of the run survives (process-tree diff);
  5. the trace of the leader's calls has the argv shapes of the Task 1 fixture
     (pane ids, window ids, the pipe name and Claude's dynamic values masked;
     compared as sets: the repeated probes vary in number from run to run);
  6. Stop-ClaudeRun removed only the run's projects/<key> files; the residue
     (~/.claude/tasks/<team>, ~/.claude.json entry) is listed and the tasks dir
     of the run is removed here.

Stops at the first auth error (claude exits right after start: the driver
throws). Output: a summary per run on stdout and files under -OutDir.

.PARAMETER Ghostty
The ghostty.exe under test (default zig-out-rf\bin\ghostty.exe).

.PARAMETER Runs
Sequential runs (default 2).

.PARAMETER OutDir
Default %TEMP%\claude-team.
#>
param(
    [string]$Ghostty,
    [int]$Runs = 2,
    [string]$OutDir,
    [double]$TimeBoxMin = 10
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if (-not $Ghostty) { $Ghostty = Join-Path $repo 'zig-out-rf\bin\ghostty.exe' }
$env:GHOSTTY_E2E_EXE = (Resolve-Path -LiteralPath $Ghostty).Path
if (-not $OutDir) { $OutDir = Join-Path $env:TEMP 'claude-team' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
$env:GHOSTTY_E2E_EVIDENCE = Join-Path $OutDir 'evidence'

$e2eDir = Join-Path $PSScriptRoot 'e2e'
. (Join-Path $e2eDir '_common.ps1')
. (Join-Path $e2eDir '_tmux.ps1')
Import-Module (Join-Path $script:WinDir 'lib\ClaudeRun.psm1') -Force
# ClaudeRun must not hide the caller's import (it no longer does); keep it explicit.
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

$fixturePath = Join-Path $repo 'src\apprt\win32\tmux\testdata\claude-spawn.jsonl'

function Read-Trace([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try { (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd() } finally { $fs.Dispose() }
}
function Get-TraceCalls([string]$Path) {
    @((Read-Trace $Path) -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
}
function Count-Calls([string]$Path, [string]$Verb) {
    @(Get-TraceCalls $Path | Where-Object { @($_.argv) -contains $Verb }).Count
}
# argv as a shape: the pipe prefix, ids, the pipe name and Claude's dynamic
# values (the respawn command line) masked.
function ConvertTo-Shape($argv) {
    $a = @($argv)
    if ($a.Count -ge 2 -and $a[0] -eq '-S') { $a = $a[2..($a.Count - 1)] }
    ($a | ForEach-Object {
            $x = [string]$_
            if ($x -match '^cd ') { '<command>' } else { ($x -replace '(?<![#\w])[%@]\d+\b', '<id>') }
        }) -join ' '
}
function Get-ConfigDir {
    if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path (Get-RealUserProfile) '.claude' }
}
function Get-RealUserProfile { [Environment]::GetFolderPath('UserProfile') }

$script:Results = @()

function Invoke-TeamRun([int]$N) {
    $script:Results += [pscustomobject]@{ Run = $N; Pass = $false; Notes = @('did not finish') }
    $idx = $script:Results.Count - 1
    Invoke-E2eScenario "claude-team-$N" {
        $sbx = $script:Sbx
        $trace = Join-Path $sbx.Root 'trace.jsonl'
        $extra = @{ GHOSTTY_TMUX_TRACE = $trace }
        $cfgText = (Get-Content -LiteralPath (Get-ConfigPath 'gitbash-de') -Raw -Encoding UTF8).TrimEnd() + "`nwindows-tmux-shim = true`n"
        $start = { param($e, $wd) Start-E2eGhostty -ConfigText $cfgText -Env $e }
        $ready = { param($g) Wait-BashReady $g }
        $failures = New-Object System.Collections.Generic.List[string]
        $notes = New-Object System.Collections.Generic.List[string]
        $t0 = Get-Date
        $run = Start-ClaudeRun -Ghostty $script:Exe -StartGhostty $start -WaitBashReady $ready -ExtraEnv $extra -TimeBoxMin $TimeBoxMin -DebugFile (Join-Path $OutDir "claude-debug-$N.txt")
        $g = $run.G
        $team = $run.Team
        try {
            $notes.Add("claude: $($run.Version); team (driver) $($run.Team)")
            $spawned = Wait-ClaudeRun -Run $run -TimeoutSec 420 -Condition { param($r) (Count-Calls $trace 'respawn-pane') -ge 2 }
            if (-not $spawned) { throw 'fewer than 2 respawn-pane calls in 420 s' }
            # The team name Claude gave itself is in the respawn command line.
            $rs = @(Get-TraceCalls $trace | Where-Object { @($_.argv) -contains 'respawn-pane' })[0]
            if ((@($rs.argv) -join ' ') -match '--team-name (\S+)') { $team = $Matches[1] }
            $notes.Add("team: $team")
            Start-Sleep -Seconds 4

            # 1 + 2: panes, layout, titles
            $s = Get-GhosttyState -Class $g.Class
            $panes = @($s.tmux.panes)
            if ($panes.Count -ne 3) { $failures.Add("1: $($panes.Count) tmux panes, expected 3") }
            $w = @($s.windows)[0]
            $surfaces = @(@($w.tabs)[[int]$w.active_tab].surfaces)
            $contentW = [int]($w.client[2] - $w.client[0])
            $cellW = [int]$w.cell[0]
            $lead = $surfaces | Sort-Object { $_.id } | Select-Object -First 1
            $leadW = [int]($lead.rect[2] - $lead.rect[0])
            $share = $leadW / [double]$contentW
            $notes.Add(('leader {0} of {1} px = {2:P1}; cell {3} px' -f $leadW, $contentW, $share, $cellW))
            if ([Math]::Abs($leadW - 0.3 * $contentW) -gt $cellW + 2) { $failures.Add(('1: leader is {0:P1} of the width, not 30 % +- 1 cell' -f $share)) }
            $titles = @($surfaces | ForEach-Object { [string]$_.title })
            $notes.Add("titles: $($titles -join ' | ')")
            foreach ($name in 'alpha', 'beta') {
                if (@($titles | Where-Object { $_ -like "*$name*" }).Count -lt 1) { $failures.Add("2: no pane titled '$name'") }
            }
            Save-Evidence -Tag 'team' -G $g -Window

            # 3: inbox messages (read-only), while the team exists
            $teamDir = Join-Path (Get-ConfigDir) "teams\$team"
            $seen = @{ alpha = $false; beta = $false }
            [void](Wait-ClaudeRun -Run $run -TimeoutSec 240 -Condition {
                    param($r)
                    if (Test-Path -LiteralPath $teamDir) {
                        foreach ($f in Get-ChildItem -LiteralPath $teamDir -Recurse -File -Force -ErrorAction SilentlyContinue) {
                            try { $t = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop } catch { continue }
                            foreach ($name in 'alpha', 'beta') {
                                if ($t -match ('"from"\s*:\s*"' + $name + '"')) { $seen[$name] = $true }
                            }
                        }
                    }
                    $seen.alpha -and $seen.beta
                })
            foreach ($name in 'alpha', 'beta') {
                if (-not $seen[$name]) { $failures.Add("3: no message from $name in the inbox files under $teamDir") }
            }
            $notes.Add("inbox: alpha=$($seen.alpha) beta=$($seen.beta)")
            $beforeExit = @(Get-ProcessTree $g.Pid | Where-Object { $_.Name -in 'claude.exe', 'tmux.exe', 'sleep.exe' })
            $notes.Add("processes before /exit: $((@($beforeExit | ForEach-Object { $_.Name }) | Group-Object | ForEach-Object { $_.Name + 'x' + $_.Count }) -join ' ')")

            # leave
            $gone = $false
            for ($try = 0; $try -lt 4 -and -not $gone; $try++) {
                if ($try) { Send-ClaudeKey $run '\x03'; Start-Sleep -Milliseconds 800 }
                Send-ClaudeText $run '/exit'
                Start-Sleep -Milliseconds 800
                Send-ClaudeKey $run '\r'
                $gone = [bool](Wait-ClaudeRun -Run $run -TimeoutSec 20 -Condition { param($r) -not (Test-ClaudeAlive $r) })
            }
            if (-not $gone) { $failures.Add('4: claude did not exit after /exit (4 tries)') }

            # 4: only the leader remains, no strays
            $closed = Wait-Until -TimeoutSec 20 -PollMs 300 -Condition { @((Get-GhosttyState -Class $g.Class).tmux.panes).Count -eq 1 }
            if (-not $closed) { $failures.Add("4: $(@((Get-GhosttyState -Class $g.Class).tmux.panes).Count) panes after /exit, expected 1") }
            $strays = @()
            [void](Wait-Until -TimeoutSec 15 -PollMs 500 -Condition {
                    $script:strays = @(Get-ProcessTree $g.Pid | Where-Object { $_.Name -in 'claude.exe', 'tmux.exe', 'sleep.exe' })
                    $script:strays.Count -eq 0
                })
            $strays = @($script:strays)
            if ($strays.Count) { $failures.Add("4: processes of the run survive: $((@($strays | ForEach-Object { $_.Name + '#' + $_.ProcessId })) -join ', ')") }
            Save-Evidence -Tag 'after-exit' -G $g -Window

            # 5: the trace against the fixture
            $calls = @(Get-TraceCalls $trace)
            $mine = @($calls | Where-Object { -not $_.pane -or $_.pane -eq '%1' } | ForEach-Object { ConvertTo-Shape $_.argv } | Sort-Object)
            $fix = @(Get-Content -LiteralPath $fixturePath -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { ConvertTo-Shape (($_ | ConvertFrom-Json).argv) } | Sort-Object)
            $extraShapes = @($mine | Where-Object { $fix -notcontains $_ } | Select-Object -Unique)
            $missing = @($fix | Where-Object { $mine -notcontains $_ } | Select-Object -Unique)
            if ($extraShapes.Count -or $missing.Count) {
                $failures.Add("5: trace shapes differ from the fixture: extra [$($extraShapes -join ' ;; ')] missing [$($missing -join ' ;; ')]")
            }
            # Repeated probes (list-panes, the display-message probes) vary in number from run to run: the check is on the set of shapes.
            $notes.Add("trace: $($calls.Count) calls, $($mine.Count) from the leader, fixture $($fix.Count)")
            $bad = @($calls | Where-Object { $_.code -ne 0 })
            if ($bad.Count) { $failures.Add("5: $($bad.Count) tmux calls failed, first: $((@($bad[0].argv) -join ' '))") }
        } catch {
            $failures.Add("run aborted: $($_.Exception.Message)")
        } finally {
            if (Test-Path -LiteralPath $g.Log) { Copy-Item -LiteralPath $g.Log -Destination (Join-Path $OutDir "ghostty-$N.log") -Force }
            if (Test-Path -LiteralPath $trace) { Copy-Item -LiteralPath $trace -Destination (Join-Path $OutDir "trace-$N.jsonl") -Force }
            $residue = @(Stop-ClaudeRun $run)
            $notes.Add("projects files removed by the driver: $(@($run.Cleaned).Count)")
            # The run's task dir under the config dir is the run's own (named by its team).
            $taskDir = Join-Path (Get-ConfigDir) "tasks\$($run.Team)"
            $notes.Add("residue: $($residue -join '; ')")
            if ($run.Team -like 'session-*' -and (Test-Path -LiteralPath $taskDir)) {
                Remove-Item -LiteralPath $taskDir -Recurse -Force -ErrorAction SilentlyContinue
                $notes.Add("removed $taskDir")
            }
            $notes.Add(('duration {0} s' -f [int]((Get-Date) - $t0).TotalSeconds))
        }
        $script:Results[$idx] = [pscustomobject]@{ Run = $N; Pass = ($failures.Count -eq 0); Notes = @($notes) + @($failures | ForEach-Object { "FAIL $_" }) }
        if ($failures.Count) { throw "run ${N}: $($failures -join ' | ')" }
    }
}

for ($n = 1; $n -le $Runs; $n++) {
    Invoke-TeamRun $n
    $r = $script:Results[$n - 1]
    Write-Output ("RUN {0}: {1}" -f $n, $(if ($r.Pass) { 'PASS' } else { 'FAIL' }))
    foreach ($line in $r.Notes) { Write-Output "  $line" }
    if (-not $r.Pass) { break }
}
$allPass = @($script:Results | Where-Object { $_.Pass }).Count -eq $Runs
Write-Output ("claude-team: {0} of {1} runs passed" -f @($script:Results | Where-Object { $_.Pass }).Count, $Runs)
Set-Content -LiteralPath (Join-Path $OutDir 'summary.txt') -Value (($script:Results | ForEach-Object { "RUN $($_.Run): $(if ($_.Pass) { 'PASS' } else { 'FAIL' })"; $_.Notes | ForEach-Object { "  $_" } })) -Encoding UTF8
exit $(if ($allPass) { 0 } else { 1 })
