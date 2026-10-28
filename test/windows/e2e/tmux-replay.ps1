# e2e: milestone=M4 timeout=420 order=720 surfaces=3
# tmux-replay: Claude Code's recorded tmux calls (testdata/claude-spawn.*.jsonl)
# played through the real tmux.exe against the scenario's own Ghostty, with
# fake teammates in place of claude. Checks the spawn answers and layout, the
# leader's typing across layout changes, a minimized window, remain-on-exit,
# kill-pane while a dialog is up and in parallel, load-buffer -w, and what is
# left after Ghostty is killed.
#
# Needs: zig build (ghostty.exe, tmux.exe), Git Bash. Keep this file ASCII only.
. (Join-Path $PSScriptRoot '_common.ps1')
. (Join-Path $PSScriptRoot '_tmux.ps1')
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

if (-not ('GhosttyE2e.Replay' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name Replay -MemberDefinition @"
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
"@
}

$script:TDM_CLICK_BUTTON = 0x466
$script:IdCancel = 2

Invoke-E2eScenario 'tmux-replay' {
    $git = Find-GitBash
    if (-not $git) { throw 'E2E-SKIP: Git Bash not found' }
    $sbx = $script:Sbx.Tmp
    $sbxMsys = ConvertTo-MsysPath $sbx

    $fixtureDir = Join-Path $script:Root 'src\apprt\win32\tmux\testdata'
    $fixture = Join-Path $fixtureDir 'claude-spawn.jsonl'
    if (-not (Test-Path -LiteralPath $fixture)) { $fixture = Join-Path $fixtureDir 'claude-spawn.static.jsonl' }
    $calls = @(Get-Content -LiteralPath $fixture -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
    if ($calls.Count -lt 10) { throw "fixture $fixture has only $($calls.Count) calls" }
    Write-E2eInfo "replaying $($calls.Count) calls from $(Split-Path -Leaf $fixture)"

    # Confirmation on, for the modal step.
    $text = (Get-Content -LiteralPath (Get-ConfigPath 'gitbash-de') -Raw -Encoding UTF8) -replace 'confirm-close-surface = false', 'confirm-close-surface = true'
    $g = Start-E2eGhostty -ConfigText $text
    Wait-BashReady $g
    $pipe = Get-TmuxPipe $g
    $leader = [string]@(Get-TmuxPanes $g)[0].pane
    $win = "@$(@(Get-TmuxPanes $g)[0].tab)"
    $saved = Save-ClipboardText

    function Get-Window { @((Get-GhosttyState -Class $g.Class).windows)[0] }
    function Get-Panes { @(Get-TmuxPanes $g) }
    function Wait-PaneCount([int]$N, [string]$What, [double]$Sec = 10) {
        if (-not (Wait-Until -TimeoutSec $Sec -PollMs 150 -Condition { @(Get-Panes).Count -eq $N })) {
            throw "$What : expected $N panes, state has $(@(Get-Panes).Count): $((Get-Panes | ConvertTo-Json -Compress -Depth 4))"
        }
    }
    function Tm([string[]]$A, [string]$Stdin = $null, [string]$From = $leader) {
        Invoke-Tmux $g $A $Stdin 15000 $From
    }
    function Expect-Ok($R, [string]$What) {
        if ($R.Code -ne 0) { throw "$What : exit $($R.Code), stderr '$($R.Stderr.Trim())'" }
        $R
    }

    # --- fake teammates ---
    # The string Claude sends is replaced by this: it records its TMUX_PANE
    # and stays alive (or exits with a code).
    function Get-FakeCommand([string]$Marker, [string]$Body = 'exec sleep 600') {
        $inner = 'printf "%s\n" "$TMUX_PANE" > ' + $sbxMsys + '/' + $Marker + '.txt; ' + $Body
        "cd '$sbx' && env CLAUDECODE=1 '$git' -c '$inner'"
    }
    function Read-Marker([string]$Marker) {
        $p = Join-Path $sbx ($Marker + '.txt')
        if (-not (Wait-File $p 15)) { throw "fake teammate '$Marker' never wrote $p" }
        (Read-ShellFile $p).Utf8.TrimEnd("`r", "`n")
    }

    # --- the replay ---
    # Fixture ids -> live ids. %1 is the leader, @1 its window.
    $map = @{ '%1' = $leader; "@1" = $win }
    function Convert-Ids([string]$S) {
        [regex]::Replace($S, '(?<![#\w])([%@])(\d+)\b', {
            param($m)
            $k = $m.Value
            if ($map.ContainsKey($k)) { $map[$k] } else { $k }
        })
    }
    $teammates = 0
    $layoutChanges = 0
    $leaderLines = New-Object System.Collections.Generic.List[string]
    function Type-Leader([string]$Tag) {
        $name = "k$($leaderLines.Count + 1)"
        $leaderLines.Add($name)
        [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
        Send-Line $g.Hwnd ("printf '%s\n' $name >> $sbxMsys/leader.txt")
        Write-E2eInfo "typed $name ($Tag)"
    }

    $replayStart = [Diagnostics.Stopwatch]::StartNew()
    $n = 0
    # The recording ends with the kill-pane calls that clean up; the panes are
    # needed for the checks below, which kill them in their own way.
    $replay = @($calls)
    while ($replay.Count -gt 0 -and $replay[$replay.Count - 1].argv -contains 'kill-pane') { $replay = @($replay[0..($replay.Count - 2)]) }
    foreach ($c in $replay) {
        $n++
        $argv = @($c.argv)
        # The pipe is the scenario's own.
        if ($argv.Count -ge 2 -and $argv[0] -eq '-S') { $argv = $argv[2..($argv.Count - 1)] }
        $argv = @($argv | ForEach-Object { Convert-Ids ([string]$_) })

        $stdin = $null
        if ($null -ne $c.stdin) {
            $len = 0
            if ("$($c.stdin)" -match '^(\d+) bytes$') { $len = [int]$Matches[1] } else { $len = ("$($c.stdin)").Length }
            $stdin = ('x' * [Math]::Max($len, 1))
        }

        # Pane commands become fake teammates.
        $verb = if ($argv.Count) { $argv[0] } else { '' }
        $marker = $null
        if ($verb -in 'respawn-pane', 'split-window') {
            $dd = [array]::IndexOf($argv, '--')
            if ($dd -ge 0 -and $dd -lt $argv.Count - 1 -and $argv[$dd + 1] -ne 'cat') {
                $teammates++
                $marker = "mate$teammates"
                $argv = @($argv[0..$dd]) + @(Get-FakeCommand $marker)
            }
        }
        $isLayout = $verb -in 'split-window', 'respawn-pane', 'select-layout', 'resize-pane', 'kill-pane'

        $r = Tm $argv $stdin
        $want = Convert-Ids ([string]$c.stdout)
        $exp = [string]$c.stdout
        if ($r.Code -ne 0) { throw "call $n ($($argv -join ' ')): exit $($r.Code), stderr '$($r.Stderr.Trim())'" }
        if ($r.Stdout.Contains("`r")) { throw "call $n ($verb): stdout has a CR: $($r.Stdout | ConvertTo-Json -Compress)" }
        if ($verb -eq 'split-window' -and $exp -match '^(%\d+)\n$') {
            # The fixture's new pane id is learned from the live answer.
            if ($r.Stdout -notmatch '^%\d+\n$') { throw "call $n : split-window printed '$($r.Stdout)'" }
            $map[$Matches[0].Trim()] = $r.Stdout.Trim()
            $map[$exp.Trim()] = $r.Stdout.Trim()
        } elseif ($exp -ne '') {
            if ($r.Stdout -ne $want) { throw "call $n ($($argv -join ' ')): stdout '$($r.Stdout | ConvertTo-Json -Compress)', expected '$($want | ConvertTo-Json -Compress)'" }
        }
        if ($marker) {
            $m = Read-Marker $marker
            if ($m -notmatch '^%\d+$') { throw "marker $marker holds '$m'" }
        }
        if ($isLayout) {
            $layoutChanges++
            # One line typed into the leader after each layout change.
            Start-Sleep -Milliseconds 700
            Type-Leader "after $verb"
        }
    }
    Write-E2eInfo ("replay: {0} calls in {1:N1} s" -f $replay.Count, $replayStart.Elapsed.TotalSeconds)

    # --- the spawn ---
    Wait-PaneCount 3 'after the replay'
    $panes = Get-Panes
    $s = Get-GhosttyState -Class $g.Class
    $w = @($s.windows)[0]
    $contentW = [int]($w.client[2] - $w.client[0])
    $surfaces = @(@($w.tabs)[0].surfaces)
    $leaderSurf = @($surfaces | Where-Object { $_.id -eq @($panes | Where-Object { $_.pane -eq $leader })[0].surface })[0]
    $leaderW = [int]($leaderSurf.rect[2] - $leaderSurf.rect[0])
    $cellW = [int]$w.cell[0]
    $share = $leaderW / [double]$contentW
    if ([Math]::Abs($share - 0.3) * $contentW -gt $cellW + 2) {
        throw ("leader width {0} px of {1} px ({2:P1}) is not 30% +- 1 cell" -f $leaderW, $contentW, $share)
    }
    $others = @($surfaces | Where-Object { $_.id -ne $leaderSurf.id })
    if ($others.Count -ne 2) { throw "expected 2 teammate surfaces, found $($others.Count)" }
    $h0 = [int]($others[0].rect[3] - $others[0].rect[1]); $h1 = [int]($others[1].rect[3] - $others[1].rect[1])
    if ([Math]::Abs($h0 - $h1) -gt 1) { throw "teammate boxes differ in height: $h0 vs $h1" }
    foreach ($i in 1..$teammates) {
        $m = Read-Marker "mate$i"
        if (@($panes | Where-Object { $_.pane -eq $m }).Count -ne 1) { throw "mate$i reports TMUX_PANE '$m', not a live pane" }
    }
    Save-Evidence -Tag 'tmux-replay-spawned' -G $g -Window

    # --- minimized: everything still works ---
    [void][GhosttyE2e.Replay]::ShowWindow($g.Hwnd, 6)
    if (-not (Wait-Until -TimeoutSec 4 -PollMs 100 -Condition { [GhosttyE2e.Replay]::IsIconic($g.Hwnd) })) { throw 'the window did not minimize' }
    $r = Expect-Ok (Tm @('split-window', '-d', '-t', $leader, '-v', '-P', '-F', '#{pane_id}', '--', (Get-FakeCommand 'min'))) 'split while minimized'
    $minPane = $r.Stdout.Trim()
    if ($minPane -notmatch '^%\d+$') { throw "split while minimized printed '$($r.Stdout)'" }
    $r = Expect-Ok (Tm @('respawn-pane', '-k', '-t', $minPane, '--', (Get-FakeCommand 'min2'))) 'respawn while minimized'
    $r = Expect-Ok (Tm @('display-message', '-p', '-t', $minPane, '#{pane_width}')) 'display-message while minimized'
    if ([int]$r.Stdout.Trim() -le 0) { throw "pane_width while minimized is '$($r.Stdout.Trim())'" }
    [void][GhosttyE2e.Replay]::ShowWindow($g.Hwnd, 9)
    if (-not (Wait-Until -TimeoutSec 4 -PollMs 100 -Condition { -not [GhosttyE2e.Replay]::IsIconic($g.Hwnd) })) { throw 'the window did not restore' }
    $m = Read-Marker 'min2'
    if ($m -ne $minPane) { throw "min2 reports '$m', expected '$minPane'" }
    Wait-PaneCount 4 'after the minimized split'
    Type-Leader 'after restore'

    # --- exit handling ---
    $pa = $map['%2']
    $pb = $map['%3']
    # A: remain-on-exit failed (set by the fixture), exit 0 -> closes.
    Expect-Ok (Tm @('respawn-pane', '-k', '-t', $pa, '--', (Get-FakeCommand 'exitA' 'exit 0'))) 'respawn A' | Out-Null
    if (-not (Wait-Until -TimeoutSec 10 -PollMs 150 -Condition { @(Get-Panes | Where-Object { $_.pane -eq $pa }).Count -eq 0 })) {
        throw "pane $pa (exit 0, remain-on-exit failed) is still there"
    }
    # B: exit 3 -> stays, reported dead.
    Expect-Ok (Tm @('set-option', '-p', '-t', $pb, 'remain-on-exit', 'failed')) 'set remain-on-exit B' | Out-Null
    Expect-Ok (Tm @('respawn-pane', '-k', '-t', $pb, '--', (Get-FakeCommand 'exitB' 'exit 3'))) 'respawn B' | Out-Null
    $dead = Wait-Until -TimeoutSec 10 -PollMs 200 -Condition {
        $d = Tm @('display-message', '-p', '-t', $pb, '#{pane_dead}')
        $d.Code -eq 0 -and $d.Stdout.Trim() -eq '1'
    }
    if (-not $dead) { throw "pane $pb (exit 3, remain-on-exit failed) did not stay dead" }
    Save-Evidence -Tag 'tmux-replay-exit' -G $g -Window

    # --- kill-pane while a close dialog is up ---
    Send-Line $g.Hwnd 'ping -t 127.0.0.1 > /dev/null'
    if (-not (Wait-ChildNamed $g @('ping.exe') 15)) { throw 'ping.exe never started in the leader' }
    Start-Sleep -Milliseconds 400
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'close_surface')
    $dlg = Wait-Until -TimeoutSec 8 -PollMs 100 -Condition { [GhosttyE2e.Win]::TopLevel([uint32]$g.Pid, 'GhosttyDialog') | Select-Object -First 1 }
    if (-not $dlg) { throw 'no close confirmation dialog' }
    $victim = $minPane
    $r = Tm @('kill-pane', '-t', $victim)
    if ($r.Code -ne 0) { throw "kill-pane behind the dialog: exit $($r.Code), stderr '$($r.Stderr.Trim())'" }
    [void][GhosttyE2e.Win]::PostMessageW($dlg, $script:TDM_CLICK_BUTTON, [IntPtr]$script:IdCancel, [IntPtr]::Zero)
    if (-not (Wait-Until -TimeoutSec 5 -PollMs 100 -Condition { -not [GhosttyE2e.Win]::IsWindow($dlg) })) { throw 'the dialog did not go away after Cancel' }
    # The leader's ping goes away again.
    foreach ($p in @(Get-ProcessTree $g.Pid | Where-Object { $_.Name -ieq 'ping.exe' })) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }

    # --- parallel kill ---
    [void][GhosttyE2e.Replay]::ShowWindow($g.Hwnd, 3)
    Start-Sleep -Milliseconds 800
    $made = 0
    $dir = '-h'
    for ($attempt = 0; $attempt -lt 30 -and $made -lt 6; $attempt++) {
        $live = @(Get-Panes | Where-Object { $_.pane -ne $leader })
        $target = if ($live.Count) { [string]$live[$attempt % $live.Count].pane } else { $leader }
        $r = Tm @('split-window', '-d', '-t', $target, $dir, '-P', '-F', '#{pane_id}', '--', (Get-FakeCommand "pk$attempt"))
        if ($r.Code -eq 0) { $made++ } elseif ($r.Stderr -notmatch 'no space|too small') { throw "split-window: $($r.Stderr.Trim())" }
        $dir = if ($dir -eq '-h') { '-v' } else { '-h' }
    }
    $victims = @(Get-Panes | Where-Object { $_.pane -ne $leader } | ForEach-Object { [string]$_.pane })
    if ($victims.Count -lt 4) { throw "only $($victims.Count) panes to kill in parallel" }
    Write-E2eInfo "parallel kill of $($victims.Count) panes"
    $runs = @($victims | ForEach-Object { Start-TmuxProc $g @('kill-pane', '-t', $_) $null $leader })
    $codes = @($runs | ForEach-Object { (Wait-TmuxProc $_ 20000) })
    $bad = @($codes | Where-Object { $_.Code -ne 0 })
    if ($bad.Count) { throw "parallel kill-pane: $($bad.Count) failed, first: exit $($bad[0].Code) '$($bad[0].Stderr.Trim())'" }
    Wait-PaneCount 1 'after the parallel kill'
    foreach ($v in $victims[0..1]) {
        $r = Tm @('kill-pane', '-t', $v)
        if ($r.Code -ne 1 -or $r.Stderr -notmatch "can't find pane") { throw "kill-pane of a dead pane: exit $($r.Code), stderr '$($r.Stderr.Trim())'" }
    }
    [void][GhosttyE2e.Replay]::ShowWindow($g.Hwnd, 9)

    # --- load-buffer -w sets the clipboard ---
    Expect-Ok (Tm @('load-buffer', '-w', '-') 'm4-clip') 'load-buffer -w' | Out-Null
    $got = Invoke-ClipboardRetry { [System.Windows.Forms.Clipboard]::GetText() }
    if ($got -ne 'm4-clip') { throw "clipboard holds '$got', expected 'm4-clip'" }

    # --- the leader's typing ---
    $lp = Join-Path $sbx 'leader.txt'
    Start-Sleep -Milliseconds 800
    $have = if (Test-Path -LiteralPath $lp) { @(Get-Content -LiteralPath $lp) } else { @() }
    $lost = @($leaderLines | Where-Object { $have -notcontains $_ })
    Write-E2eInfo ("leader typing: typed {0}, arrived {1}, lost {2} [{3}]" -f $leaderLines.Count, ($leaderLines.Count - $lost.Count), $lost.Count, ($lost -join ','))
    if ($lost.Count -gt 0) { throw "the leader lost typed lines: $($lost -join ', ')" }

    # --- Ghostty dies: no strays, tmux.exe says so ---
    Expect-Ok (Tm @('split-window', '-d', '-t', $leader, '-h', '-P', '-F', '#{pane_id}', '--', (Get-FakeCommand 'c1'))) 'crash setup 1' | Out-Null
    Expect-Ok (Tm @('split-window', '-d', '-t', $leader, '-v', '-P', '-F', '#{pane_id}', '--', (Get-FakeCommand 'c2'))) 'crash setup 2' | Out-Null
    Expect-Ok (Tm @('split-window', '-d', '-t', $leader, '-v', '-P', '-F', '#{pane_id}', '--', 'cat')) 'crash setup idle' | Out-Null
    [void](Read-Marker 'c1'); [void](Read-Marker 'c2')
    $snapshot = @(Get-ProcessTree $g.Pid)
    if (@($snapshot | Where-Object { $_.Name -ieq 'tmux.exe' }).Count -lt 1) { throw 'no __idle tmux.exe in the process tree' }
    Restore-ClipboardText $saved
    $oldPid = $g.Pid
    Stop-Process -Id $oldPid -Force
    Assert-NoSurvivors $snapshot $oldPid 10 -HostsMayLinger
    $t = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-Tmux $g @('list-panes') $null 15000 '' $pipe
    if ($r.Code -ne 1 -or $r.Stderr -notmatch 'no server running') { throw "after the crash: exit $($r.Code), stderr '$($r.Stderr.Trim())'" }
    if ($t.ElapsedMilliseconds -gt 2000) { throw "tmux.exe took $($t.ElapsedMilliseconds) ms to notice that Ghostty is gone" }
}
