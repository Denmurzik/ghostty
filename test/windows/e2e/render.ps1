# render: the frame dump shows the configured background in the empty parts
# of the window, and text (the prompt) where it belongs.
. (Join-Path $PSScriptRoot '_common.ps1')

Invoke-E2eScenario 'render' {
    $bg = 0x10, 0x20, 0x30
    $g = Start-E2eGhostty
    $ready = Wait-Dump $g { param($d) $d.Width -gt 100 -and $d.Height -gt 100 } 15
    if (-not $ready) { throw "no frame dump at $($g.Dump) within 15 s" }

    # Wait for the shell prompt: some pixels differ from the background.
    $d = Wait-Dump $g {
        param($d) [GhosttyE2e.Win]::CountNotNear($d.Bytes, 54, $d.Width, $d.Height, 0x10, 0x20, 0x30, 2) -gt 20
    } 20
    if (-not $d) { throw 'the dump never showed anything but background (no prompt drawn)' }

    $w = $d.Width; $h = $d.Height
    $points = @(@(($w - 3), ($h - 3)), @(($w - 3), 2), @(($w / 2), ($h - 3)), @(2, ($h - 3)), @(($w - 3), ($h / 2)))
    foreach ($pt in $points) {
        $px = Get-DumpPixel $d ([int]$pt[0]) ([int]$pt[1])
        if (-not (Test-PixelNear $px $bg 2)) {
            throw ("pixel ({0},{1}) of the {2}x{3} dump is {4}, expected background #102030" -f $pt[0], $pt[1], $w, $h, (Format-Pixel $px))
        }
        if ($px.A -ne 255) { throw "pixel ($($pt[0]),$($pt[1])) is not opaque: $(Format-Pixel $px)" }
    }
    $client = Get-ClientSize $g.Hwnd
    Write-E2eInfo "dump ${w}x${h}, client $($client.Width)x$($client.Height), background ok at $($points.Count) points"
    Save-Evidence 'prompt' $g -Window
}
