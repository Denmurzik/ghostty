# e2e: milestone=M3 timeout=120 order=525 surfaces=2
# bell-border: with `bell-features = border` a bell in the unfocused split
# draws a border of rgb(255, 204, 0) at half opacity (Ghostty for macOS) on the
# edge of that split; focusing it clears the border.
. (Join-Path $PSScriptRoot '_common.ps1')
. (Join-Path $PSScriptRoot '_splits.ps1')

function Get-EdgePixels($G, [int]$SurfaceId) {
    $d = Read-Dump (Get-DumpPath $G $SurfaceId)
    if (-not $d) { return $null }
    [pscustomobject]@{
        Corner = Get-DumpPixel $d 0 0
        Inside = Get-DumpPixel $d ([int]($d.Width / 2)) ([int]($d.Height / 2))
        Far = Get-DumpPixel $d ($d.Width - 1) ($d.Height - 1)
    }
}

function Wait-Edge($G, [int]$SurfaceId, [int[]]$Rgb, [string]$What) {
    $ok = Wait-Until -TimeoutSec 12 -PollMs 150 -Condition {
        $e = Get-EdgePixels $G $SurfaceId
        if ($e -and (Test-PixelNear $e.Corner $Rgb 3) -and (Test-PixelNear $e.Far $Rgb 3)) { $true }
    }
    if (-not $ok) {
        $e = Get-EdgePixels $G $SurfaceId
        throw "$What : surface $SurfaceId corner $(if ($e) { Format-Pixel $e.Corner } else { 'missing' }), expected #{0:x2}{1:x2}{2:x2}" -f $Rgb[0], $Rgb[1], $Rgb[2]
    }
}

Invoke-E2eScenario 'bell-border' {
    $g = Start-E2eGhostty -ConfigText "command = direct:cmd.exe /k chcp 65001`nbackground = #000000`nunfocused-split-opacity = 1`nbell-features = border`n"
    if (-not (Set-ForegroundSafe -Hwnd $g.Hwnd)) { throw 'E2E-SKIP: could not take the foreground' }
    $global:E2eLast = $g

    [void](Wait-SurfaceCount $g 1)
    Invoke-SplitAction $g 'new_split:right'
    $st = Wait-SurfaceCount $g 2
    $left = @(Get-SurfaceBoxes $st | Sort-Object L)[0]
    Invoke-SplitAction $g 'goto_split:left'

    # A bell two seconds from now, rung while the right split has the focus.
    Send-Line $g.Hwnd 'powershell -NoProfile -Command "Start-Sleep 2; [Console]::Write([char]7)"'
    Invoke-SplitAction $g 'goto_split:right'

    # blend(black, rgb(255, 204, 0), 0.5)
    Wait-Edge $g $left.Id @(128, 102, 0) 'border after the bell'
    $e = Get-EdgePixels $g $left.Id
    if (Test-PixelNear $e.Inside @(128, 102, 0) 3) { throw 'the border fills the whole surface' }
    Save-Evidence 'border' $g -Window

    # Focusing the surface clears it.
    Invoke-SplitAction $g 'goto_split:left'
    Wait-Edge $g $left.Id @(0, 0, 0) 'border cleared by focus'
}
