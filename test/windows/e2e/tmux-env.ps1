# e2e: milestone=M4 timeout=180 order=710
# tmux-env: every pane gets TMUX (the Ghostty tmux pipe, the Ghostty pid, 0),
# its own TMUX_PANE and the directory of tmux.exe first on PATH; the key
# `windows-tmux-shim = false` leaves an inherited TMUX alone and does not
# touch PATH.
. (Join-Path $PSScriptRoot '_common.ps1')
. (Join-Path $PSScriptRoot '_tmux.ps1')
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

Invoke-E2eScenario 'tmux-env' {
    $binDir = Split-Path -Parent $script:TmuxExe
    if (-not (Test-Path -LiteralPath $script:TmuxExe)) { throw "missing $script:TmuxExe (run zig build first)" }
    $msysBin = ConvertTo-MsysPath $binDir

    # Types one line into the focused pane; the shell writes
    # TMUX|TMUX_PANE|command -v tmux|PATH to $File.
    function Read-PaneEnv($G, [string]$File) {
        $path = Join-Path $script:Sbx.Tmp $File
        Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
        [void](Set-ForegroundSafe -Hwnd $G.Hwnd)
        Send-Line $G.Hwnd ('printf ''%s|%s|%s|%s\n'' "$TMUX" "$TMUX_PANE" "$(command -v tmux)" "$PATH" > "$TEMP/' + $File + '"')
        if (-not (Wait-File $path 20)) { throw "the shell never wrote $path" }
        $text = (Read-ShellFile $path).Utf8.TrimEnd("`r", "`n")
        $f = $text -split '\|', 4
        if ($f.Count -ne 4) { throw "unexpected shell output '$text'" }
        # Git Bash's profile puts its own ~/bin first; the first entry that is a
        # Windows drive path is where the Ghostty directory must be.
        $head = @($f[3] -split ':' | Where-Object { $_ -match '^/[a-z]/' })[0]
        [pscustomobject]@{ Tmux = $f[0]; Pane = $f[1]; Command = $f[2]; PathHead = [string]$head }
    }

    # --- enabled (default) ---
    $g = Start-BashE2e
    if (-not (Wait-Until -TimeoutSec 10 -Condition { @(Get-TmuxPanes $g).Count -eq 1 })) { throw 'the state does not list exactly one tmux pane' }
    $first = @(Get-TmuxPanes $g)[0]
    $pipe = Get-TmuxPipe $g
    if ($pipe -notmatch '^\\\\\.\\pipe\\ghostty-tmux-\d+-[0-9a-f]{16}$') { throw "tmux pipe name is '$pipe'" }

    $e = Read-PaneEnv $g 'tmux-env-1.txt'
    $wantTmux = "$pipe,$($g.Pid),0"
    if ($e.Tmux -ne $wantTmux) { throw "TMUX is '$($e.Tmux)', expected '$wantTmux'" }
    if ($e.Pane -ne [string]$first.pane) { throw "TMUX_PANE is '$($e.Pane)', state says '$($first.pane)'" }
    if ($e.Command -ine "$msysBin/tmux") { throw "command -v tmux is '$($e.Command)', expected '$msysBin/tmux'" }
    if ($e.PathHead -ine $msysBin) { throw "first PATH entry is '$($e.PathHead)', expected '$msysBin'" }
    if ([string]$first.env_tmux_pane -ne [string]$first.pane) { throw "state env_tmux_pane '$($first.env_tmux_pane)' differs from pane '$($first.pane)'" }

    # A second surface, checked from the state alone (no typing).
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'new_split:right')
    [void](Wait-GhosttyState -Class $g.Class -TimeoutSec 15 -Predicate { @($_.tmux.panes).Count -eq 2 })
    $both = @(Get-TmuxPanes $g)
    $second = @($both | Where-Object { $_.pane -ne $first.pane })[0]
    if (-not $second) { throw 'the second surface has the same pane as the first' }
    if ([string]$second.env_tmux_pane -ne [string]$second.pane) { throw "second pane env_tmux_pane '$($second.env_tmux_pane)' differs from its pane '$($second.pane)'" }
    if ([string]$second.env_tmux_pane -eq [string]$first.env_tmux_pane) { throw 'both panes got the same TMUX_PANE' }

    # The real host answers: the pane format of the caller's own pane.
    $r = Invoke-Tmux $g @('display-message', '-p', '-t', [string]$first.pane, '#{pane_id}')
    if ($r.Code -ne 0 -or $r.Stdout -ne "$($first.pane)`n") {
        throw "display-message: exit $($r.Code), stdout '$($r.Stdout)', stderr '$($r.Stderr.Trim())'"
    }
    Stop-OwnGhostty

    # --- windows-tmux-shim = false with an inherited TMUX ---
    $text = (Get-Content -LiteralPath (Get-ConfigPath 'gitbash-de') -Raw -Encoding UTF8).TrimEnd() + "`nwindows-tmux-shim = false`n"
    $g2 = Start-E2eGhostty -ConfigText $text -Env @{ TMUX = 'outer'; TMUX_PANE = $null }
    Wait-BashReady $g2
    $e2 = Read-PaneEnv $g2 'tmux-env-2.txt'
    if ($e2.Tmux -ne 'outer') { throw "disabled: TMUX is '$($e2.Tmux)', expected the inherited 'outer'" }
    if ($e2.Pane -ne '') { throw "disabled: TMUX_PANE is '$($e2.Pane)', expected empty" }
    if ($e2.PathHead -ieq $msysBin) { throw 'disabled: the tmux.exe directory is first on PATH' }
    $p2 = @(Get-TmuxPanes $g2)[0]
    if ($null -ne $p2.env_tmux_pane) { throw "disabled: state env_tmux_pane is '$($p2.env_tmux_pane)', expected null" }
}
