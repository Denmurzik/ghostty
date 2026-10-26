# e2e: milestone=M2 timeout=180 order=460
# tab-drag: a tab dragged out of the window opens in a new window (the
# surface's hwnd and its cmd.exe stay, a GhosttyDragGhost window is visible
# during the drag), dragged onto another window's strip it moves there (the
# emptied window is gone), Esc cancels a drag. Interactive only.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\MouseInput.psm1') -Force
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

Add-Type -AssemblyName System.Windows.Forms
if (-not ('GhosttyE2e.TabDrag' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name TabDrag -MemberDefinition @"
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int cx, uint flags);
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
public static int[] Rect(IntPtr h) { RECT r; GetWindowRect(h, out r); return new int[] { r.L, r.T, r.R, r.B }; }
"@
}

Invoke-E2eScenario 'tab-drag' {
    $cfg = (Get-Content -LiteralPath (Get-ConfigPath 'cmd') -Raw -Encoding UTF8) +
        "`nconfirm-close-surface = false`nwindow-decoration = client`nwindow-show-tab-bar = always`n"
    $g = Start-E2eGhostty -ConfigText $cfg
    [void](Wait-ChildNamed $g @('cmd.exe') 15)
    [void](Set-ForegroundSafe -Hwnd $g.Hwnd)

    function Get-Wins {
        $r = Get-GhosttyState -Class $g.Class
        $d = if ($r.PSObject.Properties['data']) { $r.data } else { $r }
        @($d.windows)
    }
    function Wait-Wins([string]$What, [scriptblock]$Predicate, [double]$TimeoutSec = 8) {
        $w = Wait-Until -TimeoutSec $TimeoutSec -PollMs 100 -Condition {
            $all = @(Get-Wins)
            if (& $Predicate $all) { , $all }
        }
        if (-not $w) { throw "timeout waiting for: $What; state: $((Get-Wins) | ConvertTo-Json -Depth 8 -Compress)" }
        $w
    }
    function Get-Hwnd($W) { [IntPtr][Convert]::ToInt64(([string]$W.hwnd), 16) }
    function Get-Centre($R) { , @([int](($R[0] + $R[2]) / 2), [int](($R[1] + $R[3]) / 2)) }
    function Get-Ghosts { @([GhosttyE2e.Win]::TopLevel([uint32]$g.Pid, 'GhosttyDragGhost') | Where-Object { [GhosttyE2e.Win]::IsWindowVisible($_) }) }
    function Get-CmdPids { @(Get-ProcessTree $g.Pid | Where-Object { $_.Name -ieq 'cmd.exe' } | ForEach-Object { [int]$_.ProcessId } | Sort-Object) }

    # Window A at a fixed place, at most half the work area's height, so that
    # 250 px below it is on screen and off the taskbar.
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $h = [Math]::Min(500, [int]($wa.Height / 2))
    [void][GhosttyE2e.TabDrag]::SetWindowPos($g.Hwnd, [IntPtr]::Zero, $wa.X + 40, $wa.Y + 20, 900, $h, 0x14)
    Start-Sleep -Milliseconds 300

    # Window A with tabs T0, T1.
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'new_tab')
    $wins = @(Wait-Wins 'two tabs' { param($a) @($a[0].tabs).Count -eq 2 })
    $aId = $wins[0].id
    $t1 = @($wins[0].tabs)[1]
    $t1Hwnd = $t1.surfaces[0].hwnd
    $pids = @(Get-CmdPids)
    if ($pids.Count -lt 2) { throw "expected two cmd.exe, got $($pids -join ',')" }

    # 1. Tear T1 off: 250 px below A's bottom edge.
    $rc = [GhosttyE2e.TabDrag]::Rect($g.Hwnd)
    $c = Get-Centre @($wins[0].strip.tabs)[1]
    Send-MouseMove -Hwnd $g.Hwnd -X $c[0] -Y $c[1]
    Start-Sleep -Milliseconds 60
    Send-MouseDown
    $ghostSeen = $false
    try {
        Start-Sleep -Milliseconds 60
        $sp = Convert-ClientToScreen $g.Hwnd $c[0] $c[1]
        Send-MouseMove -ScreenX $sp.X -ScreenY ($rc[3] + 250) -Steps 25
        $ghostSeen = [bool](Wait-Until -TimeoutSec 2 -PollMs 50 -Condition { @(Get-Ghosts).Count -ge 1 })
        Start-Sleep -Milliseconds 300
    } finally {
        Send-MouseUp
    }
    if (-not $ghostSeen) { throw 'no visible GhosttyDragGhost window during the drag' }
    $wins = @(Wait-Wins 'two windows, one tab each' { param($a) $a.Count -eq 2 -and @($a[0].tabs).Count -eq 1 -and @($a[1].tabs).Count -eq 1 })
    $moved = @($wins | Where-Object { $_.id -ne $aId })[0]
    if (@($moved.tabs)[0].surfaces[0].hwnd -ne $t1Hwnd) { throw 'the torn-off surface changed its hwnd' }
    if ((@(Get-CmdPids) -join ",") -ne ($pids -join ",")) { throw "cmd.exe pids changed: $((Get-CmdPids) -join ',') vs $($pids -join ',')" }
    if (@(Get-Ghosts).Count -ne 0) { throw 'the drag ghost is still visible after the drop' }
    $newHwnd = Get-Hwnd $moved
    [void](Set-ForegroundSafe -Hwnd $newHwnd)
    $echo = Join-Path (Get-E2eTempRoot) 'tab-drag-echo.txt'
    Send-Line $newHwnd "echo moved> `"$echo`""
    if (-not (Wait-File $echo 10)) { throw 'the echo oracle in the torn-off tab produced nothing' }
    Write-E2eInfo 'tear-off ok'

    # 2. Drag T1 back onto A's strip, right of T0.
    $a = @($wins | Where-Object { $_.id -eq $aId })[0]
    $mc = Get-Centre @($moved.strip.tabs)[0]
    $ar = @($a.strip.tabs)[0]
    $target = Convert-ClientToScreen (Get-Hwnd $a) ($ar[2] + 20) ([int](($ar[1] + $ar[3]) / 2))
    Send-MouseMove -Hwnd $newHwnd -X $mc[0] -Y $mc[1]
    Start-Sleep -Milliseconds 60
    Send-MouseDown
    try {
        Start-Sleep -Milliseconds 60
        Send-MouseMove -ScreenX $target.X -ScreenY $target.Y -Steps 25
        Start-Sleep -Milliseconds 300
    } finally {
        Send-MouseUp
    }
    $wins = @(Wait-Wins 'one window with two tabs' { param($x) $x.Count -eq 1 -and @($x[0].tabs).Count -eq 2 })
    if (@($wins[0].tabs)[1].surfaces[0].hwnd -ne $t1Hwnd) { throw 'T1 is not second after the re-dock' }
    if ((@(Get-CmdPids) -join ",") -ne ($pids -join ",")) { throw 'cmd.exe pids changed after the re-dock' }
    Write-E2eInfo 're-dock ok'

    # 3. Esc cancels a tear-off.
    $order = @($wins[0].tabs | ForEach-Object { $_.id })
    $rc = [GhosttyE2e.TabDrag]::Rect($g.Hwnd)
    $c = Get-Centre @($wins[0].strip.tabs)[0]
    $sp = Convert-ClientToScreen $g.Hwnd $c[0] $c[1]
    Send-MouseMove -Hwnd $g.Hwnd -X $c[0] -Y $c[1]
    Start-Sleep -Milliseconds 60
    Send-MouseDown
    try {
        Start-Sleep -Milliseconds 60
        Send-MouseMove -ScreenX $sp.X -ScreenY ($rc[3] + 250) -Steps 25
        Start-Sleep -Milliseconds 200
        Invoke-SendInput -Hwnd $g.Hwnd -Keys 'esc'
        Start-Sleep -Milliseconds 300
    } finally {
        Send-MouseUp
    }
    $wins = @(Get-Wins)
    if ($wins.Count -ne 1) { throw "Esc did not cancel: $($wins.Count) windows" }
    if ((@($wins[0].tabs | ForEach-Object { $_.id }) -join ',') -ne ($order -join ',')) { throw 'tab order changed after Esc' }
    if (@(Get-Ghosts).Count -ne 0) { throw 'the ghost is visible after Esc' }

    Save-Evidence -Tag 'tab-drag' -G $g -Window
}
