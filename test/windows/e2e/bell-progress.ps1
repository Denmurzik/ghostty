# e2e: milestone=M2 timeout=120 order=410
# bell-progress: a bell from an unfocused tab marks the tab (state `bell`) and
# puts the bell emoji before the window caption; selecting the tab clears
# both. OSC 9;4 sets and removes the taskbar progress of the window.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\GhosttyIpc.psm1') -Force

Invoke-E2eScenario 'bell-progress' {
    if (-not (Find-GitBash)) { throw 'E2E-SKIP: Git Bash not found' }
    $g = Start-BashE2e
    $bell = [string][char]0xD83D + [char]0xDD14

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
    function Get-Caption { [GhosttyE2e.Win]::TextOf($g.Hwnd) }

    # 1. Tab 0 rings while tab 1 is shown.
    Invoke-Act 'new_tab'
    [void](Wait-Win 'two tabs' { param($w) @($w.tabs).Count -eq 2 -and $w.active_tab -eq 1 })
    Invoke-Act 'goto_tab:1'
    [void](Wait-Win 'tab 0 active' { param($w) $w.active_tab -eq 0 })
    Send-Line $g.Hwnd "sleep 2; printf '\a'"
    Invoke-Act 'goto_tab:2'
    [void](Wait-Win 'tab 1 active' { param($w) $w.active_tab -eq 1 })
    [void](Wait-Win 'bell on tab 0' { param($w) @($w.tabs)[0].bell -eq $true } 10)

    # 2. Selecting the tab clears the bell and the caption prefix.
    Invoke-Act 'goto_tab:1'
    [void](Wait-Win 'bell cleared on tab 0' { param($w) @($w.tabs)[0].bell -eq $false })
    $ok = Wait-Until -TimeoutSec 4 -PollMs 100 -Condition { -not (Get-Caption).StartsWith($bell) }
    if (-not $ok) { throw "caption '$(Get-Caption)' still starts with the bell" }

    # 3. OSC 9;4 progress.
    Send-Line $g.Hwnd "printf '\e]9;4;1;40\a'"
    $w = Wait-Win 'progress set 40' { param($w) $w.progress -and $w.progress.state -eq 'set' -and $w.progress.value -eq 40 }
    Send-Line $g.Hwnd "printf '\e]9;4;0\a'"
    [void](Wait-Win 'progress removed' { param($w) $null -eq $w.progress })

    Save-Evidence -Tag 'bell-progress' -G $g -Window
}
