# e2e: milestone=M2 timeout=120 order=290
# frame-hittest: the custom frame answers WM_NCHITTEST for the caption buttons,
# the strip and the top edge, maximizing keeps the client on the monitor, a
# double click on the caption maximizes, and Alt+Space opens the system menu
# (the top-level has no WS_SYSMENU, SPEC section 18 item 9).
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\MouseInput.psm1') -Force

if (-not ('GhosttyE2e.Frame' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name Frame -MemberDefinition @"
[DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
[DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
[DllImport("user32.dll")] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
"@
}

function Get-HitCode([IntPtr]$Hwnd, [int]$X, [int]$Y) {
    $p = New-Object GhosttyE2e.Mouse+POINT
    $p.X = $X
    $p.Y = $Y
    [void][GhosttyE2e.Mouse]::ClientToScreen($Hwnd, [ref]$p)
    $lp = [IntPtr](([int64]$p.Y -shl 16) -bor ([int64]$p.X -band 0xFFFF))
    [int][GhosttyE2e.Frame]::SendMessage($Hwnd, 0x84, [IntPtr]::Zero, $lp)
}

function Assert-Hit($G, [int]$X, [int]$Y, [int]$Expected, [string]$What) {
    $got = Get-HitCode $G.Hwnd $X $Y
    if ($got -ne $Expected) { throw "$What : WM_NCHITTEST at ($X,$Y) is $got, expected $Expected" }
}

function Get-ClientWidth([IntPtr]$Hwnd) {
    $rc = New-Object GhosttyE2e.Win+RECT
    [void][GhosttyE2e.Win]::GetClientRect($Hwnd, [ref]$rc)
    $rc.Right
}

Invoke-E2eScenario 'frame-hittest' {
    $g = Start-E2eGhostty -ConfigText "confirm-close-surface = false`nwindow-decoration = client`n"
    if (-not (Wait-Dump $g { param($x) $x.Width -gt 100 } 15)) { throw "no frame dump at $($g.Dump)" }
    $h = $g.Hwnd
    $s = [GhosttyE2e.Frame]::GetDpiForWindow($h) / 96.0
    $btn = [int][Math]::Round(46 * $s)
    $mid = [int][Math]::Round(20 * $s)
    $w = Get-ClientWidth $h

    Assert-Hit $g ($w - [int]($btn / 2)) $mid 20 'close'
    Assert-Hit $g ($w - $btn - [int]($btn / 2)) $mid 9 'maximize'
    Assert-Hit $g ($w - 2 * $btn - [int]($btn / 2)) $mid 8 'minimize'
    Assert-Hit $g ([int]($w / 2)) $mid 2 'caption'
    # With one tab the strip holds the title, the new-tab button and the caption.
    Assert-Hit $g ($w - 3 * $btn - [int](20 * $s)) $mid 1 'new tab button'
    Assert-Hit $g ([int]($w / 2)) 1 12 'top edge'
    Assert-Hit $g 1 1 13 'top-left corner'
    Assert-Hit $g ($w - 2) 1 14 'top-right corner'

    # Maximize: the client must stay on the monitor.
    [void][GhosttyE2e.Frame]::ShowWindow($h, 3)
    if (-not (Wait-Until { [GhosttyE2e.Frame]::IsZoomed($h) } 5)) { throw 'window did not maximize' }
    Start-Sleep -Milliseconds 300
    $scr = [Windows.Forms.Screen]::FromHandle($h)
    $p = New-Object GhosttyE2e.Mouse+POINT
    [void][GhosttyE2e.Mouse]::ClientToScreen($h, [ref]$p)
    $rc2 = New-Object GhosttyE2e.Win+RECT
    [void][GhosttyE2e.Win]::GetClientRect($h, [ref]$rc2)
    $b = $scr.Bounds
    if ($p.X -lt $b.Left -or $p.Y -lt $b.Top -or ($p.X + $rc2.Right) -gt $b.Right -or ($p.Y + $rc2.Bottom) -gt $b.Bottom) {
        throw "maximized client at ($($p.X),$($p.Y)) size $($rc2.Right)x$($rc2.Bottom) is outside the monitor $b"
    }
    [void][GhosttyE2e.Frame]::ShowWindow($h, 9)
    if (-not (Wait-Until { -not [GhosttyE2e.Frame]::IsZoomed($h) } 5)) { throw 'window did not restore' }

    # Double click on the caption toggles maximize.
    [void](Set-ForegroundSafe -Hwnd $h)
    Send-MouseClick -Hwnd $h -X ([int]((Get-ClientWidth $h) / 2)) -Y $mid -Double
    if (-not (Wait-Until { [GhosttyE2e.Frame]::IsZoomed($h) } 5)) { throw 'double click on the caption did not maximize' }
    Start-Sleep -Milliseconds 300
    Send-MouseClick -Hwnd $h -X ([int]((Get-ClientWidth $h) / 2)) -Y $mid -Double
    if (-not (Wait-Until { -not [GhosttyE2e.Frame]::IsZoomed($h) } 5)) { throw 'double click on the caption did not restore' }

    # Alt+Space opens the system menu (#32768); Esc closes it.
    [void](Set-ForegroundSafe -Hwnd $h)
    Invoke-SendInput -Hwnd $h -Keys 'alt+space'
    $script:menu = [IntPtr]::Zero
    $found = Wait-Until {
        $script:menu = [GhosttyE2e.Frame]::FindWindowEx([IntPtr]::Zero, [IntPtr]::Zero, '#32768', $null)
        $script:menu -ne [IntPtr]::Zero
    } 5
    if (-not $found) { throw 'Alt+Space did not open the system menu' }
    Invoke-SendInput -Hwnd $h -Keys 'esc'
    if (-not (Wait-Until { -not [GhosttyE2e.Frame]::IsWindowVisible($script:menu) } 5)) { throw 'Esc did not close the system menu' }
    Write-E2eInfo 'hit codes, maximize bounds, caption double click and Alt+Space menu pass'
}
