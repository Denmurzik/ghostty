# e2e: milestone=M3 timeout=120 order=610
# inspector: `inspector:toggle` opens a GhosttyInspector window of the
# process (own taskbar entry); a key typed in the terminal makes the
# inspector draw more frames; toggling again closes the window.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\GhosttyIpc.psm1') -Force

Invoke-E2eScenario 'inspector' {
    if (-not (Find-GitBash)) { throw 'E2E-SKIP: Git Bash not found' }
    $g = Start-BashE2e

    function Get-Insp {
        $r = Get-GhosttyState -Class $g.Class
        $d = if ($r.PSObject.Properties['data']) { $r.data } else { $r }
        $d.m3.inspector
    }
    function Get-InspectorWindows {
        @([GhosttyE2e.Win]::TopLevel([uint32]$g.Pid, 'GhosttyInspector') | Where-Object { [GhosttyE2e.Win]::IsWindowVisible($_) })
    }

    if ((Get-InspectorWindows).Count -ne 0) { throw 'an inspector window exists before the action' }

    [void](Invoke-GhosttyAction -Class $g.Class -Action 'inspector:toggle')
    if (-not (Wait-Until -TimeoutSec 8 -PollMs 100 -Condition { (Get-InspectorWindows).Count -eq 1 })) {
        throw 'inspector:toggle did not open a GhosttyInspector window'
    }
    $caption = [GhosttyE2e.Win]::TextOf((Get-InspectorWindows)[0])
    if (-not $caption.StartsWith('Inspector')) { throw "unexpected inspector caption '$caption'" }
    if ((Get-Insp).open -ne 1) { throw "state.m3.inspector.open is $((Get-Insp).open), expected 1" }

    # The tick draws a first frame, then keeps drawing while input arrives.
    if (-not (Wait-Until -TimeoutSec 5 -PollMs 100 -Condition { (Get-Insp).frames -ge 1 })) { throw 'the inspector drew no frame' }
    $before = (Get-Insp).frames
    Send-Typed $g.Hwnd 'x'
    if (-not (Wait-Until -TimeoutSec 5 -PollMs 100 -Condition { (Get-Insp).frames -gt $before })) {
        throw 'a key typed in the terminal did not advance the inspector frames'
    }

    [void](Invoke-GhosttyAction -Class $g.Class -Action 'inspector:toggle')
    if (-not (Wait-Until -TimeoutSec 5 -PollMs 100 -Condition { (Get-InspectorWindows).Count -eq 0 })) {
        throw 'the second inspector:toggle did not close the window'
    }
    $i = Get-Insp
    if ($i.open -ne 0 -or $i.contexts -ne 0) { throw "inspector state after close: $($i | ConvertTo-Json -Compress)" }
}
