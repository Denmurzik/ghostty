# e2e: milestone=M3 timeout=180 order=535
# overlay-follow: an overlay popup (the read-only badge, shown with
# `toggle_readonly`) follows its window: moving the window moves the popup by
# the same delta, minimizing hides it and restoring shows it again, and a tab
# dragged out into a new window takes the badge along (owner = the new window,
# placed on it). SKIPs until the badge is real (M3 Task 11). Interactive only.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\MouseInput.psm1') -Force
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force

Add-Type -AssemblyName System.Windows.Forms
if (-not ('GhosttyE2e.Follow' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name Follow -MemberDefinition @"
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int cx, uint flags);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
public static int[] Rect(IntPtr h) { RECT r; GetWindowRect(h, out r); return new int[] { r.L, r.T, r.R, r.B }; }
"@
}

Invoke-E2eScenario 'overlay-follow' {
    $cfg = (Get-Content -LiteralPath (Get-ConfigPath 'cmd') -Raw -Encoding UTF8) +
        "`nconfirm-close-surface = false`nwindow-decoration = client`nwindow-show-tab-bar = always`n"
    $g = Start-E2eGhostty -ConfigText $cfg
    [void](Wait-ChildNamed $g @('cmd.exe') 15)
    [void](Set-ForegroundSafe -Hwnd $g.Hwnd)

    function Get-Labels { @([GhosttyE2e.Win]::TopLevel([uint32]$g.Pid, 'GhosttyOverlayLabel')) }
    function Get-VisibleLabels { @(Get-Labels | Where-Object { [GhosttyE2e.Win]::IsWindowVisible($_) }) }
    function Get-Wins {
        $r = Get-GhosttyState -Class $g.Class
        $d = if ($r.PSObject.Properties['data']) { $r.data } else { $r }
        @($d.windows)
    }
    function Get-Hwnd($W) { [IntPtr][Convert]::ToInt64(([string]$W.hwnd), 16) }

    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $h = [Math]::Min(500, [int]($wa.Height / 2))
    [void][GhosttyE2e.Follow]::SetWindowPos($g.Hwnd, [IntPtr]::Zero, $wa.X + 40, $wa.Y + 20, 900, $h, 0x14)
    Start-Sleep -Milliseconds 300

    [void](Invoke-GhosttyAction -Class $g.Class -Action 'toggle_readonly')
    if (-not (Wait-Until -TimeoutSec 3 -PollMs 100 -Condition { @(Get-VisibleLabels).Count -ge 1 })) {
        throw 'E2E-SKIP: needs Task 11 (the read-only badge is not shown yet)'
    }
    $badge = (Get-VisibleLabels)[0]
    if ([GhosttyE2e.Follow]::GetWindow($badge, 4) -ne $g.Hwnd) { throw 'the badge is not owned by the window' }

    # 1. Move: same delta.
    $before = [GhosttyE2e.Follow]::Rect($badge)
    [void][GhosttyE2e.Follow]::SetWindowPos($g.Hwnd, [IntPtr]::Zero, $wa.X + 100, $wa.Y + 60, 0, 0, 0x15)
    $moved = Wait-Until -TimeoutSec 2 -PollMs 50 -Condition {
        $r = [GhosttyE2e.Follow]::Rect($badge)
        ($r[0] - $before[0]) -eq 60 -and ($r[1] - $before[1]) -eq 40
    }
    if (-not $moved) { throw "the badge did not follow the window by (60,40): $($before -join ',') -> $(([GhosttyE2e.Follow]::Rect($badge)) -join ',')" }
    Write-E2eInfo 'move ok'

    # 2. Minimize hides, restore shows.
    [void][GhosttyE2e.Follow]::ShowWindow($g.Hwnd, 6)
    if (-not (Wait-Until -TimeoutSec 2 -PollMs 50 -Condition { @(Get-VisibleLabels).Count -eq 0 })) { throw 'the badge is still visible while the window is minimized' }
    [void][GhosttyE2e.Follow]::ShowWindow($g.Hwnd, 9)
    if (-not (Wait-Until -TimeoutSec 3 -PollMs 50 -Condition { @(Get-VisibleLabels).Count -ge 1 })) { throw 'the badge did not come back after the restore' }
    Write-E2eInfo 'minimize/restore ok'

    # 3. Tear the tab off: the badge belongs to the new window.
    [void](Set-ForegroundSafe -Hwnd $g.Hwnd)
    [void](Invoke-GhosttyAction -Class $g.Class -Action 'new_tab')
    $wins = @(Get-Wins)
    $aId = $wins[0].id
    Start-Sleep -Milliseconds 300
    $rc = [GhosttyE2e.Follow]::Rect($g.Hwnd)
    $tab = @($wins[0].strip.tabs)[0]
    $cx = [int](($tab[0] + $tab[2]) / 2); $cy = [int](($tab[1] + $tab[3]) / 2)
    Send-MouseMove -Hwnd $g.Hwnd -X $cx -Y $cy
    Start-Sleep -Milliseconds 60
    Send-MouseDown
    try {
        Start-Sleep -Milliseconds 60
        $sp = Convert-ClientToScreen $g.Hwnd $cx $cy
        Send-MouseMove -ScreenX $sp.X -ScreenY ($rc[3] + 250) -Steps 25
        Start-Sleep -Milliseconds 300
    } finally {
        Send-MouseUp
    }
    $two = Wait-Until -TimeoutSec 8 -PollMs 100 -Condition { @(Get-Wins).Count -eq 2 }
    if (-not $two) { throw 'the tear-off did not open a second window' }
    $new = @(Get-Wins | Where-Object { $_.id -ne $aId })[0]
    $newHwnd = Get-Hwnd $new
    $ok = Wait-Until -TimeoutSec 3 -PollMs 100 -Condition {
        $owned = @(Get-VisibleLabels | Where-Object { [GhosttyE2e.Follow]::GetWindow($_, 4) -eq $newHwnd })
        if ($owned.Count -ge 1) {
            $r = [GhosttyE2e.Follow]::Rect($owned[0]); $w = [GhosttyE2e.Follow]::Rect($newHwnd)
            $r[0] -ge $w[0] -and $r[2] -le $w[2] -and $r[1] -ge $w[1] -and $r[3] -le $w[3]
        }
    }
    if (-not $ok) { throw 'no visible badge owned by and placed inside the new window' }
    Write-E2eInfo 'tear-off ok'

    $errors = @(Get-LogErrors $g)
    if ($errors.Count) { throw "ghostty.log has $($errors.Count) error line(s), first: $($errors[0])" }
}
