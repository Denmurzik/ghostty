# e2e: milestone=M3 timeout=150 order=640
# tab-menu: a right click on a tab opens the tab context menu (a #32768
# window of the process); "Close Other Tabs" (arrows + Enter) leaves one tab.
# In a 30-tab strip a tab whose title is trimmed shows a tooltip with the
# full title after the hover delay.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\MouseInput.psm1') -Force
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

Invoke-E2eScenario 'tab-menu' {
    $g = Start-E2eGhostty -ConfigText "confirm-close-surface = false`nwindow-decoration = client`nwindow-show-tab-bar = always`n"
    if (-not (Wait-Dump $g { param($x) $x.Width -gt 100 } 15)) { throw "no frame dump at $($g.Dump)" }
    [void](Set-ForegroundSafe -Hwnd $g.Hwnd)

    function Get-Win {
        $d = Get-GhosttyState -Class $g.Class
        @($d.windows)[0]
    }
    function Wait-Win([string]$What, [scriptblock]$Predicate, [double]$TimeoutSec = 8) {
        $w = Wait-Until -TimeoutSec $TimeoutSec -PollMs 100 -Condition {
            $w = Get-Win
            if ($w -and (& $Predicate $w)) { $w }
        }
        if (-not $w) { throw "timeout waiting for: $What; state: $(Get-Win | ConvertTo-Json -Depth 8 -Compress)" }
        $w
    }
    function Get-Centre($R) { , @([int](($R[0] + $R[2]) / 2), [int](($R[1] + $R[3]) / 2)) }
    function Get-Popup([string]$Class) {
        @([GhosttyE2e.Win]::TopLevel([uint32]$g.Pid, $Class) | Where-Object { [GhosttyE2e.Win]::IsWindowVisible($_) })
    }
    function Wait-Popup([string]$Class, [bool]$Present, [string]$What, [double]$TimeoutSec = 4) {
        $ok = Wait-Until -TimeoutSec $TimeoutSec -PollMs 50 -Condition { (@(Get-Popup $Class).Count -gt 0) -eq $Present }
        if (-not $ok) { throw "$What : the $Class window is $(if ($Present) { 'missing' } else { 'still there' })" }
    }

    # 1. Three tabs, right click on the second: the menu.
    foreach ($i in 1..2) { [void](Invoke-GhosttyAction -Class $g.Class -Action 'new_tab') }
    $w = Wait-Win 'three tabs' { param($w) @($w.tabs).Count -eq 3 }
    $c = Get-Centre @($w.strip.tabs)[1]
    Send-MouseClick -Hwnd $g.Hwnd -X ($c[0] - 40) -Y $c[1] -Button right
    Wait-Popup '#32768' $true 'right click on a tab'
    Save-Evidence -Tag 'tab-menu' -G $g -Window

    # Items: Close Tab, Close Other Tabs, ... Down twice selects "Close Other Tabs"
    # (the first Down selects the first item).
    Invoke-SendInput -Hwnd $g.Hwnd -Keys 'down', 'down', 'enter' -Panel
    Wait-Popup '#32768' $false 'Enter on the menu item'
    $w = Wait-Win 'one tab left' { param($w) @($w.tabs).Count -eq 1 }

    # 2. A strip of 30 tabs: a trimmed title shows a tooltip.
    foreach ($i in 1..29) { [void](Invoke-GhosttyAction -Class $g.Class -Action 'new_tab') }
    $w = Wait-Win '30 tabs' { param($w) @($w.tabs).Count -eq 30 }
    $long = 'a title that is much too long for a narrow tab'
    $c = Get-Centre @($w.strip.tabs)[29]
    Send-MouseClick -Hwnd $g.Hwnd -X ($c[0] - 20) -Y $c[1] -Double
    Start-Sleep -Milliseconds 300
    Invoke-SendInput -Hwnd $g.Hwnd -Text $long
    Invoke-SendInput -Hwnd $g.Hwnd -Keys 'enter'
    $w = Wait-Win 'long title' { param($w) @($w.tabs)[29].title -eq $long }
    $c = Get-Centre @($w.strip.tabs)[29]
    Send-MouseMove -Hwnd $g.Hwnd -X ($c[0] - 20) -Y $c[1] -Steps 4
    Start-Sleep -Milliseconds 700
    Wait-Popup 'tooltips_class32' $true 'hover on a trimmed tab'
    Save-Evidence -Tag 'tab-menu-tooltip' -G $g -Window
    Send-MouseMove -Hwnd $g.Hwnd -X ($c[0] - 20) -Y ($c[1] + 200) -Steps 4
    Wait-Popup 'tooltips_class32' $false 'pointer left the strip'
}
