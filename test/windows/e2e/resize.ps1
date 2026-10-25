# resize: SetWindowPos to 400x300 and then 1200x800; every size produces a
# dump that matches the client area and is clean at its edges, with no
# `error` line in ghostty.log.
. (Join-Path $PSScriptRoot '_common.ps1')

Invoke-E2eScenario 'resize' {
    $g = Start-E2eGhostty
    if (-not (Wait-Dump $g { param($d) $d.Width -gt 100 } 15)) { throw 'no frame dump within 15 s' }

    foreach ($size in @(@(400, 300), @(1200, 800), @(500, 350))) {
        Set-WindowSize $g.Hwnd $size[0] $size[1]
        $client = Get-ClientSize $g.Hwnd
        $d = Wait-Dump $g { param($d) $d.Width -eq $client.Width -and $d.Height -eq $client.Height } 10
        if (-not $d) {
            $last = Read-Dump $g.Dump
            throw "after SetWindowPos $($size[0])x$($size[1]) (client $($client.Width)x$($client.Height)) the dump is still $($last.Width)x$($last.Height)"
        }
        # Give the renderer a moment to repaint everything at the new size.
        Start-Sleep -Milliseconds 600
        $d = Read-Dump $g.Dump
        if ($d.Width -ne $client.Width -or $d.Height -ne $client.Height) {
            throw "dump changed to $($d.Width)x$($d.Height) while the client is $($client.Width)x$($client.Height)"
        }
        foreach ($pt in @(@(($d.Width - 2), ($d.Height - 2)), @(($d.Width - 2), 1), @(1, ($d.Height - 2)))) {
            $px = Get-DumpPixel $d $pt[0] $pt[1]
            if (-not (Test-PixelNear $px (0x10, 0x20, 0x30) 2)) {
                throw ("at {0}x{1}: pixel ({2},{3}) is {4}, expected background #102030" -f $d.Width, $d.Height, $pt[0], $pt[1], (Format-Pixel $px))
            }
        }
        Write-E2eInfo "client $($client.Width)x$($client.Height): dump matches, edges clean"
        Save-Evidence "$($size[0])x$($size[1])" $g -Window
        if (-not [GhosttyE2e.Win]::IsWindow($g.Hwnd) -or $g.Process.HasExited) { throw 'ghostty exited during the resize' }
    }

    $errors = @(Get-LogErrors $g)
    if ($errors.Count) { throw "ghostty.log has $($errors.Count) error line(s), first: $($errors[0])" }
}
