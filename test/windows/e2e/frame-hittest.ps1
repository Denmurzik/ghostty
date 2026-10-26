# e2e: milestone=M2 timeout=180 order=290
# frame-hittest: the custom frame answers WM_NCHITTEST for the caption buttons,
# the strip and the top edge, maximizing keeps the client on the monitor, a
# double click on the caption maximizes, and the top-level has no WS_SYSMENU
# (SPEC section 18 item 9), so the acceptance items of that removal are
# checked here: Alt+Space and caption right-click menus, Win+Up/Down, a lone
# Alt tap, Alt+key reaching the terminal, the inactive caption, Alt+F4.
# Strip rects come from the IPC `state` op when it is there, else from the
# fixed metrics of the strip.
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\MouseInput.psm1') -Force
$script:HaveIpc = Test-Path -LiteralPath (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1')
if ($script:HaveIpc) { Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force }

# Physical pixels: strip rects from `state` are physical and the client is
# DPI-virtualized for a DPI-unaware process, so opt in before any window call.
if (-not ('GhosttyE2e.TestDpi' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name TestDpi -MemberDefinition @"
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
"@
}
# DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
[void][GhosttyE2e.TestDpi]::SetProcessDpiAwarenessContext([IntPtr](-4))

if (-not ('GhosttyE2e.Frame' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name Frame -MemberDefinition @"
[DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
[DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
[DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
[DllImport("user32.dll")] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
[DllImport("user32.dll")] public static extern IntPtr GetShellWindow();
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
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

# Centre of a [l,t,r,b] rect.
function Get-Centre($R) { , @([int](($R[0] + $R[2]) / 2), [int](($R[1] + $R[3]) / 2)) }

# The points to probe, from the strip rects of the `state` op, or from the
# metrics of the strip (46x40 caption buttons at 96 dpi, close rightmost).
function Get-FramePoints($G) {
    $w = Get-ClientWidth $G.Hwnd
    $s = [GhosttyE2e.Frame]::GetDpiForWindow($G.Hwnd) / 96.0
    if ($script:HaveIpc) {
        try {
            $st = Get-GhosttyState -Class $G.Class
            $strip = if ($st.windows) { $st.windows[0].strip } else { $st.strip }
            if ($strip -and $strip.close -and $strip.maximize -and $strip.minimize -and $strip.new_tab) {
                return @{
                    close = Get-Centre $strip.close
                    maximize = Get-Centre $strip.maximize
                    minimize = Get-Centre $strip.minimize
                    new_tab = Get-Centre $strip.new_tab
                    # One tab: the strip shows the title and the caption rect is
                    # empty, so use the title area left of the new-tab button.
                    caption = if (($strip.caption[2] - $strip.caption[0]) -gt 8) { Get-Centre $strip.caption } else {
                        , @([int]($strip.new_tab[0] / 2), [int](($strip.close[1] + $strip.close[3]) / 2))
                    }
                    close_h = $strip.close[3]
                    source = 'state'
                }
            }
        } catch {
            Write-E2eInfo "state op unusable, using metrics: $($_.Exception.Message)"
        }
    }
    $btn = [int][Math]::Round(46 * $s)
    $mid = [int][Math]::Round(20 * $s)
    @{
        close = @(($w - [int]($btn / 2)), $mid)
        maximize = @(($w - $btn - [int]($btn / 2)), $mid)
        minimize = @(($w - 2 * $btn - [int]($btn / 2)), $mid)
        new_tab = @(($w - 3 * $btn - [int](20 * $s)), $mid)
        caption = @([int]($w / 2), $mid)
        close_h = [int][Math]::Round(40 * $s)
        source = 'metrics'
    }
}

function Wait-SystemMenu {
    $script:menu = [IntPtr]::Zero
    $found = Wait-Until {
        $script:menu = [GhosttyE2e.Frame]::FindWindowEx([IntPtr]::Zero, [IntPtr]::Zero, '#32768', $null)
        $script:menu -ne [IntPtr]::Zero
    } 5
    [bool]$found
}

function Close-SystemMenu($G, [string]$What) {
    Invoke-SendInput -Hwnd $G.Hwnd -Keys 'esc'
    if (-not (Wait-Until { -not [GhosttyE2e.Win]::IsWindowVisible($script:menu) } 5)) { throw "$What : Esc did not close the menu" }
}

function Test-Responsive([IntPtr]$Hwnd) {
    $r = [IntPtr]::Zero
    # SMTO_ABORTIFHUNG
    [GhosttyE2e.Frame]::SendMessageTimeout($Hwnd, 0, [IntPtr]::Zero, [IntPtr]::Zero, 2, 2000, [ref]$r) -ne [IntPtr]::Zero
}

function Get-ScreenRegionPng([int]$X, [int]$Y, [int]$W, [int]$H) {
    $bmp = New-Object Drawing.Bitmap $W, $H
    try {
        $g = [Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($X, $Y, 0, 0, (New-Object Drawing.Size $W, $H))
        $g.Dispose()
        $ms = New-Object IO.MemoryStream
        $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
        , $ms.ToArray()
    } finally { $bmp.Dispose() }
}
function Get-ScreenPixel([int]$X, [int]$Y) {
    $bmp = New-Object Drawing.Bitmap 1, 1
    try {
        $g = [Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($X, $Y, 0, 0, (New-Object Drawing.Size 1, 1))
        $g.Dispose()
        $c = $bmp.GetPixel(0, 0)
        , @([int]$c.R, [int]$c.G, [int]$c.B)
    } finally { $bmp.Dispose() }
}

Invoke-E2eScenario 'frame-hittest' {
    $g = Start-E2eGhostty -ConfigText "confirm-close-surface = false`nwindow-decoration = client`nkeybind = alt+x=new_tab`n"
    if (-not (Wait-Dump $g { param($x) $x.Width -gt 100 } 15)) { throw "no frame dump at $($g.Dump)" }
    $h = $g.Hwnd
    # The keys below are typed on the US layout (the shell window brings back the owner's).
    Set-WindowLayout $h "00000409"
    $s = [GhosttyE2e.Frame]::GetDpiForWindow($h) / 96.0
    $w = Get-ClientWidth $h
    # Two tabs: with one the strip shows an editable title (double click renames) and no caption.
    if ($script:HaveIpc) {
        [void](Invoke-GhosttyAction -Class $g.Class -Action "new_tab")
        [void](Wait-GhosttyState -Class $g.Class -Predicate { @($_.windows[0].tabs).Count -eq 2 } -TimeoutSec 10)
        Start-Sleep -Milliseconds 300
    }
    $pt = Get-FramePoints $g
    Write-E2eInfo "probe points from $($pt.source)"
    Write-E2eInfo ('probe points: ' + (($pt.GetEnumerator() | Where-Object { $_.Key -ne 'source' } | ForEach-Object { "$($_.Key)=$($_.Value -join ',')" }) -join ' ') + " client width $w")

    Assert-Hit $g $pt.close[0] $pt.close[1] 20 'close'
    Assert-Hit $g $pt.maximize[0] $pt.maximize[1] 9 'maximize'
    Assert-Hit $g $pt.minimize[0] $pt.minimize[1] 8 'minimize'
    Assert-Hit $g $pt.caption[0] $pt.caption[1] 2 'caption'
    Assert-Hit $g $pt.new_tab[0] $pt.new_tab[1] 1 'new tab button'
    Assert-Hit $g ([int]($w / 2)) 1 12 'top edge'
    Assert-Hit $g 1 1 13 'top-left corner'
    Assert-Hit $g ($w - 2) 1 14 'top-right corner'

    # Maximize (toggle_maximize through the action, else ShowWindow): the
    # client must stay on the monitor.
    $viaAction = $false
    if ($script:HaveIpc) { $viaAction = [bool](Invoke-GhosttyAction -Class $g.Class -Action 'toggle_maximize') }
    if (-not $viaAction) { [void][GhosttyE2e.Frame]::ShowWindow($h, 3) }
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
    $pt = Get-FramePoints $g

    # Double click on the caption toggles maximize.
    [void](Set-ForegroundSafe -Hwnd $h)
    Send-MouseClick -Hwnd $h -X $pt.caption[0] -Y $pt.caption[1] -Double
    if (-not (Wait-Until { [GhosttyE2e.Frame]::IsZoomed($h) } 5)) { $cp = New-Object GhosttyE2e.Mouse+POINT; [void][GhosttyE2e.Mouse]::GetCursorPos([ref]$cp); $sp = New-Object GhosttyE2e.Mouse+POINT; $sp.X = $pt.caption[0]; $sp.Y = $pt.caption[1]; [void][GhosttyE2e.Mouse]::ClientToScreen($h, [ref]$sp); throw ('double click on the caption did not maximize: cursor {0},{1} wanted {2},{3} hit {4} dpiAware={5}' -f $cp.X, $cp.Y, $sp.X, $sp.Y, (Get-HitCode $h $pt.caption[0] $pt.caption[1]), [GhosttyE2e.Frame]::GetDpiForWindow($h)) }
    Start-Sleep -Milliseconds 300
    $pt = Get-FramePoints $g
    Send-MouseClick -Hwnd $h -X $pt.caption[0] -Y $pt.caption[1] -Double
    if (-not (Wait-Until { -not [GhosttyE2e.Frame]::IsZoomed($h) } 5)) { throw 'double click on the caption did not restore' }
    $pt = Get-FramePoints $g

    # Alt+Space opens the system menu (#32768); Esc closes it.
    [void](Set-ForegroundSafe -Hwnd $h)
    Invoke-SendInput -Hwnd $h -Keys 'alt+space'
    if (-not (Wait-SystemMenu)) { throw 'Alt+Space did not open the system menu' }
    Close-SystemMenu $g 'Alt+Space'

    # Right click on the caption opens it too.
    Start-Sleep -Milliseconds 300
    Send-MouseClick -Hwnd $h -X $pt.caption[0] -Y $pt.caption[1] -Button right
    if (-not (Wait-SystemMenu)) { throw 'caption right click did not open the system menu' }
    Close-SystemMenu $g 'caption right click'

    # Win+Up maximizes, Win+Down restores.
    [void](Set-ForegroundSafe -Hwnd $h)
    Invoke-SendInput -Hwnd $h -Keys 'win+up'
    if (-not (Wait-Until { [GhosttyE2e.Frame]::IsZoomed($h) } 5)) { throw 'Win+Up did not maximize' }
    Invoke-SendInput -Hwnd $h -Keys 'win+down'
    if (-not (Wait-Until { -not [GhosttyE2e.Frame]::IsZoomed($h) } 5)) { throw 'Win+Down did not restore' }

    # A lone Alt tap must not start a modal menu loop.
    [void](Set-ForegroundSafe -Hwnd $h)
    Invoke-SendInput -Hwnd $h -Keys 'alt'
    Start-Sleep -Milliseconds 400
    if (-not (Test-Responsive $h)) { throw 'the UI thread is blocked after a lone Alt tap' }
    if ([GhosttyE2e.Frame]::FindWindowEx([IntPtr]::Zero, [IntPtr]::Zero, '#32768', $null) -ne [IntPtr]::Zero) {
        throw 'a lone Alt tap opened a menu'
    }

    # The inactive caption repaints: the shell window takes the focus, the
    # ink of the tab titles and caption buttons changes (the background does
    # not), so the strip bitmap differs.
    $origin = New-Object GhosttyE2e.Mouse+POINT
    [void][GhosttyE2e.Mouse]::ClientToScreen($h, [ref]$origin)
    $stripH = [int]$pt.close_h
    $active = Get-ScreenRegionPng $origin.X $origin.Y $w $stripH
    [void](Set-ForegroundSafe -Hwnd ([GhosttyE2e.Frame]::GetShellWindow()))
    Start-Sleep -Milliseconds 600
    $inactive = Get-ScreenRegionPng $origin.X $origin.Y $w $stripH
    if ([Convert]::ToBase64String($active) -eq [Convert]::ToBase64String($inactive)) {
        $fgNow = [GhosttyE2e.Frame]::GetForegroundWindow()
        throw "the strip did not repaint when inactive (foreground is $(if ($fgNow -eq $h) { 'still ghostty' } else { 'another window' })): region ($($origin.X),$($origin.Y)) ${w}x$stripH is unchanged"
    }    [void](Set-ForegroundSafe -Hwnd $h)

    # Alt+x reaches the terminal (keybind alt+x=new_tab): a second tab.
    if ($script:HaveIpc) {
        Invoke-SendInput -Hwnd $h -Keys 'alt+x'
        [void](Wait-GhosttyState -Class $g.Class -Predicate { @($_.windows[0].tabs).Count -eq 3 } -TimeoutSec 10)
    } else {
        Write-E2eInfo 'no IPC state: Alt+x delivery not checked'
    }

    # Alt+F4 closes the window and the process ends.
    [void](Set-ForegroundSafe -Hwnd $h)
    Invoke-SendInput -Hwnd $h -Keys 'alt+f4'
    $exit = Wait-ProcessExit $g 15
    if (-not $exit.Exited) { throw 'Alt+F4 did not close ghostty' }
    Write-E2eInfo 'hit codes, maximize, double click, system menus, Win+Up/Down, Alt tap, Alt+x, inactive caption and Alt+F4 pass'
}
