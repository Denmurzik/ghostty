# e2e: milestone=M2 timeout=150 order=310
# tab-strip-mouse: mouse on the tab strip. A click on the new-tab button adds
# a tab, a click on a tab selects it, dragging a tab past its neighbour
# swaps them (the state is read in the middle of the drag), a click on the
# close button and a middle click close tabs. After every click the active
# tab's focused surface really has the keyboard focus.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\MouseInput.psm1') -Force
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

if (-not ('GhosttyE2e.StripFocus' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name StripFocus -MemberDefinition @"
[StructLayout(LayoutKind.Sequential)] public struct GUITHREADINFO {
    public int cbSize; public int flags;
    public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
    public int l, t, r, b;
}
[DllImport("user32.dll")] public static extern bool GetGUIThreadInfo(uint tid, ref GUITHREADINFO i);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
public static IntPtr FocusOf(IntPtr top) {
    uint pid;
    uint tid = GetWindowThreadProcessId(top, out pid);
    GUITHREADINFO i = new GUITHREADINFO();
    i.cbSize = Marshal.SizeOf(typeof(GUITHREADINFO));
    if (!GetGUIThreadInfo(tid, ref i)) return IntPtr.Zero;
    return i.hwndFocus;
}
"@
}

Invoke-E2eScenario 'tab-strip-mouse' {
    $g = Start-E2eGhostty -ConfigText "confirm-close-surface = false`nwindow-decoration = client`nwindow-show-tab-bar = always`n"
    if (-not (Wait-Dump $g { param($x) $x.Width -gt 100 } 15)) { throw "no frame dump at $($g.Dump)" }
    [void](Set-ForegroundSafe -Hwnd $g.Hwnd)

    function Get-Win {
        $d = Get-GhosttyState -Class $g.Class
        @($d.windows)[0]
    }
    function Wait-Win([string]$What, [scriptblock]$Predicate, [double]$TimeoutSec = 6) {
        $w = Wait-Until -TimeoutSec $TimeoutSec -PollMs 100 -Condition {
            $w = Get-Win
            if ($w -and (& $Predicate $w)) { $w }
        }
        if (-not $w) { throw "timeout waiting for: $What; state: $(Get-Win | ConvertTo-Json -Depth 8 -Compress)" }
        $w
    }
    function Get-Centre($R) { , @([int](($R[0] + $R[2]) / 2), [int](($R[1] + $R[3]) / 2)) }
    function Get-TabCentre($W, [int]$I) { Get-Centre @($W.strip.tabs)[$I] }
    # The active tab's focused surface owns the keyboard focus.
    function Assert-SurfaceFocus([string]$What) {
        $w = Get-Win
        $s = @(@($w.tabs)[$w.active_tab].surfaces | Where-Object { $_.focused })[0]
        if (-not $s) { throw "$What : the active tab has no focused surface" }
        $want = [IntPtr][Convert]::ToInt64(([string]$s.hwnd), 16)
        $ok = Wait-Until -TimeoutSec 2 -PollMs 50 -Condition { [GhosttyE2e.StripFocus]::FocusOf($g.Hwnd) -eq $want }
        if (-not $ok) {
            $got = [GhosttyE2e.StripFocus]::FocusOf($g.Hwnd)
            throw ("$What : keyboard focus is 0x{0:X}, expected the surface 0x{1:X}" -f $got.ToInt64(), $want.ToInt64())
        }
    }

    # 1. The new-tab button adds a tab.
    $w = Get-Win
    if (-not $w.strip.new_tab) { throw 'no new_tab rect in the state' }
    $c = Get-Centre $w.strip.new_tab
    Send-MouseClick -Hwnd $g.Hwnd -X $c[0] -Y $c[1]
    $w = Wait-Win 'two tabs' { param($w) @($w.tabs).Count -eq 2 -and $w.active_tab -eq 1 }
    Assert-SurfaceFocus 'after new_tab click'
    $ids = @($w.tabs | ForEach-Object { $_.id })

    # 2. A click on tab 0 selects it.
    $c = Get-TabCentre $w 0
    Send-MouseClick -Hwnd $g.Hwnd -X $c[0] -Y $c[1]
    $w = Wait-Win 'tab 0 active' { param($w) $w.active_tab -eq 0 }
    Assert-SurfaceFocus 'after tab click'

    # 3. Drag tab 0 past tab 1: the order swaps, seen while the button is
    # still down, and the dragged tab stays active.
    $r0 = @($w.strip.tabs)[0]
    $r1 = @($w.strip.tabs)[1]
    $y = [int](($r0[1] + $r0[3]) / 2)
    $x0 = $r0[0] + 60
    $x1 = $r1[0] + 120
    Send-MouseMove -Hwnd $g.Hwnd -X $x0 -Y $y
    Start-Sleep -Milliseconds 40
    Send-MouseDown
    try {
        Start-Sleep -Milliseconds 40
        Send-MouseMove -Hwnd $g.Hwnd -X $x1 -Y $y -Steps 12
        $mid = Wait-Win 'order swapped while dragging' { param($w) @($w.tabs)[0].id -eq $ids[1] }
        if (@($mid.tabs)[1].id -ne $ids[0]) { throw 'tab ids after the drag are not swapped' }
    } finally {
        Send-MouseUp
    }
    $w = Wait-Win 'order swapped after release' { param($w) @($w.tabs)[0].id -eq $ids[1] -and @($w.tabs)[1].id -eq $ids[0] }
    if ($w.active_tab -ne 1) { throw "active tab after the drag is $($w.active_tab), want 1 (the dragged tab)" }
    Assert-SurfaceFocus 'after the drag'

    # 4. Middle click on tab 1 closes it.
    $c = Get-TabCentre $w 1
    Send-MouseClick -Hwnd $g.Hwnd -X $c[0] -Y $c[1] -Button middle
    $w = Wait-Win 'one tab after the middle click' { param($w) @($w.tabs).Count -eq 1 }
    if (@($w.tabs)[0].id -ne $ids[1]) { throw 'the middle click closed the wrong tab' }
    Assert-SurfaceFocus 'after the middle click'

    # 5. The close button of a tab closes it (two tabs first).
    $c = Get-Centre $w.strip.new_tab
    Send-MouseClick -Hwnd $g.Hwnd -X $c[0] -Y $c[1]
    $w = Wait-Win 'two tabs again' { param($w) @($w.tabs).Count -eq 2 }
    $closing = @($w.tabs)[1].id
    $r = @($w.strip.tabs)[1]
    # The close button is the right 28 px (scaled) of the hovered tab.
    $s = [GhosttyE2e.StripFocus]::GetDpiForWindow($g.Hwnd) / 96.0
    Send-MouseClick -Hwnd $g.Hwnd -X ($r[2] - [int](14 * $s)) -Y ([int](($r[1] + $r[3]) / 2))
    $w = Wait-Win 'one tab after the close button' { param($w) @($w.tabs).Count -eq 1 }
    if (@($w.tabs)[0].id -eq $closing) { throw 'the close button closed the wrong tab' }
    Assert-SurfaceFocus 'after the close button'

    Save-Evidence -Tag 'tab-strip-mouse' -G $g -Window
}
