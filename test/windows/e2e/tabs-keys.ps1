# e2e: milestone=M2 timeout=90 order=220
# tabs-keys: the default tab bindings with real key presses on cmd.exe:
# Ctrl+Shift+T opens a tab, Ctrl+Tab cycles, Ctrl+Shift+W closes the tab.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\GhosttyIpc.psm1') -Force

Invoke-E2eScenario 'tabs-keys' {
    $g = Start-E2eGhostty -ConfigText "confirm-close-surface = false`ncommand = direct:cmd.exe /k chcp 65001`n"
    Set-WindowLayout $g.Hwnd '00000409'
    if (-not (Get-ShellProcess $g)) { throw 'no shell started' }

    function Get-Win {
        $r = Get-GhosttyState -Class $g.Class
        $d = if ($r.PSObject.Properties['data']) { $r.data } else { $r }
        @($d.windows)[0]
    }
    function Wait-Win([string]$What, [scriptblock]$Predicate, [double]$TimeoutSec = 8) {
        $w = Wait-Until -TimeoutSec $TimeoutSec -PollMs 100 -Condition {
            $w = Get-Win
            if ($w -and (& $Predicate $w)) { $w }
        }
        if (-not $w) {
            $now = Get-Win | ConvertTo-Json -Depth 8 -Compress
            throw "timeout waiting for: $What; state: $now"
        }
        $w
    }

    # 1. Ctrl+Shift+T: a second tab, active.
    Invoke-SendInput -Hwnd $g.Hwnd -Keys 'ctrl+shift+t'
    [void](Wait-Win 'two tabs, active 1' { param($w) @($w.tabs).Count -eq 2 -and $w.active_tab -eq 1 })

    # 2. Ctrl+Tab: next tab, wrapping to tab 0.
    Invoke-SendInput -Hwnd $g.Hwnd -Keys 'ctrl+tab'
    [void](Wait-Win 'active 0' { param($w) @($w.tabs).Count -eq 2 -and $w.active_tab -eq 0 })

    # 3. Ctrl+Shift+W: closes the active tab (no confirmation, the config
    # turns it off).
    Invoke-SendInput -Hwnd $g.Hwnd -Keys 'ctrl+shift+w'
    [void](Wait-Win 'one tab left' { param($w) @($w.tabs).Count -eq 1 })
}
