# e2e: milestone=M3 timeout=240 order=400
# scrollbar: the overlay scroller (macOS style). It takes no width (the surface
# is as wide with and without scrollback, no WS_VSCROLL), appears when the
# viewport scrolls, fades out after a pause, appears again when the pointer
# reaches the right edge, the knob can be dragged, a click on the track beside
# it scrolls a page, and `scrollbar = never` never shows it. Screenshots of the
# strip go to %TEMP%\m3-scroller (dark and light, idle, visible, hover).
. (Join-Path $PSScriptRoot '_common.ps1')
Import-Module (Join-Path $script:WinDir 'lib\GhosttyIpc.psm1') -Force
Import-Module (Join-Path $script:WinDir 'lib\MouseInput.psm1') -Force
Add-Type -AssemblyName System.Drawing

if (-not ('GhosttyE2e.Style' -as [type])) {
    Add-Type -Namespace GhosttyE2e -Name Style -MemberDefinition @"
[DllImport("user32.dll", EntryPoint = "GetWindowLongW")] public static extern int GetWindowLong(IntPtr h, int index);
"@
}

$WS_VSCROLL = 0x00200000
$ShotDir = Join-Path $env:TEMP 'm3-scroller'
New-Item -ItemType Directory -Force -Path $ShotDir | Out-Null

function Get-FirstSurface($Class, [scriptblock]$Predicate = { $true }, [double]$TimeoutSec = 15) {
    $s = Wait-GhosttyState -Class $Class -TimeoutSec $TimeoutSec -Predicate {
        @($_.windows).Count -eq 1 -and @(@($_.windows)[0].tabs).Count -eq 1 -and
        (& $Predicate (@(@($_.windows)[0].tabs)[0].surfaces)[0])
    }.GetNewClosure()
    @(@($s.windows)[0].tabs)[0].surfaces[0]
}

function Get-SurfaceHwnd($Surface) { [IntPtr][Convert]::ToInt64($Surface.hwnd, 16) }

function Get-SurfaceWidth($Surface) {
    $r = $Surface.rect
    $r[2] - $r[0]
}

# Saves the right-hand part of the surface as a PNG (the strip and a bit of text).
function Save-Strip($Surface, [string]$Name) {
    $hwnd = Get-SurfaceHwnd $Surface
    $w = Get-SurfaceWidth $Surface
    $h = $Surface.rect[3] - $Surface.rect[1]
    $o = Convert-ClientToScreen $hwnd 0 0
    $bw = [Math]::Min(120, $w)
    $bmp = New-Object Drawing.Bitmap $bw, $h
    $gfx = [Drawing.Graphics]::FromImage($bmp)
    try { $gfx.CopyFromScreen($o.X + $w - $bw, $o.Y, 0, 0, (New-Object Drawing.Size $bw, $h)) } finally { $gfx.Dispose() }
    $path = Join-Path $ShotDir "$Name.png"
    $bmp.Save($path, [Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-E2eInfo "shot $path"
}

function Test-Scroller($Class, [bool]$Want, [double]$TimeoutSec = 6) {
    [void](Get-FirstSurface $Class { param($s) $s.scrollbar.scroller_visible -eq $Want } $TimeoutSec)
}

function Invoke-ScrollerRun([string]$Tag, [string]$ExtraConfig) {
    $g = Start-E2eGhostty -ConfigText ($script:BaseConfig + "`n$ExtraConfig`n")
    $class = $g.Class
    $global:E2eLast = $g
    Wait-BashReady $g

    $before = Get-FirstSurface $class
    $hwnd = Get-SurfaceHwnd $before
    if (([GhosttyE2e.Style]::GetWindowLong($hwnd, -16) -band $WS_VSCROLL) -ne 0) { throw 'the surface has a native WS_VSCROLL' }
    $widthBefore = Get-SurfaceWidth $before

    [void](Invoke-GhosttyAction -Class $class -Action 'text:seq 1 300\r')
    $filled = Get-FirstSurface $class { param($s) $s.scrollbar.len -gt 0 -and $s.scrollbar.total -gt $s.scrollbar.len }
    Write-E2eInfo ("[$Tag] scrollbar total {0} offset {1} len {2}" -f $filled.scrollbar.total, $filled.scrollbar.offset, $filled.scrollbar.len)
    if ((Get-SurfaceWidth $filled) -ne $widthBefore) { throw "[$Tag] the surface width changed when scrollback appeared" }
    Save-Strip $filled "$Tag-idle"

    # Scrolling the viewport shows the knob.
    [void](Invoke-GhosttyAction -Class $class -Action 'scroll_to_top')
    $top = Get-FirstSurface $class { param($s) $s.scrollbar.offset -eq 0 }
    Test-Scroller $class $true 3
    $vis = Get-FirstSurface $class { param($s) $s.scrollbar.scroller_visible }
    Write-E2eInfo ("[$Tag] knob {0}" -f ($vis.scrollbar.knob -join ','))
    Save-Strip $vis "$Tag-visible"
    if ($vis.scrollbar.knob[0] -gt 6) { throw "[$Tag] knob is not at the top at offset 0: $($vis.scrollbar.knob -join ',')" }

    # It fades out on its own.
    Start-Sleep -Milliseconds 400
    $mid = Get-FirstSurface $class { param($s) $s.scrollbar.scroller_visible }
    Test-Scroller $class $false 4
    Write-E2eInfo "[$Tag] hidden after the pause"

    # The pointer at the right edge brings it back, grown.
    $w = Get-SurfaceWidth $top
    Send-MouseMove -Hwnd $hwnd -X 300 -Y 200
    Start-Sleep -Milliseconds 200
    Send-MouseMove -Hwnd $hwnd -X ($w - 5) -Y 200 -Steps 6
    Test-Scroller $class $true 3
    Start-Sleep -Milliseconds 400
    $hover = Get-FirstSurface $class { param($s) $s.scrollbar.scroller_visible }
    Save-Strip $hover "$Tag-hover"
    # Hovering keeps it past the pause.
    Start-Sleep -Milliseconds 1500
    Test-Scroller $class $true 1

    # Drag the knob down: the viewport follows.
    $k = $hover.scrollbar.knob
    $cy = $k[0] + [int]($k[1] / 2)
    Send-MouseDrag -Hwnd $hwnd -X ($w - 6) -Y $cy -ToX ($w - 6) -ToY ($cy + 120) -Steps 12 -HoldMs 100
    $dragged = Get-FirstSurface $class { param($s) $s.scrollbar.offset -gt 20 }
    Write-E2eInfo ("[$Tag] drag moved the viewport to offset {0}" -f $dragged.scrollbar.offset)

    # A click on the track below the knob scrolls one page.
    Start-Sleep -Milliseconds 300
    $now = Get-FirstSurface $class { param($s) $s.scrollbar.scroller_visible }
    $k2 = $now.scrollbar.knob
    $off0 = $now.scrollbar.offset
    $h = $now.rect[3] - $now.rect[1]
    Send-MouseClick -Hwnd $hwnd -X ($w - 6) -Y ($h - 10)
    $paged = Get-FirstSurface $class { param($s) $s.scrollbar.offset -gt $off0 }
    Write-E2eInfo ("[$Tag] page click: offset {0} -> {1} (len {2})" -f $off0, $paged.scrollbar.offset, $paged.scrollbar.len)
    if ($paged.scrollbar.offset -ne [Math]::Min($off0 + $paged.scrollbar.len, $paged.scrollbar.total - $paged.scrollbar.len)) {
        throw "[$Tag] a click on the track did not scroll exactly one page"
    }

    # Away from the edge it fades again.
    Send-MouseMove -Hwnd $hwnd -X 300 -Y 200 -Steps 4
    Test-Scroller $class $false 5
    $errors = @(Get-LogErrors $g)
    if ($errors.Count) { throw "[$Tag] ghostty.log has $($errors.Count) error line(s), first: $($errors[0])" }
}

Invoke-E2eScenario 'scrollbar' {
    Invoke-ScrollerRun 'dark' ''
    Stop-OwnGhostty
    Invoke-ScrollerRun 'light' "background = ffffff`nforeground = 000000"
    Stop-OwnGhostty

    # scrollbar = never: no scroller whatever happens.
    $never = Start-E2eGhostty -ConfigText ($script:BaseConfig + "`nscrollbar = never`n")
    Wait-BashReady $never
    [void](Invoke-GhosttyAction -Class $never.Class -Action 'text:seq 1 300\r')
    [void](Get-FirstSurface $never.Class { param($s) $s.scrollbar.total -gt $s.scrollbar.len })
    [void](Invoke-GhosttyAction -Class $never.Class -Action 'scroll_to_top')
    $s2 = Get-FirstSurface $never.Class { param($s) $s.scrollbar.offset -eq 0 }
    $hw = Get-SurfaceHwnd $s2
    Send-MouseMove -Hwnd $hw -X ((Get-SurfaceWidth $s2) - 5) -Y 200 -Steps 4
    Start-Sleep -Milliseconds 600
    $s3 = Get-FirstSurface $never.Class
    if ($s3.scrollbar.scroller_visible) { throw 'scrollbar = never: the scroller is shown' }
}
