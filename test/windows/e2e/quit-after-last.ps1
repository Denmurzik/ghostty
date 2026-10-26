# e2e: milestone=M2 timeout=120 order=440
# quit-after-last: with quit-after-last-window-closed = true there is no tray
# icon and closing the last window ends the process within 3 s; with a
# 2 s delay the process is alive at 1 s and gone by 4 s, and a launch that
# forwards a new window inside the delay keeps it running.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\GhosttyIpc.psm1') -Force

$script:WM_CLOSE = 0x10

function Close-Window($G) {
    [void][GhosttyE2e.Win]::PostMessageW($G.Hwnd, $script:WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
}

Invoke-E2eScenario 'quit-after-last' {
    $delayed = (Get-Content -LiteralPath (Get-ConfigPath 'gitbash-de') -Raw -Encoding UTF8) + "`nquit-after-last-window-closed-delay = 2s`n"
    # 1. No delay: no icon, the process ends with its last window.
    $a = Start-E2eGhostty -ConfigFile (Get-ConfigPath 'gitbash-de')
    Wait-BashReady $a
    $s = Get-GhosttyState -Class $a.Class
    if ($s.tray.visible) { throw 'state.tray.visible is true with quit-after-last-window-closed = true' }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Close-Window $a
    $exit = Wait-ProcessExit $a 5
    if (-not $exit.Exited) { throw 'the process outlived its last window' }
    if ($sw.ElapsedMilliseconds -gt 3000) { throw "exit took $($sw.ElapsedMilliseconds) ms (limit 3000 ms)" }

    # 2. A 2 s delay: alive at 1 s, gone by 4 s.
    $b = Start-E2eGhostty -ConfigText $delayed
    Wait-BashReady $b
    $sw.Restart()
    Close-Window $b
    Start-Sleep -Milliseconds 1000
    $b.Process.Refresh()
    if ($b.Process.HasExited) { throw "the process ended $($sw.ElapsedMilliseconds) ms after the last window, before the 2 s delay" }
    $exit = Wait-ProcessExit $b 3
    if (-not $exit.Exited) { throw 'the process was still running 4 s after its last window closed' }
    Write-E2eInfo "delayed quit after $($sw.ElapsedMilliseconds) ms"

    # 3. A window opened inside the delay keeps the process running.
    $c = Start-E2eGhostty -ConfigText $delayed
    Wait-BashReady $c
    Close-Window $c
    Start-Sleep -Milliseconds 300
    $d = Start-Launch $c.Class @()
    if (-not $d.WaitForExit(2000)) { throw 'the forwarding launch was still running after 2 s' }
    Start-Sleep -Seconds 3
    $c.Process.Refresh()
    if ($c.Process.HasExited) { throw 'a window opened inside the delay did not keep the process running' }
    $s = Get-GhosttyState -Class $c.Class
    if (@($s.windows).Count -ne 1) { throw "expected 1 window after the forwarded launch, got $(@($s.windows).Count)" }
}
