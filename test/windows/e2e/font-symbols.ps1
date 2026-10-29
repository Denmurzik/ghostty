# e2e: milestone=M7 timeout=120 order=1100
# font-symbols: symbols and emoji come from the system faces (R-M7-3). Git Bash prints
# the record, check, warning, asterisk, prompt and arrow symbols on the first row, two emoji on the
# second and a reference row of 40 `M` below; every symbol cell has ink pixels in the frame dump, each
# emoji cell has at least 20 pixels whose R, G, B differ by more than 40 (colour), and the log reports
# `directwrite fallback family=Segoe UI Symbol` and `family=Segoe UI Emoji` and names no Noto face.
. (Join-Path $PSScriptRoot '_common.ps1')

Invoke-E2eScenario 'font-symbols' {
    # Built from code points (this file stays ASCII for Windows PowerShell 5).
    function ConvertTo-PrintfEscape([int[]]$CodePoints) {
        $text = -join ($CodePoints | ForEach-Object { [char]::ConvertFromUtf32($_) })
        ([Text.Encoding]::UTF8.GetBytes($text) | ForEach-Object { '\x{0:x2}' -f $_ }) -join ''
    }
    # U+23FA U+2714 U+26A0 U+273B U+276F U+2192, each followed by a space.
    $sym = ConvertTo-PrintfEscape (0x23FA, 0x20, 0x2714, 0x20, 0x26A0, 0x20, 0x273B, 0x20, 0x276F, 0x20, 0x2192)
    # U+1F600 and U+1F44D.
    $emo = ConvertTo-PrintfEscape (0x1F600, 0x20, 0x1F44D)
    $g = Start-BashE2e
    Send-Line $g.Hwnd 'clear'
    Send-Line $g.Hwnd "printf '\033[H\033[2J${sym}\n${emo}\nMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM\n'"

    function Test-Ink($D, $Bg, [int]$X0, [int]$X1, [int]$Y0, [int]$Y1) {
        for ($y = $Y0; $y -lt $Y1; $y++) {
            for ($x = $X0; $x -lt $X1; $x++) {
                $p = Get-DumpPixel $D $x $y
                if ([Math]::Abs($p.R - $Bg.R) + [Math]::Abs($p.G - $Bg.G) + [Math]::Abs($p.B - $Bg.B) -gt 60) { return $true }
            }
        }
        $false
    }
    # Pixels in the box whose channels differ by more than 40.
    function Get-ColourPixels($D, [int]$X0, [int]$X1, [int]$Y0, [int]$Y1) {
        $n = 0
        for ($y = $Y0; $y -lt $Y1; $y++) {
            for ($x = $X0; $x -lt $X1; $x++) {
                $p = Get-DumpPixel $D $x $y
                $hi = [Math]::Max($p.R, [Math]::Max($p.G, $p.B))
                $lo = [Math]::Min($p.R, [Math]::Min($p.G, $p.B))
                if ($hi - $lo -gt 40) { $n++ }
            }
        }
        $n
    }
    # Row bands (first and last ink row) of the text lines.
    function Get-Bands($D, $Bg) {
        $bands = @()
        $start = -1
        for ($y = 0; $y -lt [Math]::Min($D.Height, 260); $y++) {
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
        $b.Count -ge 3 -and $b[0][0] -lt 12 -and (Get-InkX $d $bg $b[2])[1] -gt 100
    } 20
    if (-not $d) { throw 'the text rows never appeared in the frame dump' }
    $bg = Get-DumpPixel $d ($d.Width - 6) ($d.Height - 6)
    $bands = @(Get-Bands $d $bg)
    $sym_band = $bands[0]
    $emo_band = $bands[1]
    $ref_band = $bands[2]

    # 40 M cells span the reference row; the ink of the first M sits a pixel or two inside its cell.
    $rx = Get-InkX $d $bg $ref_band
    $cw = ($rx[1] - $rx[0] + 3) / 40.0
    $x0 = $rx[0] - 1
    Write-E2eInfo "cell width ~$([Math]::Round($cw, 2)) px, origin x=$x0, rows $($sym_band[0])..$($sym_band[1]) / $($emo_band[0])..$($emo_band[1])"

    # Symbols sit in cells 0, 2, 4, 6, 8, 10.
    $missing = @()
    foreach ($c in 0, 2, 4, 6, 8, 10) {
        $a = [int]($x0 + $c * $cw + 1)
        $b = [int]($x0 + ($c + 1) * $cw - 1)
        if (-not (Test-Ink $d $bg $a $b ($sym_band[0] - 2) ($sym_band[1] + 2))) { $missing += $c }
    }
    if ($missing.Count) {
        Save-DumpPng $d (Join-Path $script:Sbx.Dump 'font-symbols-missing.png')
        throw "no symbol ink in cells: $($missing -join ', ')"
    }

    # Emoji are two cells wide: cells 0-1 and 3-4.
    $dull = @()
    foreach ($c in 0, 3) {
        $a = [int]($x0 + $c * $cw)
        $b = [int]($x0 + ($c + 2) * $cw)
        $n = Get-ColourPixels $d $a $b ($emo_band[0] - 2) ($emo_band[1] + 2)
        Write-E2eInfo "emoji at cell ${c}: $n colour pixels"
        if ($n -lt 20) { $dull += $c }
    }
    if ($dull.Count) {
        Save-DumpPng $d (Join-Path $script:Sbx.Dump 'font-symbols-emoji.png')
        throw "emoji not in colour in cells: $($dull -join ', ')"
    }

    $log = if (Test-Path $g.Log) { Get-Content -LiteralPath $g.Log -Raw } else { '' }
    if ($log -notmatch 'directwrite fallback family=Segoe UI Symbol') { throw 'the log has no `directwrite fallback family=Segoe UI Symbol` line' }
    if ($log -notmatch 'directwrite fallback family=Segoe UI Emoji') { throw 'the log has no `directwrite fallback family=Segoe UI Emoji` line' }
    if ($log -match 'Noto') { throw 'the log names a Noto face' }
}
