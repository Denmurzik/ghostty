# e2e: milestone=M2 timeout=120 order=210
# tabs-basic: new/goto/move/title/close tab through the test IPC actions.
# Three tabs, selection shows only the active tab's surface, moving a tab
# keeps it active, OSC 2 and set_tab_title reach the tab and the caption,
# close_tab:right leaves one tab and close_tab:this on the last one ends
# the process.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\GhosttyIpc.psm1') -Force

Invoke-E2eScenario 'tabs-basic' {
    $g = Start-BashE2e

    # The first window of the state answer, whether or not the module wraps
    # it in a `data` member.
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
    function Invoke-Act([string]$Action) {
        [void](Invoke-GhosttyAction -Class $g.Class -Action $Action)
    }

    # 1. Two new tabs: three tabs, the last one active.
    Invoke-Act 'new_tab'
    [void](Wait-Win 'two tabs' { param($w) @($w.tabs).Count -eq 2 })
    Invoke-Act 'new_tab'
    $w = Wait-Win 'three tabs, active 2' { param($w) @($w.tabs).Count -eq 3 -and $w.active_tab -eq 2 }
    $ids = @($w.tabs | ForEach-Object { $_.id })

    # 2. goto_tab:1 (1-based): tab 0 is active and the only visible surface.
    Invoke-Act 'goto_tab:1'
    $w = Wait-Win 'active 0' { param($w) $w.active_tab -eq 0 }
    for ($i = 0; $i -lt 3; $i++) {
        foreach ($s in @($w.tabs[$i].surfaces)) {
            if ([bool]$s.visible -ne ($i -eq 0)) { throw "tab $i surface $($s.id) visible=$($s.visible), want $($i -eq 0)" }
        }
    }

    # 3. move_tab:1 swaps tabs 0 and 1; the moved tab stays active.
    Invoke-Act 'move_tab:1'
    $w = Wait-Win 'tab order swapped' { param($w) @($w.tabs)[0].id -eq $ids[1] }
    $order = @($w.tabs | ForEach-Object { $_.id })
    if (($order -join ',') -ne (($ids[1], $ids[0], $ids[2]) -join ',')) { throw "order after move: $($order -join ','), want $($ids[1]),$($ids[0]),$($ids[2])" }
    if ($w.active_tab -ne 1) { throw "active tab after move: $($w.active_tab), want 1" }

    # 4. The title of tab 0 comes from the shell (OSC 2) and reaches the
    # window caption. The shell stays in `sleep` so its prompt does not
    # overwrite the title. The escapes are doubled: the text: parser turns \ into
    # one backslash and printf then makes the bytes (a raw ESC would reach readline).
    Invoke-Act 'goto_tab:1'
    [void](Wait-Win 'active 0 again' { param($w) $w.active_tab -eq 0 })
    Invoke-Act 'text:printf "\x1b]2;tab-A\x07"; sleep 60\r'
    [void](Wait-Win 'tab 0 title tab-A' { param($w) @($w.tabs)[0].title -eq 'tab-A' })
    $caption = Wait-Until -TimeoutSec 5 -PollMs 100 -Condition {
        $t = [GhosttyE2e.Win]::TextOf($g.Hwnd)
        if ($t -eq 'tab-A') { $t }
    }
    if (-not $caption) { throw "window caption '$([GhosttyE2e.Win]::TextOf($g.Hwnd))', want 'tab-A'" }

    # 5. A tab title set by the user wins.
    Invoke-Act 'set_tab_title:fixed'
    [void](Wait-Win 'tab 0 title fixed' { param($w) @($w.tabs)[0].title -eq 'fixed' })

    # 6. close_tab:right closes the tabs after the active one.
    Invoke-Act 'close_tab:right'
    [void](Wait-Win 'one tab left' { param($w) @($w.tabs).Count -eq 1 })

    # 7. Closing the last tab ends the process.
    Invoke-Act 'close_tab:this'
    $exit = Wait-ProcessExit $g 3
    Write-E2eInfo "ghostty exited after $($exit.Ms) ms"
    if (-not $exit.Exited) { throw 'ghostty still running 3 s after the last tab was closed' }
}
