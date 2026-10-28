# e2e: milestone=M4 timeout=420 order=730
# tmux-send-keys: `send-keys` right after `split-window` must not lose the first
# byte of the typed line (Git Bash drops the first byte after a pty resize;
# the R-M4-6 gate holds the bytes back), and `capture-pane -p` shows the
# visible screen. 20 rounds: split, send-keys at once, check the file the
# command wrote and the capture, kill the pane.
. (Join-Path $PSScriptRoot '_common.ps1')
. (Join-Path $PSScriptRoot '_tmux.ps1')
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

Invoke-E2eScenario 'tmux-send-keys' {
    if (-not (Test-Path -LiteralPath $script:TmuxExe)) { throw "missing $script:TmuxExe (run zig build first)" }
    $g = Start-BashE2e
    if (-not (Wait-Until -TimeoutSec 10 -Condition { @(Get-TmuxPanes $g).Count -eq 1 })) { throw 'the state does not list exactly one tmux pane' }

    for ($i = 1; $i -le 20; $i++) {
        $file = "tmux-send-keys-$i.txt"
        $path = Join-Path $script:Sbx.Tmp $file
        Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue

        $s = Invoke-Tmux $g @('split-window', '-d', '-P', '-F', '#{pane_id}')
        if ($s.Code -ne 0) { throw "round ${i}: split-window exit $($s.Code): $($s.Stderr.Trim())" }
        $pane = $s.Stdout.Trim()
        if ($pane -notmatch '^%\d+$') { throw "round ${i}: split-window printed '$pane'" }

        # No wait: the gate is what keeps the first byte.
        $k = Invoke-Tmux $g @('send-keys', '-t', $pane, "echo tok-$i > `"`$TEMP/$file`"; printf 'mark-%s\n' $i", 'Enter')
        if ($k.Code -ne 0) { throw "round ${i}: send-keys exit $($k.Code): $($k.Stderr.Trim())" }

        if (-not (Wait-File $path 20)) { throw "round ${i}: the pane never wrote $path (first byte lost?)" }
        $text = (Read-ShellFile $path).Utf8.TrimEnd("`r", "`n")
        if ($text -ne "tok-$i") { throw "round ${i}: the file holds '$text', expected 'tok-$i'" }

        $seen = $false
        $cap = $null
        for ($try = 0; $try -lt 20 -and -not $seen; $try++) {
            $cap = Invoke-Tmux $g @('capture-pane', '-p', '-t', $pane)
            if ($cap.Code -ne 0) { throw "round ${i}: capture-pane exit $($cap.Code): $($cap.Stderr.Trim())" }
            $seen = $cap.Stdout.Contains("mark-$i")
            if (-not $seen) { Start-Sleep -Milliseconds 100 }
        }
        if (-not $seen) { throw "round ${i}: capture-pane misses the output mark-${i}:`n$($cap.Stdout)" }

        $x = Invoke-Tmux $g @('kill-pane', '-t', $pane)
        if ($x.Code -ne 0) { throw "round ${i}: kill-pane exit $($x.Code): $($x.Stderr.Trim())" }
        if (-not (Wait-Until -TimeoutSec 10 -Condition { @(Get-TmuxPanes $g).Count -eq 1 })) { throw "round ${i}: the pane did not close" }
    }
}
