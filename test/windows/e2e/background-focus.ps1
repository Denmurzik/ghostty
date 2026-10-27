# e2e: milestone=M2 timeout=150 order=490
# background-focus: a shell that exits in a window the user is not working
# in (a split closing, then the last pane of a tab closing) must not bring
# that window to the front; the foreground window stays the same.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\GhosttyIpc.psm1') -Force

if (-not ('GhosttyE2e.BgFocus' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name BgFocus -MemberDefinition @"
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
"@
}

Invoke-E2eScenario 'background-focus' {
    $g = Start-BashE2e
    if (-not (Set-ForegroundSafe -Hwnd $g.Hwnd)) { throw 'E2E-SKIP: could not take the foreground' }

    function Get-Wins {
        $r = Get-GhosttyState -Class $g.Class
        $d = if ($r.PSObject.Properties['data']) { $r.data } else { $r }
        @($d.windows)
    }
    function Wait-Wins([string]$What, [scriptblock]$Predicate, [double]$TimeoutSec = 10) {
        $w = Wait-Until -TimeoutSec $TimeoutSec -PollMs 100 -Condition {
            $all = @(Get-Wins)
            if (& $Predicate $all) { , $all }
        }
        if (-not $w) { throw "timeout waiting for: $What; state: $((Get-Wins) | ConvertTo-Json -Depth 8 -Compress)" }
        $w
    }
    function Invoke-Act([string]$Action, [int]$Surface = 0) {
        [void](Invoke-GhosttyAction -Class $g.Class -Action $Action -Surface $Surface)
    }
    function Surface-Count($Win) {
        $n = 0
        foreach ($t in @($Win.tabs)) { $n += @($t.surfaces).Count }
        $n
    }

    $first = (Get-Wins)[0]
    $firstId = $first.id

    # Background window: two panes in one tab, plus a second tab.
    Invoke-Act 'new_split:right'
    $w = Wait-Wins 'two panes' { param($a) (Surface-Count $a[0]) -eq 2 }
    Invoke-Act 'new_tab'
    $w = Wait-Wins 'two tabs' { param($a) @($a[0].tabs).Count -eq 2 }
    $splitTab = @($w[0].tabs)[0]
    $lastTab = @($w[0].tabs)[1]
    $splitSurface = @($splitTab.surfaces)[1].id
    $lastSurface = @($lastTab.surfaces)[0].id

    # A second window takes the foreground; the first one is now behind it.
    Invoke-Act 'new_window'
    $w = Wait-Wins 'two windows' { param($a) $a.Count -eq 2 }
    $front = @($w | Where-Object { $_.id -ne $firstId })[0]
    $frontHwnd = [IntPtr][Convert]::ToInt64($front.hwnd, 16)
    if (-not (Set-ForegroundSafe -Hwnd $frontHwnd)) { throw 'E2E-SKIP: could not take the foreground' }
    Start-Sleep -Milliseconds 500   # the shells of both windows are up
    if ([GhosttyE2e.BgFocus]::GetForegroundWindow() -ne $frontHwnd) { throw 'the second window is not in the foreground' }

    # 1. A split of the background window closes.
    Invoke-Act 'text:exit\r' $splitSurface
    [void](Wait-Wins 'split closed in the background window' {
            param($a)
            $b = @($a | Where-Object { $_.id -eq $firstId })[0]
            $b -and (Surface-Count $b) -eq 2
        } 15)
    Start-Sleep -Milliseconds 500
    if ([GhosttyE2e.BgFocus]::GetForegroundWindow() -ne $frontHwnd) { throw 'closing a split in a background window changed the foreground window' }

    # 2. The last pane of a background tab closes.
    Invoke-Act 'text:exit\r' $lastSurface
    [void](Wait-Wins 'tab closed in the background window' {
            param($a)
            $b = @($a | Where-Object { $_.id -eq $firstId })[0]
            $b -and @($b.tabs).Count -eq 1
        } 15)
    Start-Sleep -Milliseconds 500
    if ([GhosttyE2e.BgFocus]::GetForegroundWindow() -ne $frontHwnd) { throw 'closing a tab in a background window changed the foreground window' }

    # Close everything down.
    Invoke-Act 'close_all_windows'
    $exit = Wait-ProcessExit $g 5
    if (-not $exit.Exited) { throw 'ghostty still running 5 s after close_all_windows' }
}
