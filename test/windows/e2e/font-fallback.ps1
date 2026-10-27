# e2e: milestone=M3 timeout=120 order=510
# font-fallback: DirectWrite MapCharacters fallback. Git Bash prints
# the CJK, Hangul, snowman, sigma and command-key text on the first row and a reference row of 40 `M` below it;
# every non-space cell of the first row has ink pixels in the frame dump and
# the log reports `directwrite fallback family=`.
. (Join-Path $PSScriptRoot '_common.ps1')

Invoke-E2eScenario 'font-fallback' {
    # U+3042 U+6F22 U+5B57 U+D55C U+AE00, a snowman, a sigma and the command key, by code point (this file stays ASCII for Windows PowerShell 5).
    $text = -join (0x3042, 0x6F22, 0x5B57, 0xD55C, 0xAE00, 0x20, 0x2603, 0x20, 0x2211, 0x20, 0x2318 | ForEach-Object { [char]$_ })
    $esc = ([Text.Encoding]::UTF8.GetBytes($text) | ForEach-Object { '\x{0:x2}' -f $_ }) -join ''
    $g = Start-BashE2e
    Send-Line $g.Hwnd 'clear'
    Send-Line $g.Hwnd "printf '\033[H\033[2J${esc}\nMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM\n'"

    # Ink of the rows [y0, y1) between x0 and x1: pixels that differ from the background.
    function Test-Ink($D, $Bg, [int]$X0, [int]$X1, [int]$Y0, [int]$Y1) {
        for ($y = $Y0; $y -lt $Y1; $y++) {
            for ($x = $X0; $x -lt $X1; $x++) {
                $p = Get-DumpPixel $D $x $y
                if ([Math]::Abs($p.R - $Bg.R) + [Math]::Abs($p.G - $Bg.G) + [Math]::Abs($p.B - $Bg.B) -gt 60) { return $true }
            }
        }
        $false
    }
    # Row bands (first and last ink row) of the first two text lines.
    function Get-Bands($D, $Bg) {
        $bands = @()
        $start = -1
        for ($y = 0; $y -lt [Math]::Min($D.Height, 200); $y++) {
            $ink = Test-Ink $D $Bg 0 ([Math]::Min($D.Width, 700)) $y ($y + 1)
            if ($ink -and $start -lt 0) { $start = $y }
            if (-not $ink -and $start -ge 0) { $bands += , @($start, $y); $start = -1 }
        }
        $bands
    }
    function Get-InkX($D, $Bg, $Band) {
        $min = -1; $max = -1
        for ($x = 0; $x -lt [Math]::Min($D.Width, 1200); $x++) {
            if (Test-Ink $D $Bg $x ($x + 1) $Band[0] $Band[1]) { if ($min -lt 0) { $min = $x }; $max = $x }
        }
        $min, $max
    }

    $d = Wait-Dump $g {
        param($d)
        $bg = Get-DumpPixel $d ($d.Width - 6) ($d.Height - 6)
        $b = @(Get-Bands $d $bg)
        $b.Count -ge 2 -and $b[0][0] -lt 12 -and (Get-InkX $d $bg $b[1])[1] -gt 100
    } 20
    if (-not $d) { throw 'the text rows never appeared in the frame dump' }
    $bg = Get-DumpPixel $d ($d.Width - 6) ($d.Height - 6)
    $bands = @(Get-Bands $d $bg)
    $text_band = $bands[0]
    $ref_band = $bands[1]

    # 40 M cells span the reference row; the ink of the first M sits a pixel or two inside its cell.
    $rx = Get-InkX $d $bg $ref_band
    $cw = ($rx[1] - $rx[0] + 3) / 40.0
    $x0 = $rx[0] - 1
    Write-E2eInfo "cell width ~$([Math]::Round($cw, 2)) px, origin x=$x0, text rows $($text_band[0])..$($text_band[1])"

    # Cells: the first five characters are wide (0-9), 10 is a space, 11 is the snowman, 12 a space, 13 sigma, 14 a space, 15 the command key.
    $cells = 0..9 + 11, 13, 15
    $missing = @()
    foreach ($c in $cells) {
        $a = [int]($x0 + $c * $cw + 1)
        $b = [int]($x0 + ($c + 1) * $cw - 1)
        if (-not (Test-Ink $d $bg $a $b ($text_band[0] - 2) ($text_band[1] + 2))) { $missing += $c }
    }
    if ($missing.Count) {
        Save-DumpPng $d (Join-Path $script:Sbx.Dump 'font-fallback-missing.png')
        throw "no glyph ink in cells: $($missing -join ', ')"
    }

    $log = if (Test-Path $g.Log) { Get-Content -LiteralPath $g.Log -Raw } else { '' }
    if ($log -notmatch 'directwrite fallback family=') { throw 'the log has no `directwrite fallback family=` line' }
}
