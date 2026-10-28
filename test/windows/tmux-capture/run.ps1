<#
.SYNOPSIS
Live capture of the tmux calls Claude Code makes (M4 Task 1, Steps 2-4).

.DESCRIPTION
Builds fake_tmux.zig into the run's sandbox as tmux.exe, starts a Debug Ghostty
(Git Bash) through the e2e harness with that tmux.exe first on PATH and
TMUX/TMUX_PANE set, runs a real Claude Code (test/windows/lib/ClaudeRun.psm1:
haiku, 10 minute cap, CLI flags only, real login only for this one Ghostty),
waits until both teammate spawns are in the trace, types /exit so the cleanup
kill-pane calls are captured too, and removes what the run created under
~/.claude/projects/<key>.

Outputs (in -OutDir): trace.jsonl (raw), claude-spawn.jsonl (fixture form),
ghostty-lines.txt (DCS / notification / title lines of the Debug log),
titles.txt (surface titles sampled during the run), summary.txt.

GUI only through Invoke-E2eScenario (desktop lock, sandbox, own class). Run it
from the worktree; do not wrap it in test-lock.

.PARAMETER Ghostty
A Debug ghostty.exe (default zig-out\bin\ghostty.exe; GHOSTTY_E2E_EXE wins).

.PARAMETER TmuxExe
A prebuilt fake tmux.exe (built with: zig build-exe -O ReleaseSmall
-femit-bin=<out>\tmux.exe fake_tmux.zig). Built here when omitted.

.PARAMETER OutDir
Default %TEMP%\tmux-capture.

.PARAMETER Fixture
Where to write claude-spawn.jsonl in fixture form (optional).
#>
param(
    [string]$Ghostty,
    [string]$TmuxExe,
    [string]$OutDir,
    [string]$Fixture,
    [double]$TimeBoxMin = 10
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($Ghostty) { $env:GHOSTTY_E2E_EXE = (Resolve-Path $Ghostty).Path }
if (-not $OutDir) { $OutDir = Join-Path $env:TEMP 'tmux-capture' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
$env:GHOSTTY_E2E_EVIDENCE = Join-Path $OutDir 'evidence'

if (-not $TmuxExe) {
    $zig = 'C:\tools\zig-x86_64-windows-0.17.0\zig.exe'
    $TmuxExe = Join-Path $OutDir 'tmux.exe'
    Push-Location $PSScriptRoot
    try {
        & $zig build-exe -O ReleaseSmall "-femit-bin=$TmuxExe" fake_tmux.zig
        if ($LASTEXITCODE -ne 0) { throw "zig build-exe fake_tmux.zig failed ($LASTEXITCODE)" }
    } finally { Pop-Location }
}
$TmuxExe = (Resolve-Path $TmuxExe).Path

. (Join-Path $PSScriptRoot '..\e2e\_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force
Import-Module (Join-Path $script:WinDir 'lib\ClaudeRun.psm1') -Force

function Read-Trace([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try { (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd() } finally { $fs.Dispose() }
}
function Count-Calls([string]$Path, [string]$Verb) {
    ([regex]::Matches((Read-Trace $Path), '"' + [regex]::Escape($Verb) + '"')).Count
}

Invoke-E2eScenario 'tmux-capture' {
    $sbx = $script:Sbx
    $binDir = Join-Path $sbx.Root 'tmuxbin'
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null
    Copy-Item -LiteralPath $TmuxExe -Destination (Join-Path $binDir 'tmux.exe')
    $trace = Join-Path $sbx.Root 'trace.jsonl'

    # A pre-M4 Ghostty sets none of these itself.
    $extra = @{
        PATH               = "$binDir;$env:PATH"
        TMUX               = '\\.\pipe\ghostty-tmux-capture-0,1,0'
        TMUX_PANE          = '%1'
        GHOSTTY_TMUX_TRACE = $trace
    }
    $cfgText = Get-Content -LiteralPath (Get-ConfigPath 'gitbash-de') -Raw -Encoding UTF8
    $start = { param($e, $wd) Start-E2eGhostty -ConfigText $cfgText -Env $e }
    $ready = { param($g) Wait-BashReady $g }

    $t0 = Get-Date
    $run = Start-ClaudeRun -Ghostty $script:Exe -StartGhostty $start -WaitBashReady $ready -ExtraEnv $extra -TimeBoxMin $TimeBoxMin -DebugFile (Join-Path $OutDir 'claude-debug.txt')
    $titles = [System.Collections.Generic.List[string]]::new()
    $sample = {
        try {
            $s = Get-GhosttyState -Class $run.G.Class
            foreach ($w in @($s.windows)) {
                foreach ($t in @($w.tabs)) {
                    foreach ($f in @($t.surfaces)) { $titles.Add(("{0:HH:mm:ss} title='{1}'" -f (Get-Date), $f.title)) }
                }
            }
        } catch { }
    }
    $summary = [System.Collections.Generic.List[string]]::new()
    $logLines = @()
    try {
        $summary.Add("claude: $($run.Version)")
        $summary.Add("model: sonnet; team: $($run.Team); workdir: $($run.WorkDir)")
        $summary.Add("env removed from the child: $($run.RemovedEnv -join ', ')")

        # Both teammate spawns: two respawn-pane calls in the trace.
        $spawned = Wait-ClaudeRun -Run $run -TimeoutSec 420 -Condition {
            param($r)
            & $sample
            (Count-Calls $trace 'respawn-pane') -ge 2
        }
        if (-not $spawned) { throw "fewer than 2 respawn-pane calls in 420 s; trace: $((Read-Trace $trace).Length) bytes" }
        Start-Sleep -Seconds 3
        & $sample

        # /exit with re-send-and-verify: the leader must leave, the cleanup kill-pane calls follow.
        $gone = $false
        for ($try = 0; $try -lt 4 -and -not $gone; $try++) {
            if ($try) { Send-ClaudeKey $run '\x03'; Start-Sleep -Milliseconds 800 }
            Send-ClaudeText $run '/exit'
            Start-Sleep -Milliseconds 800
            Send-ClaudeKey $run '\r'
            $gone = [bool](Wait-ClaudeRun -Run $run -TimeoutSec 20 -Condition { param($r) -not (Test-ClaudeAlive $r) })
        }
        if (-not $gone) { throw 'claude did not exit after /exit (4 tries)' }
        [void](Wait-ClaudeRun -Run $run -TimeoutSec 15 -Condition { param($r) (Count-Calls $trace 'kill-pane') -ge 2 })
        $summary.Add("kill-pane calls after exit: $(Count-Calls $trace 'kill-pane')")
    } finally {
        $dur = [int]((Get-Date) - $t0).TotalSeconds
        $summary.Add("duration: $dur s")
        # Debug log lines first: the sandbox goes away with the scenario.
        if (Test-Path -LiteralPath $run.G.Log) {
            $logLines = @(Select-String -LiteralPath $run.G.Log -Pattern 'DCS|desktop_notification|notification|title|progress|clipboard|osc|tmux' -ErrorAction SilentlyContinue |
                    Select-Object -First 400 | ForEach-Object { $_.Line })
            Copy-Item -LiteralPath $run.G.Log -Destination (Join-Path $OutDir 'ghostty.log') -Force
        }
        if (Test-Path -LiteralPath $trace) { Copy-Item -LiteralPath $trace -Destination (Join-Path $OutDir 'trace.jsonl') -Force }
        Set-Content -LiteralPath (Join-Path $OutDir 'ghostty-lines.txt') -Value $logLines -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $OutDir 'titles.txt') -Value $titles -Encoding UTF8
        $residue = Stop-ClaudeRun $run
        $summary.Add('files removed under ~/.claude/projects:')
        foreach ($f in $run.Cleaned) { $summary.Add("  $f") }
        $summary.Add('residue (left on purpose):')
        foreach ($f in $residue) { $summary.Add("  $f") }
        Set-Content -LiteralPath (Join-Path $OutDir 'summary.txt') -Value $summary -Encoding UTF8
    }

    # Fixture form: stdin_len -> stdin ("<n> bytes" or null).
    if ($Fixture -and (Test-Path -LiteralPath (Join-Path $OutDir 'trace.jsonl'))) {
        $lines = foreach ($l in Get-Content -LiteralPath (Join-Path $OutDir 'trace.jsonl') -Encoding UTF8) {
            if (-not $l.Trim()) { continue }
            $l -replace '"stdin_len":null\}$', '"stdin":null}' -replace '"stdin_len":(\d+)\}$', '"stdin":"$1 bytes"}'
        }
        [IO.File]::WriteAllLines($Fixture, [string[]]$lines, (New-Object Text.UTF8Encoding $false))
    }
}
