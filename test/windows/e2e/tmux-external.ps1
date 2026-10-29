# e2e: milestone=M5 timeout=240 order=975
# tmux-external: the opt-in external tmux pipe (R-M5-14). With
# `windows-tmux-external = true` the primary instance serves
# \\.\pipe\ghostty-tmux-<SID>-<session>-<class>: `tmux.exe -L <name>` (TMUX
# removed, GHOSTTY_TMUX_CLASS naming the sandbox instance) reaches it and
# `has-session -t claude-swarm` says "can't find session: claude-swarm"
# (exit 1); a raw request without a namespace is refused (code 2) and so is
# one with a namespace on the per-process pipe; a reload to false releases the
# pipe ("no server running on ..."); with the key false (the default) there is
# no pipe at all. Task 18 adds fake teammates: new-session -d makes a Ghostty
# window without taking the foreground, two splits and `tiled` give 3 panes,
# kill-server closes the window. Keep this file ASCII only.
. (Join-Path $PSScriptRoot '_common.ps1')
. (Join-Path $PSScriptRoot '_tmux.ps1')
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

# tmux.exe without -S: TMUX and TMUX_PANE removed, the instance named through
# GHOSTTY_TMUX_CLASS.
function Invoke-TmuxExt($G, [string[]]$TmuxArgs, [hashtable]$Env = @{}) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:TmuxExe
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $script:Sbx.Tmp
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding $false
    $psi.StandardErrorEncoding = New-Object System.Text.UTF8Encoding $false
    $psi.Arguments = (@($TmuxArgs | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' ')
    foreach ($n in 'TMUX', 'TMUX_PANE', 'GHOSTTY_TMUX_TRACE', 'GHOSTTY_TMUX_STATS') { [void]$psi.EnvironmentVariables.Remove($n) }
    $psi.EnvironmentVariables['GHOSTTY_TMUX_CLASS'] = $G.Class
    foreach ($k in $Env.Keys) { $psi.EnvironmentVariables[[string]$k] = [string]$Env[$k] }
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $out = $p.StandardOutput.ReadToEndAsync()
    $err = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(15000)) { try { $p.Kill() } catch {}; throw "tmux.exe $($TmuxArgs -join ' ') did not exit within 15 s" }
    [pscustomobject]@{ Code = $p.ExitCode; Stdout = $out.Result; Stderr = $err.Result }
}

# One raw request frame to a pipe; returns the parsed response.
function Send-RawTmux([string]$PipeName, [string]$Json) {
    $short = $PipeName -replace '^\\\\\.\\pipe\\', ''
    $pipe = New-Object IO.Pipes.NamedPipeClientStream '.', $short, ([IO.Pipes.PipeDirection]::InOut), ([IO.Pipes.PipeOptions]::None)
    try {
        $pipe.Connect(5000)
        $payload = [Text.Encoding]::UTF8.GetBytes($Json)
        $frame = New-Object 'byte[]' (4 + $payload.Length)
        [BitConverter]::GetBytes([uint32]$payload.Length).CopyTo($frame, 0)
        $payload.CopyTo($frame, 4)
        $pipe.Write($frame, 0, $frame.Length)
        $pipe.Flush()
        $head = New-Object 'byte[]' 4
        [void]$pipe.Read($head, 0, 4)
        $len = [BitConverter]::ToUInt32($head, 0)
        $body = New-Object 'byte[]' $len
        $got = 0
        while ($got -lt $len) { $n = $pipe.Read($body, $got, $len - $got); if ($n -le 0) { break }; $got += $n }
        [Text.Encoding]::UTF8.GetString($body, 0, $got) | ConvertFrom-Json
    } finally { $pipe.Dispose() }
}

function Assert-Failed($R, [string]$Want, [string]$What) {
    if ($R.Code -ne 1) { throw "$What : exit code $($R.Code), expected 1 (stderr '$($R.Stderr)')" }
    if ($R.Stderr -notlike $Want) { throw "$What : stderr is '$($R.Stderr.TrimEnd())', expected '$Want'" }
}

Invoke-E2eScenario 'tmux-external' {
    if (-not (Test-Path -LiteralPath $script:TmuxExe)) { throw "missing $script:TmuxExe (run zig build first)" }

    # --- Key true: the user pipe is served. -----------------------------------
    $g = Start-E2eGhostty -ConfigText ($script:BaseConfig + "`nwindows-tmux-external = true`nwindows-tmux-shim = true`n")
    $s = Get-GhosttyState -Class $g.Class
    $user = [string]$s.tmux.user_pipe
    if ($user -notmatch '^..[.].pipe.ghostty-tmux-S-1-[0-9]+(-[0-9]+)+-[ua]-[0-9]+-.+') { throw "unexpected user pipe name '$user'" }
    if ($user -notmatch '-u-[0-9]+-') { throw "the sandbox Ghostty is not elevated, but the pipe is '$user'" }
    if (-not [string]$s.tmux.pipe) { throw 'the per-process pipe is missing' }

    $r = Invoke-TmuxExt $g @('-L', 'claude-swarm-1', 'has-session', '-t', 'claude-swarm')
    Assert-Failed $r "can't find session: claude-swarm*" '-L claude-swarm-1 has-session'
    $r = Invoke-TmuxExt $g @('has-session', '-t', 'claude-swarm')
    Assert-Failed $r "can't find session: claude-swarm*" 'default namespace has-session'
    # -L wins even when TMUX is set (to a pipe that does not exist).
    $r = Invoke-TmuxExt $g @('-L', 'w', 'has-session', '-t', 'x') @{ TMUX = '\\.\pipe\ghostty-tmux-1-0000000000000000,1,0' }
    Assert-Failed $r "can't find session: x*" '-L with TMUX set'
    # No session yet: nothing to target.
    $r = Invoke-TmuxExt $g @('-L', 'w', 'list-panes')
    Assert-Failed $r 'no current target*' 'list-panes without a session'

    # Raw requests: the user pipe needs a namespace, the per-process pipe refuses one.
    $r1 = Send-RawTmux $user '{"v":1,"op":"tmux","args":["has-session"]}'
    if ($r1.code -ne 2) { throw "user pipe without a namespace: code $($r1.code), expected 2" }
    $r2 = Send-RawTmux ([string]$s.tmux.pipe) '{"v":1,"op":"tmux","args":["list-panes"],"namespace":"w"}'
    if ($r2.code -ne 2) { throw "per-process pipe with a namespace: code $($r2.code), expected 2" }
    $r3 = Send-RawTmux $user '{"v":1,"op":"state"}'
    if ($r3.code -ne 2) { throw "user pipe with op state: code $($r3.code), expected 2" }

    # --- Session commands (Task 18): fake teammates in a namespace. ------------
    $ns = 'claude-swarm-4242'
    $nWin = { @((Get-GhosttyState -Class $g.Class).windows).Count }
    $before = & $nWin
    $fgBefore = [GhosttyE2e.Win]::GetForegroundWindow()
    $r = Invoke-TmuxExt $g @('-L', $ns, 'new-session', '-d', '-s', 'claude-swarm', '-n', 'swarm-view', '-P', '-F', '#{pane_id}', '--', 'cat')
    if ($r.Code -ne 0) { throw "new-session: exit $($r.Code): $($r.Stderr)" }
    $p1 = $r.Stdout.Trim()
    if ($p1 -notmatch '^%\d+$') { throw "new-session printed '$p1'" }
    if (-not (Wait-Until -TimeoutSec 10 -PollMs 150 -Condition { (& $nWin) -eq $before + 1 })) { throw 'no new Ghostty window for the session' }
    if ([GhosttyE2e.Win]::GetForegroundWindow() -ne $fgBefore) { throw 'the new window took the foreground' }
    $r = Invoke-TmuxExt $g @('-L', $ns, 'has-session', '-t', 'claude-swarm')
    if ($r.Code -ne 0) { throw "has-session after new-session: exit $($r.Code): $($r.Stderr)" }
    $r = Invoke-TmuxExt $g @('-L', $ns, 'list-windows', '-t', 'claude-swarm', '-F', '#{window_name}')
    if ($r.Stdout.Trim() -ne 'swarm-view') { throw "list-windows printed '$($r.Stdout.Trim())'" }
    # Two teammates: split like Claude Code does, then tile.
    $r = Invoke-TmuxExt $g @('-L', $ns, 'split-window', '-d', '-t', $p1, '-v', '-P', '-F', '#{pane_id}', '--', 'cat')
    if ($r.Code -ne 0) { throw "split 1: $($r.Stderr)" }
    $r = Invoke-TmuxExt $g @('-L', $ns, 'split-window', '-d', '-t', $p1, '-h', '-P', '-F', '#{pane_id}', '--', 'cat')
    if ($r.Code -ne 0) { throw "split 2: $($r.Stderr)" }
    $r = Invoke-TmuxExt $g @('-L', $ns, 'select-layout', '-t', 'claude-swarm:swarm-view', 'tiled')
    if ($r.Code -ne 0) { throw "select-layout: $($r.Stderr)" }
    $r = Invoke-TmuxExt $g @('-L', $ns, 'list-panes', '-t', 'claude-swarm:swarm-view', '-F', '#{pane_id}')
    $panes = @($r.Stdout -split "`r?`n" | Where-Object { $_ })
    if ($panes.Count -ne 3) { throw "the session has $($panes.Count) panes, expected 3: $($r.Stdout)" }
    # The leader window of this Ghostty is out of reach of the namespace.
    $r = Invoke-TmuxExt $g @('-L', $ns, 'kill-pane', '-t', '%1')
    Assert-Failed $r "can't find pane: %1*" 'kill-pane of a pane outside the namespace'
    $r = Invoke-TmuxExt $g @('-L', $ns, 'kill-server')
    if ($r.Code -ne 0) { throw "kill-server: exit $($r.Code): $($r.Stderr)" }
    if (-not (Wait-Until -TimeoutSec 10 -PollMs 150 -Condition { (& $nWin) -eq $before })) { throw 'kill-server did not close the namespace window' }
    $r = Invoke-TmuxExt $g @('-L', $ns, 'has-session', '-t', 'claude-swarm')
    Assert-Failed $r "can't find session: claude-swarm*" 'has-session after kill-server'

    # --- A reload to false releases the pipe. ---------------------------------
    $path = Join-Path $script:Sbx.Home '.config\ghostty\config.ghostty'
    $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    [IO.File]::WriteAllText($path, $text + "`nwindows-tmux-external = false`n", (New-Object Text.UTF8Encoding $false))
    Invoke-GhosttyAction -Class $g.Class -Action 'reload_config' | Out-Null
    $gone = Wait-Until -TimeoutSec 10 -PollMs 150 -Condition { -not [string](Get-GhosttyState -Class $g.Class).tmux.user_pipe }
    if (-not $gone) { throw 'the user pipe is still reported after a reload to false' }
    $r = Invoke-TmuxExt $g @('-L', 'w', 'has-session', '-t', 'x')
    Assert-Failed $r 'no server running on *' 'after the reload to false'

    # ... and a reload back to true claims it again.
    [IO.File]::WriteAllText($path, $text + "`nwindows-tmux-external = true`n", (New-Object Text.UTF8Encoding $false))
    Invoke-GhosttyAction -Class $g.Class -Action 'reload_config' | Out-Null
    $back = Wait-Until -TimeoutSec 10 -PollMs 150 -Condition { [string](Get-GhosttyState -Class $g.Class).tmux.user_pipe }
    if (-not $back) { throw 'the user pipe did not come back after a reload to true' }
    $r = Invoke-TmuxExt $g @('-L', 'w', 'has-session', '-t', 'x')
    Assert-Failed $r "can't find session: x*" 'after the reload back to true'
    Invoke-GhosttyAction -Class $g.Class -Action 'quit' | Out-Null
    [void](Wait-ProcessExit $g 10)

    # --- Key false (the default): no user pipe, "no server running". ---------
    $g = Start-E2eGhostty -ConfigText ($script:BaseConfig + "`nwindows-tmux-shim = true`n")
    $s = Get-GhosttyState -Class $g.Class
    if ([string]$s.tmux.user_pipe) { throw "user pipe '$($s.tmux.user_pipe)' exists with windows-tmux-external = false" }
    $r = Invoke-TmuxExt $g @('-L', 'claude-swarm-1', 'has-session', '-t', 'claude-swarm')
    Assert-Failed $r 'no server running on claude-swarm-1*' 'key false'
    $r = Invoke-TmuxExt $g @('has-session', '-t', 'claude-swarm')
    Assert-Failed $r 'no server running on *' 'key false, no -L'
}
