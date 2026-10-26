# e2e: milestone=M2 timeout=240 order=370
# maximize-fullscreen: the placement actions. Fullscreen covers the monitor,
# hides the strip and restores the exact rect; maximize toggles; float_window
# sets WS_EX_TOPMOST; toggle_window_decorations switches to `none` through
# frame.apply; resize_window sets the content size below the strip;
# `fullscreen = true` starts fullscreen; window-width/height in cells give an
# exact cell grid in every decoration mode (SPEC section 18 item 9 /
# pre-flight 9); WM_GETMINMAXINFO min track height includes the strip.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force
Import-Module (Join-Path $script:WinDir 'lib\MouseInput.psm1') -Force

if (-not ('GhosttyE2e.Place' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name Place -MemberDefinition @"
[DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
[DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
[DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int index);
"@
}

function Get-WinRect($S) { , @($S.window[0], $S.window[1], $S.window[2], $S.window[3]) }

function Assert-Rect($Got, $Want, [int]$Tol, [string]$What) {
    for ($i = 0; $i -lt 4; $i++) {
        if ([Math]::Abs($Got[$i] - $Want[$i]) -gt $Tol) {
            throw "$What : rect $($Got -join ',') differs from $($Want -join ',')"
        }
    }
}

function Test-Topmost([IntPtr]$Hwnd) {
    # GWL_EXSTYLE = -20, WS_EX_TOPMOST = 8
    (([int64][GhosttyE2e.Place]::GetWindowLongPtr($Hwnd, -20)) -band 8) -ne 0
}

# MINMAXINFO filled by WM_GETMINMAXINFO (ptMinTrackSize at offset 24).
function Get-MinTrack([IntPtr]$Hwnd) {
    $buf = [Runtime.InteropServices.Marshal]::AllocHGlobal(40)
    try {
        for ($i = 0; $i -lt 40; $i += 4) { [Runtime.InteropServices.Marshal]::WriteInt32($buf, $i, 0) }
        [void][GhosttyE2e.Place]::SendMessage($Hwnd, 0x24, [IntPtr]::Zero, $buf)
        @{ w = [Runtime.InteropServices.Marshal]::ReadInt32($buf, 24); h = [Runtime.InteropServices.Marshal]::ReadInt32($buf, 28) }
    } finally { [Runtime.InteropServices.Marshal]::FreeHGlobal($buf) }
}

function Get-HitCode([IntPtr]$Hwnd, [int]$X, [int]$Y) {
    $p = New-Object GhosttyE2e.Mouse+POINT
    $p.X = $X
    $p.Y = $Y
    [void][GhosttyE2e.Mouse]::ClientToScreen($Hwnd, [ref]$p)
    $lp = [IntPtr](([int64]$p.Y -shl 16) -bor ([int64]$p.X -band 0xFFFF))
    [int][GhosttyE2e.Place]::SendMessage($Hwnd, 0x84, [IntPtr]::Zero, $lp)
}

Invoke-E2eScenario 'maximize-fullscreen' {
    $g = Start-E2eGhostty -ConfigText "confirm-close-surface = false`nwindow-decoration = client`nwindow-padding-x = 0`nwindow-padding-y = 0`nwindow-padding-balance = false`nvt-window-resize-allowed = true`nenv = LC_ALL=en_US.UTF-8`nenv = LANG=en_US.UTF-8`n"
    Wait-BashReady $g
    $h = $g.Hwnd
    $c = $g.Class
    $st = Get-GhosttyState -Class $c
    $orig = Get-WinRect $st
    $scr = [Windows.Forms.Screen]::FromHandle($h)
    $mon = $scr.Bounds
    $monRect = @($mon.Left, $mon.Top, $mon.Right, $mon.Bottom)
    $pt = $st.strip.close
    $closeX = [int](($pt[0] + $pt[2]) / 2)
    $closeY = [int](($pt[1] + $pt[3]) / 2)

    # Fullscreen: window == monitor, strip hidden, then the exact rect back.
    if (-not (Invoke-GhosttyAction -Class $c -Action 'toggle_fullscreen')) { throw 'toggle_fullscreen not performed' }
    $s = Wait-GhosttyState -Class $c -Predicate { $_.fullscreen -eq $true } -TimeoutSec 5
    Assert-Rect (Get-WinRect $s) $monRect 0 'fullscreen window'
    if ($s.strip.mode -ne 'hidden') { throw "fullscreen strip.mode is $($s.strip.mode), expected hidden" }
    if (Invoke-GhosttyAction -Class $c -Action 'toggle_maximize') { throw 'toggle_maximize must be refused in fullscreen' }

    if (-not (Invoke-GhosttyAction -Class $c -Action 'toggle_fullscreen')) { throw 'second toggle_fullscreen not performed' }
    $s = Wait-GhosttyState -Class $c -Predicate { $_.fullscreen -eq $false } -TimeoutSec 5
    Assert-Rect (Get-WinRect $s) $orig 1 'restored window'
    if ($s.strip.mode -ne 'titlebar') { throw "restored strip.mode is $($s.strip.mode), expected titlebar" }

    # Maximize twice: maximized, then restored.
    [void](Invoke-GhosttyAction -Class $c -Action 'toggle_maximize')
    if (-not (Wait-Until { [GhosttyE2e.Place]::IsZoomed($h) } 5)) { throw 'toggle_maximize did not maximize' }
    [void](Invoke-GhosttyAction -Class $c -Action 'toggle_maximize')
    if (-not (Wait-Until { -not [GhosttyE2e.Place]::IsZoomed($h) } 5)) { throw 'second toggle_maximize did not restore' }
    Assert-Rect (Get-WinRect (Get-GhosttyState -Class $c)) $orig 1 'window after maximize round trip'

    # Float on top.
    [void](Invoke-GhosttyAction -Class $c -Action 'toggle_window_float_on_top')
    if (-not (Wait-Until { Test-Topmost $h } 5)) { throw 'toggle_window_float_on_top did not set WS_EX_TOPMOST' }
    if (-not (Get-GhosttyState -Class $c).topmost) { throw 'state.topmost is false after toggle_window_float_on_top' }
    [void](Invoke-GhosttyAction -Class $c -Action 'toggle_window_float_on_top')
    if (-not (Wait-Until { -not (Test-Topmost $h) } 5)) { throw 'toggle_window_float_on_top did not clear WS_EX_TOPMOST' }

    # resize_window (CSI 8 ; rows ; cols t, which core turns into pixels):
    # the content rect below the strip is exactly cols x rows cells.
    $cell = (Get-GhosttyState -Class $c).cell
    Send-Line $h "printf '\033[8;30;100t'"
    $ew = 100 * $cell[0]
    $eh = 30 * $cell[1]
    $s = Wait-GhosttyState -Class $c -Predicate { ($_.client[2] - $_.client[0]) -eq $ew } -TimeoutSec 5
    $content = $s.client[3] - $s.client[1] - $s.strip.bounds[3]
    if ($content -ne $eh) { throw "content height below the strip is $content, expected $eh" }

    # Min track height includes the strip.
    $min = Get-MinTrack $h
    $stripH = $s.strip.bounds[3] - $s.strip.bounds[1]
    # The limit core reports (at least one cell) is added to the non-client size, strip included.
    if ($min.h -lt $stripH + $s.cell[1]) { throw "min track height $($min.h) is below strip $stripH + one cell $($s.cell[1])" }

    # Decorations: none, and the former close-button point is not HTCLOSE.
    if ((Get-HitCode $h $closeX $closeY) -ne 20) { throw 'precondition: close button point is not HTCLOSE' }
    [void](Invoke-GhosttyAction -Class $c -Action 'toggle_window_decorations')
    $s = Wait-GhosttyState -Class $c -Predicate { $_.decorations -eq 'none' } -TimeoutSec 5
    if ((Get-HitCode $h $closeX $closeY) -eq 20) { throw 'decorations none: the close button still answers HTCLOSE' }
    [void](Invoke-GhosttyAction -Class $c -Action 'toggle_window_decorations')
    [void](Wait-GhosttyState -Class $c -Predicate { $_.decorations -eq 'client' } -TimeoutSec 5)
    $g.Process.Kill()
    [void]$g.Process.WaitForExit(5000)

    # `fullscreen = true` starts fullscreen.
    $g = Start-E2eGhostty -ConfigText "confirm-close-surface = false`nfullscreen = true`n"
    $s = Wait-GhosttyState -Class $g.Class -Predicate { $_.fullscreen -eq $true } -TimeoutSec 10
    $m2 = [Windows.Forms.Screen]::FromHandle($g.Hwnd).Bounds
    Assert-Rect (Get-WinRect $s) @($m2.Left, $m2.Top, $m2.Right, $m2.Bottom) 0 'start-up fullscreen window'
    $g.Process.Kill()
    [void]$g.Process.WaitForExit(5000)

    # window-width/height in cells: an exact 80x24 grid in every mode.
    foreach ($mode in 'client', 'server', 'none') {
        $cfg = "confirm-close-surface = false`nwindow-decoration = $mode`nwindow-width = 80`nwindow-height = 24`nwindow-padding-x = 0`nwindow-padding-y = 0`nwindow-padding-balance = false`n"
        $g = Start-E2eGhostty -ConfigText $cfg
        $s = Wait-GhosttyState -Class $g.Class -Predicate { $_.cell[0] -gt 0 -and $_.tabs.Count -ge 1 } -TimeoutSec 10
        $r = $s.tabs[0].surfaces[0].rect
        $w = $r[2] - $r[0]
        $hh = $r[3] - $r[1]
        $ew = 80 * $s.cell[0]
        $eh = 24 * $s.cell[1]
        if ($w -ne $ew -or $hh -ne $eh) { throw "window-decoration=$mode : surface is ${w}x${hh}, expected ${ew}x${eh} (80x24 cells of $($s.cell -join 'x'))" }
        $g.Process.Kill()
        [void]$g.Process.WaitForExit(5000)
    }
    Write-E2eInfo 'fullscreen, maximize, float, decorations, resize_window, start-up fullscreen and the 80x24 grid per decoration pass'
}
