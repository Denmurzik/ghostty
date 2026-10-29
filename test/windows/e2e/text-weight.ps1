# e2e: milestone=M7 timeout=240 order=1120
# text-weight: four text-weight variants of the same sample (R-M7-5):
#   A linear-corrected (today), B native, C linear-corrected + font-thicken, D native + font-thicken.
# Each variant runs Git Bash with a printf-only sample script, waits for two equal frame dumps, saves
# text-weight-<A..D>.png and measures the ink coverage of every sample row
# (mean of |px - bg| / |fg - bg| over the row's cells). The four crops are stacked, labelled, into
# text-weight-sheet.png. PASS when all four dumps exist and C >= A, D >= B on every row (thicken works).
# Output goes to the evidence dir (-EvidenceDir), else into the sandbox (numbers only).
. (Join-Path $PSScriptRoot '_common.ps1')

Invoke-E2eScenario 'text-weight' {
    $bash = Find-GitBash
    if (-not $bash) { throw 'E2E-SKIP: Git Bash is not installed, this scenario needs it' }

    $text = 'Hamburgefonstiv 0123 mlil {}[]() il|'
    $n = $text.Length
    # Row colours: fg, bg (R,G,B) and the SGR. Palette 2/3/5 are pinned in the config so the colours are known.
    $black = @(0, 0, 0)
    $rows = @(
        @{ Fg = @(215, 119, 87); Bg = $black; Sgr = '38;2;215;119;87' },
        @{ Fg = @(0x4e, 0x9a, 0x06); Bg = $black; Sgr = '32' },
        @{ Fg = @(0xc4, 0xa0, 0x00); Bg = $black; Sgr = '33' },
        @{ Fg = @(0x75, 0x50, 0x7b); Bg = $black; Sgr = '35' },
        @{ Fg = @(255, 255, 255); Bg = $black; Sgr = '38;2;255;255;255' },
        @{ Fg = @(128, 128, 128); Bg = $black; Sgr = '38;2;128;128;128' },
        @{ Fg = @(30, 30, 30); Bg = @(240, 240, 240); Sgr = '38;2;30;30;30;48;2;240;240;240' }
    )
    $light = $rows.Count - 1

    $outDir = Get-EvidenceDir
    if (-not $outDir) {
        $outDir = Join-Path $script:Sbx.Root 'text-weight'
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    }

    # The sample: printf only, then keep the pane alive.
    $sh = New-Object Text.StringBuilder
    [void]$sh.Append("printf '\033[H\033[2J'`n")
    foreach ($r in $rows) { [void]$sh.Append("printf '\033[$($r.Sgr)m%s\033[0m\n' '$text'`n") }
    [void]$sh.Append("exec sleep 600`n")
    $sample = Join-Path $script:Sbx.Tmp 'sample.sh'
    [IO.File]::WriteAllText($sample, $sh.ToString(), (New-Object Text.UTF8Encoding $false))
    $sampleArg = $sample -replace '\\', '/'

    $variants = [ordered]@{
        A = @('linear-corrected', $false)
        B = @('native', $false)
        C = @('linear-corrected', $true)
        D = @('native', $true)
    }
    $inv = [Globalization.CultureInfo]::InvariantCulture

    function Test-Light([byte[]]$B, [int]$W, [int]$H, [bool]$TopDown, [int]$X, [int]$Y) {
        $row = if ($TopDown) { $Y } else { $H - 1 - $Y }
        $o = 54 + ($row * $W + $X) * 4
        ([Math]::Abs($B[$o + 2] - 240) -le 2) -and ([Math]::Abs($B[$o + 1] - 240) -le 2) -and ([Math]::Abs($B[$o] - 240) -le 2)
    }

    $cov = @{}
    $crops = @{}
    foreach ($v in $variants.Keys) {
        $blend, $thick = $variants[$v]
        $cfg = @"
confirm-close-surface = false
background = #000000
foreground = #ffffff
palette = 2=#4e9a06
palette = 3=#c4a000
palette = 5=#75507b
window-padding-x = 0
window-padding-y = 0
cursor-style-blink = false
shell-integration = none
alpha-blending = $blend
font-thicken = $($thick.ToString().ToLowerInvariant())
command = direct:"$bash" --noprofile --norc $sampleArg
"@
        if (Test-Path -LiteralPath $script:Sbx.Dump) {
            Get-ChildItem -LiteralPath $script:Sbx.Dump -File | Remove-Item -Force -ErrorAction SilentlyContinue
        }
        $g = Start-E2eGhostty -ConfigText $cfg

        # Two equal dumps in a row.
        $script:twPrev = $null
        $d = Wait-Until -TimeoutSec 30 -PollMs 400 -Condition {
            if (-not (Test-Path -LiteralPath $g.Dump)) { return $null }
            $cur = Read-Dump $g.Dump
            if (-not $cur) { return $null }
            $same = $false
            $p = $script:twPrev
            if ($null -ne $p -and $p.Width -eq $cur.Width -and $p.Height -eq $cur.Height) {
                $same = [Linq.Enumerable]::SequenceEqual([byte[]]$p.Bytes, [byte[]]$cur.Bytes)
            }
            $script:twPrev = $cur
            if ($same) { $cur } else { $null }
        }
        if (-not $d) { throw "variant ${v}: the frame dump never settled" }
        Stop-OwnGhostty

        $png = Join-Path $outDir "text-weight-$v.png"
        Save-DumpPng $d $png

        # Geometry from the light row: its y span is one cell high, its x span is $n cells wide.
        $w = $d.Width; $h = $d.Height; $td = [bool]$d.TopDown; $bytes = [byte[]]$d.Bytes
        $y0 = -1
        for ($y = 0; $y -lt $h; $y++) {
            if (Test-Light $bytes $w $h $td 0 $y) { $y0 = $y; break }
        }
        if ($y0 -lt 0) { throw "variant ${v}: the light sample row is not in the dump" }
        $y1 = $y0
        while ($y1 -lt $h -and (Test-Light $bytes $w $h $td 0 $y1)) { $y1++ }
        $ch = $y1 - $y0
        $x1 = 0
        while ($x1 -lt $w -and (Test-Light $bytes $w $h $td $x1 $y0)) { $x1++ }
        $cw = $x1 / [double]$n
        if ($ch -lt 8 -or $cw -lt 4) { throw "variant ${v}: implausible cell size ${cw}x${ch}" }
        $top = $y0 - $light * $ch
        if ($top -lt 0) { throw "variant ${v}: the sample rows start above the dump (top=$top)" }
        $xEnd = [int][Math]::Floor($n * $cw)

        $crops[$v] = @{ Png = $png; X = 0; Y = $top; W = $xEnd; H = $rows.Count * $ch }
        for ($r = 0; $r -lt $rows.Count; $r++) {
            $fg = $rows[$r].Fg; $bg = $rows[$r].Bg
            $den = [Math]::Abs($fg[0] - $bg[0]) + [Math]::Abs($fg[1] - $bg[1]) + [Math]::Abs($fg[2] - $bg[2])
            $sum = 0.0
            $ry = $top + $r * $ch
            for ($y = $ry; $y -lt $ry + $ch; $y++) {
                $row = if ($td) { $y } else { $h - 1 - $y }
                $base = 54 + $row * $w * 4
                for ($x = 0; $x -lt $xEnd; $x++) {
                    $o = $base + $x * 4
                    $sum += [Math]::Abs($bytes[$o + 2] - $bg[0]) + [Math]::Abs($bytes[$o + 1] - $bg[1]) + [Math]::Abs($bytes[$o] - $bg[2])
                }
            }
            $c = $sum / $den / ($xEnd * $ch)
            $cov["$v$r"] = $c
            Write-E2eInfo ("text-weight $v $r coverage=" + $c.ToString('F5', $inv))
        }
    }

    # Contact sheet: the four crops stacked, each under a label bar.
    $labelH = 20
    $cropW = ($crops.Values | ForEach-Object { $_.W } | Measure-Object -Maximum).Maximum
    $sheetH = 0
    foreach ($v in $crops.Keys) { $sheetH += $labelH + $crops[$v].H }
    $sheet = New-Object System.Drawing.Bitmap $cropW, $sheetH
    $gfx = [System.Drawing.Graphics]::FromImage($sheet)
    try {
        $gfx.Clear([System.Drawing.Color]::FromArgb(40, 40, 40))
        $font = New-Object System.Drawing.Font('Segoe UI', 9)
        $y = 0
        $titles = @{ A = 'A  linear-corrected'; B = 'B  native'; C = 'C  linear-corrected + font-thicken'; D = 'D  native + font-thicken' }
        foreach ($v in $variants.Keys) {
            $gfx.DrawString($titles[$v], $font, [System.Drawing.Brushes]::White, 4, $y + 2)
            $y += $labelH
            $img = [System.Drawing.Image]::FromFile($crops[$v].Png)
            try {
                $src = New-Object System.Drawing.Rectangle $crops[$v].X, $crops[$v].Y, $crops[$v].W, $crops[$v].H
                $dst = New-Object System.Drawing.Rectangle 0, $y, $crops[$v].W, $crops[$v].H
                $gfx.DrawImage($img, $dst, $src, [System.Drawing.GraphicsUnit]::Pixel)
            } finally { $img.Dispose() }
            $y += $crops[$v].H
        }
        $font.Dispose()
    } finally { $gfx.Dispose() }
    $sheet.Save((Join-Path $outDir 'text-weight-sheet.png'), [System.Drawing.Imaging.ImageFormat]::Png)
    $sheet.Dispose()
    foreach ($f in 'A', 'B', 'C', 'D') {
        if (-not (Test-Path -LiteralPath (Join-Path $outDir "text-weight-$f.png"))) { throw "text-weight-$f.png is missing" }
    }

    # font-thicken must add ink on every row.
    $bad = @()
    for ($r = 0; $r -lt $rows.Count; $r++) {
        if ($cov["C$r"] -lt $cov["A$r"] - 1e-9) { $bad += "C<A row $r" }
        if ($cov["D$r"] -lt $cov["B$r"] - 1e-9) { $bad += "D<B row $r" }
    }
    if ($bad.Count) { throw "font-thicken lost ink: $($bad -join ', ')" }
}
