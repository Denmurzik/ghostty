# e2e: milestone=M5 timeout=90 order=900
# osk: show_on_screen_keyboard records one request in test mode (state
# osk.requests) and never starts TabTip.exe or touches the real keyboard.
# Keep this file ASCII only.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\GhosttyIpc.psm1') -Force

Invoke-E2eScenario 'osk' {
    if (-not (Find-GitBash)) { throw 'E2E-SKIP: Git Bash not found' }
    $g = Start-BashE2e

    function Get-Requests {
        $r = Get-GhosttyState -Class $g.Class
        $d = if ($r.PSObject.Properties['data']) { $r.data } else { $r }
        [int]$d.m5.osk.requests
    }
    $before = @(Get-Process -Name TabTip -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })

    if ((Get-Requests) -ne 0) { throw 'osk.requests is not 0 at start' }
    $performed = Invoke-GhosttyAction -Class $g.Class -Action 'show_on_screen_keyboard'
    if (-not $performed) { throw 'show_on_screen_keyboard was not performed' }
    $n = Get-Requests
    if ($n -ne 1) { throw "osk.requests is $n, expected 1" }

    $after = @(Get-Process -Name TabTip -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    $started = @($after | Where-Object { $before -notcontains $_ })
    if ($started.Count -ne 0) { throw "TabTip.exe was started (pid $($started -join ','))" }
}
