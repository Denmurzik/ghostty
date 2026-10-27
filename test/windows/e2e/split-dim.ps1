# e2e: milestone=M3 timeout=120 order=520 surfaces=2
# split-dim: the unfocused split is dimmed like Ghostty for macOS does it: a
# rectangle of `unfocused-split-fill` at 1 - `unfocused-split-opacity` over the
# split that is not focused. Read from the frame dumps at an empty cell.
. (Join-Path $PSScriptRoot '_common.ps1')
. (Join-Path $PSScriptRoot '_splits.ps1')

# blend(background, fill, alpha), per channel.
function Get-Blend([int[]]$Bg, [int[]]$Fill, [double]$Alpha) {
    @(0..2 | ForEach-Object { [int][Math]::Round($Bg[$_] * (1 - $Alpha) + $Fill[$_] * $Alpha) })
}

# The pixel near the bottom-right corner of the surface's dump: an empty cell.
function Get-EmptyPixel($G, [int]$SurfaceId) {
    $d = Read-Dump (Get-DumpPath $G $SurfaceId)
    if (-not $d) { return $null }
    Get-DumpPixel $d ($d.Width - 12) ($d.Height - 12)
}

function Wait-Pixel($G, [int]$SurfaceId, [int[]]$Rgb, [string]$What) {
    $ok = Wait-Until -TimeoutSec 10 -PollMs 150 -Condition {
        $p = Get-EmptyPixel $G $SurfaceId
        if ($p -and (Test-PixelNear $p $Rgb 3)) { $true }
    }
    if (-not $ok) {
        $p = Get-EmptyPixel $G $SurfaceId
        throw "$What : surface $SurfaceId pixel is $(if ($p) { Format-Pixel $p } else { 'missing' }), expected #{0:x2}{1:x2}{2:x2}" -f $Rgb[0], $Rgb[1], $Rgb[2]
    }
}

Invoke-E2eScenario 'split-dim' {
    $g = Start-E2eGhostty -ConfigText "command = direct:cmd.exe /k chcp 65001`nbackground = #000000`nforeground = #c0c0c0`nunfocused-split-fill = #ffffff`nunfocused-split-opacity = 0.7`n"
    if (-not (Set-ForegroundSafe -Hwnd $g.Hwnd)) { throw 'E2E-SKIP: could not take the foreground' }
    $global:E2eLast = $g

    [void](Wait-SurfaceCount $g 1)
    Invoke-SplitAction $g 'new_split:right'
    $st = Wait-SurfaceCount $g 2
    $boxes = @(Get-SurfaceBoxes $st | Sort-Object L)
    $left = $boxes[0]; $right = $boxes[1]
    $black = @(0, 0, 0)
    $dimmed = Get-Blend $black @(255, 255, 255) 0.3

    # The new split (right) has the focus.
    Wait-Pixel $g $right.Id $black 'focused right'
    Wait-Pixel $g $left.Id $dimmed 'dimmed left'
    Save-Evidence 'right-focused' $g -Window

    Invoke-SplitAction $g 'goto_split:left'
    Wait-Pixel $g $left.Id $black 'focused left'
    Wait-Pixel $g $right.Id $dimmed 'dimmed right'
    Save-Evidence 'left-focused' $g -Window

    # Opacity 1 is no dim.
    $cfg = Join-Path $script:Sbx.Home '.config\ghostty\config.ghostty'
    Add-Content -LiteralPath $cfg -Value "unfocused-split-opacity = 1`n" -Encoding UTF8
    Invoke-SplitAction $g 'reload_config'
    Wait-Pixel $g $right.Id $black 'opacity 1 right'
    Wait-Pixel $g $left.Id $black 'opacity 1 left'
}
