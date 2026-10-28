# e2e: milestone=M5 timeout=300 order=880
# undo-close: a closed tab is parked, not closed. With `ping 40 s` running in
# the second tab: close_tab parks it (shell and ping stay alive, the tab is
# gone from the state), `undo` (ctrl+shift+z) brings it back with the same
# surface id and the same ping pid; closing it again and waiting out
# undo-timeout (12 s here) ends the process tree. Closing the window (WM_CLOSE,
# like Alt+F4) parks the window, undo shows it again at the same rect. The
# palette lists "Undo". Keep this file ASCII only.
. (Join-Path $PSScriptRoot '_common.ps1')
. (Join-Path $PSScriptRoot '_splits.ps1')

Invoke-E2eScenario 'undo-close' {
    # The window outlives its last tab (no quit-after-last-window-closed), so it can be parked.
    $text = (Get-Content -LiteralPath (Get-ConfigPath 'gitbash-de') -Raw -Encoding UTF8).TrimEnd() + "`nundo-timeout = 12s`n"
    $g = Start-E2eGhostty -ConfigText $text -KeepDefaultQuit
    Wait-BashReady $g
    [void](Set-ForegroundSafe -Hwnd $g.Hwnd)

    function Get-Data { Get-IpcData (Get-GhosttyState -Class $g.Class) }
    function Get-Undo { (Get-Data).m5.undo }
    function Get-TabIds {
        $w = @((Get-Data).windows)[0]
        if (-not $w) { return @() }
        @($w.tabs | ForEach-Object { @($_.surfaces)[0].id })
    }
    function Get-Ping { Get-ProcessTree $g.Pid | Where-Object { $_.Name -ieq 'ping.exe' } | Select-Object -First 1 }

    # 1. A second tab running ping.
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'new_tab')
    [void](Wait-SurfaceCount $g 1)
    if (-not (Wait-Until -TimeoutSec 10 -PollMs 100 -Condition { @((Get-Data).windows)[0].tabs.Count -eq 2 })) { throw 'no second tab' }
    Start-Sleep -Milliseconds 2500
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'text:ping -n 40 127.0.0.1 > /dev/null')
    $ping = Wait-Until -TimeoutSec 15 -PollMs 200 -Condition { Get-Ping }
    if (-not $ping) { Save-Evidence 'no-ping' $g -Window; throw "ping.exe never started in the second tab: $(Format-Procs @(Get-ProcessTree $g.Pid))" }
    $pingPid = $ping.ProcessId
    $ids = Get-TabIds
    $second = $ids[1]

    # 2. Close it: parked, the process lives on.
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'close_tab')
    if (-not (Wait-Until -TimeoutSec 8 -PollMs 100 -Condition { (Get-Undo).parked.tabs -eq 1 })) { throw "the tab was not parked: $((Get-Undo) | ConvertTo-Json -Compress)" }
    if (@(Get-TabIds).Count -ne 1) { throw 'the parked tab is still listed' }
    if (-not (Get-Process -Id $pingPid -ErrorAction SilentlyContinue)) { throw 'ping ended when the tab was parked' }

    # 3. Undo: the same surface, the same process.
    [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
    Invoke-SendInput -Hwnd $g.Hwnd -Keys 'ctrl+shift+z'
    if (-not (Wait-Until -TimeoutSec 8 -PollMs 100 -Condition { (Get-Undo).parked.tabs -eq 0 -and @(Get-TabIds).Count -eq 2 })) { throw "undo did not bring the tab back: $((Get-Undo) | ConvertTo-Json -Compress) tabs=$(@(Get-TabIds) -join ',') win=$(@((Get-Data).windows)[0] | ConvertTo-Json -Depth 4 -Compress)" }
    if ((Get-TabIds)[1] -ne $second) { throw "the restored tab is surface $((Get-TabIds)[1]), expected $second" }
    if ((Get-Ping).ProcessId -ne $pingPid) { throw 'the process behind the restored tab changed' }

    # 4. Close again and let it expire: the tree is gone.
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'close_tab')
    if (-not (Wait-Until -TimeoutSec 8 -PollMs 100 -Condition { (Get-Undo).parked.tabs -eq 1 })) { throw 'the second close was not parked' }
    if (-not (Wait-Until -TimeoutSec 25 -PollMs 200 -Condition { (Get-Undo).parked.tabs -eq 0 })) { throw 'the parked tab did not expire' }
    if (-not (Wait-Until -TimeoutSec 10 -PollMs 200 -Condition { -not (Get-Process -Id $pingPid -ErrorAction SilentlyContinue) })) { throw 'ping survived the expiry' }

    # 5. Window close parks the window; undo shows it at the same rect.
    $r0 = New-Object GhosttyE2e.Win+RECT
    [void][GhosttyE2e.Win]::GetWindowRect($g.Hwnd, [ref]$r0)
    [void]$g.Process.CloseMainWindow()
    if (-not (Wait-Until -TimeoutSec 8 -PollMs 100 -Condition { (Get-Undo).parked.windows -eq 1 })) { throw 'the window was not parked' }
    if ([GhosttyE2e.Win]::IsWindowVisible($g.Hwnd)) { throw 'the parked window is still visible' }
    if ($g.Process.HasExited) { throw 'ghostty exited with its only window parked' }
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'undo')
    if (-not (Wait-Until -TimeoutSec 8 -PollMs 100 -Condition { (Get-Undo).parked.windows -eq 0 -and [GhosttyE2e.Win]::IsWindowVisible($g.Hwnd) })) { throw 'undo did not show the window again' }
    $r1 = New-Object GhosttyE2e.Win+RECT
    [void][GhosttyE2e.Win]::GetWindowRect($g.Hwnd, [ref]$r1)
    if ($r0.Left -ne $r1.Left -or $r0.Top -ne $r1.Top -or $r0.Right -ne $r1.Right -or $r0.Bottom -ne $r1.Bottom) { throw "the restored window has another rect: $($r0.Left),$($r0.Top),$($r0.Right),$($r0.Bottom) -> $($r1.Left),$($r1.Top),$($r1.Right),$($r1.Bottom)" }

    # 6. The palette lists Undo.
    [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'toggle_command_palette')
    if (-not (Wait-Until -TimeoutSec 8 -PollMs 100 -Condition { (Get-Data).m3.palette.open })) { throw 'the palette did not open' }
    Invoke-SendInput -Hwnd $g.Hwnd -Text 'undo' -Panel
    if (-not (Wait-Until -TimeoutSec 8 -PollMs 100 -Condition { (Get-Data).m3.palette.first -eq 'Undo' })) { throw "the palette lists '$((Get-Data).m3.palette.first)' first, expected Undo" }
    Invoke-SendInput -Hwnd $g.Hwnd -Keys 'esc' -Panel
}
