<#
.SYNOPSIS
Shared driver for real Claude Code runs inside a scenario Ghostty (M4 Task 1,
G1, Task 15 Step 3). ASCII only (Windows PowerShell 5.1).

.DESCRIPTION
Ledger ruling (c) + option B. The driver

  - starts the scenario Ghostty with the REAL USERPROFILE and HOME for that one
    instance (Claude finds the owner's login); XDG_CONFIG_HOME, APPDATA,
    LOCALAPPDATA and the Ghostty class stay sandboxed (the caller's
    -StartGhostty block decides, Start-E2eGhostty does it);
  - never copies, reads or writes credentials, settings.json or
    CLAUDE_CONFIG_DIR; configuration is passed as CLI flags only;
  - removes CLAUDECODE, CLAUDE_CODE_ENTRYPOINT, CLAUDE_CODE_SSE_PORT and every
    other CLAUDE_* variable of its own environment from the child (the nested
    session guard is `CLAUDE_CODE_CHILD_SESSION || CLAUDECODE`). The names are
    listed in the run object (.RemovedEnv). One exception: CLAUDE_CODE_GIT_BASH_PATH
    is a location, not a session variable, and is kept when present;
  - runs in a fresh work dir %TEMP%\ghostty-claude-<run>, with the fixed prompt
    below, a 10 minute time box and the cheapest model;
  - afterwards removes ONLY the files this run created under
    ~/.claude/projects/<key of the work dir> (listed before and after, deleted by
    exact path). ~/.claude/teams/<team>/ and the work dir's entry in
    ~/.claude.json stay and are reported as residue.

Claude Code 2.1.311 CLI check (Task 1 Step 0, `claude --help`):
  --agent-teams       hidden, but commander REJECTS it at start ("unknown option", seen in the
                      live run; only `--version` ignores it): NOT used. The env variable
                      CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 (set for the Ghostty instance) is the spelling
  --teammate-mode     hidden (not in --help); auto | tmux | iterm2 | in-process
  --model <model>     alias 'sonnet' (owner decision: sonnet for every real Claude run; haiku did not get TeamCreate)
  --permission-mode   choices listed: acceptEdits auto bypassPermissions manual
                      dontAsk plan; `default` is accepted too (hidden alias, checked
                      with `claude --permission-mode default --version`)
  --settings          <file-or-json>, inline JSON used
  trust option        none (only -p skips the trust dialog): the trust prompt is
                      answered once with Enter
Fallbacks if a build hides a flag: env CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 and
`teammateMode` inside the --settings JSON (the latter is always present).
#>

Set-StrictMode -Version Latest

# No -Force: it would remove the caller's own import of GhosttyIpc from the session.
Import-Module (Join-Path $PSScriptRoot 'GhosttyIpc.psm1')

# The prompt is fixed. {TEAM} becomes the team name of the run.
$ClaudeRunPrompt = 'Use the Agent tool to spawn two teammates named alpha and beta (pass the name parameter), with the same model as you (sonnet). Tell each teammate: touch no files, run no commands, send one short message to team-lead and then stop. When both have reported, reply with the single word DONE. Team marker: {TEAM}.'

# Inline --settings JSON: only the team and messaging tools are allowed, the file
# and shell tools are denied. teammateMode is the fallback for a hidden flag.
$script:SettingsJson = '{"teammateMode":"tmux","permissions":{"allow":["SendMessage","Agent","Task","TaskCreate","TaskUpdate","TaskList","TaskGet"],"deny":["Bash","PowerShell","Edit","Write","NotebookEdit","WebFetch","WebSearch"]}}'

$script:ClaudeArgs = "--teammate-mode tmux --model sonnet --permission-mode default --settings '$script:SettingsJson'"

function Get-RealUserProfile { [Environment]::GetFolderPath('UserProfile') }

function Get-ClaudeProjectFiles {
    $root = Join-Path (Get-RealUserProfile) '.claude\projects'
    if (-not (Test-Path -LiteralPath $root)) { return @() }
    @(Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
}

function Wait-ClaudeUntil([scriptblock]$Pred, [double]$TimeoutSec, [int]$PollMs = 250) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $r = & $Pred
        if ($r) { return $r }
        if ($sw.Elapsed.TotalSeconds -ge $TimeoutSec) { return $null }
        Start-Sleep -Milliseconds $PollMs
    }
}

function Get-ClaudeProcessTree([int]$RootPid) {
    $all = @(Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId, Name)
    $found = [System.Collections.Generic.List[object]]::new()
    $queue = [System.Collections.Generic.Queue[int]]::new()
    $seen = [System.Collections.Generic.HashSet[int]]::new()
    $queue.Enqueue($RootPid)
    while ($queue.Count -gt 0) {
        $parent = $queue.Dequeue()
        foreach ($p in $all) {
            if ($p.ParentProcessId -eq $parent -and $p.ProcessId -ne $parent -and $seen.Add([int]$p.ProcessId)) {
                $found.Add($p)
                $queue.Enqueue([int]$p.ProcessId)
            }
        }
    }
    $found.ToArray()
}

function Test-ClaudeAlive($Run) {
    [bool]@(Get-ClaudeProcessTree $Run.G.Pid | Where-Object { $_.Name -ieq 'claude.exe' })
}

# Types `text` into the focused surface through the binding action `text:`
# (bytes straight to the pty, no focus needed). `text` must hold no backslash.
function Send-ClaudeText($Run, [string]$Text) {
    [void](Invoke-GhosttyAction -Class $Run.G.Class -Action "text:$Text" -Surface 0)
}

# Escape sequences go in as text-action escapes (\r, \x03).
function Send-ClaudeKey($Run, [string]$Escaped) {
    [void](Invoke-GhosttyAction -Class $Run.G.Class -Action "text:$Escaped" -Surface 0)
}

function Get-ClaudeSessionFiles($Run) {
    # Files this run created: new, under a project dir named after the work dir.
    $leaf = ($Run.WorkDir | Split-Path -Leaf) -replace '[^A-Za-z0-9]', '-'
    @(Get-ClaudeProjectFiles | Where-Object { ($Run.ProjectsBefore -notcontains $_) -and ($_ -like "*$leaf*") })
}

<#
.SYNOPSIS
Starts the scenario Ghostty with the real login, runs `claude` in a fresh work
dir and submits the fixed prompt. Returns {G, WorkDir, Team, ProjectsBefore,
RemovedEnv, StartedAt, TimeBoxMin, Ghostty, Prompt}.

.PARAMETER Ghostty
The ghostty.exe under test (recorded; the caller's -StartGhostty block starts it).

.PARAMETER StartGhostty
Scriptblock { param([hashtable]$Env, [string]$WorkDir) -> G } that calls
Start-E2eGhostty -Env $Env with a Git Bash config and returns its result.

.PARAMETER WaitBashReady
Scriptblock { param($G) } that waits until the shell runs typed lines.

.PARAMETER ExtraEnv
Extra variables for the Ghostty instance (and so for the shell and Claude).
#>
function Start-ClaudeRun {
    param(
        [Parameter(Mandatory)][string]$Ghostty,
        [Parameter(Mandatory)][scriptblock]$StartGhostty,
        [Parameter(Mandatory)][scriptblock]$WaitBashReady,
        [hashtable]$ExtraEnv = @{},
        [double]$TimeBoxMin = 10,
        [string]$Prompt = $ClaudeRunPrompt,
        [string]$TeamName,
        [string]$DebugFile
    )

    $stamp = Get-Date -Format 'yyyyMMddHHmmss'
    if (-not $TeamName) { $TeamName = "m4-$stamp" }
    $claude = (Get-Command claude -ErrorAction Stop).Source
    $version = (& $claude --version 2>&1 | Select-Object -First 1)

    $workDir = Join-Path $env:TEMP "ghostty-claude-$stamp"
    New-Item -ItemType Directory -Force -Path $workDir | Out-Null

    $real = Get-RealUserProfile
    $envTable = [ordered]@{ USERPROFILE = $real; HOME = $real }
    $removed = @()
    foreach ($e in Get-ChildItem Env:) {
        if ($e.Name -like 'CLAUDE*' -and $e.Name -ne 'CLAUDE_CODE_GIT_BASH_PATH') {
            $envTable[$e.Name] = $null
            $removed += $e.Name
        }
    }
    $envTable['CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS'] = '1'
    foreach ($k in $ExtraEnv.Keys) { $envTable[[string]$k] = $ExtraEnv[$k] }

    $run = [pscustomobject]@{
        G              = $null
        WorkDir        = $workDir
        Team           = $TeamName
        ProjectsBefore = @(Get-ClaudeProjectFiles)
        RemovedEnv     = $removed
        StartedAt      = [DateTime]::UtcNow
        TimeBoxMin     = $TimeBoxMin
        Ghostty        = $Ghostty
        Prompt         = $Prompt.Replace('{TEAM}', $TeamName)
        Version        = $version
        Cleaned        = @()
        Residue        = @()
    }

    $run.G = & $StartGhostty $envTable $workDir
    & $WaitBashReady $run.G

    # cd, then claude. The shell is up (the marker proved it), a resize of its pty
    # may still eat a byte, so verify through the shell: the command only runs
    # in the work dir if `cd` arrived whole.
    $unixDir = $workDir -replace '\\', '/'
    Send-ClaudeText $run "cd '$unixDir'"
    Send-ClaudeKey $run '\r'
    Start-Sleep -Milliseconds 500
    $dbg = if ($DebugFile) { " --debug-file '" + ($DebugFile.Replace([string][char]92, '/')) + "'" } else { '' }
    Send-ClaudeText $run "claude $script:ClaudeArgs$dbg"
    Send-ClaudeKey $run '\r'

    if (-not (Wait-ClaudeUntil { Test-ClaudeAlive $run } 30)) { throw 'claude.exe did not start under ghostty within 30 s' }

    # Trust prompt for the new work dir: Enter (default is "Yes, proceed").
    # Harmless when no dialog is shown.
    Start-Sleep -Seconds 8
    if (-not (Test-ClaudeAlive $run)) { throw 'claude.exe exited right after start (bad flag or login?)' }
    Send-ClaudeKey $run '\r'
    Start-Sleep -Seconds 4

    # Submit the prompt; verify that the session file holds it, else clear and retype.
    $needle = 'Team marker: ' + $TeamName
    $accepted = $false
    for ($try = 0; $try -lt 3 -and -not $accepted; $try++) {
        if ($try) { Send-ClaudeKey $run '\x03'; Start-Sleep -Milliseconds 800 }
        Send-ClaudeText $run $run.Prompt
        Start-Sleep -Milliseconds 1500
        Send-ClaudeKey $run '\r'
        $accepted = [bool](Wait-ClaudeUntil {
                foreach ($f in Get-ClaudeSessionFiles $run) {
                    if ($f -like '*.jsonl') {
                        try { if ((Get-Content -LiteralPath $f -Raw -ErrorAction Stop).Contains($needle)) { return $true } } catch { }
                    }
                }
                $false
            } 25)
    }
    if (-not $accepted) { throw 'the prompt did not reach the Claude session (no session file holds it after 3 tries)' }
    $run
}

<#
.SYNOPSIS
Waits for `$Condition` (called with the run) until it is true; enforces the time
box. Returns the condition value, or $null on timeout. When the time box is
exceeded the run is stopped and the call throws.
#>
function Wait-ClaudeRun {
    param(
        [Parameter(Mandatory)]$Run,
        [Parameter(Mandatory)][scriptblock]$Condition,
        [double]$TimeoutSec = 120
    )
    $r = Wait-ClaudeUntil {
        if (([DateTime]::UtcNow - $Run.StartedAt).TotalMinutes -ge $Run.TimeBoxMin) { return 'TIMEBOX' }
        & $Condition $Run
    } $TimeoutSec 500
    if (($r -is [string]) -and ($r -ceq 'TIMEBOX')) {
        [void](Stop-ClaudeRun $Run)
        throw "claude run exceeded the $($Run.TimeBoxMin) min time box; process tree killed"
    }
    $r
}

<#
.SYNOPSIS
Kills the process tree of the run's Ghostty and removes the files the run created
under ~/.claude/projects/<key> (by exact path, nothing else). Returns the residue
list: what stays behind on purpose.
#>
function Stop-ClaudeRun {
    param([Parameter(Mandatory)]$Run)

    $ErrorActionPreference = 'Continue'
    if ($Run.G) {
        foreach ($p in @(Get-ClaudeProcessTree $Run.G.Pid | Where-Object { $_.Name -ieq 'claude.exe' })) {
            & taskkill.exe /PID $p.ProcessId /T /F 2>&1 | Out-Null
        }
        if (Get-Process -Id $Run.G.Pid -ErrorAction SilentlyContinue) {
            & taskkill.exe /PID $Run.G.Pid /T /F 2>&1 | Out-Null
        }
    }
    Start-Sleep -Milliseconds 500

    # The session team of 2.1.311 is named by Claude, not by us: read it from this run's own session file.
    foreach ($f in Get-ClaudeSessionFiles $Run) {
        if ($f -like '*.jsonl') {
            try {
                $m = [regex]::Match((Get-Content -LiteralPath $f -Raw -ErrorAction Stop), '"(?:teamName|team_name)":"([^"]+)"')
                if ($m.Success) { $Run.Team = $m.Groups[1].Value; break }
            } catch { }
        }
    }
    $cleaned = @()
    foreach ($f in Get-ClaudeSessionFiles $Run) {
        try { Remove-Item -LiteralPath $f -Force -ErrorAction Stop; $cleaned += $f } catch { }
    }
    # Directories the run created (session dir, subagents, memory) and that are now
    # empty, deepest first. The project dir carries the unique name of the work dir,
    # so nothing of the owner's is below it.
    $leaf = ($Run.WorkDir | Split-Path -Leaf) -replace '[^A-Za-z0-9]', '-'
    $projRoot = Join-Path (Get-RealUserProfile) '.claude\projects'
    foreach ($proj in @(Get-ChildItem -LiteralPath $projRoot -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*$leaf*" })) {
        $dirs = @(Get-ChildItem -LiteralPath $proj.FullName -Recurse -Directory -Force -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending) + $proj
        foreach ($d in $dirs) {
            if ((Test-Path -LiteralPath $d.FullName) -and -not (Get-ChildItem -LiteralPath $d.FullName -Force)) {
                Remove-Item -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue
                $cleaned += $d.FullName
            }
        }
    }    $Run.Cleaned = $cleaned

    $home_ = Get-RealUserProfile
    $residue = @()
    $teamDir = Join-Path $home_ ".claude\teams\$($Run.Team)"
    if (Test-Path -LiteralPath $teamDir) { $residue += $teamDir }
    $taskDir = Join-Path $home_ ".claude\tasks\$($Run.Team)"
    if (Test-Path -LiteralPath $taskDir) { $residue += $taskDir }
    $residue += "$home_\.claude.json (entry for $($Run.WorkDir))"
    # The work dir is ours (created by Start-ClaudeRun in %TEMP%): remove it.
    if (Test-Path -LiteralPath $Run.WorkDir) { Remove-Item -LiteralPath $Run.WorkDir -Recurse -Force -ErrorAction SilentlyContinue }
    $Run.Residue = $residue
    $residue
}

Export-ModuleMember -Function Start-ClaudeRun, Wait-ClaudeRun, Stop-ClaudeRun, Send-ClaudeText, Send-ClaudeKey, Test-ClaudeAlive, Get-ClaudeSessionFiles -Variable ClaudeRunPrompt
