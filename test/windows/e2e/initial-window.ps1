# e2e: milestone=M5 timeout=90 order=990
# initial-window: with `initial-window = false` ghostty starts with no window
# (the process and the tray stay), and a second launch (the jump list / tray
# path) opens the first window. PENDING: written, not yet run (the desktop
# was in use). Keep this file ASCII only.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\GhosttyIpc.psm1') -Force

Invoke-E2eScenario 'initial-window' {
    $g = Start-E2eGhostty -KeepDefaultQuit -ConfigText "initial-window = false`n" -WindowTimeoutSec 4 -AllowNoWindow
    Start-Sleep -Milliseconds 800
    $g.Process.Refresh()
    if ($g.Process.HasExited) { throw 'the process ended with initial-window = false' }
    if (@(Get-GhosttyWindows $g).Count -ne 0) { throw 'a window exists with initial-window = false' }
    $s = Get-GhosttyState -Class $g.Class
    if (@($s.windows).Count -ne 0) { throw "state lists $(@($s.windows).Count) windows" }

    $l = Start-Launch $g.Class @()
    if (-not $l.WaitForExit(5000)) { throw 'the forwarding launch did not exit' }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (@(Get-GhosttyWindows $g).Count -lt 1 -and $sw.Elapsed.TotalSeconds -lt 10) { Start-Sleep -Milliseconds 100 }
    if (@(Get-GhosttyWindows $g).Count -ne 1) { throw 'the forwarded launch did not open a window' }
}
